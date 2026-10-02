//
//  NotebookViewModel+InlineEdit.swift
//  Dblore
//
//  Inline grid edit: primary-key-only UPDATE, checked by the protection gate (never Safe Mode)
//  and staged in the app transaction or committed at once (`inlineEditAutoCommit`).
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

  /// Same check for the sidebar cell (`columnNames` = the row's columns). Only the live target
  /// captured by `showCellDetail` counts; the passed table name and key are display data.
  func canEdit(
    tableName _: String?, primaryKeyColumns _: [String], columnNames: Set<String>
  ) -> Bool {
    guard let target = cellDetailEditTarget else { return false }
    return canEdit(target: target, columnNames: columnNames)
  }

  private func canEdit(target: EditTarget, columnNames: Set<String>) -> Bool {
    protectionPolicy.protectionLevel != .readOnly && !target.primaryKeyColumns.isEmpty
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
    guard !result.columns.isEmpty, let relation = CellUpdateStatement.singleRelation(in: query),
      let tableID = Self.columnTableID(result.columns),
      let table = await editTable(relation, tableID: tableID, connectionManager),
      table.connectionEpoch == epoch,
      CellUpdateStatement.isServerQualifiedName(table.qualifiedName)
    else { return nil }
    let primaryKey = CellUpdateStatement.editablePrimaryKey(columns: result.columns, table: table)
    guard !primaryKey.isEmpty else { return nil }
    return EditTarget(
      qualifiedName: table.qualifiedName, tableID: tableID, primaryKeyColumns: primaryKey,
      connectionEpoch: table.connectionEpoch, updateOnly: table.updateOnly)
  }

  /// The one table identity shared by every column, or nil when any column came from elsewhere.
  static func columnTableID(_ columns: [ColumnInfo]) -> TableRef? {
    guard let tableID = columns.first?.origin?.tableID,
      columns.allSatisfy({ $0.origin?.tableID == tableID })
    else { return nil }
    return tableID
  }

  /// `relation` resolved by the server, or, while the app transaction is pending (no catalog
  /// query is sent), the table cached under the result columns' `tableID`.
  private func editTable(
    _ relation: String, tableID: TableRef, _ connectionManager: DatabaseConnectionManager
  ) async -> EditTable? {
    if await connectionManager.isMetadataPaused {
      return await connectionManager.cachedEditTable(id: tableID)
    }
    do {
      return try await connectionManager.fetchEditTable(tableName: relation, tableID: tableID)
    } catch {
      return nil
    }
  }

  /// The connection changed (connect/disconnect): no displayed result stays editable, and the
  /// open sidebar cell or a pending edit can no longer be sent. Results stay displayed.
  func invalidateEditTargets() {
    for index in notebook.cells.indices {
      notebook.cells[index].result?.editTarget = nil
      notebook.cells[index].statementResults = notebook.cells[index].statementResults.map(
        Self.withoutEditTarget)
    }
    editorResult?.editTarget = nil
    editorStatementResults = editorStatementResults.map(Self.withoutEditTarget)
    cellDetailEditTarget = nil
  }

  private nonisolated static func withoutEditTarget(_ statement: StatementResult) -> StatementResult
  {
    var result = statement.result
    result.editTarget = nil
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
    let sameTable =
      next?.tableID == current.tableID && next?.qualifiedName == current.qualifiedName
      && next?.primaryKeyColumns == current.primaryKeyColumns
    cellDetailEditTarget = sameTable ? next : nil
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

    // Update the sidebar content with the new value
    rightSidebarContent = .cellInfo(
      columnName: columnName,
      columnType: columnType,
      value: Self.editedCellValue(newValue, original: originalValue),
      tableName: tableName,
      rowData: rowData,
      primaryKeyColumns: primaryKeyColumns,
      cellId: cellId
    )

    guard let connectionManager, let rowData else { return }
    guard !refuseWhileTransactionPendingElsewhere() else { return }

    // Only the live target of the result the cell was opened from; never the passed table/key
    guard let target = cellDetailEditTarget, isLiveEditTarget(target, cellId: cellId) else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }

    let statement: CellUpdateStatement
    do {
      statement = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, columnName: columnName, newValue: bindText,
        primaryKeyColumns: target.primaryKeyColumns, rowData: rowData,
        updateOnly: target.updateOnly)
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
      statement: statement, columnName: columnName, tableName: target.qualifiedName,
      cellId: cellId, connectionManager: connectionManager)

    // No Safe Mode confirmation: the edit is staged (Commit / Rollback) unless committed at once
    let autoCommit = AppSettings.shared.inlineEditAutoCommit
    Task { [weak self] in
      await self?.sendInlineEdit(edit, target: target, autoCommit: autoCommit)
    }
  }

  /// Shown when an edit has no live target (result from a file, re-run or not a single table)
  nonisolated static let notEditableMessage =
    "This result is read-only: run the cell again to edit a single table with a primary key"

  /// Send an inline edit through the actor gate and refresh the cell. `autoCommit` false stages
  /// it in the app transaction (Protected mode forced, whatever the connection's toggle); true
  /// commits it at once unless a transaction is pending (see `executeGatedUpdate`).
  /// `target` must still be the live edit target of the edited result (same generation).
  /// Anything but exactly one updated row is reported as an error (the actor undoes it, see
  /// `DatabaseConnectionManager.executeGatedUpdate`).
  func sendInlineEdit(_ edit: PendingInlineEdit, target: EditTarget?, autoCommit: Bool) async {
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    guard let target, target.qualifiedName == edit.tableName,
      isLiveEditTarget(target, cellId: edit.cellId)
    else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    let started = Date()
    do {
      let policy = protectionPolicy
      let rowsAffected = try await edit.connectionManager.executeGatedUpdate(
        edit.statement,
        policy: autoCommit
          ? policy
          : ProtectionPolicy(
            protectionLevel: policy.protectionLevel, safeMode: policy.safeMode,
            protectedMode: true),
        connectionEpoch: target.connectionEpoch, caller: id, commitImmediately: autoCommit)
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
          "Expected to update 1 row, updated \(rowsAffected) ('\(edit.columnName)' in '\(edit.tableName)')",
          type: .error)
      }
      // Re-run the cell to refresh the table view with the stored data
      if let cellId = edit.cellId {
        await runCell(id: cellId)
      } else if dataViewer != nil {
        // Data viewer: reload the current page
        await loadDataViewerPage()
      }
    } catch {
      recordFailure(
        error, sql: edit.statement.sql, duration: Date().timeIntervalSince(started),
        source: .dataViewerEdit)
      showToast(
        "Failed to update '\(edit.columnName)': \(error.localizedDescription)", type: .error)
    }
    await onStatementsExecuted?()
  }

  /// The edited text as a `CellValue` of the original's type (sidebar display and staged edits).
  /// Nil is NULL, whatever the original type.
  static func editedCellValue(_ newValue: String?, original: CellValue) -> CellValue {
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
      return bindText(for: newValue, original: original) == nil ? .null : .string(newValue)
    case .json:
      return .json(newValue)
    case .date:
      return ISO8601DateFormatter().date(from: newValue).map(CellValue.date) ?? .string(newValue)
    case .data:
      return .data(Data(newValue.utf8))
    }
  }
}
