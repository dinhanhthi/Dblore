//
//  NotebookViewModel+InlineEdit.swift
//  Dblore
//
//  Inline grid edit: primary-key-only UPDATE, checked by the protection gate.
//  Confirm and password ask before the edit is sent. Review holds it in the app
//  transaction. Immediate, confirm, and password commit at once.
//

import AppKit
import Foundation

extension NotebookViewModel {
  // MARK: - Editability

  /// True when a value of `result` can be edited in place: the result carries a live,
  /// server-validated edit target (never true for a result read from a file) whose primary key
  /// columns are all in the result, and the connection is not read-only.
  func canEdit(_ result: CellResult) -> Bool {
    guard let target = result.editTarget else { return false }
    return canEdit(target: target, columnNames: Set(result.columns.map(\.name)))
  }

  /// Indexes of `result` columns that stay read-only in an editable result: generated columns.
  func readOnlyColumnIndexes(_ result: CellResult) -> Set<Int> {
    guard let generated = result.editTarget?.generatedColumns, !generated.isEmpty else { return [] }
    return Set(result.columns.indices.filter { generated.contains(result.columns[$0].name) })
  }

  /// Same check for the sidebar cell (`columnNames` = the row's columns), and `columnName` must
  /// not be generated. Only the live target captured by `showCellDetail` counts; the passed
  /// table name and key are display data.
  func canEdit(
    tableName _: String?, primaryKeyColumns _: [String], columnNames: Set<String>,
    columnName: String
  ) -> Bool {
    guard let target = cellDetailEditTarget, !target.generatedColumns.contains(columnName) else {
      return false
    }
    return canEdit(target: target, columnNames: columnNames)
  }

  private func canEdit(target: EditTarget, columnNames: Set<String>) -> Bool {
    rowEditingUnsupportedReason == nil && protectionPolicy.protectionLevel != .readOnly
      && !target.primaryKeyColumns.isEmpty
      && target.primaryKeyColumns.allSatisfy(columnNames.contains)
  }

  /// Validated edit target of `result`, produced by the live execution of `query`, or nil (not
  /// editable). `query` must be a SELECT from exactly one relation
  /// (`CellUpdateStatement.singleRelation`), which the server resolves (same session, so same
  /// search_path) to its table identity and `%I.%I` name; every result column must be a plain
  /// column of that table (`CellUpdateStatement.editablePrimaryKey`). `epoch` is the connection epoch
  /// read before `query` ran: if the table resolves on another connection (reconnect in
  /// between), the rows and the table may not match, so there is no target.
  func editTarget(
    for query: String, result: QueryResult, connectionManager: DatabaseConnectionManager,
    epoch: UInt64
  ) async -> EditTarget? {
    await resultTargets(
      for: query, result: result, connectionManager: connectionManager, epoch: epoch
    ).editTarget
  }

  /// `editTarget(for:)` plus the read-only lookup relation from the same resolved table: columns
  /// with an origin must all name that table, aliased and expression columns allowed
  /// (`CellUpdateStatement.lookupRelation`). The edit target keeps its own stricter checks.
  /// MongoDB never takes the SQL lookup (`mongoResultTarget`).
  func resultTargets(
    for query: String, result: QueryResult, connectionManager: DatabaseConnectionManager,
    epoch: UInt64
  ) async -> ResultTargets {
    if let config = notebook.connectionConfig,
      config.databaseType.capabilities.queryLanguage == .mongosh
    {
      return (mongoResultTarget(for: query, result: result, config: config, epoch: epoch), nil)
    }
    assert(sqlDialect != .mongodb, "mongosh text must not reach CellUpdateStatement")
    guard !result.columns.isEmpty,
      let relation = CellUpdateStatement.singleRelation(in: query, dialect: sqlDialect),
      let tableID = Self.originTableID(result.columns),
      let table = await editTable(relation, tableID: tableID, connectionManager),
      table.connectionEpoch == epoch,
      CellUpdateStatement.isServerQualifiedName(table.qualifiedName, dialect: sqlDialect)
    else { return (nil, nil) }
    let lookup = CellUpdateStatement.lookupRelation(columns: result.columns, table: table)
    guard Self.columnTableID(result.columns) == tableID else { return (nil, lookup) }
    let primaryKey = CellUpdateStatement.editablePrimaryKey(columns: result.columns, table: table)
    guard !primaryKey.isEmpty else { return (nil, lookup) }
    let target = EditTarget(
      qualifiedName: table.qualifiedName, tableID: tableID, primaryKeyColumns: primaryKey,
      connectionEpoch: table.connectionEpoch, updateOnly: table.updateOnly, schema: table.schema,
      name: table.name, generatedColumns: table.generatedColumns)
    return (target, lookup)
  }

  /// The collection of a result read by exactly one `find`, keyed by `_id`, or nil. Nil for
  /// other reads (`aggregate`, `distinct`, `countDocuments`, `listCollections`: their `_id` need
  /// not name a document of one collection), a find on a view (`databaseViews`, the cached
  /// catalog), a projection that excludes `_id` or sets it to an expression, a projection whose
  /// other fields are not plain inclusions or exclusions (`projectsStoredFields`), and a result
  /// without an `_id` column or whose `_id` type is `mixed`. No lookup relation (no foreign keys).
  private func mongoResultTarget(
    for query: String, result: QueryResult, config: ConnectionConfig, epoch: UInt64
  ) -> EditTarget? {
    guard MongoshSplitter.split(query).count == 1,
      case .find(let collection, _, let projection, _, _, _, _)? = try? MongoshParser.parse(query),
      !databaseViews.contains(where: { $0.name == collection }),
      Self.keepsPlainID(projection), Self.projectsStoredFields(projection),
      let idColumn = result.columns.first(where: { $0.name == "_id" }), idColumn.type != "mixed"
    else { return nil }
    let database = config.database.isEmpty ? MongoSession.defaultDatabase : config.database
    return EditTarget(
      qualifiedName: collection, tableID: .mongodb(database: database, collection: collection),
      primaryKeyColumns: ["_id"], connectionEpoch: epoch, updateOnly: false, schema: nil,
      name: collection, generatedColumns: [])
  }

  /// True when a find projection leaves `_id` as the stored value: no `_id` key, or `1`/`true`.
  /// `0`/`false` drop the column; any other value (`"$other"`, `{$toString: "$_id"}`) computes
  /// it, and a `_id.<path>` key keeps only part of it.
  private nonisolated static func keepsPlainID(_ projection: MongoValue?) -> Bool {
    guard case .document(let fields)? = projection else { return true }
    if fields.contains(where: { $0.key.hasPrefix("_id.") }) { return false }
    let ids = fields.filter { $0.key == "_id" }
    guard let value = ids.first?.value else { return true }
    guard ids.count == 1 else { return false }
    switch value {
    case .bool(let flag): return flag
    case .int32(let number): return number != 0
    case .int64(let number): return number != 0
    case .double(let number): return number != 0
    default: return false
    }
  }

  /// True when every projected field other than `_id` (`keepsPlainID`) is a plain inclusion or
  /// exclusion of a top-level key: `true`/`false`, or 1/0 of any numeric type. A string
  /// (`"$other"` renames), an expression, `$slice` / `$elemMatch` (part of an array), or a dotted
  /// key (part of a document) shows a value that an edit would write back as a stray or
  /// truncated field.
  private nonisolated static func projectsStoredFields(_ projection: MongoValue?) -> Bool {
    guard case .document(let fields)? = projection else { return true }
    return fields.allSatisfy { field in
      if field.key == "_id" { return true }
      guard !field.key.contains("."), !field.key.hasPrefix("$") else { return false }
      switch field.value {
      case .bool: return true
      case .int32(let number): return number == 0 || number == 1
      case .int64(let number): return number == 0 || number == 1
      case .double(let number): return number == 0 || number == 1
      default: return false
      }
    }
  }

  /// The one table identity shared by every column, or nil when any column came from elsewhere.
  static func columnTableID(_ columns: [ColumnInfo]) -> TableRef? {
    guard let tableID = columns.first?.origin?.tableID,
      columns.allSatisfy({ $0.origin?.tableID == tableID })
    else { return nil }
    return tableID
  }

  /// The one table identity shared by the columns read from a table (`tableOrigin`), or nil
  /// when there is none or more than one.
  static func originTableID(_ columns: [ColumnInfo]) -> TableRef? {
    let tableIDs = Set(columns.compactMap(\.tableOrigin?.tableID))
    return tableIDs.count == 1 ? tableIDs.first : nil
  }

  /// `relation` resolved by the server, or, while the app transaction is pending (no catalog
  /// query is sent), the table cached under the result columns' `tableID`. Nil when
  /// `relation` does not name that table (`relationNamesTable`).
  private func editTable(
    _ relation: String, tableID: TableRef, _ connectionManager: DatabaseConnectionManager
  ) async -> EditTable? {
    guard await connectionManager.relationNamesTable(relation, tableID: tableID) else {
      return nil
    }
    if await connectionManager.isMetadataPaused {
      return await connectionManager.cachedEditTable(id: tableID)
    }
    do {
      return try await connectionManager.fetchEditTable(tableName: relation, tableID: tableID)
    } catch {
      return nil
    }
  }

  /// A data-viewer page read with `state.pageSQL` made a plain single-table result again,
  /// before anything reads it: the length columns are moved into the truncation (full lengths
  /// over `lazyPrefixBytes` by row key and column), and each prefixed column, an expression
  /// on every engine, gets the origin a plain read gives (table identity and ordinal from
  /// `EditTable.attributeNames`, MySQL source names) and its cached type when it has none.
  /// A `SELECT *` page is returned as read. A lazy page that does not have the lazy columns, a
  /// row of another width, or a length that is not a number throws
  /// (`LazyPageError.unexpectedShape`): its prefixes must never show as whole values.
  /// `epoch` is the connection the page was read on; full values are read only there.
  func strippedDataViewerPage(
    _ result: QueryResult, state: DataViewerState, epoch: UInt64,
    connectionManager: DatabaseConnectionManager
  ) async throws -> (result: QueryResult, truncation: DataViewerState.Truncation?) {
    guard let lazy = state.lazyColumns else { return (result, nil) }
    guard result.columns.map(\.name) == lazy.map(\.name) + state.lengthColumns,
      result.rows.allSatisfy({ $0.count == result.columns.count })
    else { throw LazyPageError.unexpectedShape }
    var columns = Array(result.columns.prefix(lazy.count))
    var table: EditTable?
    if let tableID = Self.originTableID(columns),
      let relation = CellUpdateStatement.singleRelation(in: state.pageSQL, dialect: sqlDialect),
      let resolved = await editTable(relation, tableID: tableID, connectionManager),
      resolved.resolvedTableRef == tableID
    {
      table = resolved
      let ordinals = Dictionary(
        resolved.attributeNames.map { ($0.value, Int($0.key)) }, uniquingKeysWith: { $1 })
      let source = columns.lazy.compactMap(\.sourceName).first
      for (index, column) in lazy.enumerated() where column.isPrefixed {
        let read = columns[index]
        columns[index] = ColumnInfo(
          name: read.name, type: read.type.isEmpty ? column.type : read.type,
          origin: ordinals[read.name].map { ColumnOrigin(tableID: tableID, columnOrdinal: $0) },
          sourceName: source.map {
            ColumnSourceName(schema: $0.schema, table: $0.table, column: read.name)
          }, wallClock: read.wallClock)
      }
    }
    // The edit target's key order; the cached key when the table did not resolve
    var truncation = DataViewerState.Truncation(
      connectionEpoch: epoch, relation: state.relation, dialect: state.databaseType.dialect)
    let names = lazy.map(\.name)
    truncation.keyColumns =
      table.map(\.primaryKeyColumns).flatMap { $0.allSatisfy(names.contains) ? $0 : nil }
      ?? lazy.filter(\.isPrimaryKey).map(\.name)
    let keyIndexes = truncation.keyColumns.compactMap { names.firstIndex(of: $0) }
    let prefixed = lazy.indices.filter { lazy[$0].isPrefixed }
    for row in result.rows {
      var lengths: [String: Int] = [:]
      for (offset, index) in prefixed.enumerated() {
        let length: Int?
        switch row[lazy.count + offset] {
        case .null: length = nil
        case .int(let value): length = value
        case .double(let value): length = Int(exactly: value)
        case .string(let value): length = Int(value) ?? Double(value).flatMap { Int(exactly: $0) }
        default: throw LazyPageError.unexpectedShape
        }
        if let length, length > DataViewerState.lazyPrefixBytes {
          lengths[lazy[index].name] = length
        } else if length == nil, case .data(let data) = row[index],
          data.count >= DataViewerState.lazyPrefixBytes
        {
          // A prefix-sized value without a usable length may be cut: never shown as whole
          throw LazyPageError.unexpectedShape
        }
      }
      guard !lengths.isEmpty else { continue }
      let key = RowChangeSet.RowKey(values: keyIndexes.map { row[$0] })
      truncation.lengths[key, default: [:]].merge(lengths) { $1 }
    }
    var stripped = QueryResult(
      columns: columns, rows: result.rows.map { Array($0.prefix(lazy.count)) },
      rowCount: result.rowCount, executionTime: result.executionTime,
      wasLimited: result.wasLimited, affectedRows: result.affectedRows)
    stripped.truncated = result.truncated
    stripped.sessionReset = result.sessionReset
    stripped.skippedStatements = result.skippedStatements
    return (stripped, truncation)
  }

  /// Why a lazy data-viewer page was not shown
  nonisolated enum LazyPageError: Error, Equatable, LocalizedError {
    /// The page did not come back in the shape its SQL asked for
    case unexpectedShape

    var errorDescription: String? {
      "The page did not come back with the columns it asked for. Reload the table."
    }
  }

  /// The connection changed (connect/disconnect): no displayed result stays editable or offers
  /// a referenced-row lookup, and the open sidebar cell or a pending edit can no longer be sent.
  /// Results stay displayed.
  func invalidateEditTargets() {
    for index in notebook.cells.indices {
      notebook.cells[index].result?.editTarget = nil
      notebook.cells[index].result?.lookupRelation = nil
      notebook.cells[index].statementResults = notebook.cells[index].statementResults.map(
        Self.withoutEditTarget)
    }
    editorResult?.editTarget = nil
    editorResult?.lookupRelation = nil
    editorStatementResults = editorStatementResults.map(Self.withoutEditTarget)
    cellDetailEditTarget = nil
  }

  private nonisolated static func withoutEditTarget(_ statement: StatementResult) -> StatementResult
  {
    var result = statement.result
    result.editTarget = nil
    result.lookupRelation = nil
    return StatementResult(
      id: statement.id, queryText: statement.queryText, result: result,
      statementIndex: statement.statementIndex)
  }

  /// True if `target` is still the edit target of a result currently shown for `cellId`
  /// (notebook cell) or of the editor (`cellId == nil`): same generation, not a re-run.
  func isLiveEditTarget(_ target: EditTarget, cellId: UUID?) -> Bool {
    liveResult(of: target, cellId: cellId) != nil
  }

  /// The result shown for `cellId` (nil: the editor) whose edit target is `target`
  private func liveResult(of target: EditTarget, cellId: UUID?) -> CellResult? {
    let results: [CellResult]
    if let cellId {
      guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return nil }
      results = [cell.result].compactMap { $0 } + cell.statementResults.map(\.result)
    } else {
      results = [editorResult].compactMap { $0 } + editorStatementResults.map(\.result)
    }
    return results.first { $0.editTarget == target }
  }

  /// Input text to bind for an edited value. Nil is an explicit NULL. A NULL cell left empty
  /// or set to "null" also binds NULL. Any other text is kept (PostgreSQL parses it for the
  /// column type).
  nonisolated static func bindText(for newValue: String?, original: CellValue) -> String? {
    guard let newValue else { return nil }
    if case .null = original, newValue.isEmpty || newValue.lowercased() == "null" {
      return nil
    }
    return newValue
  }

  /// After a re-run replaced `old` with `new` (e.g. the refresh after an edit), keep the open
  /// sidebar cell editable when the new live target is the same table and key.
  func carryCellDetailEditTarget(from old: CellResult?, to new: CellResult?) {
    guard let current = cellDetailEditTarget, old?.editTarget == current else { return }
    let next = new?.editTarget
    cellDetailEditTarget = Self.isSameTable(next, current) ? next : nil
  }

  /// Same table and key (any generation or connection epoch); two nil targets match
  nonisolated static func isSameTable(_ lhs: EditTarget?, _ rhs: EditTarget?) -> Bool {
    lhs?.tableID == rhs?.tableID && lhs?.qualifiedName == rhs?.qualifiedName
      && lhs?.primaryKeyColumns == rhs?.primaryKeyColumns
  }

  // MARK: - Edit

  /// Handle cell value edit from sidebar. `newValue` is typed over the raw value: the edit of a
  /// binary cell (which the grid always edits in the sidebar) starts from its raw base64 text
  /// whatever its Display As format, so decoded MessagePack, Protobuf, hex or UUID text is never
  /// written back.
  /// - Parameter connectionManager: Optional connection manager from workspace for database updates
  /// - Parameter wallClock: the column's `ColumnInfo.wallClock`, how a date's text reads
  func handleCellValueEdit(
    columnName: String,
    columnType: String,
    newValue: String?,
    originalValue: CellValue,
    tableName: String?,
    rowData: [String: CellValue]?,
    primaryKeyColumns: [String],
    cellId: UUID?,
    connectionManager: DatabaseConnectionManager? = nil,
    wallClock: Bool
  ) {
    let bindText = Self.bindText(for: newValue, original: originalValue)
    let editedValue = Self.editedCellValue(
      newValue, original: originalValue, columnType: columnType, wallClock: wallClock,
      dialect: sqlDialect)

    // Copy to clipboard (an explicit NULL has no text to copy)
    if let newValue {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(newValue, forType: .string)
    }

    // Update the sidebar content with the new value. Open Row Details are not replaced by a
    // grid edit; the refresh after the send may still rebuild them and drop their drafts.
    // An edit still armed for a dialog closed without Cancel is dropped unsent here, once: its
    // value leaves the sidebar first, so this edit's Cancel puts the stored value back, and the
    // dialog this edit opens has no old edit left to put back over it.
    restoreSidebar(pendingInlineEdit?.sidebarRestore)
    pendingInlineEdit = nil
    if let batch = pendingStagedBatch, batch.mongoInlineEdit != nil {
      restoreSidebar(batch.mongoInlineEdit?.sidebarRestore)
      pendingStagedBatch = nil
    }
    var sidebarRestore: (edited: SidebarContent, original: SidebarContent?)?
    if case .rowDetail = rightSidebarContent {
    } else {
      let edited = SidebarContent.cellInfo(
        columnName: columnName,
        columnType: columnType,
        value: editedValue,
        tableName: tableName,
        rowData: rowData,
        primaryKeyColumns: primaryKeyColumns,
        cellId: cellId
      )
      sidebarRestore = (edited: edited, original: rightSidebarContent)
      sidebarRestoreWallClock = (edited: edited, wallClock: cellDetailWallClock)
      rightSidebarContent = edited
      cellDetailWallClock = wallClock
    }

    guard let connectionManager, var rowData else { return }
    // The sidebar's value decides how the text binds (base64 for bytes), as it does for the
    // validator and `editedCellValue`: its `rowData` is only refreshed by a re-run, so an edit
    // not re-read yet (Confirm, a stale result) left that column behind. A key keeps the stored
    // value the WHERE needs.
    if !primaryKeyColumns.contains(columnName) { rowData[columnName] = originalValue }
    if let message = Self.gridDateRefusal(
      newValue, original: originalValue, columnType: columnType, wallClock: wallClock,
      dialect: sqlDialect)
    {
      showToast(message, type: .error)
      restoreSidebar(sidebarRestore)
      return
    }
    let armed = submitInlineEdit(
      assignments: [(column: columnName, value: bindText)], rowData: rowData,
      target: cellDetailEditTarget, cellId: cellId, connectionManager: connectionManager,
      documentValue: (columnType: columnType, text: newValue), sidebarRestore: sidebarRestore,
      values: [columnName: editedValue])
    // A refused edit sends nothing: the sidebar shows the stored value again
    if !armed { restoreSidebar(sidebarRestore) }
  }

  /// A cell edit that stored nothing (refused, cancelled, dropped or failed): the Cell Value
  /// sidebar shows `restore.original` again while it still shows `restore.edited`, with the
  /// column flag it had (`sidebarRestoreWallClock`)
  func restoreSidebar(_ restore: (edited: SidebarContent, original: SidebarContent?)?) {
    guard let restore, rightSidebarContent == restore.edited else { return }
    rightSidebarContent = restore.original
    if let saved = sidebarRestoreWallClock, saved.edited == restore.edited {
      cellDetailWallClock = saved.wallClock
      sidebarRestoreWallClock = nil
    }
  }

  /// Gate shared by a cell edit and Row Details Apply: ONE UPDATE setting every `assignments`
  /// column of `rowData` against `target` (the cell's `cellDetailEditTarget`, the panel's own
  /// target), which must be live for `cellId`, checked by the protection gate, confirmed when
  /// the commit style asks, then sent. On MongoDB the one assignment is sent as a `$set` of
  /// `documentValue` (its column type and the typed text) at `documentPath` (nil: the column).
  /// `sidebarRestore` goes with the edit, put back when it stores nothing. `values` is what each
  /// assignment's text reads as (`editedCellValue`): a date binds as its instant
  /// (`boundAssignments`), the edit keeps the typed text. False: refused, nothing sent or armed
  /// (on MongoDB also: the editor sheet opened on the stored value).
  @discardableResult
  func submitInlineEdit(
    assignments: [(column: String, value: String?)], rowData: [String: CellValue],
    target: EditTarget?, cellId: UUID?, connectionManager: DatabaseConnectionManager,
    documentValue: (columnType: String, text: String?)? = nil, documentPath: [String]? = nil,
    sidebarRestore: (edited: SidebarContent, original: SidebarContent?)? = nil,
    values: [String: CellValue] = [:]
  ) -> Bool {
    if let reason = rowEditingUnsupportedReason {
      showToast(reason, type: .error)
      return false
    }
    guard !refuseWhileTransactionPendingElsewhere() else { return false }

    // Only the live target of the result the cell was opened from; never the passed table/key
    guard let target, isLiveEditTarget(target, cellId: cellId) else {
      showToast(Self.notEditableMessage, type: .error)
      return false
    }
    let columnNames = assignments.map(\.column)
    if let generated = columnNames.first(where: target.generatedColumns.contains) {
      showToast(Self.generatedColumnMessage(generated), type: .error)
      return false
    }
    // MongoDB: one `$set` through `executeGatedSequentialBatch`, never `executeGatedUpdate`
    if stagesDocuments {
      guard assignments.count == 1, let column = columnNames.first, let documentValue else {
        showToast(Self.oneDocumentFieldMessage, type: .error)
        return false
      }
      return handleDocumentValueEdit(
        columnName: column, columnType: documentValue.columnType, newValue: documentValue.text,
        rowData: rowData, target: target, cellId: cellId, path: documentPath,
        sidebarRestore: sidebarRestore)
    }

    let bound = Self.boundAssignments(assignments, values: values, dialect: sqlDialect)
    let statement: CellUpdateStatement
    do {
      statement = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, assignments: bound,
        primaryKeyColumns: target.primaryKeyColumns, rowData: rowData,
        updateOnly: target.updateOnly, dialect: sqlDialect)
    } catch {
      showToast(error.localizedDescription, type: .error)
      return false
    }

    // Protection level: same gate the actor enforces again before sending
    if let message = protectionBlockMessage(for: statement.sql) {
      showToast(message, type: .error)
      return false
    }

    let step = RewindPlan.inlineStep(
      assignments: bound, primaryKeyColumns: target.primaryKeyColumns, rowData: rowData)
    let edit = PendingInlineEdit(
      statement: statement, columnNames: columnNames, tableName: target.qualifiedName,
      cellId: cellId, connectionManager: connectionManager,
      rewindPlan: RewindPlan.make(
        target: target, resultColumns: liveResult(of: target, cellId: cellId)?.columns ?? [],
        editKind: .inline, steps: step.map { [$0] } ?? [],
        engine: notebook.connectionConfig?.databaseType,
        enabled: historySettings.rewindEnabled),
      inputValues: assignments.map(\.value), sidebarRestore: sidebarRestore)

    // Confirm and password ask before anything is sent. Review and immediate do not.
    if resolvedCommitStyle().confirmsWrites,
      presentConfirmationIfNeeded(for: statement.sql, cellId: cellId)
    {
      pendingExplainSQL = nil
      pendingStagedBatch = nil
      pendingInlineEdit = edit
      return true
    }

    Task { [weak self] in
      await self?.sendInlineEdit(edit, target: target)
    }
    return true
  }

  /// Commit style of this notebook's connection, or the app default when it has none.
  private func resolvedCommitStyle() -> CommitStyle {
    notebook.connectionConfig?.resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
      ?? AppSettings.shared.commitStyle
  }

  /// Shown when an edit targets a generated column
  nonisolated static func generatedColumnMessage(_ column: String) -> String {
    "'\(column)' is a generated column and cannot be edited"
  }

  /// Shown when an edit has no live target (result from a file, re-run or not a single table)
  nonisolated static let notEditableMessage =
    "This result is read-only: run the cell again to edit a single table with a primary key"

  /// Shown when Row Details applies more than one field of a MongoDB document at once
  nonisolated static let oneDocumentFieldMessage =
    "On MongoDB, Row Details applies one changed field at a time"

  /// Send an inline edit through the actor gate and refresh the cell. Review keeps the
  /// connection's policy and leaves the edit pending (`commitImmediately` false). Immediate,
  /// confirm, and password commit at once unless an app transaction is already open
  /// (`executeGatedUpdate` joins it). `target` must still be the live edit target of the
  /// edited result (same generation). Anything but exactly one updated row is reported as an
  /// error (the actor undoes it, see `DatabaseConnectionManager.executeGatedUpdate`).
  func sendInlineEdit(_ edit: PendingInlineEdit, target: EditTarget?) async {
    guard !refuseWhileTransactionPendingElsewhere() else {
      restoreSidebar(edit.sidebarRestore)
      return
    }
    guard let target, target.qualifiedName == edit.tableName,
      isLiveEditTarget(target, cellId: edit.cellId)
    else {
      restoreSidebar(edit.sidebarRestore)
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    let columnList = edit.columnNames.joined(separator: ", ")
    let started = Date()
    var updated = false
    do {
      let rowsAffected = try await edit.connectionManager.executeGatedUpdate(
        edit.statement,
        policy: protectionPolicy,
        connectionEpoch: target.connectionEpoch, caller: id,
        commitImmediately: resolvedCommitStyle() != .review, rewind: edit.rewindPlan)
      updated = true
      scheduleHistory(
        [
          QueryHistoryOutcome(
            sql: edit.statement.sql, duration: Date().timeIntervalSince(started),
            rowCount: rowsAffected, status: .success, errorMessage: nil)
        ], source: .dataViewerEdit)
      if let cellId = edit.cellId { cellsEditedInTransaction.insert(cellId) }
      // Success needs no toast: the refreshed cell (and the pending banner) shows it
      if rowsAffected != 1 {
        showToast(
          "Expected to update 1 row, updated \(rowsAffected) ('\(columnList)' in '\(edit.tableName)')",
          type: .error)
      }
      // Re-run the cell to refresh the table view with the stored data
      if let cellId = edit.cellId {
        await runCell(id: cellId)
      } else if dataViewer != nil {
        if hasPendingStagedChanges {
          // Refresh stored values without replacing the batch's generation or drafts.
          let count = edit.columnNames.count
          let newValues = edit.setInputValues
          let assignments = zip(edit.columnNames, newValues).map { (column: $0, value: $1) }
          let result = editorResult
          let columns = edit.columnNames.compactMap { name in
            result?.columns.firstIndex(where: { $0.name == name })
          }
          if isLiveEditTarget(target, cellId: nil), let result,
            columns.count == count,
            let row = result.rows.firstIndex(where: { values in
              guard
                let statement = try? CellUpdateStatement.make(
                  qualifiedName: target.qualifiedName, assignments: assignments,
                  primaryKeyColumns: target.primaryKeyColumns,
                  rowData: CellResult.rowData(columns: result.columns, row: values),
                  dialect: sqlDialect)
              else { return false }
              return statement.values.dropFirst(count) == edit.statement.values.dropFirst(count)
            })
          {
            let rowData = CellResult.rowData(columns: result.columns, row: result.rows[row])
            let key = RowChangeSet.RowKey(
              values: target.primaryKeyColumns.compactMap { rowData[$0] })
            for (name, (column, newValue)) in zip(edit.columnNames, zip(columns, newValues)) {
              let value = Self.editedCellValue(
                newValue, original: result.rows[row][column],
                columnType: result.columns[column].type,
                wallClock: result.columns[column].wallClock, dialect: sqlDialect)
              if var changes = dataViewer?.changeSet, changes.edits[key]?[name] != nil {
                try changes.stageEdit(row: key, column: name, value: value, original: value)
                dataViewer?.changeSet = changes.isEmpty ? nil : changes
              }
            }
            // Undo snapshots must not restore a draft over the value just committed.
            undoManager.removeAllActions()
            await refreshDataViewerRows(
              target: target, connectionManager: edit.connectionManager, done: "Cell updated")
          }
        } else {
          await loadDataViewerPage()
        }
      } else if rowsAffected == 1 {
        // Row Details takes the sent values as its row (kept when the re-run fails)
        rowDetailSent(edit, target: target)
        await refreshEditorResult(after: target)
      }
    } catch {
      // The UPDATE refused, failed or undone (a row count other than one): nothing is stored
      if !updated { restoreSidebar(edit.sidebarRestore) }
      recordFailure(
        error, sql: edit.statement.sql, duration: Date().timeIntervalSince(started),
        source: .dataViewerEdit)
      showToast(
        "Failed to update '\(columnList)': \(error.localizedDescription)", type: .error)
    }
    if updated { await onRelationsWritten?([edit.statement.sql], id, target.connectionEpoch) }
    await onStatementsExecuted?()
  }

  /// After an edit of the editor result whose live target is `target`: re-runs the query that
  /// produced it when that text passes `ReadOnlyQueryGuard`, through the user's read path (same
  /// gate and tab, so inside a pending app transaction it shows the uncommitted edit, as Run
  /// does), not recorded in history. A result of a script (re-running one statement would drop
  /// the others), of a refused statement or of a query with `:name` parameters (the result does
  /// not keep the values it ran with; the live ones may differ) shows "Run again to refresh".
  private func refreshEditorResult(after target: EditTarget) async {
    guard isLiveEditTarget(target, cellId: nil), let query = editorResult?.sourceQuery else {
      return
    }
    if editorStatementResults.isEmpty, !isEditorQueryRunning,
      parameterNames(in: query).isEmpty,
      (try? ReadOnlyQueryGuard.check(query, dialect: sqlDialect)) != nil
    {
      // No Safe Mode confirmation: safe only because ReadOnlyQueryGuard admits one read; do not
      // widen without routing through Safe Mode
      await executeEditorQuery(query, source: .internal)
      return
    }
    if editorResult?.editTarget == target { editorResult?.staleAfterEdit = true }
    // Kept when another statement of the script is selected and this one again
    editorStatementResults = editorStatementResults.map { statement in
      guard statement.result.editTarget == target else { return statement }
      var result = statement.result
      result.staleAfterEdit = true
      return StatementResult(
        id: statement.id, queryText: statement.queryText, result: result,
        statementIndex: statement.statementIndex)
    }
  }

  /// Re-reads the data viewer's page into the shown result, keeping its edit target (staged
  /// changes were made against that generation and stay valid) and its columns. The page is
  /// `mongoQueries()` for MongoDB (`pageSQL` asserts it is not), else `pageSQL`. A failed read
  /// shows "<done>, but failed to refresh"; a page, target, or column list that changed
  /// meanwhile is left as shown.
  func refreshDataViewerRows(
    target: EditTarget, connectionManager: DatabaseConnectionManager, done: String
  ) async {
    guard let result = editorResult, let state = dataViewer else { return }
    var stored: QueryResult
    var truncation: DataViewerState.Truncation?
    do {
      let epoch = await connectionManager.connectionEpoch
      let page: String
      if isMongoDataViewer {
        // Past the user limit there is no page to read
        guard let command = try state.mongoQueries().page else { return }
        page = command.render()
      } else {
        page = state.pageSQL
      }
      stored = try await connectionManager.execute(
        userSQL: page, policy: protectionPolicy,
        maxRows: max(state.pageSize, SessionBrakeLimits.rowCapRange.lowerBound), caller: id)
      if !isMongoDataViewer {
        (stored, truncation) = try await strippedDataViewerPage(
          stored, state: state, epoch: epoch, connectionManager: connectionManager)
      }
    } catch {
      showToast("\(done), but failed to refresh: \(error.localizedDescription)", type: .error)
      return
    }
    guard isLiveEditTarget(target, cellId: nil), dataViewer?.loadKey == state.loadKey,
      stored.columns.map(\.name) == result.columns.map(\.name)
    else { return }
    var updated = CellResult(
      columns: result.columns, rows: stored.rows, executionTime: result.executionTime,
      rowCount: stored.rows.count, timestamp: result.timestamp, error: result.error,
      wasLimited: result.wasLimited, sourceQuery: result.sourceQuery,
      tableName: result.tableName, primaryKeyColumns: result.primaryKeyColumns,
      affectedRows: result.affectedRows, editTarget: result.editTarget,
      lookupRelation: result.lookupRelation)
    updated.sessionReset = result.sessionReset
    updated.skippedStatements = result.skippedStatements
    updated.skippedQueuedCells = result.skippedQueuedCells
    updated.aiSessionKey = result.aiSessionKey
    // Same run, new rows: the timestamp stays (display mode, filters), the revision moves
    updated.dataRevision = result.dataRevision + 1
    updated.truncation = truncation
    if !isMongoDataViewer { resetLazyCells() }
    editorResult = updated
    syncRowDetail(cellId: nil, result: updated)
  }

  /// The edited text as a `CellValue` of the original's type (sidebar display and staged edits).
  /// Nil is NULL, whatever the original type. A NULL original takes `columnType`'s type (a date
  /// as `editedNewDate` on `dialect`, the connection's). A date reads the text its column shows
  /// (`CellValueValidator.date(from:wallClock:)`, `wallClock` is the column's
  /// `ColumnInfo.wallClock`), then ISO 8601; text of the stored date's own microsecond is that
  /// stored value (a decoded date's Double may differ from the parsed one).
  /// Nonisolated: Paste Rows types its values off the main actor.
  nonisolated static func editedCellValue(
    _ newValue: String?, original: CellValue, columnType: String = "", wallClock: Bool = false,
    dialect: SQLDialect = .postgresql
  ) -> CellValue {
    guard let newValue else { return .null }
    switch original {
    case .string:
      return .string(newValue)
    case .int:
      return Int(newValue).map(CellValue.int) ?? .string(newValue)
    case .double:
      return Double(newValue).map(CellValue.double) ?? .string(newValue)
    case .bool:
      return Bool(newValue).map(CellValue.bool) ?? .string(newValue)
    case .null:
      guard bindText(for: newValue, original: original) != nil else { return .null }
      let placeholder = CellValue.placeholder(forColumnType: columnType)
      // A NULL bytea cell binds the typed text as bytea input, not base64 (`CellUpdateStatement`)
      if case .data = placeholder { return .data(Data(newValue.utf8)) }
      if case .date = placeholder {
        return editedNewDate(
          newValue, columnType: columnType, wallClock: wallClock, dialect: dialect)
      }
      return editedCellValue(newValue, original: placeholder)
    case .json:
      return .json(newValue)
    case .date(let stored):
      guard
        let date = CellValueValidator.date(from: newValue, wallClock: wallClock)
          ?? ISO8601DateFormatter().date(from: newValue)
      else { return .string(newValue) }
      let micros = { (date: Date) in (date.timeIntervalSince1970 * 1_000_000).rounded() }
      return micros(date) == micros(stored) ? original : .date(date)
    case .data:
      return Data(base64Encoded: newValue).map(CellValue.data) ?? .string(newValue)
    case .decimal:
      // The typed text exactly (an exponent written out as plain digits), never through
      // Double; other text stays a string
      return DecimalText.exactText(typed: newValue).map(CellValue.decimal) ?? .string(newValue)
    }
  }

  /// `text` typed for a date column of `columnType` with no stored value (a NULL cell, a new or
  /// pasted row): a timestamp reads as a stored date's text is
  /// (`CellValueValidator.date(from:wallClock:)`) on an engine that decodes dates (PostgreSQL,
  /// MySQL and MariaDB, DuckDB), so the same text is the same instant whether the cell held a
  /// value or not. A DATE is a calendar day, not an instant: its text, other text, and any text
  /// on SQLite (whose dates are text) is sent as typed for the server to read, ISO 8601 aside.
  nonisolated static func editedNewDate(
    _ text: String, columnType: String, wallClock: Bool, dialect: SQLDialect
  ) -> CellValue {
    if columnType.uppercased() != "DATE",
      dialect == .postgresql || dialect == .mysql || dialect == .duckdb,
      let date = CellValueValidator.date(from: text, wallClock: wallClock)
    {
      return .date(date)
    }
    return ISO8601DateFormatter().date(from: text).map(CellValue.date) ?? .string(text)
  }

  /// Why `text` typed in a grid cell holding `original` (a column of `columnType`) cannot be
  /// sent on `dialect`, checked as the Cell Value sidebar does (`CellValueValidator`): date text
  /// (`yyyy-MM-dd` first) of a timestamp that reads as no instant, such as a wall clock the
  /// display zone skips or an impossible date, which the server would otherwise read in its
  /// session's zone. Nil for any other text (keywords like `now` or `infinity`, BC dates), a
  /// DATE column, SQLite (whose dates are text) and MongoDB (which reads its own dates).
  nonisolated static func gridDateRefusal(
    _ text: String?, original: CellValue, columnType: String, wallClock: Bool,
    dialect: SQLDialect
  ) -> String? {
    guard let text, dialect != .sqlite, dialect != .mongodb, columnType.uppercased() != "DATE",
      text.prefixMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil, !text.hasSuffix(" BC")
    else { return nil }
    switch original {
    case .date: break
    case .null:
      guard case .date = CellValue.placeholder(forColumnType: columnType) else { return nil }
    default: return nil
    }
    return CellValueValidator.validate(
      text, for: original, columnType: columnType, wallClock: wallClock
    ).errorMessage
  }

  /// `assignments` as the UPDATE binds them: the text of a column whose edited value
  /// (`values`, `editedCellValue`) is a date binds as that instant
  /// (`CellUpdateStatement.inputText`: UTC plain text on MySQL, right under its `+00:00`
  /// session, else ISO 8601 UTC), as a staged edit does, so the server stores the time the
  /// editor showed whatever its session zone. Any other text, and any text on SQLite (whose
  /// dates are text), binds as typed.
  nonisolated static func boundAssignments(
    _ assignments: [(column: String, value: String?)], values: [String: CellValue],
    dialect: SQLDialect
  ) -> [(column: String, value: String?)] {
    if dialect == .sqlite { return assignments }
    return assignments.map { assignment in
      guard assignment.value != nil, case .date(let date)? = values[assignment.column] else {
        return assignment
      }
      return (assignment.column, CellUpdateStatement.inputText(.date(date), dialect: dialect))
    }
  }
}
