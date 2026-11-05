// DataRewindModel.swift
// Drives the Data Rewind sheet for the active tab: the recorded entries of this connection,
// the exact inverse SQL of the ones picked (`RewindPlanner`, against the live table), the Safe
// Mode confirmation, then one atomic batch through the gate (`executeGatedBatch`). Store reads
// and planning run off the main actor. Outside Protected mode the entries are rewound once the
// batch commits; under Protected mode (or inside the user's transaction) when that commits (D5).

import Foundation
import Observation

@Observable
@MainActor
final class DataRewindModel {
  /// What an entry shows, from its stored state and the transactions still open
  enum Status: Equatable {
    case committed
    /// Pending with no open transaction in this run (a quit, a crash, a connection lost during
    /// Commit): the rewind's checks decide
    case unconfirmed
    /// Pending in a transaction still open
    case inTransaction
    /// Undone by a rewind in a transaction still open (rewound on its Commit)
    case rewindPending
    case rewound
    case discarded

    var label: String {
      switch self {
      case .committed: "Committed"
      case .unconfirmed: "Unconfirmed"
      case .inTransaction: "In transaction"
      case .rewindPending: "Rewind pending"
      case .rewound: "Rewound"
      case .discarded: "Discarded"
      }
    }

    var isSelectable: Bool { self == .committed || self == .unconfirmed }
  }

  struct Item: Identifiable, Equatable {
    var entry: RewindEntry
    var status: Status
    var id: Int64 { entry.id }
  }

  enum Activity: Equatable {
    case loading
    case planning
    case rewinding
  }

  /// The commit style Safe Mode reads; tests replace it
  struct Environment {
    var commitStyle: @MainActor (NotebookViewModel) -> CommitStyle

    static let live = Environment(commitStyle: { viewModel in
      viewModel.notebook.connectionConfig?.resolvedCommitStyle(
        fallback: AppSettings.shared.commitStyle) ?? AppSettings.shared.commitStyle
    })
  }

  /// The active tab: its connection, protection policy, History and notebook id (`caller`)
  let viewModel: NotebookViewModel
  @ObservationIgnored private let environment: Environment

  private(set) var items: [Item] = []
  private(set) var selection: Set<Int64> = []
  /// The inverse of `selection`, nil while none is picked or planning failed
  private(set) var plan: RewindInverse?
  /// The user agreed to leave out the rows `plan.skipped` lists
  var skipConsent = false
  private(set) var activity: Activity?
  private(set) var isConfirming = false
  private(set) var confirmationRequiresPassword = false
  private(set) var confirmation: [StatementConfirmation] = []
  private(set) var errorMessage: String?
  private(set) var resultMessage: String?
  private(set) var engine: DatabaseType?

  @ObservationIgnored private var recorder: RewindRecorder?
  /// Connection the entries were read on (`executeGatedBatch` refuses another)
  @ObservationIgnored private var epoch: UInt64?
  /// Changes with every selection, so a late plan of an earlier one is dropped
  @ObservationIgnored private var planID = UUID()

  init(viewModel: NotebookViewModel, environment: Environment = .live) {
    self.viewModel = viewModel
    self.environment = environment
  }

  var isBusy: Bool { activity != nil }

  var dialect: SQLDialect { engine?.dialect ?? .postgresql }

  /// A plan with statements, every skipped row agreed to, nothing running or asking
  var canRewind: Bool {
    guard let plan, !plan.statements.isEmpty, !isBusy, !isConfirming else { return false }
    return plan.skipped.isEmpty || skipConsent
  }

  func status(of id: Int64) -> Status? {
    items.first { $0.id == id }?.status
  }

  // MARK: - Entries

  /// Reads this connection's entries (newest first) once every recorded write is stored
  func load() async {
    guard activity == nil else { return }
    errorMessage = nil
    guard let manager = viewModel.connectionManager, let config = await manager.config else {
      errorMessage = "No database connection available"
      return
    }
    guard config.databaseType.supportsDataRewind else {
      errorMessage = "Data Rewind is not available for \(config.databaseType.rawValue)."
      return
    }
    guard let recorder = await manager.dataRewindRecorder() else {
      errorMessage = "Data Rewind could not open its file, so no edits were recorded."
      return
    }
    self.recorder = recorder
    engine = config.databaseType
    epoch = await manager.connectionEpoch
    activity = .loading
    defer { activity = nil }
    let key = RewindEntry.connectionKey(for: config)
    do {
      let (entries, open, rewinding) = try await Task.detached(priority: .userInitiated) {
        await recorder.flushed()
        let open = await recorder.openEntryIDs()
        let rewinding = await recorder.rewindingEntryIDs()
        return (try recorder.store.entries(connectionKey: key), open, rewinding)
      }.value
      items = entries.map { entry in
        Item(entry: entry, status: Self.status(entry, open: open, rewinding: rewinding))
      }
    } catch {
      items = []
      errorMessage = error.localizedDescription
    }
    let selectable = Set(items.filter(\.status.isSelectable).map(\.id))
    if !selection.isSubset(of: selectable) {
      selection.formIntersection(selectable)
      plan = nil
    }
  }

  nonisolated static func status(
    _ entry: RewindEntry, open: Set<Int64>, rewinding: Set<Int64>
  ) -> Status {
    if rewinding.contains(entry.id) { return .rewindPending }
    switch entry.state {
    case .committed: return .committed
    case .pending: return open.contains(entry.id) ? .inTransaction : .unconfirmed
    case .rewound: return .rewound
    case .discarded: return .discarded
    }
  }

  // MARK: - Plan

  func toggle(_ id: Int64) async {
    var next = selection
    if next.remove(id) == nil { next.insert(id) }
    await setSelection(next)
  }

  /// Picks `ids` (only committed or unconfirmed entries) and plans their inverse: rows read off
  /// the main actor, the live columns from the catalog. The plan's preview (shown, confirmed and
  /// logged to History) masks the columns the connection's mask rules match; its binds keep the
  /// real values.
  func setSelection(_ ids: Set<Int64>) async {
    let chosen = items.filter { ids.contains($0.id) && $0.status.isSelectable }.map(\.entry)
    selection = Set(chosen.map(\.id))
    plan = nil
    skipConsent = false
    errorMessage = nil
    resultMessage = nil
    let id = UUID()
    planID = id
    guard !chosen.isEmpty, let recorder, let engine,
      let manager = viewModel.connectionManager
    else { return }
    activity = .planning
    defer { if planID == id { activity = nil } }
    do {
      let store = recorder.store
      let loaded = try await Task.detached(priority: .userInitiated) {
        try chosen.map { (entry: $0, rows: try store.rows(entryID: $0.id)) }
      }.value
      let rules = await manager.currentMaskRules()
      var tables: [RewindTableName: RewindTable] = [:]
      for entry in chosen {
        guard let schema = entry.schema else { continue }
        let name = RewindTableName(schema: schema, table: entry.table)
        guard tables[name] == nil else { continue }
        tables[name] = try await Self.rewindTable(
          name, engine: engine, manager: manager, hidesServerText: !rules.isEmpty)
      }
      let planned = try await Task.detached(priority: .userInitiated) {
        try RewindPlanner.plan(
          loaded, tables: tables, engine: engine, masks: ColumnMaskRuleSet(rules))
      }.value
      guard planID == id else { return }
      plan = planned
    } catch {
      guard planID == id else { return }
      errorMessage = error.localizedDescription
    }
  }

  /// The live columns of `name`: its table structure, or on PostgreSQL, where that reads only
  /// tables, the updatable view it names, resolved again through the edit path
  /// (`fetchEditTable`: the catalog checks, then the cached or newly probed map), so an entry
  /// read after a reconnect plans with an empty edit-target cache. Anything else that is not a
  /// table keeps the structure read's error; a failed view read (a probe's connect or timeout)
  /// says so. `hidesServerText`: the connection has mask rules (the plan can mask values), so
  /// that error shows only its SQLSTATE or type, never the server's text.
  private static func rewindTable(
    _ name: RewindTableName, engine: DatabaseType, manager: DatabaseConnectionManager,
    hidesServerText: Bool
  ) async throws -> RewindTable {
    do {
      return RewindTable(
        try await manager.fetchTableStructure(schema: name.schema, table: name.table))
    } catch DatabaseError.metadataPausedDuringTransaction {
      throw DataRewindError.transactionPending
    } catch {
      let structureError = error
      let dialect = SQLDialect.postgresql
      guard engine == .postgresql,
        let relation = try? dialect.quoteIdentifier(name.schema) + "."
          + dialect.quoteIdentifier(name.table)
      else { throw structureError }
      let view: EditTable?
      do {
        view = try await manager.fetchEditTable(tableName: relation)
      } catch DatabaseError.metadataPausedDuringTransaction {
        throw DataRewindError.transactionPending
      } catch {
        let reason =
          hidesServerText && carriesServerText(error)
          ? (DatabaseConnectionManager.serverSQLState(error).map { "SQLSTATE \($0)" }
            ?? "\(type(of: error))") + " (its message is hidden, as it can show a masked value)"
          : error.localizedDescription
        throw DataRewindError.viewUnreadable(
          name: "\(name.schema).\(name.table)", reason: reason)
      }
      guard let view, view.viewBase != nil, view.schema == name.schema, view.name == name.table
      else { throw structureError }
      return RewindTable(view: view)
    }
  }

  // MARK: - Rewind

  /// Checks the gate's answer, then asks Safe Mode when the commit style confirms writes, or
  /// runs the rewind at once
  func rewind() async {
    guard canRewind, let plan else { return }
    errorMessage = nil
    resultMessage = nil
    if case .blocked(let index, _, let reason) = DatabaseConnectionManager.evaluateBatch(
      plan.statements, policy: viewModel.protectionPolicy, dialect: dialect)
    {
      errorMessage = "Statement \(index + 1): \(reason)"
      return
    }
    let style = environment.commitStyle(viewModel)
    if let statements = NotebookViewModel.statementsNeedingConfirmation(
      SQLStatementClassifier.classify(plan.preview, dialect: dialect), commitStyle: style,
      dialect: dialect)
    {
      confirmation = statements
      confirmationRequiresPassword = style.requiresPassword
      isConfirming = true
      return
    }
    await run(plan)
  }

  /// Safe Mode said yes (the confirmation panel checked Touch ID or the password)
  func confirmRewind() async {
    guard isConfirming, activity == nil, let plan else { return }
    cancelConfirmation()
    await run(plan)
  }

  func cancelConfirmation() {
    isConfirming = false
    confirmationRequiresPassword = false
    confirmation = []
  }

  /// The sheet went away: a late Safe Mode answer rewinds nothing, a late plan is dropped
  func sheetDisappeared() {
    cancelConfirmation()
    planID = UUID()
    // The running plan's `defer` no longer matches `planID`
    if activity == .planning { activity = nil }
  }

  private func run(_ plan: RewindInverse) async {
    guard let manager = viewModel.connectionManager, let epoch else {
      errorMessage = "No database connection available"
      return
    }
    activity = .rewinding
    let started = Date()
    let outcome: QueryHistoryOutcome
    do {
      let counts = try await manager.executeGatedBatch(
        plan.statements, policy: viewModel.protectionPolicy, connectionEpoch: epoch,
        caller: viewModel.id, rewind: nil, rewinding: plan.entryIDs)
      outcome = QueryHistoryOutcome(
        sql: Self.historySQL(plan), duration: Date().timeIntervalSince(started),
        rowCount: counts.reduce(0, +), status: .success, errorMessage: nil)
      let appTransaction = await !manager.transactionStatus().state.isIdle
      let userTransaction = await manager.userTxOpen
      resultMessage = Self.rewoundMessage(plan, pending: appTransaction || userTransaction)
    } catch {
      let message = Self.failureMessage(error, plan: plan)
      errorMessage = message
      outcome = QueryHistoryOutcome(
        sql: Self.historySQL(plan), duration: Date().timeIntervalSince(started), rowCount: nil,
        status: DatabaseBackupModel.historyStatus(for: error), errorMessage: message)
    }
    activity = nil
    await viewModel.recordExecution([outcome], source: .rewind)
    // Pending transaction banner, and the edited grids
    await viewModel.onStatementsExecuted?()
    let (result, failure) = (resultMessage, errorMessage)
    selection = []
    self.plan = nil
    skipConsent = false
    await load()
    resultMessage = result
    errorMessage = errorMessage ?? failure
  }

  /// The History text of `plan`: its preview, or, when it shows mask text
  /// (`RewindInverse.masksValues`), the preview commented out line by line, so Insert, Copy or
  /// the command palette never put a runnable statement that writes mask text back.
  nonisolated static func historySQL(_ plan: RewindInverse) -> String {
    guard plan.masksValues else { return plan.preview }
    let lines = plan.preview.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    return (["Data Rewind with masked values, not runnable"] + lines.map(String.init))
      .map { "-- " + $0 }.joined(separator: "\n")
  }

  private static func rewoundMessage(_ plan: RewindInverse, pending: Bool) -> String {
    let count = "\(plan.statements.count) statement\(plan.statements.count == 1 ? "" : "s")"
    if pending {
      return "Rewound with \(count) in the open transaction: Commit to keep it or Roll Back."
    }
    return "Rewound with \(count)."
  }

  /// Which row stopped the rewind (the batch rolled back to before it), or the error. Only a
  /// row count off the expected one (a failed check) means the row changed since the edit.
  /// A plan that shows mask text never shows the server's text, which can echo a masked value
  /// (a duplicate key, a failed check): only its error code, when it leads the text.
  nonisolated static func failureMessage(_ error: Error, plan: RewindInverse) -> String {
    guard case DatabaseError.batchStatementFailed(let index, _, let reason, _) = error,
      plan.origins.indices.contains(index)
    else {
      guard plan.masksValues, carriesServerText(error) else {
        return "Nothing was rewound: \(error.localizedDescription)"
      }
      return "Nothing was rewound: \(hiddenServerText(nil))."
    }
    let origin = plan.origins[index]
    let time = origin.created.formatted(date: .abbreviated, time: .standard)
    let row = origin.key.isEmpty ? "a row of \(origin.table)" : "\(origin.table) row \(origin.key)"
    let edited = "\(row) (\(origin.operation.rawValue) at \(time))"
    guard reason.hasPrefix(DatabaseConnectionManager.unexpectedRowCountReason) else {
      let shown = plan.masksValues ? hiddenServerText(reason) : reason
      return "Nothing was rewound: \(edited) could not be rewound: \(shown). "
        + "The whole rewind was rolled back."
    }
    return "Nothing was rewound: \(edited) changed since the edit (\(reason)). "
      + "The whole rewind was rolled back."
  }

  /// "the database refused it with ERROR 23505 (…)" for a plan that shows mask text: the code
  /// that leads `reason` (PostgreSQL `ERROR 23505: …`, MySQL `ERROR 1062 (23000): …`), never
  /// the rest of the text
  private nonisolated static func hiddenServerText(_ reason: String?) -> String {
    let code = reason?.firstMatch(
      of: /^(?:ERROR|FATAL|PANIC) (?:[0-9]+ \([0-9A-Z]{5}\)|[0-9A-Z]{5}):/
    ).map { " with " + String($0.output.dropLast()) }
    return "the database refused it\(code ?? "") (its message is hidden, as it can show a "
      + "masked value)"
  }

  /// An error whose text can hold the server's or the driver's (which can echo a masked value):
  /// every case that wraps such text, and any error Dblore does not know. Dblore's own refusals
  /// (protection, cancel, locks) keep their text. No `default`, so a new case must be sorted.
  private nonisolated static func carriesServerText(_ error: Error) -> Bool {
    guard let error = error as? DatabaseError else {
      return !(error is DataRewindError || error is CancellationError)
    }
    switch error {
    case .connectionFailed, .queryFailed, .transactionAborted, .connectionLost,
      .batchStatementFailed, .schemaChangePartiallyApplied, .batchPartiallyApplied:
      return true
    case .notConnected, .emptyQuery, .blockedByProtection, .missingParameters, .mixedPlaceholders,
      .notEditable, .transactionPendingInAnotherTab, .metadataPausedDuringTransaction,
      .editRowCountMismatch, .batchCancelled, .schemaChangeRefused, .sequentialBatchRefused,
      .commitRefusedTransactionChanged, .transactionEnding, .rollbackRefusedStatementRunning,
      .queryCancelled, .sessionChanged, .sshCredentialMissing, .sshHostKeyNotTrusted,
      .sshHostKeyChanged, .sshHostKeyStoreUnreadable, .passwordStoreUnreadable,
      .passwordRequiredOnConnect, .passwordNotHeldByWorkspace, .passwordSourcesMixed,
      .sshHostKeyPinFailed, .sshAuthenticationFailed, .sshUnsupportedHostKeyAlgorithm,
      .sshHandshakeTimedOut, .engineUnavailable, .connectionLocked:
      return false
    }
  }
}

nonisolated enum DataRewindError: LocalizedError, Equatable {
  /// Catalog reads wait while a transaction is pending
  case transactionPending
  /// The view's edit target could not be read; `reason` holds no server text when masked
  case viewUnreadable(name: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .transactionPending:
      "Commit or roll back the pending transaction first: the table's columns cannot be read "
        + "while it is open."
    case .viewUnreadable(let name, let reason):
      "Could not read view \(name): \(reason)"
    }
  }
}
