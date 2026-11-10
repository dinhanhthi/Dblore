// DatabaseBackupModel.swift
// Drives the SQL dump, SQLite file copy and restore sheets for the active tab. The dump opens
// its own connection (`SQLDumpWriter`) from the tab manager's in-memory config, unremembered
// certificate and SSH secret, and host-key prompt (DuckDB: it reads on the tab's own manager
// instead, never a second instance); the restore checks the file in chunks off the main actor
// (pass 1), then runs it on the tab's connection through the gate (`executeGatedRestore`, which
// reads it again, pass 2) after the Safe Mode confirmation, holding the file's security-scoped
// access from pass 1 until the run ends. Progress callbacks arrive off the main actor and hop
// back here. One History row per dump and per restore (success, failure, cancel) when History
// is on.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The dump sheet's database row for Structure, Data or Drop: on for every table, for none, or
/// for some (the checkbox shows a dash)
nonisolated enum SQLDumpTriState: Sendable, Equatable {
  case all
  case none
  case mixed
}

nonisolated enum DatabaseBackupError: LocalizedError, Equatable, Sendable {
  case notUTF8

  var errorDescription: String? {
    switch self {
    case .notUTF8:
      "This file is not UTF-8 text, so it is not a Dblore SQL dump. Nothing was executed."
    }
  }
}

@Observable
@MainActor
final class DatabaseBackupModel {
  enum Activity: Equatable {
    case dumping
    case copying
    case reading
    case restoring
  }

  /// Panels, the dump connection and the file copy; tests replace them
  struct Environment {
    /// Save panel with a suggested name and file extension; nil when cancelled
    var chooseSaveURL: @MainActor (_ suggestedName: String, _ fileExtension: String) async -> URL?
    /// Open panel for a dump file; nil when cancelled
    var chooseOpenURL: @MainActor () async -> URL?
    /// The tab's in-memory config, the tab manager's unremembered certificate and SSH secret,
    /// and the host-key prompt the tab's manager was built with
    var makeDumpWriter:
      @MainActor (
        ConnectionConfig, ClientCertificateStoreFactory.ConnectionMaterial?,
        SSHCredentialStoreFactory.ConnectionCredential?, any SSHHostKeyPrompt
      ) -> SQLDumpWriter
    /// DuckDB: the tab's own manager and in-memory config (the dump reads on the tab's session)
    var makeTabDumpWriter: @MainActor (DatabaseConnectionManager, ConnectionConfig) -> SQLDumpWriter
    var copyDatabase:
      @Sendable (URL, URL, @escaping @Sendable (SQLiteFileBackup.Progress) -> Void) async throws
        -> SQLiteFileBackup.Progress
    /// The tab's commit style (Safe Mode), as the query confirmation reads it
    var commitStyle: @MainActor (NotebookViewModel) -> CommitStyle
    /// Checks a restore file (`readPlan`, pass 1), run off the main actor, reporting how far
    var readRestorePlan:
      @Sendable (URL, DatabaseType, @escaping @Sendable (SQLRestoreReadProgress) -> Void)
        async throws -> (SQLRestorePlan, Int)
    /// Starts the restore file's security-scoped access (kept from pass 1 until the run ends)
    var startAccess: @MainActor (URL) -> SecurityScopedAccessToken

    static let live = Environment(
      chooseSaveURL: { await DatabaseBackupModel.showSavePanel(name: $0, fileExtension: $1) },
      chooseOpenURL: { await DatabaseBackupModel.showOpenPanel() },
      makeDumpWriter: { config, material, credential, prompt in
        SQLDumpWriter(
          config: config, material: material, sshCredential: credential, sshHostKeyPrompt: prompt)
      },
      makeTabDumpWriter: { SQLDumpWriter(tabManager: $0, config: $1) },
      copyDatabase: { source, destination, progress in
        try await SQLiteFileBackup.copy(from: source, to: destination, progress: progress)
      },
      commitStyle: { viewModel in
        viewModel.notebook.connectionConfig?.resolvedCommitStyle(
          fallback: AppSettings.shared.commitStyle) ?? AppSettings.shared.commitStyle
      },
      readRestorePlan: { try DatabaseBackupModel.readPlan(url: $0, engine: $1, progress: $2) },
      startAccess: { SecurityScopedAccessToken(url: $0) })
  }

  /// The active tab: its connection, protection policy, History and notebook id (`caller`)
  let viewModel: NotebookViewModel
  @ObservationIgnored private let environment: Environment

  private(set) var activity: Activity?
  private(set) var dumpProgress: SQLDumpProgress?
  private(set) var copyProgress: SQLiteFileBackup.Progress?
  private(set) var restoreProgress: SQLRestoreProgress?
  /// How far the restore file's read and plan are, while `activity` is `.reading`
  private(set) var restoreReadProgress: SQLRestoreReadProgress?
  private(set) var restoreFileName: String?
  private(set) var restoreFileSize: Int?
  private(set) var restorePlan: SQLRestorePlan?
  /// Why the gate would refuse the loaded restore, shown before any confirmation
  private(set) var restoreBlockedReason: String?
  /// Safe Mode asks before the restore runs
  private(set) var isConfirmingRestore = false
  private(set) var confirmationRequiresPassword = false
  /// What Safe Mode shows while it asks: every statement but the rows (`restoreConfirmation`)
  private(set) var restoreConfirmation: [StatementConfirmation] = []
  /// The loaded plan ran to the end (running it again would restore twice)
  private(set) var restoreCompleted = false
  private(set) var errorMessage: String?
  /// What the last finished operation did
  private(set) var resultMessage: String?

  /// Stops the running dump, copy or file read (a restore stops through the connection)
  @ObservationIgnored private var cancelWork: (() -> Void)?
  /// Changes with every operation, so late progress of an earlier one is dropped
  @ObservationIgnored private var operationID = UUID()
  /// Connection the restore plan was read for (`executeGatedRestore` refuses another)
  @ObservationIgnored private var planEpoch: UInt64?
  /// The restore's own batch is running (`executeGatedRestore` has not returned). The connection
  /// is shared by every tab: once the batch returned, whatever runs there belongs to another tab,
  /// so Cancel (or the sheet going away) must not stop it.
  @ObservationIgnored private var restoreBatchInFlight = false
  /// The restore file's security-scoped access: taken before pass 1, released when another file
  /// is chosen, the read fails or stops, the sheet goes away, or the run ends
  @ObservationIgnored private var restoreAccess: SecurityScopedAccessToken?
  /// `restore()` is checking the gate's answer off the main actor (`activity` is `.restoring`):
  /// Cancel or the sheet going away stops it before anything runs
  @ObservationIgnored private var checkingRestore = false

  init(viewModel: NotebookViewModel, environment: Environment = .live) {
    self.viewModel = viewModel
    self.environment = environment
  }

  var isBusy: Bool { activity != nil }

  // MARK: - Dump

  /// Asks where to save, then dumps. A destination that is the open SQLite file or one of its
  /// journal files is refused before any connection is made.
  func exportDump(options: SQLDumpOptions) async {
    guard activity == nil else { return }
    clearMessages()
    guard let manager = viewModel.connectionManager, let config = await manager.config else {
      errorMessage = "No database connection available"
      return
    }
    guard
      let destination = await environment.chooseSaveURL(Self.baseName(config) + ".sql", "sql")
    else { return }
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
      errorMessage = SQLDumpError.destinationIsDatabase.localizedDescription
      return
    }
    let writer =
      config.databaseType == .duckdb
      ? environment.makeTabDumpWriter(manager, config)
      : environment.makeDumpWriter(
        config, await manager.activeUnrememberedCertificate,
        await manager.activeUnrememberedSSHCredential, manager.sshHostKeyPolicy.prompt)
    let id = begin(.dumping)
    let runningWork = beginRunningWork("SQL dump of \(Self.baseName(config))", kind: .dump)
    defer { RunningWorkRegistry.shared.end(runningWork) }
    dumpProgress = SQLDumpProgress(tablesDone: 0, tableCount: 0, rowsWritten: 0)
    let started = ContinuousClock.now
    let report = reporter(id, .dumping) { $0.dumpProgress = $1 }
    let work = Task { try await writer.write(to: destination, options: options, progress: report) }
    cancelWork = { work.cancel() }
    let status: QueryHistoryEntry.Status
    var failure: String?
    do {
      let final = try await work.value
      dumpProgress = final
      status = .success
      resultMessage =
        "Saved \(destination.lastPathComponent): \(Self.counted(final.tablesDone, "table")), "
        + "\(Self.counted(final.rowsWritten, "row"))."
        + (final.foreignKeyCycle
          ? " The tables' foreign keys form a cycle, so a restore into a database that has them"
            + " may fail on a foreign key." : "")
    } catch {
      status = Self.historyStatus(for: error)
      failure = error.localizedDescription
      if status == .cancelled {
        resultMessage = "Dump cancelled. Nothing was saved."
      } else {
        errorMessage = failure
      }
    }
    let progress = dumpProgress ?? SQLDumpProgress(tablesDone: 0, tableCount: 0, rowsWritten: 0)
    await recordHistory(started: started) { workspaceID, workspaceName, duration in
      QueryHistoryEntry.dumpSummary(
        progress, config: config, workspaceID: workspaceID, workspaceName: workspaceName,
        durationMs: duration, status: status, errorMessage: failure)
    }
    end(id)
  }

  /// SQLite only: asks where to save, then copies the database file (`sqlite3_backup`). A
  /// relocked database (the manager's `lockSource`) is refused before the panel, after it and
  /// just before the copy starts.
  func copyDatabaseFile() async {
    guard activity == nil else { return }
    clearMessages()
    guard let manager = viewModel.connectionManager, let config = await manager.config,
      config.databaseType == .sqlite
    else {
      errorMessage = "No SQLite database is open"
      return
    }
    let lockSource = manager.lockSource
    if let refusal = lockSource.refusal(for: config) {
      errorMessage = refusal.localizedDescription
      return
    }
    guard
      let destination = await environment.chooseSaveURL(
        Self.baseName(config) + " copy.sqlite", "sqlite")
    else { return }
    if let refusal = lockSource.refusal(for: config) {
      errorMessage = refusal.localizedDescription
      return
    }
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
      errorMessage = SQLiteFileBackupError.destinationIsDatabase.localizedDescription
      return
    }
    let id = begin(.copying)
    copyProgress = nil
    let source = URL(fileURLWithPath: config.database)
    let runningWork = beginRunningWork("Copy of \(source.lastPathComponent)", kind: .dump)
    defer { RunningWorkRegistry.shared.end(runningWork) }
    let copy = environment.copyDatabase
    let report = reporter(id, .copying) { $0.copyProgress = $1 }
    let work = Task {
      if let refusal = lockSource.refusal(for: config) { throw refusal }
      return try await copy(source, destination, report)
    }
    cancelWork = { work.cancel() }
    do {
      copyProgress = try await work.value
      resultMessage = "Saved \(destination.lastPathComponent)."
    } catch {
      if Self.historyStatus(for: error) == .cancelled {
        resultMessage = "Copy cancelled. Nothing was saved."
      } else {
        errorMessage = error.localizedDescription
      }
    }
    end(id)
  }

  /// The listed tables' flags as dump options. A table without an entry, or with Structure and
  /// Data off, is left out; nil tables when none is, so the dump also keeps tables the sidebar
  /// does not list. Those (and partitions the dump adds) get Structure and Data unless no chosen
  /// table has it, Drop only when every chosen table has it (no chosen table: the defaults).
  nonisolated static func dumpOptions(
    _ flags: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions], from tables: [DatabaseTable]
  ) -> SQLDumpOptions {
    let chosen = flags.filter { $0.value.structure || $0.value.data }
    let all = Set(tables.map { SQLDumpDDL.ObjectName(schema: $0.schema, name: $0.name) })
    let other =
      chosen.isEmpty
      ? SQLDumpOptions.TableOptions()
      : SQLDumpOptions.TableOptions(
        structure: databaseRow(\.structure, of: chosen) != .none,
        data: databaseRow(\.data, of: chosen) != .none,
        drop: databaseRow(\.drop, of: chosen) == .all)
    return SQLDumpOptions(
      tables: all.isSubset(of: Set(chosen.keys)) ? nil : Set(chosen.keys),
      perTable: chosen.filter { $0.value != other }, otherTables: other)
  }

  /// Every listed table's flags (its override, else the "All tables" `baseline`; Drop only with
  /// Structure) as dump options, off the main actor. No listed table: the defaults.
  @concurrent nonisolated static func dumpOptions(
    _ tables: [DatabaseTable], baseline: SQLDumpOptions.TableOptions,
    overrides: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions]
  ) async -> SQLDumpOptions {
    guard !tables.isEmpty else { return SQLDumpOptions() }
    let flags = Dictionary(
      tables.map { table in
        let name = SQLDumpDDL.ObjectName(schema: table.schema, name: table.name)
        var options = overrides[name] ?? baseline
        if !options.structure { options.drop = false }
        return (name, options)
      }, uniquingKeysWith: { first, _ in first })
    return dumpOptions(flags, from: tables)
  }

  /// The database row's checkbox for `flag` (Structure, Data or Drop) over the tables' flags
  nonisolated static func databaseRow(
    _ flag: KeyPath<SQLDumpOptions.TableOptions, Bool>,
    of flags: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions]
  ) -> SQLDumpTriState {
    let on = flags.values.filter { $0[keyPath: flag] }.count
    if on == 0 { return .none }
    return on == flags.count ? .all : .mixed
  }

  /// The database row set to `on`: `flag` on or off for every table beneath it
  static func settingDatabaseRow(
    _ flag: WritableKeyPath<SQLDumpOptions.TableOptions, Bool>, to on: Bool,
    in flags: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions]
  ) -> [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions] {
    flags.mapValues {
      var table = $0
      table[keyPath: flag] = on
      return table
    }
  }

  // MARK: - Restore

  func chooseRestoreFile() async {
    guard activity == nil, let url = await environment.chooseOpenURL() else { return }
    await loadRestore(from: url)
  }

  /// Checks `url` off the main actor (pass 1, in chunks), for the connected engine and connection,
  /// then the gate's answer there too, under the policy when the read started
  func loadRestore(from url: URL) async {
    guard activity == nil else { return }
    clearMessages()
    releaseRestoreAccess()
    restorePlan = nil
    restoreBlockedReason = nil
    restoreProgress = nil
    restoreReadProgress = nil
    isConfirmingRestore = false
    restoreCompleted = false
    restoreFileName = url.lastPathComponent
    restoreFileSize = nil
    guard let manager = viewModel.connectionManager, let engine = await manager.databaseType else {
      errorMessage = "No database connection available"
      return
    }
    let epoch = await manager.connectionEpoch
    restoreAccess = environment.startAccess(url)
    let id = begin(.reading)
    let read = environment.readRestorePlan
    let report = reporter(id, .reading) { $0.restoreReadProgress = $1 }
    let policy = viewModel.protectionPolicy
    let config = viewModel.notebook.connectionConfig
    let work = Task.detached(priority: .userInitiated) {
      let (plan, size) = try await read(url, engine, report)
      return (plan, size, Self.restoreBlockReason(plan, policy: policy, config: config))
    }
    cancelWork = { work.cancel() }
    do {
      let (plan, size, blockedReason) = try await work.value
      if operationID == id {
        restorePlan = plan
        restoreFileSize = size
        planEpoch = epoch
        restoreBlockedReason = blockedReason
      }
    } catch {
      if operationID == id {
        releaseRestoreAccess()
        if Self.historyStatus(for: error) != .cancelled {
          errorMessage = error.localizedDescription
        }
      }
    }
    end(id)
  }

  /// Checks the gate's answer, then asks Safe Mode when the commit style confirms writes (Confirm
  /// and Password ask for every non-empty restore: a restore always writes, even one of only
  /// sequence values or session settings), or runs the restore at once. The click shows the
  /// restore starting at once; the gate's answer walks every statement (millions for a dump of
  /// one INSERT per row), so it is worked out off the main actor.
  func restore() async {
    guard activity == nil, !isConfirmingRestore, !restoreCompleted, let plan = restorePlan else {
      return
    }
    clearMessages()
    // A failed run's count would show during the check
    restoreProgress = nil
    let id = begin(.restoring)
    checkingRestore = true
    let policy = viewModel.protectionPolicy
    let config = viewModel.notebook.connectionConfig
    let blockedReason = await Task.detached(priority: .userInitiated) {
      Self.restoreBlockReason(plan, policy: policy, config: config)
    }.value
    // Cancel, or the sheet going away, stopped the check: nothing runs
    guard operationID == id else { return }
    checkingRestore = false
    end(id)
    restoreBlockedReason = blockedReason
    guard restoreBlockedReason == nil else { return }
    let style = environment.commitStyle(viewModel)
    if plan.summary.statementCount > 0, style == .confirm || style == .password {
      confirmationRequiresPassword = style.requiresPassword
      restoreConfirmation = Self.restoreConfirmation(plan)
      isConfirmingRestore = true
      return
    }
    await runRestore(plan)
  }

  /// Safe Mode said yes (the confirmation panel checked Touch ID or the password)
  func confirmRestore() async {
    guard isConfirmingRestore, activity == nil, let plan = restorePlan else { return }
    cancelRestoreConfirmation()
    await runRestore(plan)
  }

  func cancelRestoreConfirmation() {
    isConfirmingRestore = false
    confirmationRequiresPassword = false
    restoreConfirmation = []
  }

  /// The Safe Mode list of a restore: every statement but the rows (each DROP, schema,
  /// triggers, sequence values, session settings), each with its text on one line (comments
  /// dropped, whitespace runs collapsed), cut as the query confirmation cuts it. A cut row and
  /// every trigger also carry their whole text (`fullText`, behind "Show full statement") and a note: how much the
  /// preview leaves out, and for a trigger the table whose writes run its body. INSERTs (and
  /// SQLite's `DELETE FROM sqlite_sequence`) stay a count. A file-backed plan's rows were built
  /// the same way in pass 1 (`SQLRestorePlan.confirmationRows`).
  nonisolated static func restoreConfirmation(_ plan: SQLRestorePlan) -> [StatementConfirmation] {
    guard case .memory(let statements) = plan.source else { return plan.confirmationRows }
    let dialect = plan.engine.dialect
    return zip(statements, plan.kinds).enumerated().compactMap { index, pair in
      restoreConfirmationRow(pair.0, kind: pair.1, index: index, dialect: dialect)
    }
  }

  /// The Safe Mode row of restore statement `index` (`restoreConfirmation`), nil for data
  nonisolated static func restoreConfirmationRow(
    _ statement: ClassifiedStatement, kind: SQLRestoreStatementKind, index: Int,
    dialect: SQLDialect
  ) -> StatementConfirmation? {
    let label: String
    switch kind {
    case .data: return nil
    case .drop: label = "Drop"
    case .schema: label = "Schema"
    case .trigger: label = "Trigger"
    case .sequenceValue: label = "Sequence value"
    case .sessionSetting: label = "Session setting"
    }
    let line = NotebookViewModel.collapsedLine(statement.text, dialect: dialect)
    let omitted = NotebookViewModel.previewOmittedCount(line)
    var notes: [String] = []
    if kind == .trigger {
      let table = SQLRestorePlan.triggerTable(statement.text) ?? "its table"
      notes.append("Trigger body runs on every later write to \(table)")
    }
    if omitted > 0 {
      notes.append("Statement continues for \(omitted.formatted()) more characters")
    }
    var row = StatementConfirmation(
      index: index, preview: NotebookViewModel.oneLinePreview(statement.text, dialect: dialect),
      kindLabel: label, affectsAllRows: statement.affectsAllRows,
      touchesBrake: statement.resetsSessionBrakes,
      changesPrivileges: statement.changesPrivileges)
    row.isTruncated = omitted > 0
    if !notes.isEmpty {
      row.fullText = statement.text
      row.fullTextNotes = notes
    }
    return row
  }

  /// Why the gate would refuse `plan` under `policy` (the connection's own policy; the
  /// connection still decides when it runs), or nil. `config`: the tab's connection, for a
  /// DuckDB file opened read-only.
  nonisolated static func restoreBlockReason(
    _ plan: SQLRestorePlan, policy: ProtectionPolicy, config: ConnectionConfig? = nil
  ) -> String? {
    if policy.protectionLevel == .readOnly {
      if let config, SQLRestorePlan.isReadOnlyDuckDBFile(config) {
        return SQLRestorePlan.duckdbReadOnlyFileMessage
      }
      return "This connection is read-only: restoring a SQL dump is not allowed."
    }
    if plan.engine == .mysql, policy.protectedMode {
      return "Turn Protected mode off for this connection to restore a MySQL dump: MySQL commits "
        + "each schema change at once, so the restore cannot wait for Commit."
    }
    if plan.engine == .duckdb, policy.protectedMode {
      return SQLRestorePlan.duckdbProtectedModeMessage
    }
    if case .blocked(let index, _, let reason) = DatabaseConnectionManager.evaluate(
      plan.gateStatements, policy: policy, dialect: plan.engine.dialect)
    {
      return "Statement \(index + 1): \(reason)"
    }
    return nil
  }

  private func runRestore(_ plan: SQLRestorePlan) async {
    guard let manager = viewModel.connectionManager, let epoch = planEpoch,
      let config = await manager.config
    else {
      errorMessage = "No database connection available"
      return
    }
    // Released after an earlier run: a retry reads the file again
    if restoreAccess == nil, case .file(let url, _) = plan.source {
      restoreAccess = environment.startAccess(url)
    }
    let id = begin(.restoring)
    let runningWork = beginRunningWork(
      "Restore of \(restoreFileName ?? "a SQL file")", kind: .restore(plan.engine)
    ) { [weak self] in
      self?.confirmingRestoreCancel() ?? Task { false }
    }
    defer { RunningWorkRegistry.shared.end(runningWork) }
    restoreProgress = SQLRestoreProgress(
      statementsDone: 0, statementCount: plan.summary.statementCount)
    let started = ContinuousClock.now
    var summary = plan.summary
    let status: QueryHistoryEntry.Status
    var failure: String?
    do {
      restoreBatchInFlight = true
      defer { restoreBatchInFlight = false }
      summary = try await manager.executeGatedRestore(
        plan, policy: viewModel.protectionPolicy, connectionEpoch: epoch, caller: viewModel.id,
        access: restoreAccess, progress: reporter(id, .restoring) { $0.restoreProgress = $1 })
      status = .success
      restoreCompleted = true
      restoreProgress = SQLRestoreProgress(
        statementsDone: summary.statementsRun, statementCount: summary.statementCount)
      resultMessage = Self.restoredMessage(summary)
    } catch {
      status = Self.historyStatus(for: error)
      failure = error.localizedDescription
      if status == .cancelled {
        resultMessage = "Restore cancelled."
      } else {
        errorMessage = failure
      }
    }
    releaseRestoreAccess()
    await recordHistory(started: started) { workspaceID, workspaceName, duration in
      QueryHistoryEntry.restoreSummary(
        summary, config: config, workspaceID: workspaceID, workspaceName: workspaceName,
        durationMs: duration, status: status, errorMessage: failure)
    }
    // Pending transaction banner and the sidebar's tables
    await viewModel.onStatementsExecuted?()
    end(id)
  }

  private static func restoredMessage(_ summary: SQLRestoreSummary) -> String {
    let count = counted(summary.statementsRun, "statement")
    if summary.pending {
      return "Restored \(count) into the pending transaction: Commit to keep them or Roll Back."
    }
    if summary.insideUserTransaction {
      return "Restored \(count) inside your open transaction: they stay only if you commit it."
    }
    return "Restored \(count)."
  }

  /// Pass 1 of a restore: the file checked in chunks for `engine` (`SQLRestorePlan(file:)`),
  /// never read whole. The caller holds the file's security-scoped access from here until the
  /// run ends. `progress` gets the bytes checked of the file's size after each chunk. Returns the
  /// plan and the bytes read. `maxStatementBytes` and `maxConfirmationBytes` are the plan's caps.
  nonisolated static func readPlan(
    url: URL, engine: DatabaseType, maxStatementBytes: Int = SQLRestorePlan.maxStatementBytes,
    maxConfirmationBytes: Int = SQLRestorePlan.maxConfirmationBytes,
    progress: (SQLRestoreReadProgress) -> Void = { _ in }
  ) throws -> (SQLRestorePlan, Int) {
    var bytes = 0
    let plan = try PerfSignpost.interval("restore.plan") {
      try SQLRestorePlan(
        file: url, engine: engine, maxStatementBytes: maxStatementBytes,
        maxConfirmationBytes: maxConfirmationBytes
      ) { report in
        if case .reading(let bytesRead, _) = report { bytes = bytesRead }
        progress(report)
      }
    }
    return (plan, bytes)
  }

  // MARK: - Cancel

  /// The sheet went away (closed, or its tab closed while it worked): a late Safe Mode answer
  /// restores nothing, and the running dump, copy, read or restore stops (a read at once). The
  /// restore file's access ends now, or when the stopped run ends.
  func sheetDisappeared() {
    cancelRestoreConfirmation()
    switch activity {
    case .reading: stopReading()
    case nil: releaseRestoreAccess()
    case .restoring where checkingRestore:
      stopRestoreCheck()
      releaseRestoreAccess()
    case .dumping, .copying, .restoring: Task { await cancel() }
    }
  }

  /// Stops the running operation: a dump, copy or read by task cancellation, a restore through
  /// the connection (as Stop does for a running statement), only while the restore's own batch
  /// runs (afterwards it only records History and refreshes the tab). A cancelled read ends at
  /// once: its plan, if planning still finishes, is dropped; so does the restore's gate check.
  func cancel() async {
    switch activity {
    case .restoring:
      if checkingRestore {
        stopRestoreCheck()
        return
      }
      guard restoreBatchInFlight else { return }
      _ = await viewModel.cancelRunningStatement(cancelQueue: false)
    case .reading:
      stopReading()
    case .dumping, .copying:
      cancelWork?()
    case nil:
      break
    }
  }

  /// The restore's Cancel for the running-work prompt's Stop, with `cancel()`'s guards: its
  /// task is true when the restore statement's warning was answered "Keep running"
  private func confirmingRestoreCancel() -> Task<Bool, Never> {
    guard activity == .restoring else { return Task { false } }
    if checkingRestore {
      stopRestoreCheck()
      return Task { false }
    }
    guard restoreBatchInFlight else { return Task { false } }
    return Task { await viewModel.stopRunningStatement(cancelQueue: false) == .keptRunning }
  }

  private func stopReading() {
    cancelWork?()
    cancelWork = nil
    operationID = UUID()
    activity = nil
    releaseRestoreAccess()
  }

  /// `restore()`'s gate check ends without running anything
  private func stopRestoreCheck() {
    checkingRestore = false
    operationID = UUID()
    activity = nil
  }

  private func releaseRestoreAccess() {
    restoreAccess?.release()
    restoreAccess = nil
  }

  // MARK: - Private

  private func begin(_ activity: Activity) -> UUID {
    let id = UUID()
    operationID = id
    self.activity = activity
    return id
  }

  /// Lists the running dump, copy or restore in the tab's workspace (Quit and close ask first);
  /// Stop there is this model's Cancel, or `confirmingCancel` when given (awaited by the Stop)
  private func beginRunningWork(
    _ label: String, kind: RunningWorkRegistry.Kind,
    confirmingCancel: (@MainActor () -> Task<Bool, Never>)? = nil
  ) -> RunningWorkRegistry.Token {
    RunningWorkRegistry.shared.begin(
      workspaceID: viewModel.historyWorkspace()?.id, label: label, kind: kind,
      confirmingCancel: confirmingCancel
    ) { [weak self] in
      Task { await self?.cancel() }
    }
  }

  /// A progress callback (called off the main actor) that hops back here, dropped once the
  /// operation `id` is over
  private func reporter<Progress: Sendable>(
    _ id: UUID, _ activity: Activity,
    _ apply: @escaping @MainActor (DatabaseBackupModel, Progress) -> Void
  ) -> @Sendable (Progress) -> Void {
    { [weak self] progress in
      Task { @MainActor in
        guard let self, self.operationID == id, self.activity == activity else { return }
        apply(self, progress)
      }
    }
  }

  private func end(_ id: UUID) {
    guard operationID == id else { return }
    activity = nil
    cancelWork = nil
  }

  private func clearMessages() {
    errorMessage = nil
    resultMessage = nil
  }

  /// Records as the AI queries do: only with History on, on the tab's recorder, then the list
  /// reloads
  private func recordHistory(
    started: ContinuousClock.Instant,
    _ entry: (_ workspaceID: UUID?, _ workspaceName: String?, _ durationMs: Int) ->
      QueryHistoryEntry
  ) async {
    guard viewModel.historySettings.historyEnabled else { return }
    let workspace = viewModel.historyWorkspace()
    let duration = Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded())
    await viewModel.historyRecorder.record(entry(workspace?.id, workspace?.name, duration))
    viewModel.onHistoryRecorded?()
  }

  nonisolated static func historyStatus(for error: Error) -> QueryHistoryEntry.Status {
    if error is CancellationError { return .cancelled }
    switch error as? DatabaseError {
    case .queryCancelled, .batchCancelled: return .cancelled
    default: return .error
    }
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  /// The database name, the SQLite or DuckDB file name without its extension, or "memory" for
  /// an in-memory DuckDB database
  private static func baseName(_ config: ConnectionConfig) -> String {
    let name: String
    switch config.databaseType {
    case .duckdb where config.database == DuckDBSession.inMemoryPath:
      name = "memory"
    case .sqlite, .duckdb:
      name = URL(fileURLWithPath: config.database).deletingPathExtension().lastPathComponent
    case .postgresql, .mysql, .mongodb:
      name = config.database
    }
    return name.isEmpty ? "dump" : name
  }

  private static func showSavePanel(name: String, fileExtension: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = UTType(filenameExtension: fileExtension).map { [$0] } ?? []
    // A database copy may be named .db or .bak. A dump keeps .sql, also when the whole name is
    // retyped: Restore's open panel lists only .sql and plain text files
    panel.allowsOtherFileTypes = fileExtension != "sql"
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }

  private static func showOpenPanel() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.sql, .plainText]
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
