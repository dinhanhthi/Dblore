//
//  NotebookViewModel+InlineEdit.swift
//  SQLNotebook
//
//  Inline grid edit: primary-key-only UPDATE, checked by the protection gate and confirmed by
//  Safe Mode before anything is sent.
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
  /// search_path) to its OID and `%I.%I` name; every result column must be a plain column of
  /// that table (`CellUpdateStatement.editablePrimaryKey`). `epoch` is the connection epoch
  /// read before `query` ran: if the table resolves on another connection (reconnect in
  /// between), the rows and the table may not match, so there is no target.
  func editTarget(
    for query: String, result: QueryResult, connectionManager: DatabaseConnectionManager,
    epoch: UInt64
  ) async -> EditTarget? {
    guard !result.columns.isEmpty, let relation = CellUpdateStatement.singleRelation(in: query),
      let table = await editTable(relation, columns: result.columns, connectionManager),
      table.connectionEpoch == epoch,
      CellUpdateStatement.isServerQualifiedName(table.qualifiedName)
    else { return nil }
    let primaryKey = CellUpdateStatement.editablePrimaryKey(columns: result.columns, table: table)
    guard !primaryKey.isEmpty else { return nil }
    return EditTarget(
      qualifiedName: table.qualifiedName, oid: table.oid, primaryKeyColumns: primaryKey,
      connectionEpoch: table.connectionEpoch, updateOnly: table.updateOnly)
  }

  /// `relation` resolved by the server, or, while the app transaction is pending (no catalog
  /// query is sent), the table resolved before it for the result's source table OID.
  private func editTable(
    _ relation: String, columns: [ColumnInfo], _ connectionManager: DatabaseConnectionManager
  ) async -> EditTable? {
    do {
      return try await connectionManager.fetchEditTable(tableName: relation)
    } catch DatabaseError.metadataPausedDuringTransaction {
      guard let oid = columns.first?.tableOID, columns.allSatisfy({ $0.tableOID == oid }) else {
        return nil
      }
      return await connectionManager.cachedEditTable(oid: oid)
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
    pendingInlineEditTarget = nil
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

  /// Input text to bind for an edited value: nil (NULL) when a NULL cell is left empty or set
  /// to "null", otherwise the text as typed (PostgreSQL parses it for the column type).
  nonisolated static func bindText(for newValue: String, original: CellValue) -> String? {
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
      next?.oid == current.oid && next?.qualifiedName == current.qualifiedName
      && next?.primaryKeyColumns == current.primaryKeyColumns
    cellDetailEditTarget = sameTable ? next : nil
  }

  // MARK: - Edit

  /// Handle cell value edit from sidebar
  /// - Parameter connectionManager: Optional connection manager from workspace for database updates
  func handleCellValueEdit(
    columnName: String,
    columnType: String,
    newValue: String,
    originalValue: CellValue,
    tableName: String?,
    rowData: [String: CellValue]?,
    primaryKeyColumns: [String],
    cellId: UUID?,
    connectionManager: DatabaseConnectionManager? = nil
  ) {
    let bindText = Self.bindText(for: newValue, original: originalValue)

    // Copy to clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(newValue, forType: .string)

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

    guard let connectionManager, let rowData else {
      showToast("Value copied to clipboard", type: .info)
      return
    }
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

    // Safe Mode: ask before sending, with the generated UPDATE as preview
    if presentConfirmationIfNeeded(for: statement.sql, cellId: cellId) {
      queryConfirmationState.pendingInlineEdit = edit
      pendingInlineEditTarget = target
      return
    }

    Task { [weak self] in
      await self?.sendInlineEdit(edit, target: target)
    }
  }

  /// Shown when an edit has no live target (result from a file, re-run or not a single table)
  nonisolated static let notEditableMessage =
    "This result is read-only: run the cell again to edit a single table with a primary key"

  /// Send a (confirmed) inline edit through the actor gate and refresh the cell.
  /// `target` must still be the live edit target of the edited result (same generation).
  /// Anything but exactly one updated row is reported as an error (the actor undoes it, see
  /// `DatabaseConnectionManager.executeGatedUpdate`).
  func sendInlineEdit(_ edit: PendingInlineEdit, target: EditTarget?) async {
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    guard let target, target.qualifiedName == edit.tableName,
      isLiveEditTarget(target, cellId: edit.cellId)
    else {
      showToast(Self.notEditableMessage, type: .error)
      return
    }
    do {
      let rowsAffected = try await edit.connectionManager.executeGatedUpdate(
        edit.statement, policy: protectionPolicy, connectionEpoch: target.connectionEpoch,
        caller: id)
      if rowsAffected == 1 {
        showToast("Updated '\(edit.columnName)' in '\(edit.tableName)' (1 row)", type: .success)
      } else {
        showToast(
          "Expected to update 1 row, updated \(rowsAffected) ('\(edit.columnName)' in '\(edit.tableName)')",
          type: .error)
      }
      // Re-run the cell to refresh the table view with the stored data
      if let cellId = edit.cellId {
        await runCell(id: cellId)
      }
    } catch {
      showToast(
        "Failed to update '\(edit.columnName)': \(error.localizedDescription)", type: .error)
    }
    await onStatementsExecuted?()
  }

  /// The edited text as a `CellValue` of the original's type (sidebar display only)
  private static func editedCellValue(_ newValue: String, original: CellValue) -> CellValue {
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
