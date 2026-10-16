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
      case .find(let collection, _, let projection, _, _, _)? = try? MongoshParser.parse(query),
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
    let results: [CellResult]
    if let cellId {
      guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return false }
      results = [cell.result].compactMap { $0 } + cell.statementResults.map(\.result)
    } else {
      results = [editorResult].compactMap { $0 } + editorStatementResults.map(\.result)
    }
    return results.contains { $0.editTarget == target }
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

  /// Handle cell value edit from sidebar
  /// - Parameter connectionManager: Optional connection manager from workspace for database updates
  func handleCellValueEdit(
    columnName: String,
    columnType: String,
    newValue: String?,
    originalValue: CellValue,
    tableName: String?,
    rowData: [String: CellValue]?,
    primaryKeyColumns: [String],
    cellId: UUID?,
    connectionManager: DatabaseConnectionManager? = nil
  ) {
    let bindText = Self.bindText(for: newValue, original: originalValue)

    // Copy to clipboard (an explicit NULL has no text to copy)
    if let newValue {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(newValue, forType: .string)
    }

    // Update the sidebar content with the new value. Open Row Details are not replaced by a
    // grid edit; the refresh after the send may still rebuild them and drop their drafts.
    if case .rowDetail = rightSidebarContent {
    } else {
      rightSidebarContent = .cellInfo(
        columnName: columnName,
        columnType: columnType,
        value: Self.editedCellValue(newValue, original: originalValue, columnType: columnType),
        tableName: tableName,
        rowData: rowData,
        primaryKeyColumns: primaryKeyColumns,
        cellId: cellId
      )
    }

    guard let connectionManager, let rowData else { return }
    submitInlineEdit(
      assignments: [(column: columnName, value: bindText)], rowData: rowData,
      target: cellDetailEditTarget, cellId: cellId, connectionManager: connectionManager,
      documentValue: (columnType: columnType, text: newValue))
  }

  /// Gate shared by a cell edit and Row Details Apply: ONE UPDATE setting every `assignments`
  /// column of `rowData` against `target` (the cell's `cellDetailEditTarget`, the panel's own
  /// target), which must be live for `cellId`, checked by the protection gate, confirmed when
  /// the commit style asks, then sent. On MongoDB the one assignment is sent as a `$set` of
  /// `documentValue` (its column type and the typed text) at `documentPath` (nil: the column).
  func submitInlineEdit(
    assignments: [(column: String, value: String?)], rowData: [String: CellValue],
    target: EditTarget?, cellId: UUID?, connectionManager: DatabaseConnectionManager,
    documentValue: (columnType: String, text: String?)? = nil, documentPath: [String]? = nil
  ) {
    if let reason = rowEditingUnsupportedReason {
      showToast(reason, type: .error)
      return
    }
    guard !refuseWhileTransactionPendingElsewhere() else { return }

    // Only the live target of the result the cell was opened from; never the passed table/key
    guard let target, isLiveEditTarget(target, cellId: cellId) else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    let columnNames = assignments.map(\.column)
    if let generated = columnNames.first(where: target.generatedColumns.contains) {
      showToast(Self.generatedColumnMessage(generated), type: .error)
      return
    }
    // MongoDB: one `$set` through `executeGatedSequentialBatch`, never `executeGatedUpdate`
    if stagesDocuments {
      guard assignments.count == 1, let column = columnNames.first, let documentValue else {
        showToast(Self.oneDocumentFieldMessage, type: .error)
        return
      }
      handleDocumentValueEdit(
        columnName: column, columnType: documentValue.columnType, newValue: documentValue.text,
        rowData: rowData, target: target, cellId: cellId, path: documentPath)
      return
    }

    let statement: CellUpdateStatement
    do {
      statement = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, assignments: assignments,
        primaryKeyColumns: target.primaryKeyColumns, rowData: rowData,
        updateOnly: target.updateOnly, dialect: sqlDialect)
    } catch {
      showToast(error.localizedDescription, type: .error)
      return
    }

    // Protection level: same gate the actor enforces again before sending
    if let message = protectionBlockMessage(for: statement.sql) {
      showToast(message, type: .error)
      return
    }

    let edit = PendingInlineEdit(
      statement: statement, columnNames: columnNames, tableName: target.qualifiedName,
      cellId: cellId, connectionManager: connectionManager)

    // Confirm and password ask before anything is sent. Review and immediate do not.
    if resolvedCommitStyle().confirmsWrites,
      presentConfirmationIfNeeded(for: statement.sql, cellId: cellId)
    {
      pendingExplainSQL = nil
      pendingStagedBatch = nil
      pendingInlineEdit = edit
      return
    }

    Task { [weak self] in
      await self?.sendInlineEdit(edit, target: target)
    }
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
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    guard let target, target.qualifiedName == edit.tableName,
      isLiveEditTarget(target, cellId: edit.cellId)
    else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    let columnList = edit.columnNames.joined(separator: ", ")
    let started = Date()
    do {
      let rowsAffected = try await edit.connectionManager.executeGatedUpdate(
        edit.statement,
        policy: protectionPolicy,
        connectionEpoch: target.connectionEpoch, caller: id,
        commitImmediately: resolvedCommitStyle() != .review)
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
          let newValues = Array(edit.statement.values.prefix(count))
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
              let value = Self.editedCellValue(newValue, original: result.rows[row][column])
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
        // A plain editor result is not re-run: Row Details takes the sent values as its row
        rowDetailSent(edit, target: target)
      }
    } catch {
      recordFailure(
        error, sql: edit.statement.sql, duration: Date().timeIntervalSince(started),
        source: .dataViewerEdit)
      showToast(
        "Failed to update '\(columnList)': \(error.localizedDescription)", type: .error)
    }
    await onStatementsExecuted?()
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
    let stored: QueryResult
    do {
      let page = isMongoDataViewer ? try state.mongoQueries().page.render() : state.pageSQL
      stored = try await connectionManager.execute(
        userSQL: page, policy: protectionPolicy,
        maxRows: max(state.pageSize, SessionBrakeLimits.rowCapRange.lowerBound), caller: id)
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
    editorResult = updated
    syncRowDetail(cellId: nil, result: updated)
  }

  /// The edited text as a `CellValue` of the original's type (sidebar display and staged edits).
  /// Nil is NULL, whatever the original type. A NULL original takes `columnType`'s type.
  static func editedCellValue(
    _ newValue: String?, original: CellValue, columnType: String = ""
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
      return bindText(for: newValue, original: original) == nil
        ? .null : editedCellValue(newValue, original: .placeholder(forColumnType: columnType))
    case .json:
      return .json(newValue)
    case .date:
      return ISO8601DateFormatter().date(from: newValue).map(CellValue.date) ?? .string(newValue)
    case .data:
      return .data(Data(newValue.utf8))
    }
  }
}
