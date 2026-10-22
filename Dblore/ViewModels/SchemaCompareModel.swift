// SchemaCompareModel.swift
// The Schema Compare sheet's state. TARGET: the tab's connection and one of its schemas; the
// only place a script is ever sent. SOURCE: another schema of the same connection, or a saved
// connection of the same engine and one of its schemas, read on a private short-lived connection
// (`openSchemaCompareSource`) that is closed after the read, its failure, a cancel and the sheet
// closing. A MySQL source in another database of the same server also gets its own connection
// (MySQL lists only the connected database's tables).
// Compare reads the source, then the target (`SchemaSnapshotLoader`, with progress and Cancel),
// diffs them (`SchemaDiff`) and builds the script for the ticked items
// (`SchemaMigrationScriptBuilder`), off the main actor; ticking an item builds it again and
// clears the last run's report. Only the latest compare writes its result.
// Run sends exactly the shown statements to the target, in one `executeGatedSchemaChange` call
// (the structure editor's gate: PostgreSQL and SQLite atomic, inside the pending transaction
// under Protected mode; MySQL one by one, stopping at the first failure), with the target's
// `connectionEpoch` captured at compare time: a changed connection is refused before anything is
// sent. Selected drops ask first (Run cannot skip that step), then Safe Mode asks as for the
// structure editor, with the tab's protection read at Run. A sent table drop closes the table's
// tabs (`onTableChange`, on Commit when pending). After a run that applied something the diff is
// stale (Run is disabled) until the next compare; changing the source or the target clears the
// result. History rows use source `.structure`.

import Foundation
import Observation

/// The private connection a source snapshot is read on. Read calls only, then `disconnect`.
nonisolated protocol SchemaCompareSourceConnection: SchemaSnapshotDatabase {
  func disconnect() async
}

/// The target connection's calls. `DatabaseConnectionManager` in the app.
nonisolated protocol SchemaCompareDatabase: SchemaSnapshotDatabase, StructureEditorDatabase {
  /// A private, connected, single-use connection for a source snapshot: `config` (this
  /// connection's own when nil), connected to `database` instead when set (MySQL). The caller
  /// disconnects it.
  func openSchemaCompareSource(
    config: ConnectionConfig?, database: String?
  ) async throws -> any SchemaCompareSourceConnection
}

extension DatabaseConnectionManager: SchemaCompareSourceConnection {}

extension DatabaseConnectionManager: SchemaCompareDatabase {
  // A snapshot side manager, not `MCPReadOnlySession`: the PostgreSQL qualified read sends its
  // own `BEGIN … READ ONLY` and `SET LOCAL search_path`, which the MCP wrapper refuses. The
  // source stays read-only by construction instead: only `SchemaSnapshotLoader` reads it (it
  // has no write call), SQLite opens read-only (`SQLDumpSessionFactory`), and PostgreSQL reads
  // inside a READ ONLY transaction that is always rolled back.
  func openSchemaCompareSource(
    config: ConnectionConfig?, database: String?
  ) async throws -> any SchemaCompareSourceConnection {
    guard let identity = config ?? self.config else { throw DatabaseError.notConnected }
    var config = identity
    if let database { config.database = database }
    let side = makeSnapshotSideManager()
    do {
      // The certificate and SSH secret stay those of the connection as saved or connected
      try await connectSideManager(side, config: config, identity: identity)
      return side
    } catch {
      await side.disconnect()
      throw error
    }
  }
}

/// The connection, rules and history sink of the tab Schema Compare runs on
struct SchemaCompareContext {
  var database: any SchemaCompareDatabase
  var databaseType: DatabaseType
  /// Read at Run, so a protection change while the sheet is open counts
  var policy: @MainActor () -> ProtectionPolicy
  /// Read at Run, so a commit style changed while the sheet is open counts
  var commitStyle: @MainActor () -> CommitStyle
  /// The tab's caller token, so the script joins that tab's Protected mode transaction
  var caller: UUID?
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void
  /// A saved connection's password, called off the main actor (the Keychain in the app)
  var password: @Sendable (ConnectionConfig) -> String? = SchemaCompareContext.keychainPassword

  nonisolated static func keychainPassword(_ config: ConnectionConfig) -> String? {
    SessionManager.isRunningAsTestHost
      ? nil
      : KeychainConnectionPasswordStore.loadPassword(
        forKey: ConnectionKeychainKey.password(for: config))
  }
}

extension SchemaCompareContext {
  /// `tab`'s connection, rules and History. Nil when the tab is not connected.
  init?(tab: NotebookViewModel) {
    guard let manager = tab.connectionManager, let base = StructureEditorContext(tab: tab) else {
      return nil
    }
    self.init(
      database: manager, databaseType: base.databaseType,
      policy: { [weak tab] in tab?.protectionPolicy ?? base.policy },
      commitStyle: base.commitStyle, caller: base.caller, recordHistory: base.recordHistory)
  }
}

@MainActor
@Observable
final class SchemaCompareModel: Identifiable {
  enum SourceConnection: Hashable {
    /// The target's own connection
    case current
    /// A saved connection (`ConnectionHistoryEntry.id`)
    case saved(UUID)
  }

  struct SavedConnection: Identifiable, Hashable {
    let id: UUID
    let name: String
  }

  struct Progress: Equatable {
    enum Side { case source, target }
    var side: Side
    var done = 0
    /// Nil until the table list is read
    var total: Int?
  }

  /// What a run that stopped at a failing statement applied
  struct RunReport: Equatable {
    var applied: [String]
    var failed: String?
    var notRun: [String]
  }

  /// The ticked and unticked items of one table, in diff order
  struct TableGroup: Identifiable {
    let table: String
    let items: [SchemaDiffItem]
    var id: String { table }
  }

  static let connectionChangedMessage = "The connection changed since the compare. Compare again."
  static let compareAgainMessage = "Compare again before running anything else."

  // Changing a side clears the result: Run never sends a script built for other schemas
  var sourceConnection: SourceConnection = .current {
    didSet {
      guard sourceConnection != oldValue else { return }
      clearResult()
      sourceSchema = defaultSourceSchema
    }
  }
  var sourceSchema: String {
    didSet { if sourceSchema != oldValue { clearResult() } }
  }
  var targetSchema: String {
    didSet { if targetSchema != oldValue { clearResult() } }
  }
  let targetSchemas: [String]
  let savedConnections: [SavedConnection]

  private(set) var items: [SchemaDiffItem] = []
  /// Differences the diff cannot cover (MySQL against MariaDB)
  private(set) var diffWarnings: [String] = []
  /// The script for the ticked items
  private(set) var script = SchemaMigrationScript()
  private(set) var isBuildingScript = false
  /// Set while comparing
  private(set) var progress: Progress?
  private(set) var compareError: String?
  /// The driver's text behind a fixed `compareError` (a source connection that failed)
  private(set) var compareErrorDetail: String?
  /// A run sent something since the compare: Run waits for the next compare
  private(set) var isStale = false
  private(set) var isRunning = false
  private(set) var runError: String?
  private(set) var runReport: RunReport?
  private(set) var resultMessage: String?
  /// Drop statements the user confirms before Safe Mode (nil when not asking)
  private(set) var pendingDestructive: [String]?
  /// Statements Safe Mode asks about before Run sends anything; nil when not asking
  private(set) var pendingConfirmation: [StatementConfirmation]?
  private(set) var confirmationRequiresPassword = false

  /// Called once a run reached the server, to reload the sidebar schema
  @ObservationIgnored var onApplied: (@MainActor () async -> Void)?
  /// A sent table drop, for the workspace to close the table's tabs (on Commit when pending)
  @ObservationIgnored var onTableChange:
    (@MainActor (StructureEditorModel.TableChange, _ pending: Bool) -> Void)?
  /// Toast for the outcome. The workspace routes it to the tab's toast; nothing by default.
  @ObservationIgnored var toastPresenter: @MainActor (String, ToastMessage.ToastType) -> Void = {
    _, _ in
  }

  @ObservationIgnored private let context: SchemaCompareContext
  @ObservationIgnored private let savedEntries: [ConnectionHistoryEntry]
  private var snapshots: (source: SchemaSnapshot, target: SchemaSnapshot)?
  private var connection = StructureEditorConnectionState()
  @ObservationIgnored private var confirmedStatements: [String]?
  @ObservationIgnored private var compareTask: Task<Void, Never>?
  @ObservationIgnored private var compareGeneration = 0
  @ObservationIgnored private var scriptTask: Task<Void, Never>?
  @ObservationIgnored private var scriptGeneration = 0

  /// `savedConnections`: the saved connections without passwords (other engines are left out)
  init(
    context: SchemaCompareContext, targetSchemas: [String], targetSchema: String,
    savedConnections: [ConnectionHistoryEntry]
  ) {
    self.context = context
    self.targetSchemas =
      targetSchemas.contains(targetSchema)
      ? targetSchemas : [targetSchema] + targetSchemas
    self.targetSchema = targetSchema
    savedEntries = savedConnections.filter { $0.config.databaseType == context.databaseType }
    self.savedConnections = savedEntries.map {
      SavedConnection(id: $0.id, name: $0.shortDisplayName)
    }
    sourceSchema = targetSchemas.first { $0 != targetSchema } ?? targetSchema
  }

  var databaseType: DatabaseType { context.databaseType }

  /// Under Protected mode the script waits in the pending transaction until Commit
  var runsInPendingTransaction: Bool { context.policy().protectedMode }

  /// The schemas of this connection a source can be (the target's choices)
  var sourceSchemas: [String] { targetSchemas }

  /// MySQL names a database, the other engines a schema
  var schemaLabel: String { databaseType == .mysql ? "Database" : "Schema" }

  var isComparing: Bool { progress != nil }

  /// A compare finished and found these items (empty: the schemas match)
  var hasResult: Bool { snapshots != nil }

  /// The schema the shown script was built for (and Run sends it to); nil without a result
  var comparedTargetSchema: String? { snapshots?.target.schema }

  var tableGroups: [TableGroup] {
    var order: [String] = []
    var grouped: [String: [SchemaDiffItem]] = [:]
    for item in items {
      if grouped[item.table] == nil { order.append(item.table) }
      grouped[item.table, default: []].append(item)
    }
    return order.map { TableGroup(table: $0, items: grouped[$0] ?? []) }
  }

  /// The exact text Copy, Save and Run use
  var scriptText: String {
    script.statements.map { $0.sql + ";" }.joined(separator: "\n")
  }

  var canCompare: Bool {
    !isComparing && !isRunning && !sourceSchema.trimmingCharacters(in: .whitespaces).isEmpty
      && !targetSchema.isEmpty && sourceDiffersFromTarget
  }

  /// The same schema of the same connection has nothing to compare
  var sourceDiffersFromTarget: Bool {
    sourceConnection != .current || sourceSchema != targetSchema
  }

  /// Why Run cannot send to this connection (read-only, schema-only, MySQL under Protected mode
  /// or with a transaction open), as the structure editor says; nil before a compare
  var runDisabledReason: String? {
    guard hasResult else { return nil }
    return StructureEditorModel.disabledReason(
      databaseType: databaseType, policy: context.policy(), state: connection)
  }

  var canRun: Bool {
    hasResult && !isStale && !isRunning && !isComparing && !isBuildingScript
      && !script.statements.isEmpty && runDisabledReason == nil && pendingConfirmation == nil
      && pendingDestructive == nil
  }

  var canEditSelection: Bool { hasResult && !isStale && !isRunning && !isComparing }

  func isDestructive(_ item: SchemaDiffItem) -> Bool {
    switch item.kind {
    case .dropTable, .dropColumn, .dropIndex, .dropForeignKey: true
    default: false
    }
  }

  func manualItems(for id: String) -> [SchemaMigrationScript.ManualItem] {
    script.manualItems.filter { $0.itemID == id }
  }

  func warnings(for id: String) -> [String] {
    script.warnings.filter { $0.itemID == id }.map(\.message)
  }

  // MARK: - Compare

  /// Reads both snapshots and diffs them. Returns once done, failed or cancelled.
  func compare() async {
    guard canCompare else { return }
    // Set before the task starts, so a second click finds the compare running
    compareGeneration += 1
    let generation = compareGeneration
    clearResult()
    progress = Progress(side: .source)
    let task = Task { await self.performCompare(generation) }
    compareTask = task
    await task.value
  }

  /// Stops the compare after the reads in flight; the source connection is closed
  func cancelCompare() {
    compareTask?.cancel()
  }

  /// The sheet closes: a compare stops, a Safe Mode step still open is cancelled
  func close() {
    cancelCompare()
    scriptTask?.cancel()
    cancelConfirmation()
  }

  /// Writes its result only while it is the latest compare
  private func performCompare(_ generation: Int) async {
    defer {
      if compareGeneration == generation {
        progress = nil
        compareTask = nil
      }
    }
    do {
      let source = try await loadSource(generation)
      try Task.checkCancellation()
      guard compareGeneration == generation else { return }
      progress = Progress(side: .target)
      let state = await context.database.structureEditorState()
      guard compareGeneration == generation else { return }
      connection = state
      let target: SchemaSnapshot
      do {
        target = try await SchemaSnapshotLoader.load(
          schema: targetSchema, from: context.database, progress: reporter(.target, generation))
      } catch {
        try Self.rethrowIfCancelled(error)
        throw CompareFailure.target(Self.message(error))
      }
      try Task.checkCancellation()
      let (diff, built) = try await Self.diffAndBuild(source: source, target: target)
      try Task.checkCancellation()
      guard compareGeneration == generation else { return }
      snapshots = (source, target)
      items = diff.items
      diffWarnings = diff.warnings
      script = built
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), compareGeneration == generation
      else { return }
      if case CompareFailure.sourceConnection(let name, let reason) = error {
        compareError =
          "Source: could not connect to \(name). This tab's connection is not affected."
        compareErrorDetail = reason
      } else {
        compareError = Self.message(error)
      }
    }
  }

  /// No result: the diff, its script (one being built is dropped), the messages and an open
  /// confirmation go, so Run waits for the next compare
  private func clearResult() {
    snapshots = nil
    items = []
    diffWarnings = []
    scriptTask?.cancel()
    scriptGeneration += 1
    isBuildingScript = false
    script = SchemaMigrationScript()
    compareError = nil
    compareErrorDetail = nil
    runError = nil
    runReport = nil
    resultMessage = nil
    isStale = false
    cancelConfirmation()
  }

  /// The source snapshot: on the target's connection, or on a private one closed on every path
  private func loadSource(_ generation: Int) async throws -> SchemaSnapshot {
    let schema = sourceSchema.trimmingCharacters(in: .whitespaces)
    let progress = reporter(.source, generation)
    let config: ConnectionConfig?
    let name: String
    switch sourceConnection {
    case .current:
      guard databaseType == .mysql, schema != targetSchema else {
        do {
          return try await SchemaSnapshotLoader.load(
            schema: schema, from: context.database, progress: progress)
        } catch {
          try Self.rethrowIfCancelled(error)
          throw CompareFailure.source(Self.message(error))
        }
      }
      config = nil
      name = "this server"
    case .saved(let id):
      guard let entry = savedEntries.first(where: { $0.id == id }) else {
        throw CompareFailure.source("The saved connection is no longer available.")
      }
      config = await Self.withSavedPassword(entry.config, password: context.password)
      name = entry.shortDisplayName
    }
    let side: any SchemaCompareSourceConnection
    do {
      side = try await context.database.openSchemaCompareSource(
        config: config, database: databaseType == .mysql ? schema : nil)
    } catch {
      try Self.rethrowIfCancelled(error)
      throw CompareFailure.sourceConnection(name: name, reason: Self.message(error))
    }
    do {
      try Task.checkCancellation()
      let snapshot = try await SchemaSnapshotLoader.load(
        schema: schema, from: side, progress: progress)
      await side.disconnect()
      return snapshot
    } catch {
      await side.disconnect()
      try Self.rethrowIfCancelled(error)
      throw CompareFailure.source(Self.message(error))
    }
  }

  /// Loader progress (called off the main actor) for this compare only
  private func reporter(
    _ side: Progress.Side, _ generation: Int
  ) -> @Sendable (Int, Int) -> Void {
    { [weak self] done, total in
      Task { @MainActor in
        guard let self, self.compareGeneration == generation, self.progress?.side == side
        else { return }
        self.progress = Progress(side: side, done: done, total: total)
      }
    }
  }

  private var defaultSourceSchema: String {
    switch sourceConnection {
    case .current:
      return targetSchemas.first { $0 != targetSchema } ?? targetSchema
    case .saved(let id):
      // MySQL reads the saved connection's database; elsewhere the same schema name is likeliest
      guard databaseType == .mysql, let entry = savedEntries.first(where: { $0.id == id }) else {
        return targetSchema
      }
      return entry.config.database
    }
  }

  // MARK: - Selection

  func setSelected(_ id: String, _ isSelected: Bool) {
    guard canEditSelection, let index = items.firstIndex(where: { $0.id == id }),
      items[index].isSelected != isSelected
    else { return }
    items[index].isSelected = isSelected
    rebuildScript()
  }

  func setTableSelected(_ table: String, _ isSelected: Bool) {
    guard canEditSelection else { return }
    var changed = false
    for index in items.indices where items[index].table == table {
      guard items[index].isSelected != isSelected else { continue }
      items[index].isSelected = isSelected
      changed = true
    }
    if changed { rebuildScript() }
  }

  private func rebuildScript() {
    guard let snapshots else { return }
    cancelConfirmation()
    // The last run's outcome was for the script this one replaces
    runError = nil
    runReport = nil
    resultMessage = nil
    scriptGeneration += 1
    let generation = scriptGeneration
    let items = items
    isBuildingScript = true
    scriptTask?.cancel()
    scriptTask = Task { [weak self] in
      let built = await Self.build(items, source: snapshots.source, target: snapshots.target)
      guard let self, self.scriptGeneration == generation else { return }
      self.script = built
      self.isBuildingScript = false
    }
  }

  // MARK: - Run

  /// The ticked drops ask first, then Safe Mode when the connection's commit style confirms
  /// writes (the sheet verifies the password / Touch ID and calls `confirmRun`); otherwise
  /// sends the script.
  func run() async {
    guard canRun else { return }
    let statements = script.statements.map(\.sql)
    let destructive = destructiveStatements
    if !destructive.isEmpty {
      confirmedStatements = statements
      pendingDestructive = destructive
      return
    }
    await askThenSend(statements)
  }

  /// The drops were confirmed: Safe Mode next, unless the script changed meanwhile
  func confirmDestructive() async {
    guard pendingDestructive != nil else { return }
    let statements = confirmedStatements
    cancelConfirmation()
    guard let statements, statements == script.statements.map(\.sql), canRun else { return }
    await askThenSend(statements)
  }

  /// Sends the statements Safe Mode showed, unless the script changed meanwhile
  func confirmRun() async {
    guard pendingConfirmation != nil else { return }
    let statements = confirmedStatements
    cancelConfirmation()
    guard let statements, statements == script.statements.map(\.sql), canRun else { return }
    await send(statements)
  }

  func cancelConfirmation() {
    pendingDestructive = nil
    pendingConfirmation = nil
    confirmedStatements = nil
    confirmationRequiresPassword = false
  }

  /// The script's statements that belong to a ticked drop
  private var destructiveStatements: [String] {
    let drops = Set(items.filter { $0.isSelected && isDestructive($0) }.map(\.id))
    return script.statements.filter { drops.contains($0.itemID) }.map(\.sql)
  }

  private func askThenSend(_ statements: [String]) async {
    if askSafeMode(statements) { return }
    await send(statements)
  }

  /// Arms the Safe Mode step for `statements` when the connection's commit style confirms
  /// writes. True when it asks (nothing is sent until `confirmRun`).
  private func askSafeMode(_ statements: [String]) -> Bool {
    let dialect = databaseType.dialect
    let classified = statements.flatMap { SQLStatementClassifier.classify($0, dialect: dialect) }
    let commitStyle = context.commitStyle()
    guard
      let listed = NotebookViewModel.statementsNeedingConfirmation(
        classified, commitStyle: commitStyle, dialect: dialect)
    else { return false }
    confirmedStatements = statements
    confirmationRequiresPassword = commitStyle.requiresPassword
    pendingConfirmation = listed
    return true
  }

  private func send(_ statements: [String]) async {
    guard let target = snapshots?.target else { return }
    let sent = SentScript(
      schema: target.schema, statements: script.statements, items: items.filter(\.isSelected))
    isRunning = true
    runError = nil
    runReport = nil
    resultMessage = nil
    defer { isRunning = false }
    // Checked here too, so a reconnect since the compare sends nothing (the gate checks again)
    guard await context.database.structureEditorState().connectionEpoch == target.connectionEpoch
    else {
      runError = Self.connectionChangedMessage
      isStale = true
      return
    }
    let sql = statements.joined(separator: ";\n")
    let started = Date()
    do {
      let result = try await context.database.executeGatedSchemaChange(
        statements, policy: context.policy(), connectionEpoch: target.connectionEpoch,
        caller: context.caller)
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: result.duration, rowCount: nil, status: .success, errorMessage: nil)
      ])
      isStale = true
      let message: String
      if result.pending {
        message = StructureEditorModel.pendingMessage
      } else if result.insideUserTransaction {
        message = StructureEditorModel.insideTransactionMessage
      } else {
        message =
          statements.count == 1 ? "Applied 1 statement" : "Applied \(statements.count) statements"
      }
      resultMessage = message
      toastPresenter(message, result.pending || result.insideUserTransaction ? .warning : .success)
      reportDroppedTables(sent, applied: statements.count, pending: result.pending)
      await onApplied?()
    } catch {
      let message = Self.message(error)
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: Date().timeIntervalSince(started), rowCount: nil, status: .error,
          errorMessage: message)
      ])
      switch error {
      case DatabaseError.schemaChangePartiallyApplied(let applied, _, _):
        runReport = Self.report(statements, failedAt: applied, applied: applied)
        // MySQL, never pending: the drops before the failing statement are done
        reportDroppedTables(sent, applied: applied, pending: false)
      case DatabaseError.batchStatementFailed(let index, _, _, true):
        // Rolled back: nothing changed and the diff still holds
        runReport = RunReport(
          applied: [], failed: statements.indices.contains(index) ? statements[index] : nil,
          notRun: statements.enumerated().filter { $0.offset != index }.map(\.element))
        runError = message
        toastPresenter(message, .error)
        return
      case DatabaseError.batchStatementFailed(let index, _, _, false):
        runReport = Self.report(statements, failedAt: index, applied: index)
      default:
        // Refused or failed before anything was applied
        runError = message
        toastPresenter(message, .error)
        return
      }
      runError = "\(message) \(Self.compareAgainMessage)"
      isStale = true
      toastPresenter(message, .warning)
      await onApplied?()
    }
  }

  /// The sent table drops whose statements are all among the first `applied` that ran, to
  /// the workspace (it closes the tables' tabs, on Commit when pending)
  private func reportDroppedTables(
    _ sent: SentScript, applied: Int, pending: Bool
  ) {
    guard let onTableChange else { return }
    let done = Set(sent.statements.prefix(applied).map(\.itemID))
    let notDone = Set(sent.statements.dropFirst(applied).map(\.itemID))
    for item in sent.items where done.contains(item.id) && !notDone.contains(item.id) {
      guard case .dropTable(let table) = item.kind else { continue }
      onTableChange(.dropped(schema: sent.schema, table: table.name), pending)
    }
  }

  /// What a run sends, captured before it is sent
  private struct SentScript {
    var schema: String
    var statements: [SchemaMigrationScript.Statement]
    var items: [SchemaDiffItem]
  }

  // MARK: - Helpers

  private enum CompareFailure: LocalizedError {
    case source(String)
    case sourceConnection(name: String, reason: String)
    case target(String)

    var errorDescription: String? {
      switch self {
      case .source(let reason): "Source: \(reason)"
      case .sourceConnection(let name, let reason):
        "Source: could not connect to \(name): \(reason)"
      case .target(let reason): "Target: \(reason)"
      }
    }
  }

  private static func report(
    _ statements: [String], failedAt index: Int, applied: Int
  )
    -> RunReport
  {
    RunReport(
      applied: Array(statements.prefix(applied)),
      failed: statements.indices.contains(index) ? statements[index] : nil,
      notRun: Array(statements.dropFirst(index + 1)))
  }

  private static func rethrowIfCancelled(_ error: any Error) throws {
    // A cancelled read may fail as a wrapped query error
    if error is CancellationError || Task.isCancelled { throw CancellationError() }
  }

  private static func message(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  /// The saved connection with its password, read off the main actor (the Keychain)
  @concurrent nonisolated private static func withSavedPassword(
    _ config: ConnectionConfig, password: @Sendable (ConnectionConfig) -> String?
  ) async -> ConnectionConfig {
    var config = config
    if config.databaseType.capabilities.usesPassword, let saved = password(config) {
      config.password = saved
    }
    return config
  }

  @concurrent nonisolated private static func diffAndBuild(
    source: SchemaSnapshot, target: SchemaSnapshot
  ) async throws -> (SchemaDiffResult, SchemaMigrationScript) {
    let diff = try SchemaDiff.diff(source: source, target: target)
    return (diff, SchemaMigrationScriptBuilder.build(diff.items, source: source, target: target))
  }

  @concurrent nonisolated private static func build(
    _ items: [SchemaDiffItem], source: SchemaSnapshot, target: SchemaSnapshot
  ) async -> SchemaMigrationScript {
    SchemaMigrationScriptBuilder.build(items, source: source, target: target)
  }
}
