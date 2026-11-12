// SchemaDiagramEditModel.swift
// The ER diagram's staged schema edits, across tables: add, rename and drop column, add and drop
// foreign key, rename table. Every change names tables and columns as loaded (a column added
// here by the name it is added with; renaming or dropping it edits or removes its ADD COLUMN).
// Each touched table's `TableStructure` is read first (on the connection's actor, one read per
// table shared by the calls that wait for it), so a staging call returns once the change is
// staged and the canvas shows the table loading meanwhile. The preview is built in passes, one
// `StructureDDLBuilder.build` call per table per pass, tables in the order first touched:
// 1. drop foreign keys, 2. add and drop columns, 3. add foreign keys, 4. renames (the builder
// writes column renames before the table rename). So a column is dropped only once the foreign
// keys on it are gone, and a foreign key is added once the columns it joins exist, whatever
// table they belong to. Apply sends exactly the preview through `SchemaChangeConfirmation` as
// one gated schema change: atomic on PostgreSQL and SQLite (or pending in the Protected mode
// transaction); MySQL / MariaDB run it statement by statement, each committing, so a failure
// leaves the earlier ones applied (`DatabaseError.schemaChangePartiallyApplied`). SQLite refuses
// foreign-key changes up front. Table renames that reached the server go to `onTableChange` (the
// workspace retargets the table's tabs and moves its saved diagram position), pending ones as
// pending. The model captures the connection epoch it was made for: a change is refused once
// the connection changed.

import Foundation
import Observation

@MainActor
@Observable
final class SchemaDiagramEditModel {
  /// A table by its loaded schema (MySQL: database) and name
  nonisolated struct TableKey: Hashable, Sendable {
    var schema: String
    var table: String

    /// `schema.table`, as `SchemaNode.qualifiedName`
    var qualifiedName: String { "\(schema).\(table)" }
  }

  static let unsupportedMessage = "Tables of this connection can only be viewed"
  static let readOnlyMessage = "This connection is read-only"
  static let schemaOnlyMessage = "This connection blocks schema changes"
  static let mysqlReviewMessage =
    "MySQL commits schema changes immediately; switch off Review to edit the diagram"
  static let mysqlUnknownServerMessage =
    "The MySQL server version is unknown; reconnect to edit the diagram"
  static let pausedMessage = "Commit or roll back the pending changes to edit the diagram"
  static let sqliteForeignKeyMessage =
    "SQLite cannot add or drop a foreign key on an existing table."
  static let statementByStatementWarning =
    "Each statement commits at once; a failure leaves the earlier ones applied"
  static let appliedMessage = "Applied"
  static let pendingMessage = "Pending until you commit"
  static let insideTransactionMessage = "Applied inside your open transaction; commit to keep it"
  static let notConnectedMessage = "The active tab is not connected; reconnect to edit the diagram"
  static let droppedColumnMessage = "This column is staged to be dropped and cannot be renamed"

  let databaseType: DatabaseType
  /// Safe Mode and the gated send, on the context of the tab Apply runs from
  private(set) var confirmation: SchemaChangeConfirmation
  /// Why nothing can be staged or applied, or nil
  private(set) var disabledReason: String?
  /// Staged changes per table, in loaded names
  private(set) var changes: [TableKey: [StructureChange]] = [:]
  /// Tables with staged changes, in the order first touched (the build order of each pass)
  private(set) var stagedTables: [TableKey] = []
  /// Tables whose structure is being read before a change is staged
  private(set) var loadingTables: Set<TableKey> = []
  /// Exactly the strings Apply sends
  private(set) var previewStatements: [String] = []
  /// Why the staged changes build no DDL (Apply is disabled)
  private(set) var previewError: String?
  private(set) var isApplying = false
  private(set) var resultMessage: String?
  private(set) var applyError: String?
  /// `applyError` reports a MySQL apply that stopped part way (the earlier statements stay)
  private(set) var applyPartiallyFailed = false

  /// Called once a change reached the server (pending: waits for Commit), after
  /// `onTableChange`. The workspace refreshes its transaction state and reloads the schema.
  @ObservationIgnored var onApplied: (@MainActor (_ pending: Bool) async -> Void)?
  /// Called for each table rename that reached the server (pending: applied on Commit)
  @ObservationIgnored var onTableChange:
    (@MainActor (StructureEditorModel.TableChange, _ pending: Bool) -> Void)?
  /// Toast for Apply results, staging refusals and new preview errors. The host routes it;
  /// nothing by default.
  @ObservationIgnored var toastPresenter: @MainActor (String, ToastMessage.ToastType) -> Void = {
    _, _ in
  }

  @ObservationIgnored private let database: any StructureEditorDatabase
  @ObservationIgnored private let policy: ProtectionPolicy
  @ObservationIgnored private let connectionEpoch: UInt64
  @ObservationIgnored private var structures: [TableKey: TableStructure] = [:]
  @ObservationIgnored private var loads:
    [TableKey: Task<(StructureEditorConnectionState, TableStructure), any Error>] = [:]
  /// Bumped when the loaded structures go stale (an apply, a transaction end): a read started
  /// before stages nothing
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var mysqlServerInfo: MySQLServerInfo?
  /// The table renames of the preview, by the index of their statement
  @ObservationIgnored private var renameStatements: [Int: StructureEditorModel.TableChange] = [:]

  /// `database` reads the structures (the context's manager in the app); `connectionEpoch` is
  /// the epoch of the schema the diagram shows
  init(
    context: SchemaChangeContext, database: any StructureEditorDatabase, connectionEpoch: UInt64
  ) {
    databaseType = context.databaseType
    policy = context.policy
    self.database = database
    self.connectionEpoch = connectionEpoch
    confirmation = SchemaChangeConfirmation(context: context)
    disabledReason = Self.disabledReason(databaseType: context.databaseType, policy: context.policy)
  }

  /// Why `databaseType` under `policy` cannot change tables from the diagram, or nil
  static func disabledReason(databaseType: DatabaseType, policy: ProtectionPolicy) -> String? {
    guard SidebarSectionModel.supportsTableChanges(databaseType) else { return unsupportedMessage }
    switch policy.protectionLevel {
    case .readOnly: return readOnlyMessage
    case .schemaOnly: return schemaOnlyMessage
    case .none: break
    }
    if databaseType == .mysql, policy.protectedMode { return mysqlReviewMessage }
    return nil
  }

  /// Why foreign keys cannot be added or dropped here (SQLite), or nil
  var foreignKeyChangeDisabledReason: String? {
    databaseType == .sqlite ? Self.sqliteForeignKeyMessage : nil
  }

  var changeCount: Int { changes.values.reduce(0) { $0 + $1.count } }

  /// `qualifiedName` of every table with staged changes (a foreign key counts for the table it
  /// is defined on)
  var touchedTables: Set<String> { Set(stagedTables.map(\.qualifiedName)) }

  var canApply: Bool {
    disabledReason == nil && !isApplying && previewError == nil && !previewStatements.isEmpty
  }

  /// Shown before Apply: MySQL / MariaDB run more than one statement one by one
  var applyWarning: String? {
    databaseType == .mysql && previewStatements.count > 1 ? Self.statementByStatementWarning : nil
  }

  /// What Apply sends, from the preview
  var plan: SchemaChangeConfirmation.Plan { .init(batch: previewStatements) }

  // MARK: - Staging

  func addColumn(_ column: StructureChange.NewColumn, to table: TableKey) async {
    await stage(table) { changes, _ in changes[table, default: []].append(.addColumn(column)) }
  }

  /// Renames `column` (loaded, or added here: its ADD COLUMN and the foreign keys staged on it
  /// follow). The loaded name takes a rename back.
  func renameColumn(_ column: String, in table: TableKey, to newName: String) async {
    await stage(table) { changes, structure in
      var staged = changes[table, default: []]
      if let added = staged.firstIndex(where: { Self.addedName($0) == column }),
        case .addColumn(var definition) = staged[added]
      {
        definition.name = newName
        staged[added] = .addColumn(definition)
        changes[table] = staged
        for owner in changes.keys {
          changes[owner] = changes[owner]?.map {
            Self.renamingKeyColumn($0, on: owner, of: table, from: column, to: newName)
          }
        }
        return
      }
      guard structure.columns.contains(where: { $0.name == column }) else { return }
      guard !staged.contains(.dropColumn(column: column)) else {
        self.toastPresenter(Self.droppedColumnMessage, .warning)
        return
      }
      staged.removeAll {
        if case .renameColumn(column, _) = $0 { true } else { false }
      }
      if newName != column { staged.append(.renameColumn(column: column, newName: newName)) }
      changes[table] = staged
    }
  }

  /// Drops a loaded column (its rename goes) or removes one added here; foreign keys staged on
  /// it, from either side, go too
  func dropColumn(_ column: String, in table: TableKey) async {
    await stage(table) { changes, structure in
      let isAdded = changes[table, default: []].contains { Self.addedName($0) == column }
      guard isAdded || structure.columns.contains(where: { $0.name == column }) else { return }
      for owner in changes.keys {
        changes[owner]?.removeAll { Self.addsForeignKey($0, using: column, of: table, on: owner) }
      }
      if isAdded {
        changes[table]?.removeAll { Self.addedName($0) == column }
        return
      }
      changes[table]?.removeAll {
        if case .renameColumn(column, _) = $0 { true } else { false }
      }
      if changes[table]?.contains(.dropColumn(column: column)) != true {
        changes[table, default: []].append(.dropColumn(column: column))
      }
    }
  }

  /// Stages the table rename (replacing an earlier one); the loaded name takes it back
  func renameTable(_ table: TableKey, to newName: String) async {
    await stage(table) { changes, _ in
      changes[table, default: []].removeAll {
        if case .renameTable = $0 { true } else { false }
      }
      if newName != table.table {
        changes[table, default: []].append(.renameTable(newName: newName))
      }
    }
  }

  /// A foreign key on `table`.`column` referencing `target`.`targetColumn` (unnamed: the engine
  /// names it). Refused on SQLite.
  func addForeignKey(
    from table: TableKey, column: String, to target: TableKey, column targetColumn: String
  ) async {
    guard !refusesForeignKeyChange() else { return }
    let constraint = TableStructure.Constraint(
      name: nil,
      kind: .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: target.schema, table: target.table, columns: [targetColumn],
          onUpdate: .noAction, onDelete: .noAction)),
      columns: [column])
    await stage(table) { changes, _ in
      if changes[table]?.contains(.addConstraint(constraint)) != true {
        changes[table, default: []].append(.addConstraint(constraint))
      }
    }
  }

  /// Drops the loaded foreign key a diagram edge shows. Refused on SQLite.
  func dropForeignKey(_ foreignKey: ForeignKey) async {
    guard !refusesForeignKeyChange(), !foreignKey.constraintName.isEmpty else { return }
    let table = TableKey(schema: foreignKey.sourceSchema, table: foreignKey.sourceTable)
    let drop = StructureChange.dropConstraint(name: foreignKey.constraintName, kind: .foreignKey)
    await stage(table) { changes, _ in
      if changes[table]?.contains(drop) != true { changes[table, default: []].append(drop) }
    }
  }

  /// The staged changes of `table`, in loaded names
  func changes(in table: TableKey) -> [StructureChange] { changes[table] ?? [] }

  func discardChanges() {
    guard !isApplying else { return }
    edit(touching: nil) { changes in changes = [:] }
  }

  // MARK: - Apply

  /// Asks Safe Mode first when the commit style confirms writes (the host then verifies the
  /// password / Touch ID and calls `confirmApply`); otherwise sends the preview.
  func apply() async {
    guard canApply else { return }
    let plan = plan
    if confirmation.ask(plan) { return }
    await send(plan)
  }

  /// Sends what Safe Mode showed, unless the preview changed meanwhile
  func confirmApply() async {
    guard let confirmed = confirmation.takeConfirmed(), confirmed == plan, canApply else { return }
    await send(confirmed)
  }

  func cancelConfirmation() {
    confirmation.cancel()
  }

  /// Apply runs from `context` from now on (the tab the model was made on may have closed):
  /// its caller token, commit style and History. Call before `apply()`, never between it and
  /// `confirmApply()` (the Safe Mode step is cancelled).
  func retarget(_ context: SchemaChangeContext) {
    confirmation.cancel()
    confirmation = SchemaChangeConfirmation(context: context)
  }

  /// The app transaction ended (Commit / Rollback): a model paused by its pending change, or by
  /// a catalog paused when it read a table, can stage again; the loaded structures are read again
  func transactionEnded() {
    guard disabledReason == Self.pausedMessage else { return }
    if resultMessage == Self.pendingMessage { resultMessage = nil }
    disabledReason = Self.disabledReason(databaseType: databaseType, policy: policy)
    forgetStructures()
  }

  // MARK: - Private

  private func send(_ plan: SchemaChangeConfirmation.Plan) async {
    isApplying = true
    resultMessage = nil
    applyError = nil
    applyPartiallyFailed = false
    let renames = renameStatements.sorted { $0.key < $1.key }
    do {
      let result = try await confirmation.send(plan, connectionEpoch: connectionEpoch)
      isApplying = false
      clearStaged()
      if result.pending {
        // Catalog reads are paused until Commit / Rollback
        resultMessage = Self.pendingMessage
        disabledReason = Self.pausedMessage
        toastPresenter(Self.pendingMessage, .warning)
        for (_, change) in renames { onTableChange?(change, true) }
        await onApplied?(true)
        return
      }
      let message =
        result.insideUserTransaction ? Self.insideTransactionMessage : Self.appliedMessage
      resultMessage = message
      toastPresenter(message, result.insideUserTransaction ? .warning : .success)
      for (_, change) in renames { onTableChange?(change, false) }
      await onApplied?(false)
    } catch {
      isApplying = false
      let message = error.localizedDescription
      applyError = message
      guard case DatabaseError.schemaChangePartiallyApplied(let applied, _, _) = error else {
        toastPresenter(message, .error)
        return
      }
      // The first statements are committed: the staged changes no longer match the tables
      toastPresenter(message, .warning)
      applyPartiallyFailed = true
      clearStaged()
      for (index, change) in renames where index < applied { onTableChange?(change, false) }
      await onApplied?(false)
    }
  }

  /// Editable, and no change on its way to the server
  private var canStage: Bool { disabledReason == nil && !isApplying }

  /// True (with a toast) when foreign keys cannot change on this engine
  private func refusesForeignKeyChange() -> Bool {
    guard let reason = foreignKeyChangeDisabledReason else { return false }
    toastPresenter(reason, .error)
    return true
  }

  /// Reads `table` when it is not loaded yet, then applies `edit` to the staged changes
  private func stage(
    _ table: TableKey,
    _ edit: (_ changes: inout [TableKey: [StructureChange]], _ structure: TableStructure) -> Void
  ) async {
    guard canStage, let structure = await structure(of: table), canStage else { return }
    self.edit(touching: table) { edit(&$0, structure) }
  }

  /// Applies `edit` (`table` joins the staged tables when it has changes now), then keeps only
  /// tables with changes and rebuilds the preview
  private func edit(
    touching table: TableKey?, _ edit: (inout [TableKey: [StructureChange]]) -> Void
  ) {
    confirmation.cancel()
    let before = changes
    edit(&changes)
    changes = changes.filter { !$0.value.isEmpty }
    if let table, changes[table] != nil, !stagedTables.contains(table) {
      stagedTables.append(table)
    }
    stagedTables.removeAll { changes[$0] == nil }
    // A new edit: "Applied" and an apply error no longer describe the diagram (the open
    // transaction warning and a partial failure, whose statements stay applied, stay)
    if changes != before {
      if resultMessage == Self.appliedMessage { resultMessage = nil }
      if !applyPartiallyFailed { applyError = nil }
    }
    rebuildPreview()
  }

  /// `table`'s structure, read once (concurrent calls share the read); nil when the read failed
  /// (toasted) or went stale
  private func structure(of table: TableKey) async -> TableStructure? {
    if let loaded = structures[table] { return loaded }
    let started = generation
    let database = database
    let task =
      loads[table]
      ?? Task {
        try await PerfSignpost.interval("schema.diagramTableLoad") {
          let state = await database.structureEditorState()
          return (
            state,
            try await database.fetchTableStructure(
              schema: table.schema, table: table.table)
          )
        }
      }
    loads[table] = task
    loadingTables.insert(table)
    let result = await task.result
    guard started == generation else { return nil }
    let first = loads[table] == task
    if first {
      loads[table] = nil
      loadingTables.remove(table)
    }
    switch result {
    case .success(let (state, structure)):
      if let info = state.mysqlServerInfo { mysqlServerInfo = info }
      if databaseType == .mysql, mysqlServerInfo == nil {
        disabledReason = Self.mysqlUnknownServerMessage
        return nil
      }
      structures[table] = structure
      return structure
    case .failure(let error):
      if case DatabaseError.metadataPausedDuringTransaction = error {
        disabledReason = Self.pausedMessage
        if first { toastPresenter(Self.pausedMessage, .warning) }
      } else if first {
        toastPresenter(error.localizedDescription, .error)
      }
      return nil
    }
  }

  /// The staged changes went to the server: they and the structures they were built on go
  private func clearStaged() {
    changes = [:]
    stagedTables = []
    forgetStructures()
    rebuildPreview()
  }

  private func forgetStructures() {
    generation += 1
    structures = [:]
    loads = [:]
    loadingTables = []
  }

  private func rebuildPreview() {
    let previous = previewError
    previewError = nil
    previewStatements = []
    renameStatements = [:]
    guard !changes.isEmpty, let engine else { return }
    var statements: [String] = []
    var renames: [Int: StructureEditorModel.TableChange] = [:]
    do {
      for pass in Pass.allCases {
        for table in stagedTables {
          let subset = (changes[table] ?? []).filter { Self.pass(of: $0) == pass }
          guard !subset.isEmpty, let structure = structures[table] else { continue }
          do {
            statements += try StructureDDLBuilder.build(
              changes: subset, structure: structure, engine: engine)
          } catch {
            throw TableError(table: table, message: error.localizedDescription)
          }
          // The builder writes the table rename last
          for case .renameTable(let newName) in subset {
            renames[statements.count - 1] = .renamed(
              schema: table.schema, from: table.table, to: newName)
          }
        }
      }
      previewStatements = statements
      renameStatements = renames
    } catch {
      previewError = error.localizedDescription
    }
    // Only a new error: an unrelated edit that keeps the same one stays quiet
    if let previewError, previewError != previous { toastPresenter(previewError, .error) }
  }

  private var engine: StructureDDLBuilder.Engine? {
    switch databaseType {
    case .postgresql: .postgresql
    case .mysql: mysqlServerInfo.map { .mysql($0) }
    case .sqlite: .sqlite(libraryVersion: SQLiteLibraryVersion.current)
    // Not editable here: no engine, so no preview and nothing to apply
    case .duckdb, .mongodb, .clickhouse, .sqlserver, .redis: nil
    }
  }

  /// A build error, prefixed with the table it came from
  private struct TableError: LocalizedError {
    let table: TableKey
    let message: String

    var errorDescription: String? { "\(table.qualifiedName): \(message)" }
  }

  /// The build passes, in run order
  private enum Pass: CaseIterable {
    case dropForeignKeys
    case columns
    case addForeignKeys
    case renames
  }

  private static func pass(of change: StructureChange) -> Pass {
    switch change {
    case .dropConstraint(_, .foreignKey): .dropForeignKeys
    case .addConstraint(let constraint):
      if case .foreignKey = constraint.kind { .addForeignKeys } else { .columns }
    case .renameColumn, .renameTable: .renames
    // Only ADD / DROP COLUMN are staged here among the rest
    default: .columns
    }
  }

  private static func addedName(_ change: StructureChange) -> String? {
    if case .addColumn(let column) = change { return column.name }
    return nil
  }

  /// `change` (staged on `owner`) adds a foreign key that uses `table`.`column`, on either side
  private static func addsForeignKey(
    _ change: StructureChange, using column: String, of table: TableKey, on owner: TableKey
  ) -> Bool {
    guard case .addConstraint(let constraint) = change,
      case .foreignKey(let reference) = constraint.kind
    else { return false }
    if owner == table, constraint.columns.contains(column) { return true }
    return TableKey(schema: reference.schema, table: reference.table) == table
      && reference.columns.contains(column)
  }

  /// A foreign key (staged on `owner`) on the added column `table`.`name` follows its rename,
  /// on either side
  private static func renamingKeyColumn(
    _ change: StructureChange, on owner: TableKey, of table: TableKey, from name: String,
    to newName: String
  ) -> StructureChange {
    guard case .addConstraint(var constraint) = change,
      case .foreignKey(var reference) = constraint.kind
    else { return change }
    let rename = { (columns: [String]) in columns.map { $0 == name ? newName : $0 } }
    if owner == table { constraint.columns = rename(constraint.columns) }
    if TableKey(schema: reference.schema, table: reference.table) == table {
      reference.columns = rename(reference.columns)
      constraint.kind = .foreignKey(reference)
    }
    return .addConstraint(constraint)
  }
}
