//
//  NotebookViewModel+AddRow.swift
//  Dblore
//
//  Add Row form of the data viewer in the right sidebar. Add stages one insert with the
//  form's values; Commit sends it like any other staged row.
//

import Foundation

extension NotebookViewModel {
  /// + Row: opens the form, or closes it when it is already shown.
  func toggleAddRowForm() async {
    if isRightSidebarVisible && rightSidebarContent == .addRow {
      closeSidebar()
      return
    }
    await openAddRowForm()
  }

  /// Opens the form with empty fields (the grid's "Add Row" menu item).
  func openAddRowForm() async {
    if let reason = rowStagingUnavailableReason {
      showToast(reason, type: .error)
      return
    }
    await prepareAddRowFields()
    guard dataViewer != nil, !addRowFields.isEmpty else { return }
    showSidebar(content: .addRow)
  }

  /// One empty field per result column. A single integer primary key with no database default
  /// is set to the next number, as + Row did.
  func prepareAddRowFields() async {
    guard let state = dataViewer, let result = editorResult else {
      addRowFields = []
      return
    }
    let table = databaseTables.first { $0.schema == state.schema && $0.name == state.name }
    let primaryKey = Set(result.editTarget?.primaryKeyColumns ?? result.primaryKeyColumns)
    let generated = result.editTarget?.generatedColumns ?? []
    var fields = result.columns.map { column in
      let info = table?.columns.first { $0.name == column.name }
      return NewRowField(
        name: column.name, type: column.type,
        isPrimaryKey: primaryKey.contains(column.name) || info?.isPrimaryKey == true,
        isNullable: info?.isNullable ?? true, isIdentity: info?.isIdentity ?? false,
        isGenerated: generated.contains(column.name) || info?.isGenerated == true)
    }
    for (column, value) in await automaticIntegerKeyValues() {
      guard let index = fields.firstIndex(where: { $0.name == column }) else { continue }
      fields[index].text = value.fullString
    }
    // The key lookup awaited: another relation may be shown now
    guard dataViewer?.schema == state.schema, dataViewer?.name == state.name else { return }
    addRowFields = fields
  }

  /// Fields that block Add
  var addRowHasErrors: Bool {
    addRowFields.contains { $0.validationError != nil }
  }

  /// Stages the form as a new row, closes the form, and empties it with the next key, so
  /// reopening the sidebar cannot add the same row twice. A refused insert keeps it open.
  func applyAddRow() {
    guard !addRowHasErrors else { return }
    if let message = stageInsert(values: NewRowField.values(addRowFields)) {
      showToast(message, type: .error)
      return
    }
    closeSidebar()
    addRowFields = addRowFields.map { field in
      var empty = field
      empty.text = ""
      empty.isNull = false
      return empty
    }
    Task { await prepareAddRowFields() }
  }
}
