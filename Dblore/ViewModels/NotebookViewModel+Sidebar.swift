//
//  NotebookViewModel+Sidebar.swift
//  Dblore
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Sidebar Management

extension NotebookViewModel {
  // MARK: - Right Sidebar

  /// Show `content` in the right sidebar, sliding it in when it was closed. Every entry point
  /// that opens the sidebar goes through here so opening animates like closing.
  func showSidebar(content: SidebarContent) {
    rightSidebarContent = content
    withSidebarAnimation {
      isRightSidebarVisible = true
    }
    handleRightSidebarConflict()
  }

  /// Show JSON in the sidebar
  func showJSONInSidebar(json: String, path: String) {
    showSidebar(content: .jsonViewer(json: json, path: path))
  }

  /// Show cell value details in sidebar
  func showCellDetail(
    columnName: String,
    columnType: String,
    value: CellValue,
    tableName: String? = nil,
    rowData: [String: CellValue]? = nil,
    primaryKeyColumns: [String] = [],
    editTarget: EditTarget? = nil,
    cellId: UUID? = nil
  ) {
    cellDetailEditTarget = editTarget
    showSidebar(
      content: .cellInfo(
        columnName: columnName,
        columnType: columnType,
        value: value,
        tableName: tableName,
        rowData: rowData,
        primaryKeyColumns: primaryKeyColumns,
        cellId: cellId
      ))
  }

  // Note: showConnectionForm() removed - connection form is now at workspace level
  // Note: showSettings() removed - settings is now a modal at workspace level

  /// Toggle sidebar visibility
  func toggleSidebar() {
    withSidebarAnimation {
      isRightSidebarVisible.toggle()
    }
    if isRightSidebarVisible {
      handleRightSidebarConflict()
    }
  }

  /// Close the sidebar
  func closeSidebar() {
    withSidebarAnimation {
      isRightSidebarVisible = false
    }
  }

  // MARK: - Left Sidebar - Database Schema

  // Note: loadDatabaseSchema() and refreshDatabaseSchema() removed
  // Schema loading is now handled at workspace level (WorkspaceManager)
  // Schema data is synced to NotebookViewModel via WorkspaceTabContentView.syncConnectionState()

  /// Toggle table expansion state
  func toggleTableExpansion(tableId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseTables.firstIndex(where: { $0.id == tableId }) {
        databaseTables[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle view expansion state
  func toggleViewExpansion(viewId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseViews.firstIndex(where: { $0.id == viewId }) {
        databaseViews[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle function expansion state
  func toggleFunctionExpansion(functionId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseFunctions.firstIndex(where: { $0.id == functionId }) {
        databaseFunctions[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle procedure expansion state
  func toggleProcedureExpansion(procedureId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseProcedures.firstIndex(where: { $0.id == procedureId }) {
        databaseProcedures[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle user expansion state
  func toggleUserExpansion(userId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseUsers.firstIndex(where: { $0.id == userId }) {
        databaseUsers[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle role expansion state
  func toggleRoleExpansion(roleId: UUID) {
    withAnimation(.snappy(duration: 0.2)) {
      if let index = databaseRoles.firstIndex(where: { $0.id == roleId }) {
        databaseRoles[index].isExpanded.toggle()
      }
    }
  }

  /// Toggle expand/collapse all entities in the sidebar
  func toggleExpandCollapseAll() {
    withAnimation(.snappy(duration: 0.25)) {
      areAllEntitiesExpanded.toggle()

      // Apply to all entities
      for index in databaseTables.indices {
        databaseTables[index].isExpanded = areAllEntitiesExpanded
      }
      for index in databaseViews.indices {
        databaseViews[index].isExpanded = areAllEntitiesExpanded
      }
      for index in databaseFunctions.indices {
        databaseFunctions[index].isExpanded = areAllEntitiesExpanded
      }
      for index in databaseProcedures.indices {
        databaseProcedures[index].isExpanded = areAllEntitiesExpanded
      }
      for index in databaseUsers.indices {
        databaseUsers[index].isExpanded = areAllEntitiesExpanded
      }
      for index in databaseRoles.indices {
        databaseRoles[index].isExpanded = areAllEntitiesExpanded
      }
    }
  }

  // MARK: - Responsive Sidebar Management

  /// Handle sidebar conflict when window width is narrow (< 1200pt)
  /// When opening right sidebar on narrow window, close left sidebar
  func handleRightSidebarConflict() {
    guard let window = NSApp.keyWindow else { return }
    let windowWidth = window.frame.size.width
    let narrowWindowThreshold: CGFloat = 1200

    guard windowWidth < narrowWindowThreshold else { return }

    if isLeftSidebarVisible {
      isLeftSidebarVisible = false
      AppSettings.shared.isLeftSidebarVisible = false
    }
  }

  /// Insert text into selected cell or editor at cursor position
  func insertTextIntoSelectedCell(_ text: String) {
    // Handle based on current view mode
    if viewMode == .editor {
      // Editor mode: insert directly into editor text view
      if let textView = editorTextView {
        let selectedRange = textView.selectedRange()
        textView.insertText(text, replacementRange: selectedRange)
        // Focus the editor after inserting text
        textView.window?.makeFirstResponder(textView)
      }
    } else {
      // Notebook mode: post notification to insert text - will be handled by CellView
      NotificationCenter.default.post(
        name: .insertTextIntoCell,
        object: nil,
        userInfo: ["text": text]
      )
    }
  }

  /// Cell clicked in the result grid at result column `index` (`row` is the displayed row's
  /// values, `originalRow` its index into `result.rows`): a JSON value opens in the JSON
  /// viewer, any other value in the cell detail
  func showGridCellInSidebar(
    row: [CellValue], originalRow: Int, column index: Int, result: CellResult, cellId: UUID?
  ) {
    guard result.columns.indices.contains(index) else { return }
    let column = result.columns[index]
    let value = index < row.count ? row[index] : .null
    if case .json(let json) = value {
      showJSONInSidebar(json: json, path: "Row \(originalRow + 1), Column '\(column.name)'")
    } else {
      showCellDetail(
        columnName: column.name,
        columnType: column.type,
        value: value,
        tableName: result.tableName,
        rowData: CellResult.rowData(columns: result.columns, row: row),
        primaryKeyColumns: result.primaryKeyColumns,
        editTarget: result.editTarget,
        cellId: cellId
      )
      cellDetailRow = originalRow
    }
  }

  /// Re-run what produced the sidebar cell (same gates as Run); the new result refreshes the
  /// sidebar through `syncCellDetail`
  func refreshCellDetail() {
    guard case .cellInfo(_, _, _, _, _, _, let cellId) = rightSidebarContent else { return }
    if let cellId {
      confirmAndRunCell(id: cellId)
    } else {
      Task { await runEditorQuery() }
    }
  }

  /// After `result` replaced the result of `cellId` (nil = editor), re-read the sidebar cell from
  /// it: the same row (by primary key when there is one, else by position) and column. The
  /// sidebar keeps its value when the row or column is gone.
  func syncCellDetail(cellId: UUID?, result: CellResult?) {
    guard let result, result.error == nil,
      case .cellInfo(let columnName, _, _, _, let oldRow, let keys, let sidebarCellId) =
        rightSidebarContent,
      sidebarCellId == cellId,
      let column = result.columns.firstIndex(where: { $0.name == columnName })
    else { return }

    let rowIndex: Int?
    if let oldRow, !keys.isEmpty {
      rowIndex = result.rows.firstIndex { row in
        let data = CellResult.rowData(columns: result.columns, row: row)
        return keys.allSatisfy { data[$0] == oldRow[$0] }
      }
    } else {
      rowIndex = cellDetailRow
    }
    guard let rowIndex, result.rows.indices.contains(rowIndex) else { return }

    let row = result.rows[rowIndex]
    cellDetailEditTarget = result.editTarget
    cellDetailRow = rowIndex
    rightSidebarContent = .cellInfo(
      columnName: columnName,
      columnType: result.columns[column].type,
      value: column < row.count ? row[column] : .null,
      tableName: result.tableName,
      rowData: CellResult.rowData(columns: result.columns, row: row),
      primaryKeyColumns: result.primaryKeyColumns,
      cellId: cellId
    )
  }

  // MARK: - Cell Value Editing

  /// Inline edit committed in the result grid at result column `index`: `row` is the displayed
  /// row's values, so the primary key is that row's. A data viewer with a primary-key edit
  /// target sends a loaded row through `handleCellValueEdit` and keeps an appended insert staged.
  /// A notebook grid goes through `handleCellValueEdit` (live target, protection gate) and sends
  /// one UPDATE, without opening the sidebar.
  func handleGridCellEdit(
    row: [CellValue], column index: Int, newValue: String, result: CellResult, cellId: UUID?,
    connectionManager: DatabaseConnectionManager?
  ) {
    guard result.columns.indices.contains(index) else { return }
    if dataViewer != nil, rowStagingUnavailableReason == nil {
      if let page = stagedPageIndex(matching: row, result: result) {
        handleStagedGridCellEdit(row: page, column: index, newValue: newValue, result: result)
      } else {
        showToast(Self.rowNotOnPage, type: .error)
      }
      return
    }
    let column = result.columns[index]
    let originalValue = index < row.count ? row[index] : .null
    cellDetailEditTarget = result.editTarget
    handleCellValueEdit(
      columnName: column.name,
      columnType: column.type,
      newValue: newValue,
      originalValue: originalValue,
      tableName: result.tableName,
      rowData: CellResult.rowData(columns: result.columns, row: row),
      primaryKeyColumns: result.primaryKeyColumns,
      cellId: cellId,
      connectionManager: connectionManager
    )
  }

  /// Cell edit from the data-viewer grid. A loaded row is sent through `handleCellValueEdit`
  /// for every commit style. An insert appended after the loaded page stays staged until its
  /// batch is committed.
  func handleStagedGridCellEdit(
    row: Int, column index: Int, newValue: String, result: CellResult
  ) {
    guard result.columns.indices.contains(index) else { return }
    let name = result.columns[index].name
    let original = originalStagedCell(row: row, column: name, index: index, result: result)
    if result.rows.indices.contains(row) {
      if result.primaryKeyColumns.contains(name) {
        showToast(RowChangeError.primaryKeyColumn(name).message, type: .error)
        return
      }
      let rowData = CellResult.rowData(columns: result.columns, row: result.rows[row])
      let key = RowChangeSet.RowKey(values: result.primaryKeyColumns.compactMap { rowData[$0] })
      if dataViewer?.changeSet?.deletes.contains(key) == true {
        showToast(RowChangeError.deletedRow.message, type: .error)
        return
      }
      cellDetailEditTarget = result.editTarget
      handleCellValueEdit(
        columnName: name, columnType: result.columns[index].type, newValue: newValue,
        originalValue: original, tableName: result.tableName,
        rowData: rowData,
        primaryKeyColumns: result.primaryKeyColumns, cellId: nil,
        connectionManager: connectionManager)
      return
    }
    let value = Self.editedCellValue(newValue, original: original)
    if let message = stageEdit(row: row, column: name, value: value) {
      showToast(message, type: .error)
    }
  }

  /// Loaded-page index of `row`, matched on the primary key. Nil when it is not on the page.
  private func stagedPageIndex(matching row: [CellValue], result: CellResult) -> Int? {
    guard let target = editorResult?.editTarget, !target.primaryKeyColumns.isEmpty else {
      return nil
    }
    let columns = result.columns
    func key(_ values: [CellValue]) -> [CellValue]? {
      var primaryKey: [CellValue] = []
      primaryKey.reserveCapacity(target.primaryKeyColumns.count)
      for name in target.primaryKeyColumns {
        guard let index = columns.firstIndex(where: { $0.name == name }), index < values.count
        else { return nil }
        primaryKey.append(values[index])
      }
      return primaryKey
    }
    guard let wanted = key(row) else { return nil }
    return result.rows.firstIndex { candidate in
      guard let candidateKey = key(candidate) else { return false }
      return candidateKey == wanted
    }
  }

  /// Loaded cell, or the staged insert's current value, used to keep the edited type.
  private func originalStagedCell(
    row: Int, column name: String, index: Int, result: CellResult
  ) -> CellValue {
    if result.rows.indices.contains(row) {
      return result.rows[row].indices.contains(index) ? result.rows[row][index] : .null
    }
    let insertIndex = row - result.rows.count
    guard let inserts = dataViewer?.changeSet?.inserts, inserts.indices.contains(insertIndex)
    else { return .null }
    return inserts[insertIndex].values[name] ?? .null
  }

  /// Handle JSON value edit from sidebar
  func handleJSONEdit(newJSON: String, originalPath: String) {
    // Validate JSON
    guard let data = newJSON.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data)) != nil
    else {
      // Show error - invalid JSON
      showToast("Invalid JSON format. Please check your syntax.", type: .error)
      return
    }

    // Copy to clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(newJSON, forType: .string)

    // Update the sidebar content with the new JSON value
    rightSidebarContent = .jsonViewer(json: newJSON, path: originalPath)

    // Show success message
    showToast("JSON copied to clipboard", type: .success)
    // TODO: In the future, this could update the actual database value
  }
}
