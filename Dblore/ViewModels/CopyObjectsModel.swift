// CopyObjectsModel.swift
// The Copy Objects sheet's state. SOURCE: the workspace's connection and the tables ticked in its
// checklist (a schema's tables, or one table and any others ticked), read on a read-only side
// connection opened like it (`makeReadOnlySideManager`); DuckDB on the workspace's own manager
// (no second connection to its file), which is never closed here. TARGET: a saved PostgreSQL,
// MySQL / MariaDB or SQLite connection. Read-only and Schema-only rows are refused when picked,
// before anything is read; a locked row asks to unlock before its password is read (a cancelled
// unlock clears the pick); an ask-on-connect row uses the password typed in a workspace connected
// to it, or opens nothing and says to connect it first; then the row opens on its own writable
// manager (`makeCopyTargetManager`, Protected mode off).
// The plan is built off the main actor from the structures of the ticked tables only (each read
// once while the source is open) and the target's names. The preview shows its warnings and the
// planned DDL, which the user may edit (Reset puts the planned DDL back). Copy checks the edited
// DDL (`CopyObjectsDDLCheck`; a refusal shows the statement), then runs the target's Safe Mode
// step before anything is sent, from the saved row's resolved commit style: Review is asked as
// Confirm, because the copy commits on its own and cannot wait for a Commit; Confirm, Review and
// Password always ask and list the DDL (one line for the copy when it lists nothing; the sheet's
// `SafeModeConfirmationPanel`, Password with Touch ID or the password); Immediate asks nothing. A
// target locked again since it was opened asks to unlock again before anything is sent. The run
// (`CopyObjectsRun`) reports chunks done, can be cancelled, and ends with a summary, or the error
// and (MySQL / MariaDB) the tables it could not drop. Both connections are closed after the copy
// and when the sheet closes (the workspace disconnecting closes it too); once closed, nothing
// opens or is sent.

import AppKit
import Foundation
import Observation

/// The workspace's side of a Copy Objects, and the hooks the target goes through (tests pass a
/// registry and prompter double, a password reader and a manager factory)
struct CopyObjectsContext {
  /// The workspace's connection: PostgreSQL, MySQL / MariaDB and SQLite are read on a side
  /// connection opened like it, DuckDB on it directly
  var source: DatabaseConnectionManager
  var sourceConfig: ConnectionConfig
  /// The source's triggers (the sidebar's list), named per copied table as not copied
  var sourceTriggers: [DatabaseTrigger] = []
  /// Gets the target's History row; nil when History is off
  var recorder: (any QueryHistoryRecording)?
  var workspaceID: UUID?
  var workspaceName: String?
  /// A saved connection's password, called off the main actor (the Keychain in the app)
  var password: @Sendable (ConnectionConfig) throws -> String? =
    SchemaCompareContext.keychainPassword
  /// An ask-on-connect target's typed password, held by a workspace connected to it
  var heldPassword: @MainActor (ConnectionConfig) -> String? =
    SchemaCompareContext.connectedWorkspacePassword
  /// Asks before a locked target is read
  var lockCenter: LockCenter = .shared
  /// The window the unlock prompt opens on (over the sheet attached to it)
  var unlockAnchor: @MainActor () -> NSWindow? = { nil }
  /// The unconnected target manager; its lock source must be `lockCenter`'s registry
  var makeTargetManager: @MainActor () -> DatabaseConnectionManager = { .withTrustPrompt() }
  /// The app's commit style, for a saved row that has none of its own
  var defaultCommitStyle: @MainActor () -> CommitStyle = { AppSettings.shared.commitStyle }
}

@MainActor
@Observable
final class CopyObjectsModel: Identifiable {
  nonisolated struct TableRef: Hashable, Sendable {
    var schema: String
    var name: String
  }

  struct SavedTarget: Identifiable, Hashable {
    let id: UUID
    let name: String
    let databaseType: DatabaseType
    /// The row is locked: picking it asks before its password is read
    let isLocked: Bool
  }

  struct Progress: Equatable {
    var done: Int
    var total: Int
  }

  static let mysqlTargetNote =
    "Each CREATE TABLE commits at once. If the copy fails or is cancelled, Dblore drops the "
    + "tables it created."
  static let protectedModeTargetNote =
    "This connection holds writes for review, but the copy cannot wait for a Commit: it asks "
    + "first, then commits on its own."

  let id = UUID()
  /// The source as History and the sheet name it
  let sourceName: String
  /// The source tables the checklist offers (empty while `isLoadingTables`)
  private(set) var tables: [TableRef]
  /// The tables span several schemas: rows are named with theirs
  private(set) var showsSchema: Bool
  /// The sheet shows at once; a large catalog's tables land once read off the main actor
  private(set) var isLoadingTables = false
  /// The saved PostgreSQL, MySQL / MariaDB and SQLite connections
  let targets: [SavedTarget]

  private(set) var selectedTables: Set<TableRef>
  private(set) var targetID: UUID?
  /// Why the picked target cannot be one (Read-only, Schema-only)
  private(set) var targetError: String?
  private(set) var isLoadingPlan = false
  private(set) var plan: CopyObjectsPlan?
  /// Why no plan: the target did not connect, a name is taken there, a type cannot be mapped
  private(set) var planError: String?
  /// The plan's DDL, for Reset
  private(set) var plannedDDL = ""
  /// The DDL Copy runs once it passes `CopyObjectsDDLCheck`
  var editedDDL = "" {
    didSet {
      guard editedDDL != oldValue else { return }
      refusal = nil
      cancelConfirmation()
    }
  }
  /// The edited DDL was refused: its `statement` (nil: a planned table has no CREATE TABLE)
  private(set) var refusal: CopyObjectsDDLCheck.Refusal?
  /// Statements Safe Mode asks about before Copy sends anything; nil when not asking
  private(set) var pendingConfirmation: [StatementConfirmation]?
  private(set) var confirmationRequiresPassword = false
  private(set) var isRunning = false
  /// Chunks done of the total, while running
  private(set) var progress: Progress?
  private(set) var result: CopyObjectsRunResult?
  private(set) var runError: String?
  /// MySQL / MariaDB: tables the failed or cancelled copy created and could not drop
  private(set) var leftoverTables: [String] = []

  /// After a copy that changed the target (done, or tables left over), with the saved row, so
  /// an open workspace on it reloads its schema
  @ObservationIgnored var onCopied: (@MainActor (ConnectionConfig) async -> Void)?

  @ObservationIgnored private let context: CopyObjectsContext
  @ObservationIgnored private let entries: [ConnectionHistoryEntry]
  @ObservationIgnored private let triggerNames: [TableRef: [String]]
  /// The picked target, connected
  private var connectedTarget: CopyObjectsTarget?
  @ObservationIgnored private var targetTask: Task<CopyObjectsTarget, any Error>?
  @ObservationIgnored private var sourceTask: Task<DatabaseConnectionManager, any Error>?
  /// Structures read on the open source
  @ObservationIgnored private var structures: [TableRef: TableStructure] = [:]
  @ObservationIgnored private var planTask: Task<Void, Never>?
  @ObservationIgnored private var planGeneration = 0
  @ObservationIgnored private var confirmed:
    (plan: CopyObjectsPlan, ddl: String, checked: CopyObjectsDDLCheck.Checked)?
  private var isChecking = false
  @ObservationIgnored private var run: CopyObjectsRun?
  @ObservationIgnored private var cancelRequested = false
  @ObservationIgnored private var runGeneration = 0
  /// The sheet closed: nothing opens or is sent any more (a model is never reused: each sheet
  /// builds its own)
  @ObservationIgnored private var isClosed = false

  /// `tables`: the source tables offered; `selected`: those ticked at open.
  /// `savedConnections`: the saved connections without passwords (other engines are left out).
  init(
    context: CopyObjectsContext, tables: [TableRef], selected: [TableRef],
    savedConnections: [ConnectionHistoryEntry]
  ) {
    self.context = context
    self.tables = tables
    showsSchema = Self.spansSchemas(tables)
    selectedTables = Set(selected)
    entries = savedConnections.filter {
      switch $0.config.databaseType {
      case .postgresql, .mysql, .sqlite: true
      case .duckdb, .mongodb: false
      }
    }
    targets = entries.map {
      SavedTarget(
        id: $0.id, name: $0.shortDisplayName, databaseType: $0.config.databaseType,
        isLocked: $0.config.isLocked)
    }
    triggerNames = Dictionary(
      grouping: context.sourceTriggers, by: { TableRef(schema: $0.schema, name: $0.table) }
    ).mapValues { $0.map(\.name) }
    let config = context.sourceConfig
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
      sourceName = name
    } else if config.databaseType == .sqlite || config.databaseType == .duckdb {
      sourceName = (config.database as NSString).lastPathComponent
    } else {
      sourceName = config.displayString
    }
  }

  /// The tables offered, those ticked, and whether they span several schemas
  typealias TableSource = (tables: [TableRef], selected: Set<TableRef>, showsSchema: Bool)

  /// Offers and ticks the tables `read` returns (read off the main actor), behind the open sheet
  func loadTables(_ read: @escaping () async -> TableSource) {
    isLoadingTables = true
    Task { [weak self] in
      let source = await read()
      guard let self, !self.isClosed else { return }
      self.tables = source.tables
      self.showsSchema = source.showsSchema
      self.selectedTables = source.selected
      self.isLoadingTables = false
      // Nothing could be ticked before the list landed: a target picked meanwhile plans now
      if !source.selected.isEmpty { self.loadPlan() }
    }
  }

  /// The checklist's row text
  nonisolated static func label(_ table: TableRef, showsSchema: Bool) -> String {
    showsSchema ? "\(table.schema).\(table.name)" : table.name
  }

  /// The tables whose row text contains `text` (case-insensitive), in order; nil when cancelled
  /// by a newer keystroke. Off the main actor.
  @concurrent nonisolated static func filtered(
    _ tables: [TableRef], text: String, showsSchema: Bool
  ) async -> [TableRef]? {
    var kept: [TableRef] = []
    for (offset, table) in tables.enumerated() {
      if offset % 512 == 511, Task.isCancelled { return nil }
      if label(table, showsSchema: showsSchema).localizedCaseInsensitiveContains(text) {
        kept.append(table)
      }
    }
    return kept
  }

  nonisolated static func spansSchemas(_ tables: [TableRef]) -> Bool {
    guard let first = tables.first?.schema else { return false }
    return tables.contains { $0.schema != first }
  }

  /// MySQL / MariaDB targets: what happens to the tables when the copy stops
  var mysqlNote: String? {
    selectedEntry?.config.databaseType == .mysql ? Self.mysqlTargetNote : nil
  }

  /// A target under Protected mode (Review): the copy does not wait in its pending transaction
  var protectedModeNote: String? {
    guard let entry = selectedEntry else { return nil }
    return resolvedCommitStyle(entry) == .review ? Self.protectedModeTargetNote : nil
  }

  /// The plan's warnings, then the run's once it finished
  var warnings: [String] { result?.warnings ?? plan?.warnings ?? [] }

  var isDDLEdited: Bool { editedDDL != plannedDDL }

  /// For the Safe Mode panel: the target is open, and its password (the "Forgot Password?"
  /// fallback)
  var isTargetConnected: Bool { connectedTarget != nil }
  var targetPassword: String? {
    guard let password = connectedTarget?.config.password, !password.isEmpty else { return nil }
    return password
  }

  var canCopy: Bool {
    plan != nil && !isLoadingPlan && !isRunning && result == nil && pendingConfirmation == nil
      && !isChecking
  }

  // MARK: - Source and target

  /// Ticks or unticks `tables`; the plan is built again
  func setSelected(_ tables: [TableRef], _ isSelected: Bool) {
    guard !isRunning else { return }
    var selection = selectedTables
    if isSelected { selection.formUnion(tables) } else { selection.subtract(tables) }
    guard selection != selectedTables else { return }
    selectedTables = selection
    loadPlan()
  }

  /// Switches the target at once; the plan loads behind it. A Read-only or Schema-only row is
  /// refused here, before anything is read.
  func selectTarget(_ id: UUID?) {
    guard !isRunning, id != targetID else { return }
    targetID = id
    targetError = nil
    discardTarget()
    if let entry = selectedEntry {
      switch entry.config.protectionLevel {
      case .readOnly: targetError = CopyObjectsTargetError.readOnly.errorDescription
      case .schemaOnly: targetError = CopyObjectsTargetError.schemaOnly.errorDescription
      case .none: break
      }
    }
    loadPlan()
  }

  /// Puts the planned DDL back
  func resetDDL() {
    guard !isRunning else { return }
    editedDDL = plannedDDL
  }

  /// Returns once the plan in progress is built, failed or superseded
  func waitForPlan() async {
    await planTask?.value
  }

  /// The sheet closes: a plan load and an open Safe Mode step stop, a copy is cancelled, and
  /// both connections close (after the copy when one runs)
  func close() {
    isClosed = true
    planGeneration += 1
    planTask?.cancel()
    planTask = nil
    isLoadingPlan = false
    cancelConfirmation()
    // A target still opening (an unlock prompt raised by Copy) stops there; an open one stays
    targetTask?.cancel()
    guard !isRunning else {
      cancel()
      return
    }
    discardTarget()
    discardSource()
  }

  private var selectedEntry: ConnectionHistoryEntry? {
    guard let targetID else { return nil }
    return entries.first { $0.id == targetID }
  }

  private func resolvedCommitStyle(_ entry: ConnectionHistoryEntry) -> CommitStyle {
    entry.config.resolvedCommitStyle(fallback: context.defaultCommitStyle())
  }

  /// Builds the plan again for the current target and tables; the last one's DDL, outcome and
  /// confirmation go
  private func loadPlan() {
    planGeneration += 1
    let generation = planGeneration
    planTask?.cancel()
    planTask = nil
    plan = nil
    planError = nil
    plannedDDL = ""
    editedDDL = ""
    refusal = nil
    result = nil
    runError = nil
    leftoverTables = []
    cancelConfirmation()
    guard selectedEntry != nil, targetError == nil, !selectedTables.isEmpty else {
      isLoadingPlan = false
      return
    }
    isLoadingPlan = true
    planTask = Task { await self.performLoad(generation) }
  }

  /// Writes its plan only while it is the latest load
  private func performLoad(_ generation: Int) async {
    defer {
      if planGeneration == generation {
        isLoadingPlan = false
        planTask = nil
      }
    }
    do {
      let target = try await openedTarget()
      try Task.checkCancellation()
      let names = try await target.manager.copyTargetNames()
      let targetEngine = try Self.engine(
        target.config.databaseType, server: await target.manager.mysqlServerInfo)
      // Superseded or closed while the target was read: open no source for it
      guard planGeneration == generation else { throw CancellationError() }
      let source = try await openedSource()
      let sourceEngine = try Self.engine(
        context.sourceConfig.databaseType, server: await source.mysqlServerInfo)
      var read: [CopyObjectsPlanner.SourceTable] = []
      for table in tables.filter(selectedTables.contains) {
        try Task.checkCancellation()
        let structure: TableStructure
        if let known = structures[table] {
          structure = known
        } else {
          structure = try await source.fetchTableStructure(schema: table.schema, table: table.name)
          structures[table] = structure
        }
        read.append(.init(structure: structure, triggerNames: triggerNames[table] ?? []))
      }
      let plan = try await Self.makePlan(
        read, source: sourceEngine, target: targetEngine, names: names)
      guard planGeneration == generation else { return }
      self.plan = plan
      plannedDDL = plan.editableDDL
      editedDDL = plannedDDL
    } catch is UnlockCancelled {
      // Nothing was read: the pick goes, quietly
      guard planGeneration == generation else { return }
      targetID = nil
    } catch {
      guard planGeneration == generation, !Task.isCancelled, !(error is CancellationError)
      else { return }
      planError = Self.message(error)
    }
  }

  /// The picked target, opened once: a locked row asks to unlock first, and its password is
  /// read only after the unlock
  private func openedTarget() async throws -> CopyObjectsTarget {
    guard !isClosed else { throw CancellationError() }
    if let targetTask { return try await targetTask.value }
    guard let entry = selectedEntry else { throw CancellationError() }
    let context = context
    let task = Task { () async throws -> CopyObjectsTarget in
      if context.lockCenter.registry.refusal(for: entry.config) != nil {
        guard
          await context.lockCenter.requestUnlock(
            for: entry.config,
            reason: "Unlock \(entry.shortDisplayName.prefix(80)) to copy into it",
            anchor: context.unlockAnchor())
        else { throw UnlockCancelled() }
        try Task.checkCancellation()
      }
      do {
        return try await DatabaseConnectionManager.makeCopyTargetManager(
          config: entry.config, password: context.password, heldPassword: context.heldPassword,
          makeManager: context.makeTargetManager)
      } catch let error as DatabaseError {
        switch error {
        // The text names no connection: say it is the target, not the user's own
        case .passwordNotHeldByWorkspace, .passwordSourcesMixed:
          throw TargetRefusal(
            name: entry.shortDisplayName, reason: error.localizedDescription)
        default: throw error
        }
      }
    }
    targetTask = task
    do {
      let target = try await task.value
      if targetTask == task { connectedTarget = target }
      return target
    } catch {
      // A later pick or Copy opens it again
      if targetTask == task { targetTask = nil }
      throw error
    }
  }

  /// The source connection, opened once: a read-only side connection like the workspace's, or
  /// the workspace's own on DuckDB
  private func openedSource() async throws -> DatabaseConnectionManager {
    guard !isClosed else { throw CancellationError() }
    if let sourceTask { return try await sourceTask.value }
    let manager = context.source
    let isDuckDB = context.sourceConfig.databaseType == .duckdb
    let task = Task { () async throws -> DatabaseConnectionManager in
      if isDuckDB { return manager }
      guard var config = await manager.config else { throw DatabaseError.notConnected }
      if config.databaseType == .sqlite { config.readOnlyFile = true }
      let side = manager.makeReadOnlySideManager()
      do {
        try await manager.connectSideManager(side, config: config)
        return side
      } catch {
        await side.disconnect()
        throw error
      }
    }
    sourceTask = task
    do {
      return try await task.value
    } catch {
      if sourceTask == task { sourceTask = nil }
      throw error
    }
  }

  /// Closes the target opened (or being opened) for the last pick
  private func discardTarget() {
    connectedTarget = nil
    guard let task = targetTask else { return }
    targetTask = nil
    task.cancel()
    Task { if let target = try? await task.value { await target.manager.disconnect() } }
  }

  /// Closes the source side connection (never the workspace's own DuckDB manager)
  private func discardSource() {
    structures = [:]
    guard let task = sourceTask else { return }
    sourceTask = nil
    let workspace = context.source
    Task {
      if let side = try? await task.value, side !== workspace { await side.disconnect() }
    }
  }

  // MARK: - Copy

  /// Checks the edited DDL, then asks Safe Mode when the target's commit style confirms writes
  /// (the sheet verifies the password / Touch ID and calls `confirmCopy`); otherwise copies.
  func copy() async {
    guard canCopy, let plan, let entry = selectedEntry else { return }
    refusal = nil
    runError = nil
    let ddl = editedDDL
    isChecking = true
    let checked: CopyObjectsDDLCheck.Checked
    let classified: [ClassifiedStatement]
    do {
      (checked, classified) = try await Self.check(ddl, plan: plan)
      isChecking = false
    } catch {
      isChecking = false
      guard ddl == editedDDL, plan == self.plan else { return }
      if let refused = error as? CopyObjectsDDLCheck.Refusal {
        refusal = refused
      } else {
        runError = Self.message(error)
      }
      return
    }
    // The DDL, the plan or the target changed, or the sheet closed, while it was checked
    guard !isClosed, ddl == editedDDL, plan == self.plan, entry.id == targetID, canCopy else {
      return
    }
    let style = resolvedCommitStyle(entry)
    // Every style but Immediate asks, whatever the DDL lists
    if style != .immediate {
      confirmed = (plan, ddl, checked)
      confirmationRequiresPassword = style.requiresPassword
      pendingConfirmation = Self.confirmationList(
        classified, tableCount: plan.tables.count, dialect: plan.target.dialect)
      return
    }
    await send(plan, checked)
  }

  /// Copies what Safe Mode showed, unless the DDL or the plan changed meanwhile
  func confirmCopy() async {
    guard pendingConfirmation != nil, let confirmed else { return }
    cancelConfirmation()
    guard confirmed.ddl == editedDDL, confirmed.plan == plan, canCopy else { return }
    await send(confirmed.plan, confirmed.checked)
  }

  func cancelConfirmation() {
    pendingConfirmation = nil
    confirmed = nil
    confirmationRequiresPassword = false
  }

  /// Stops the copy: the target rolls back (MySQL / MariaDB drops the tables it created)
  func cancel() {
    guard isRunning else { return }
    cancelRequested = true
    run?.cancel()
  }

  private func send(_ plan: CopyObjectsPlan, _ checked: CopyObjectsDDLCheck.Checked) async {
    guard !isClosed, let entry = selectedEntry else { return }
    runGeneration += 1
    let generation = runGeneration
    isRunning = true
    cancelRequested = false
    progress = Progress(done: 0, total: 0)
    result = nil
    runError = nil
    leftoverTables = []
    do {
      // Locked again since it was opened (idle auto-lock): it asks to unlock again
      if context.lockCenter.registry.refusal(for: entry.config) != nil { discardTarget() }
      let target = try await openedTarget()
      let source = try await openedSource()
      if cancelRequested { throw CopyObjectsRunError.cancelled(leftoverTables: []) }
      // Locked again while the source opened: nothing is sent
      if let locked = context.lockCenter.registry.refusal(for: entry.config) { throw locked }
      let run = CopyObjectsRun(
        plan: plan, checked: checked, source: source, sourceLabel: sourceName, target: target,
        recorder: context.recorder, workspaceID: context.workspaceID,
        workspaceName: context.workspaceName)
      self.run = run
      result = try await run.run(progress: reporter(generation))
    } catch let error as CopyObjectsRunError {
      runError = error.errorDescription
      switch error {
      case .failed(_, let leftovers), .cancelled(let leftovers): leftoverTables = leftovers
      case .invalidValue, .unreadableKey: break
      }
    } catch is UnlockCancelled {
      // The target was locked again and the unlock cancelled: nothing was sent
    } catch {
      runError = Self.message(error)
    }
    run = nil
    progress = nil
    isRunning = false
    discardTarget()
    discardSource()
    if result != nil || !leftoverTables.isEmpty { await onCopied?(entry.config) }
  }

  /// Run progress (called off the main actor) for this run only
  private func reporter(_ generation: Int) -> CopyObjectsRun.Progress {
    { [weak self] done, total in
      Task { @MainActor in
        guard let self, self.isRunning, self.runGeneration == generation else { return }
        self.progress = Progress(done: done, total: total)
      }
    }
  }

  // MARK: - Helpers

  /// A cancelled unlock of a locked target
  private struct UnlockCancelled: Error {}

  /// A target refusal whose text does not name the connection: "Target <name>: <reason>"
  private struct TargetRefusal: LocalizedError {
    let name: String
    let reason: String
    var errorDescription: String? { "Target \(name): \(reason)" }
  }

  private static func engine(
    _ type: DatabaseType?, server: MySQLServerInfo?
  ) throws -> StructureDDLBuilder.Engine {
    switch type {
    case .postgresql: return .postgresql
    case .mysql:
      guard let server else { throw DatabaseError.notConnected }
      return .mysql(server)
    case .sqlite: return .sqlite(libraryVersion: SQLiteLibraryVersion.current)
    case .duckdb: return .duckdb
    case .mongodb: throw CopyObjectsTargetError.unsupportedEngine("MongoDB")
    case nil: throw DatabaseError.notConnected
    }
  }

  @concurrent nonisolated private static func makePlan(
    _ tables: [CopyObjectsPlanner.SourceTable], source: StructureDDLBuilder.Engine,
    target: StructureDDLBuilder.Engine, names: CopyObjectsTargetNames
  ) async throws -> CopyObjectsPlan {
    try CopyObjectsPlanner.plan(
      tables, source: source, target: target, targetSchema: names.schema,
      existingNames: names.existingNames, existingConstraintNames: names.existingConstraintNames)
  }

  /// What the Safe Mode step lists: the DDL's statements that write, or one line for the copy
  /// when none is listed (the step is asked all the same)
  nonisolated static func confirmationList(
    _ classified: [ClassifiedStatement], tableCount: Int, dialect: SQLDialect
  ) -> [StatementConfirmation] {
    if let listed = NotebookViewModel.statementsNeedingConfirmation(
      classified, commitStyle: .confirm, dialect: dialect)
    {
      return listed
    }
    return [
      StatementConfirmation(
        index: 0,
        preview: "Create \(tableCount) \(tableCount == 1 ? "table" : "tables") and copy their rows",
        kindLabel: DatabaseConnectionManager.describe(.ddl), affectsAllRows: false,
        touchesBrake: false, changesPrivileges: false)
    ]
  }

  /// The checked DDL and its statements as Safe Mode lists them
  @concurrent nonisolated private static func check(
    _ ddl: String, plan: CopyObjectsPlan
  ) async throws -> (CopyObjectsDDLCheck.Checked, [ClassifiedStatement]) {
    let checked = try CopyObjectsDDLCheck.check(ddl, plan: plan)
    return (checked, SQLStatementClassifier.classify(ddl, dialect: plan.target.dialect))
  }

  private static func message(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
