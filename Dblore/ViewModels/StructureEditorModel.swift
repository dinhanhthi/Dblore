// StructureEditorModel.swift
// The structure editor sheet's state: loads one table's structure off the main actor, says up
// front why it cannot be edited, stages changes as `[StructureChange]` with a derived working
// view, previews exactly the DDL `StructureDDLBuilder` returns, asks Safe Mode before sending,
// and applies the previewed strings through `executeGatedSchemaChange` (which re-checks every
// refusal). History rows use source `.structure`.

import Foundation
import Observation

/// What the editor reads from the connection before a change, in one actor turn
nonisolated struct StructureEditorConnectionState: Sendable, Equatable {
  /// Captured at load; a change is refused once the connection changed
  var connectionEpoch: UInt64 = 0
  /// Nil unless a MySQL session is open (the MySQL DDL depends on the server version)
  var mysqlServerInfo: MySQLServerInfo?
  /// The app transaction is pending or the user's own transaction is open
  var transactionOpen = false
}

/// The connection calls the editor makes. `DatabaseConnectionManager` in the app.
nonisolated protocol StructureEditorDatabase: Sendable {
  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure
  func structureEditorState() async -> StructureEditorConnectionState
  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
  ) async throws -> SchemaChangeResult
}

extension DatabaseConnectionManager: StructureEditorDatabase {
  func structureEditorState() -> StructureEditorConnectionState {
    StructureEditorConnectionState(
      connectionEpoch: connectionEpoch, mysqlServerInfo: mysqlServerInfo,
      transactionOpen: !txState.isIdle || userTxOpen)
  }
}

/// The connection, rules and history sink of the tab the editor was opened from
struct StructureEditorContext {
  var database: any StructureEditorDatabase
  var databaseType: DatabaseType
  var policy: ProtectionPolicy
  /// Read at Apply, so a commit style changed while the editor is open counts
  var commitStyle: @MainActor () -> CommitStyle
  /// The tab's caller token, so the change joins that tab's Protected mode transaction
  var caller: UUID?
  /// Records outcomes in History as `.structure` (the tab honours the History setting)
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void
}

@MainActor
@Observable
final class StructureEditorModel {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  /// How a working row differs from the loaded table
  enum StagedState: Equatable {
    case unchanged
    case added
    case edited
    case dropped
  }

  enum ColumnField: Hashable {
    case name
    case type
    case defaultValue
    case nullability
  }

  /// A loaded column (by its loaded name) or one added in this session (by its current name)
  enum ColumnRef: Hashable {
    case loaded(String)
    case added(String)
  }

  struct WorkingColumn: Identifiable, Equatable {
    /// Name as loaded; nil for a column added in this session
    var loadedName: String?
    /// The column with the staged values applied
    var column: TableStructure.Column
    var state: StagedState
    var editedFields: Set<ColumnField> = []
    /// Stays the same while an added column is renamed (the sheet keys its rows by it)
    var rowID: String

    var id: ColumnRef { loadedName.map(ColumnRef.loaded) ?? .added(column.name) }
  }

  struct WorkingIndex: Equatable {
    var index: TableStructure.Index
    var state: StagedState
  }

  struct WorkingConstraint: Equatable {
    var constraint: TableStructure.Constraint
    var state: StagedState
  }

  static let duckDBMessage = "DuckDB tables can only be viewed"
  static let readOnlyMessage = "This connection is read-only"
  static let schemaOnlyMessage = "This connection blocks schema changes"
  static let mysqlUnknownServerMessage =
    "The MySQL server version is unknown; reconnect to edit the structure"
  static let mysqlReviewMessage =
    "MySQL commits schema changes immediately; switch off Review to edit the structure"
  static let mysqlTransactionMessage =
    "MySQL commits schema changes immediately; commit or roll back the open transaction first"
  static let pausedMessage = "Commit or roll back the pending changes to edit the structure"
  static let appliedMessage = "Applied"
  static let pendingMessage = "Pending until you commit"
  static let insideTransactionMessage = "Applied inside your open transaction; commit to keep it"

  let schema: String
  let table: String
  private(set) var loadState = LoadState.idle
  private(set) var structure: TableStructure?
  /// Why the table cannot be edited (the sheet is view-only), or nil
  private(set) var disabledReason: String?
  private(set) var changes: [StructureChange] = []
  /// Exactly the strings Apply sends
  private(set) var previewStatements: [String] = []
  /// Why the staged changes cannot be built (Apply is disabled)
  private(set) var previewError: String?
  /// Statements Safe Mode asks about before Apply sends anything; nil when not asking
  private(set) var pendingConfirmation: [StatementConfirmation]?
  private(set) var confirmationRequiresPassword = false
  private(set) var isApplying = false
  private(set) var resultMessage: String?
  private(set) var applyError: String?
  /// `applyError` reports a MySQL change that stopped part way (some statements committed)
  private(set) var applyPartiallyFailed = false
  /// Called after a change reached the server (to reload the sidebar schema)
  @ObservationIgnored var onApplied: (@MainActor () async -> Void)?
  /// Toast for Apply results and new preview errors (the panel shows it over itself). The
  /// workspace routes it to the tab's toast; nothing by default.
  @ObservationIgnored var toastPresenter: @MainActor (String, ToastMessage.ToastType) -> Void = {
    _, _ in
  }

  @ObservationIgnored private let context: StructureEditorContext
  @ObservationIgnored private var connection = StructureEditorConnectionState()
  @ObservationIgnored private var confirmedStatements: [String]?
  /// One per `.addColumn` in `changes`, in order: the added rows' `rowID`
  @ObservationIgnored private var addedRowIDs: [UUID] = []

  init(schema: String, table: String, context: StructureEditorContext) {
    self.schema = schema
    self.table = table
    self.context = context
  }

  /// The editor for `tab`'s connection. Nil when the tab is not connected.
  convenience init?(schema: String, table: String, tab: NotebookViewModel) {
    guard let manager = tab.connectionManager, let config = tab.notebook.connectionConfig else {
      return nil
    }
    self.init(
      schema: schema, table: table,
      context: StructureEditorContext(
        database: manager, databaseType: config.databaseType, policy: tab.protectionPolicy,
        commitStyle: { [weak tab] in
          (tab?.notebook.connectionConfig ?? config)
            .resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
        },
        caller: tab.id,
        recordHistory: { [weak tab] in await tab?.recordExecution($0, source: .structure) }))
  }

  var isReadOnly: Bool { disabledReason != nil }

  var canApply: Bool {
    disabledReason == nil && loadState == .loaded && !isApplying && previewError == nil
      && !previewStatements.isEmpty
  }

  // MARK: - Load

  /// Reads the structure and the connection state (on the connection's actor)
  /// The app transaction a pending change waited on ended: drop the stale "pending" banner
  /// and reload, so the editor shows the committed or rolled-back structure.
  func transactionEnded() async {
    if resultMessage == Self.pendingMessage { resultMessage = nil }
    await load()
  }

  func load() async {
    // What Safe Mode showed was built on the structure being replaced
    cancelConfirmation()
    loadState = .loading
    do {
      let database = context.database
      let (state, loaded) = try await PerfSignpost.interval("structure.editorLoad") {
        let state = await database.structureEditorState()
        return (state, try await database.fetchTableStructure(schema: schema, table: table))
      }
      connection = state
      structure = loaded
      disabledReason = Self.disabledReason(
        databaseType: context.databaseType, policy: context.policy, state: state)
      loadState = .loaded
    } catch DatabaseError.metadataPausedDuringTransaction {
      loadState = .failed(Self.pausedMessage)
    } catch {
      loadState = .failed(error.localizedDescription)
    }
    rebuildPreview()
  }

  /// Why `databaseType` under `policy` and `state` cannot change the structure, or nil
  static func disabledReason(
    databaseType: DatabaseType, policy: ProtectionPolicy, state: StructureEditorConnectionState
  ) -> String? {
    if databaseType == .duckdb { return duckDBMessage }
    switch policy.protectionLevel {
    case .readOnly: return readOnlyMessage
    case .schemaOnly: return schemaOnlyMessage
    case .none: break
    }
    guard databaseType == .mysql else { return nil }
    if state.mysqlServerInfo == nil { return mysqlUnknownServerMessage }
    if policy.protectedMode { return mysqlReviewMessage }
    if state.transactionOpen { return mysqlTransactionMessage }
    return nil
  }

  // MARK: - Staging columns

  func addColumn(_ column: StructureChange.NewColumn) {
    guard canStage else { return }
    addedRowIDs.append(UUID())
    stage { $0.append(.addColumn(column)) }
  }

  func rename(_ ref: ColumnRef, to newName: String) {
    switch ref {
    case .loaded(let name):
      stageLoaded(name, replacing: Self.isRenameChange) {
        newName == name ? nil : .renameColumn(column: name, newName: newName)
      }
    case .added(let name):
      guard changes.contains(where: { Self.addedName($0) == name }) else { return }
      editAdded(name) { $0.name = newName }
      // Indexes and constraints staged on the added column follow its name
      stage { changes in
        changes = changes.map { Self.renamingKeyColumn($0, from: name, to: newName) }
      }
    }
  }

  func setType(_ type: String, for ref: ColumnRef) {
    switch ref {
    case .loaded(let name):
      let loaded = loadedColumn(name).map(Self.displayedType)
      stageLoaded(name, replacing: Self.isTypeChange) {
        type == loaded ? nil : .alterColumnType(column: name, type: type)
      }
    case .added(let name):
      editAdded(name) { $0.type = type }
    }
  }

  /// Nil or blank drops the default
  func setDefault(_ expression: String?, for ref: ColumnRef) {
    let trimmed = expression?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed?.isEmpty == false ? trimmed : nil
    switch ref {
    case .loaded(let name):
      let loaded = loadedColumn(name)?.defaultExpression
      stageLoaded(name, replacing: Self.isDefaultChange) {
        guard value != loaded else { return nil }
        return value.map { .setDefault(column: name, expression: $0) } ?? .dropDefault(column: name)
      }
    case .added(let name):
      editAdded(name) { $0.defaultExpression = value }
    }
  }

  func setNullable(_ isNullable: Bool, for ref: ColumnRef) {
    switch ref {
    case .loaded(let name):
      let loaded = loadedColumn(name)?.isNullable
      stageLoaded(name, replacing: Self.isNullabilityChange) {
        guard isNullable != loaded else { return nil }
        return isNullable ? .dropNotNull(column: name) : .setNotNull(column: name)
      }
    case .added(let name):
      editAdded(name) { $0.isNullable = isNullable }
    }
  }

  /// Drops a loaded column (its other staged edits go) or removes an added one. Indexes and
  /// constraints staged on the column go too.
  func dropColumn(_ ref: ColumnRef) {
    switch ref {
    case .loaded(let name):
      stageLoaded(name, replacing: Self.isAnyChange) { .dropColumn(column: name) }
      stage { $0.removeAll { Self.stagedKeyColumns(of: $0).contains(name) } }
    case .added(let name):
      stage { changes in
        while let position = changes.firstIndex(where: { Self.addedName($0) == name }) {
          removeChange(at: position, from: &changes)
        }
        changes.removeAll { Self.stagedKeyColumns(of: $0).contains(name) }
      }
    }
  }

  /// Takes back every staged change to a loaded column (edits or the drop)
  func revertColumn(named name: String) {
    stage { $0.removeAll { Self.columnName(of: $0) == name } }
  }

  // MARK: - Staging indexes and constraints

  func addIndex(_ index: StructureChange.NewIndex) {
    stage { $0.append(.createIndex(index)) }
  }

  /// Drops a loaded index, or removes one created in this session
  func dropIndex(named name: String) {
    stage { changes in
      if let added = changes.firstIndex(where: {
        if case .createIndex(let index) = $0 { index.name == name } else { false }
      }) {
        changes.remove(at: added)
      } else if !changes.contains(.dropIndex(name: name)) {
        changes.append(.dropIndex(name: name))
      }
    }
  }

  func addConstraint(_ constraint: TableStructure.Constraint) {
    stage { $0.append(.addConstraint(constraint)) }
  }

  /// Drops a loaded constraint (it needs a name), or removes one added in this session
  func dropConstraint(_ constraint: TableStructure.Constraint) {
    stage { changes in
      if let added = changes.firstIndex(of: .addConstraint(constraint)) {
        changes.remove(at: added)
      } else if let name = constraint.name {
        let drop = StructureChange.dropConstraint(name: name, kind: Self.kind(of: constraint))
        if !changes.contains(drop) { changes.append(drop) }
      }
    }
  }

  // MARK: - Undo

  func undoChange(at index: Int) {
    guard changes.indices.contains(index) else { return }
    stage { removeChange(at: index, from: &$0) }
  }

  func discardChanges() {
    stage { changes in
      changes.removeAll()
      addedRowIDs.removeAll()
    }
  }

  /// Reload button: drops the staged changes and the error of their failed Apply, then reads again
  func reload() async {
    discardChanges()
    applyError = nil
    applyPartiallyFailed = false
    await load()
  }

  // MARK: - Working view

  var workingColumns: [WorkingColumn] {
    guard let structure else { return [] }
    var rows = structure.columns.map { column in
      var shown = column
      shown.dataType = Self.displayedType(column)
      return WorkingColumn(
        loadedName: column.name, column: shown, state: .unchanged, rowID: "loaded:\(column.name)")
    }
    var addedCount = 0
    for change in changes {
      if case .addColumn(let new) = change {
        let rowID =
          addedRowIDs.indices.contains(addedCount)
          ? "added:\(addedRowIDs[addedCount])" : "added-\(addedCount)"
        addedCount += 1
        rows.append(
          WorkingColumn(
            loadedName: nil,
            column: TableStructure.Column(
              ordinal: rows.count + 1, name: new.name, dataType: new.type,
              isNullable: new.isNullable, defaultExpression: new.defaultExpression, identity: nil,
              generated: nil, comment: nil, columnType: nil, extra: nil, characterSet: nil,
              collation: nil),
            state: .added, rowID: rowID))
        continue
      }
      guard let name = Self.columnName(of: change),
        let position = rows.firstIndex(where: { $0.loadedName == name })
      else { continue }
      Self.apply(change, to: &rows[position])
    }
    return rows
  }

  var workingIndexes: [WorkingIndex] {
    let loaded = (structure?.indexes ?? []).map { index in
      WorkingIndex(
        index: index,
        state: changes.contains(.dropIndex(name: index.name)) ? .dropped : .unchanged)
    }
    let added = changes.compactMap { change -> WorkingIndex? in
      guard case .createIndex(let new) = change else { return nil }
      return WorkingIndex(
        index: TableStructure.Index(
          name: new.name, keys: new.columns.map { .column($0) }, isUnique: new.isUnique,
          isPrimary: false, method: new.method, isPartial: false, predicate: nil),
        state: .added)
    }
    return loaded + added
  }

  var workingConstraints: [WorkingConstraint] {
    let loaded = (structure?.constraints ?? []).map { constraint in
      let dropped = constraint.name.map {
        changes.contains(.dropConstraint(name: $0, kind: Self.kind(of: constraint)))
      }
      return WorkingConstraint(
        constraint: constraint, state: dropped == true ? .dropped : .unchanged)
    }
    let added = changes.compactMap { change -> WorkingConstraint? in
      guard case .addConstraint(let constraint) = change else { return nil }
      return WorkingConstraint(constraint: constraint, state: .added)
    }
    return loaded + added
  }

  // MARK: - Apply

  /// Asks Safe Mode first when the connection's commit style confirms writes (the sheet then
  /// verifies the password / Touch ID and calls `confirmApply`); otherwise sends the preview.
  func apply() async {
    guard canApply else { return }
    let statements = previewStatements
    let dialect = context.databaseType.dialect
    let commitStyle = context.commitStyle()
    let classified = statements.flatMap { SQLStatementClassifier.classify($0, dialect: dialect) }
    if let listed = NotebookViewModel.statementsNeedingConfirmation(
      classified, commitStyle: commitStyle, dialect: dialect)
    {
      confirmedStatements = statements
      confirmationRequiresPassword = commitStyle.requiresPassword
      pendingConfirmation = listed
      return
    }
    await send(statements)
  }

  /// Sends the statements Safe Mode showed, unless the preview changed meanwhile
  func confirmApply() async {
    let statements = confirmedStatements
    cancelConfirmation()
    guard let statements, statements == previewStatements, canApply else { return }
    await send(statements)
  }

  func cancelConfirmation() {
    pendingConfirmation = nil
    confirmedStatements = nil
    confirmationRequiresPassword = false
  }

  // MARK: - Private

  private func send(_ statements: [String]) async {
    isApplying = true
    resultMessage = nil
    applyError = nil
    applyPartiallyFailed = false
    let sql = statements.joined(separator: ";\n")
    let started = Date()
    do {
      let result = try await context.database.executeGatedSchemaChange(
        statements, policy: context.policy, connectionEpoch: connection.connectionEpoch,
        caller: context.caller)
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: result.duration, rowCount: nil, status: .success, errorMessage: nil)
      ])
      isApplying = false
      clearChanges()
      if result.pending {
        // Catalog reads are paused until Commit / Rollback: keep the loaded structure
        resultMessage = Self.pendingMessage
        disabledReason = Self.pausedMessage
        rebuildPreview()
        toastPresenter(Self.pendingMessage, .warning)
      } else {
        let message =
          result.insideUserTransaction ? Self.insideTransactionMessage : Self.appliedMessage
        resultMessage = message
        toastPresenter(message, result.insideUserTransaction ? .warning : .success)
        await load()
      }
      await onApplied?()
    } catch {
      let message = error.localizedDescription
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: sql, duration: Date().timeIntervalSince(started), rowCount: nil, status: .error,
          errorMessage: message)
      ])
      isApplying = false
      applyError = message
      guard case DatabaseError.schemaChangePartiallyApplied = error else {
        toastPresenter(message, .error)
        return
      }
      toastPresenter(message, .warning)
      // Part of it is committed: the staged changes no longer match the table
      applyPartiallyFailed = true
      clearChanges()
      await load()
      await onApplied?()
    }
  }

  private func clearChanges() {
    changes = []
    addedRowIDs = []
  }

  /// Removes one change, and its row id when it adds a column
  private func removeChange(at index: Int, from changes: inout [StructureChange]) {
    if case .addColumn = changes[index] {
      let position = changes[..<index].count { Self.addedName($0) != nil }
      if addedRowIDs.indices.contains(position) { addedRowIDs.remove(at: position) }
    }
    changes.remove(at: index)
  }

  /// Editable, loaded, and no change on its way to the server
  private var canStage: Bool { disabledReason == nil && structure != nil && !isApplying }

  private func stage(_ edit: (inout [StructureChange]) -> Void) {
    guard canStage else { return }
    cancelConfirmation()
    edit(&changes)
    rebuildPreview()
  }

  /// Replaces `name`'s changes matching `replacing` with `make()` (nil: back to the loaded value)
  private func stageLoaded(
    _ name: String, replacing: (StructureChange) -> Bool,
    _ make: () -> StructureChange?
  ) {
    let change = make()
    stage { changes in
      changes.removeAll { Self.columnName(of: $0) == name && replacing($0) }
      if let change { changes.append(change) }
    }
  }

  private func editAdded(_ name: String, _ edit: (inout StructureChange.NewColumn) -> Void) {
    stage { changes in
      guard let position = changes.firstIndex(where: { Self.addedName($0) == name }),
        case .addColumn(var column) = changes[position]
      else { return }
      edit(&column)
      changes[position] = .addColumn(column)
    }
  }

  private func rebuildPreview() {
    let previous = previewError
    previewError = nil
    previewStatements = []
    guard let structure, !changes.isEmpty, let engine else { return }
    do {
      previewStatements = try StructureDDLBuilder.build(
        changes: changes, structure: structure, engine: engine)
    } catch {
      previewError = error.localizedDescription
    }
    // Only a new error: an unrelated edit that keeps the same one stays quiet
    if let previewError, previewError != previous { toastPresenter(previewError, .error) }
  }

  private var engine: StructureDDLBuilder.Engine? {
    switch context.databaseType {
    case .postgresql: .postgresql
    case .mysql: connection.mysqlServerInfo.map { .mysql($0) }
    case .sqlite: .sqlite(libraryVersion: SQLiteLibraryVersion.current)
    case .duckdb: .duckdb
    // No structure editing: no engine, so no preview and nothing to apply
    case .mongodb: nil
    }
  }

  private func loadedColumn(_ name: String) -> TableStructure.Column? {
    structure?.columns.first { $0.name == name }
  }

  /// MySQL shows `COLUMN_TYPE` (`int unsigned`), the others their display type
  private static func displayedType(_ column: TableStructure.Column) -> String {
    column.columnType ?? column.dataType
  }

  private static func isRenameChange(_ change: StructureChange) -> Bool {
    if case .renameColumn = change { true } else { false }
  }

  private static func isTypeChange(_ change: StructureChange) -> Bool {
    if case .alterColumnType = change { true } else { false }
  }

  /// Dropping a loaded column replaces all of its staged edits
  private static func isAnyChange(_ change: StructureChange) -> Bool { true }

  private static func isDefaultChange(_ change: StructureChange) -> Bool {
    switch change {
    case .setDefault, .dropDefault: true
    default: false
    }
  }

  private static func isNullabilityChange(_ change: StructureChange) -> Bool {
    switch change {
    case .setNotNull, .dropNotNull: true
    default: false
    }
  }

  /// Columns a staged index or constraint is built on
  private static func stagedKeyColumns(of change: StructureChange) -> [String] {
    switch change {
    case .createIndex(let index): index.columns
    case .addConstraint(let constraint): constraint.columns
    default: []
    }
  }

  private static func renamingKeyColumn(
    _ change: StructureChange, from name: String, to newName: String
  ) -> StructureChange {
    let rename = { (columns: [String]) in columns.map { $0 == name ? newName : $0 } }
    switch change {
    case .createIndex(var index):
      index.columns = rename(index.columns)
      return .createIndex(index)
    case .addConstraint(var constraint):
      constraint.columns = rename(constraint.columns)
      return .addConstraint(constraint)
    default:
      return change
    }
  }

  private static func addedName(_ change: StructureChange) -> String? {
    if case .addColumn(let column) = change { return column.name }
    return nil
  }

  /// The loaded column a column-level change edits
  private static func columnName(of change: StructureChange) -> String? {
    switch change {
    case .alterColumnType(let column, _), .setDefault(let column, _), .dropDefault(let column),
      .setNotNull(let column), .dropNotNull(let column), .renameColumn(let column, _),
      .dropColumn(let column):
      column
    case .addColumn, .addConstraint, .dropConstraint, .createIndex, .dropIndex:
      nil
    }
  }

  private static func apply(_ change: StructureChange, to row: inout WorkingColumn) {
    let field: ColumnField
    switch change {
    case .alterColumnType(_, let type):
      row.column.dataType = type
      field = .type
    case .setDefault(_, let expression):
      row.column.defaultExpression = expression
      field = .defaultValue
    case .dropDefault:
      row.column.defaultExpression = nil
      field = .defaultValue
    case .setNotNull:
      row.column.isNullable = false
      field = .nullability
    case .dropNotNull:
      row.column.isNullable = true
      field = .nullability
    case .renameColumn(_, let newName):
      row.column.name = newName
      field = .name
    case .dropColumn:
      row.state = .dropped
      return
    case .addColumn, .addConstraint, .dropConstraint, .createIndex, .dropIndex:
      return
    }
    row.editedFields.insert(field)
    if row.state == .unchanged { row.state = .edited }
  }

  private static func kind(
    of constraint: TableStructure.Constraint
  )
    -> StructureChange.ConstraintKind
  {
    switch constraint.kind {
    case .primaryKey: .primaryKey
    case .unique: .unique
    case .foreignKey: .foreignKey
    case .check: .check
    }
  }
}
