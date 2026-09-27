//
//  NotebookViewModel+Sidebar.swift
//  SQLNotebook
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Sidebar Management

extension NotebookViewModel {
  // MARK: - Right Sidebar

  /// Show JSON in the sidebar
  func showJSONInSidebar(json: String, path: String) {
    rightSidebarContent = .jsonViewer(json: json, path: path)
    withAnimation(.easeInOut(duration: 0.2)) {
      isRightSidebarVisible = true
    }
    handleRightSidebarConflict()
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
    rightSidebarContent = .cellInfo(
      columnName: columnName,
      columnType: columnType,
      value: value,
      tableName: tableName,
      rowData: rowData,
      primaryKeyColumns: primaryKeyColumns,
      cellId: cellId
    )
    withAnimation(.easeInOut(duration: 0.2)) {
      isRightSidebarVisible = true
    }
    handleRightSidebarConflict()
  }

  // Note: showConnectionForm() removed - connection form is now at workspace level
  // Note: showSettings() removed - settings is now a modal at workspace level

  /// Toggle sidebar visibility
  func toggleSidebar() {
    withAnimation(.easeInOut(duration: 0.2)) {
      isRightSidebarVisible.toggle()
    }
    if isRightSidebarVisible {
      handleRightSidebarConflict()
    }
  }

  /// Close the sidebar
  func closeSidebar() {
    withAnimation(.easeInOut(duration: 0.2)) {
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

  // MARK: - Cell Value Editing

  /// Inline edit committed in the result grid at result column `index`: `row` is the displayed
  /// row's values, so the primary key is that row's. Goes through `handleCellValueEdit` (live
  /// target, protection gate, Safe Mode) with the result's live edit target, without opening
  /// the sidebar.
  func handleGridCellEdit(
    row: [CellValue], column index: Int, newValue: String, result: CellResult, cellId: UUID?,
    connectionManager: DatabaseConnectionManager?
  ) {
    guard result.columns.indices.contains(index) else { return }
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
