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
    isRightSidebarVisible = true
    handleSidebarConflict(opening: .right)
  }

  /// Show cell value details in sidebar
  func showCellDetail(
    columnName: String,
    columnType: String,
    value: CellValue,
    tableName: String? = nil,
    rowData: [String: CellValue]? = nil,
    primaryKeyColumns: [String] = [],
    rowIdentifier: CellValue? = nil,
    cellId: UUID? = nil
  ) {
    rightSidebarContent = .cellInfo(
      columnName: columnName,
      columnType: columnType,
      value: value,
      tableName: tableName,
      rowData: rowData,
      primaryKeyColumns: primaryKeyColumns,
      rowIdentifier: rowIdentifier,
      cellId: cellId
    )
    isRightSidebarVisible = true
    handleSidebarConflict(opening: .right)
  }

  // Note: showConnectionForm() removed - connection form is now at workspace level

  /// Show settings in sidebar
  func showSettings() {
    rightSidebarContent = .settings
    isRightSidebarVisible = true
    handleSidebarConflict(opening: .right)
  }

  /// Show settings and scroll to Safe Mode section
  func showSafeModeSettings() {
    showSettings()
    // Post notification to scroll to Safe Mode section after a short delay
    // to allow the sidebar to render first
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      NotificationCenter.default.post(name: .scrollToSafeModeSettings, object: nil)
    }
  }

  /// Toggle sidebar visibility
  func toggleSidebar() {
    isRightSidebarVisible.toggle()
    if isRightSidebarVisible {
      handleSidebarConflict(opening: .right)
    }
  }

  /// Close the sidebar
  func closeSidebar() {
    isRightSidebarVisible = false
  }

  // MARK: - Left Sidebar - Database Schema

  /// Toggle left sidebar visibility
  @MainActor
  func toggleLeftSidebar() {
    isLeftSidebarVisible.toggle()
    AppSettings.shared.isLeftSidebarVisible = isLeftSidebarVisible
    if isLeftSidebarVisible {
      handleSidebarConflict(opening: .left)
    }
  }

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

  /// Sidebar side enumeration for conflict handling
  enum SidebarSide {
    case left, right
  }

  /// Handle sidebar conflict when window width is narrow (< 1200pt)
  /// Automatically closes the opposite sidebar to ensure only one is open
  func handleSidebarConflict(opening: SidebarSide) {
    // Get current window width
    guard let window = NSApp.keyWindow else { return }
    let windowWidth = window.frame.size.width
    let narrowWindowThreshold: CGFloat = 1200

    // Only enforce single-sidebar rule when window is narrow
    guard windowWidth < narrowWindowThreshold else { return }

    // Close the opposite sidebar
    switch opening {
    case .left:
      if isRightSidebarVisible {
        isRightSidebarVisible = false
      }
    case .right:
      if isLeftSidebarVisible {
        isLeftSidebarVisible = false
        AppSettings.shared.isLeftSidebarVisible = false
      }
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
    rowIdentifier: CellValue?,
    cellId: UUID?,
    connectionManager: DatabaseConnectionManager? = nil
  ) {
    // If tableName is missing, try to extract it from the cell's source query
    var resolvedTableName = tableName
    let resolvedPrimaryKeyColumns = primaryKeyColumns

    if resolvedTableName == nil || resolvedTableName?.isEmpty == true {
      // Try to get the source query from the cell result
      if let cellId = cellId,
        let cellIndex = notebook.cells.firstIndex(where: { $0.id == cellId }),
        let result = notebook.cells[cellIndex].result
      {
        // Try to get sourceQuery from result, or fallback to cell content
        let queryToExtract = result.sourceQuery ?? notebook.cells[cellIndex].content
        resolvedTableName = extractTableName(from: queryToExtract)
      }
    }

    // Try to convert the new string value to the appropriate CellValue type
    let updatedCellValue: CellValue
    switch originalValue {
    case .string:
      updatedCellValue = .string(newValue)
    case .int:
      if let intValue = Int(newValue) {
        updatedCellValue = .int(intValue)
      } else {
        updatedCellValue = .string(newValue)
      }
    case .double:
      if let doubleValue = Double(newValue) {
        updatedCellValue = .double(doubleValue)
      } else {
        updatedCellValue = .string(newValue)
      }
    case .bool:
      if let boolValue = Bool(newValue) {
        updatedCellValue = .bool(boolValue)
      } else {
        updatedCellValue = .string(newValue)
      }
    case .null:
      if newValue.isEmpty || newValue.lowercased() == "null" {
        updatedCellValue = .null
      } else {
        updatedCellValue = .string(newValue)
      }
    case .json:
      updatedCellValue = .json(newValue)
    case .date:
      // Try to parse the date string
      if let date = ISO8601DateFormatter().date(from: newValue) {
        updatedCellValue = .date(date)
      } else {
        updatedCellValue = .string(newValue)
      }
    case .data:
      if let data = newValue.data(using: .utf8) {
        updatedCellValue = .data(data)
      } else {
        updatedCellValue = .string(newValue)
      }
    }

    // Copy to clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(newValue, forType: .string)

    // Update the sidebar content with the new value (use resolved table name)
    rightSidebarContent = .cellInfo(
      columnName: columnName,
      columnType: columnType,
      value: updatedCellValue,
      tableName: resolvedTableName,
      rowData: rowData,
      primaryKeyColumns: resolvedPrimaryKeyColumns,
      rowIdentifier: rowIdentifier,
      cellId: cellId
    )

    // If we have table name, row data, and connection manager, attempt to update database
    if let tableName = resolvedTableName, let rowData = rowData, !tableName.isEmpty,
      let connectionManager = connectionManager
    {
      Task { @MainActor [connectionManager, weak self] in
        do {
          // Fetch primary key columns if we don't have them yet
          var pkColumns = resolvedPrimaryKeyColumns
          if pkColumns.isEmpty {
            pkColumns =
              (try? await connectionManager.fetchPrimaryKeyColumns(tableName: tableName)) ?? []
          }

          let rowsAffected = try await connectionManager.updateCellValue(
            tableName: tableName,
            columnName: columnName,
            newValue: updatedCellValue,
            rowData: rowData,
            primaryKeyColumns: pkColumns,
            rowIdentifier: rowIdentifier
          )

          // Show success notification
          self?.showToast(
            "Updated '\(columnName)' in '\(tableName)' (\(rowsAffected) row\(rowsAffected == 1 ? "" : "s"))",
            type: .success
          )

          // Re-run the cell to refresh the table view with updated data
          if let cellId = cellId {
            await self?.runCell(id: cellId)
          }
        } catch {
          // Show error notification
          self?.showToast(
            "Failed to update '\(columnName)': \(error.localizedDescription)",
            type: .error
          )
        }
      }
    } else {
      // Show info message when only copying to clipboard
      showToast("Value copied to clipboard", type: .info)
    }
  }
}
