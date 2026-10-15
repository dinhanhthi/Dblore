//
//  NotebookViewModel+RowDetail.swift
//  Dblore
//
//  Row Details in the right sidebar: every column of one result row, editable as drafts until
//  Apply. Opening another row replaces the drafts.
//

import Foundation

extension NotebookViewModel {
  /// Opens Row Details for result row `originalRow` (`row` = its displayed values). In the data
  /// viewer, a row past the loaded page is a staged insert read from the change set.
  func showRowDetail(row: [CellValue], originalRow: Int, result: CellResult, cellId: UUID?) {
    guard let state = makeRowDetailState(row: row, originalRow: originalRow, result: result)
    else { return }
    cellDetailEditTarget = result.editTarget
    cellDetailRow = originalRow
    rowDetail = state
    showSidebar(content: .rowDetail(cellId: cellId))
  }

  /// Row Details state of result row `originalRow` with fresh originals (no drafts), or nil when
  /// a staged insert is no longer in the change set
  private func makeRowDetailState(
    row: [CellValue], originalRow: Int, result: CellResult
  ) -> RowDetailState? {
    let stagedInsertIndex =
      dataViewer != nil && originalRow >= result.rows.count
      ? originalRow - result.rows.count : nil
    let values: [String: CellValue]
    var stagedInsertID: UUID?
    if let stagedInsertIndex {
      guard let inserts = dataViewer?.changeSet?.inserts,
        inserts.indices.contains(stagedInsertIndex)
      else { return nil }
      values = inserts[stagedInsertIndex].values
      stagedInsertID = inserts[stagedInsertIndex].tempID
    } else {
      values = CellResult.rowData(columns: result.columns, row: row)
    }

    let primaryKey = result.editTarget?.primaryKeyColumns ?? result.primaryKeyColumns
    let editable = canEdit(result)
    let readOnlyIndexes = readOnlyColumnIndexes(result)
    let generated = result.editTarget?.generatedColumns ?? []
    let target = result.editTarget
    let table = databaseTables.first { $0.schema == target?.schema && $0.name == target?.name }
    let fields = result.columns.enumerated().map { index, column in
      let info = table?.columns.first { $0.name == column.name }
      let isPrimaryKey = primaryKey.contains(column.name)
      let field = NewRowField(
        name: column.name, type: column.type, isPrimaryKey: isPrimaryKey,
        isNullable: info?.isNullable ?? true, isIdentity: info?.isIdentity ?? false,
        isGenerated: generated.contains(column.name) || info?.isGenerated == true)
      let isReadOnly =
        !editable || readOnlyIndexes.contains(index) || field.isGenerated
        || (isPrimaryKey && stagedInsertIndex == nil)
      return RowDetailField(
        field: field, original: values[column.name] ?? .null, isReadOnly: isReadOnly)
    }

    return RowDetailState(
      tableName: result.tableName,
      rowNumber: originalRow + 1,
      keyPairs: primaryKey.map { RowDetailKey(name: $0, value: values[$0] ?? .null) },
      rowData: values,
      primaryKeyColumns: primaryKey,
      originalRow: originalRow,
      stagedInsertID: stagedInsertID,
      editTarget: target,
      fields: fields)
  }

  /// Current position of the staged insert `tempID` in the change set, or nil when it is gone
  private func stagedInsertIndex(of tempID: UUID) -> Int? {
    dataViewer?.changeSet?.inserts.firstIndex { $0.tempID == tempID }
  }

  /// Drops the panel of a staged insert that is no longer staged (reverted, discarded or
  /// committed), so nothing stale stays editable. True when it was dropped.
  @discardableResult
  func dropRowDetailOfRemovedInsert() -> Bool {
    guard let tempID = rowDetail?.stagedInsertID, stagedInsertIndex(of: tempID) == nil else {
      return false
    }
    rowDetail = nil
    if case .rowDetail = rightSidebarContent { closeSidebar() }
    return true
  }

  /// An editable field differs from its original
  var rowDetailHasChanges: Bool {
    rowDetail?.fields.contains { !$0.isReadOnly && $0.isDirty } ?? false
  }

  /// A draft blocks Apply
  var rowDetailHasErrors: Bool {
    rowDetail?.fields.contains { $0.validationError != nil } ?? false
  }

  /// Cancel: every field back to its original. The sidebar stays open.
  func cancelRowDetailEdits() {
    guard var state = rowDetail else { return }
    for index in state.fields.indices {
      state.fields[index].revert()
    }
    rowDetail = state
  }

  /// Apply: the dirty editable fields. A staged insert stages them (Commit sends them later). A
  /// loaded row is sent as ONE UPDATE through the inline-edit gate, unless it is staged for
  /// deletion.
  func applyRowDetail() {
    guard let state = rowDetail, case .rowDetail(let cellId) = rightSidebarContent else { return }
    let dirty = state.fields.filter { !$0.isReadOnly && $0.isDirty }
    guard !dirty.isEmpty else { return }

    if let tempID = state.stagedInsertID {
      guard let result = editorResult else { return }
      guard Self.isSameTable(result.editTarget, state.editTarget) else {
        showToast(Self.notEditableMessage, type: .error)
        return
      }
      guard let insertIndex = stagedInsertIndex(of: tempID) else {
        dropRowDetailOfRemovedInsert()
        showToast(Self.removedInsertMessage, type: .error)
        return
      }
      let row = result.rows.count + insertIndex
      for field in dirty {
        let value = Self.rowDetailValue(field.bindText, of: field)
        if let message = stageEdit(row: row, column: field.name, value: value) {
          showToast(message, type: .error)
          return
        }
      }
      if let state = makeRowDetailState(row: [], originalRow: row, result: result) {
        rowDetail = state
      }
      return
    }

    if dataViewer != nil {
      let key = RowChangeSet.RowKey(
        values: state.primaryKeyColumns.compactMap { state.rowData[$0] })
      if dataViewer?.changeSet?.deletes.contains(key) == true {
        showToast(RowChangeError.deletedRow.message, type: .error)
        return
      }
    }

    guard let connectionManager else { return }
    // A grid edit of another result may have replaced the shared target: the confirmation
    // sends with it, so it must be the panel's again
    cellDetailEditTarget = state.editTarget
    let documentValue =
      dirty.count == 1 ? (columnType: dirty[0].field.type, text: dirty[0].bindText) : nil
    submitInlineEdit(
      assignments: dirty.map { (column: $0.name, value: $0.bindText) }, rowData: state.rowData,
      target: state.editTarget, cellId: cellId, connectionManager: connectionManager,
      documentValue: documentValue)
  }

  /// The bound `text` of `field` as a `CellValue`. The NULL toggle decides NULL (nil text): a
  /// NULL original is typed by the column, not read as NULL, so "" or "null" stay text.
  private static func rowDetailValue(_ text: String?, of field: RowDetailField) -> CellValue {
    let original =
      field.original == .null ? .placeholder(forColumnType: field.field.type) : field.original
    return editedCellValue(text, original: original)
  }

  /// Shown when Apply targets a staged insert that is no longer staged
  nonisolated static let removedInsertMessage = "This new row is no longer staged"

  /// After `edit` updated one row of a plain editor result (not re-run, so no sync): when Row
  /// Details shows that row, the sent values become its originals and those drafts are clean.
  func rowDetailSent(_ edit: PendingInlineEdit, target: EditTarget) {
    guard let state = rowDetail, state.stagedInsertID == nil,
      case .rowDetail(let cellId) = rightSidebarContent, cellId == edit.cellId,
      Self.isSameTable(target, state.editTarget)
    else { return }
    // Same table, columns and key: the panel's row rebuilds the very statement that was sent
    let assignments = zip(edit.columnNames, edit.statement.values).map { (column: $0, value: $1) }
    guard
      let statement = try? CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, assignments: assignments,
        primaryKeyColumns: target.primaryKeyColumns, rowData: state.rowData,
        updateOnly: target.updateOnly, dialect: sqlDialect),
      statement == edit.statement
    else { return }

    var rowData = state.rowData
    let fields = state.fields.map { field in
      guard let index = edit.columnNames.firstIndex(of: field.name) else { return field }
      let value = Self.rowDetailValue(edit.statement.values[index], of: field)
      rowData[field.name] = value
      return RowDetailField(field: field.field, original: value, isReadOnly: field.isReadOnly)
    }
    rowDetail = RowDetailState(
      tableName: state.tableName, rowNumber: state.rowNumber, keyPairs: state.keyPairs,
      rowData: rowData, primaryKeyColumns: state.primaryKeyColumns,
      originalRow: state.originalRow, stagedInsertID: nil, editTarget: state.editTarget,
      fields: fields)
  }

  /// After `result` replaced the result of `cellId` (nil = editor), re-read the Row Details row
  /// from it: a staged insert by its `tempID` (dropped when it is gone), else the same row by
  /// primary key when there is one, else by position. Originals are fresh and drafts dropped;
  /// the panel of a loaded row keeps its state when the row is gone. A panel of a table keeps
  /// it too when `result` is not of that table (another statement of the same cell or editor).
  func syncRowDetail(cellId: UUID?, result: CellResult?) {
    guard let result, result.error == nil, let state = rowDetail,
      case .rowDetail(let sidebarCellId) = rightSidebarContent, sidebarCellId == cellId,
      state.editTarget == nil || Self.isSameTable(result.editTarget, state.editTarget)
    else { return }

    if let tempID = state.stagedInsertID {
      guard let index = stagedInsertIndex(of: tempID) else {
        dropRowDetailOfRemovedInsert()
        return
      }
      if let rebuilt = makeRowDetailState(
        row: [], originalRow: result.rows.count + index, result: result)
      {
        cellDetailEditTarget = result.editTarget
        cellDetailRow = rebuilt.originalRow
        rowDetail = rebuilt
      }
      return
    }

    let rowIndex: Int?
    if !state.primaryKeyColumns.isEmpty {
      rowIndex = result.rows.firstIndex { row in
        let data = CellResult.rowData(columns: result.columns, row: row)
        return state.primaryKeyColumns.allSatisfy { data[$0] == state.rowData[$0] }
      }
    } else {
      rowIndex = cellDetailRow
    }
    guard let rowIndex, result.rows.indices.contains(rowIndex),
      let rebuilt = makeRowDetailState(
        row: result.rows[rowIndex], originalRow: rowIndex, result: result)
    else { return }
    cellDetailEditTarget = result.editTarget
    cellDetailRow = rowIndex
    rowDetail = rebuilt
  }
}
