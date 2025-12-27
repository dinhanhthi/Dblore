//
//  NotebookViewModel+Sidebar.swift
//  SQLNotebook
//

import Foundation

// MARK: - Sidebar Management

extension NotebookViewModel {
  // MARK: - Right Sidebar

  /// Show JSON in the sidebar
  func showJSONInSidebar(json: String, path: String) {
    rightSidebarContent = .jsonViewer(json: json, path: path)
    isRightSidebarVisible = true
  }

  /// Show cell value details in sidebar
  func showCellDetail(columnName: String, columnType: String, value: CellValue) {
    rightSidebarContent = .cellInfo(columnName: columnName, columnType: columnType, value: value)
    isRightSidebarVisible = true
  }

  /// Show connection details in sidebar
  func showConnectionDetails() {
    rightSidebarContent = .connectionDetails
    isRightSidebarVisible = true
  }

  /// Show connection form in sidebar
  func showConnectionForm() {
    rightSidebarContent = .connectionForm
    isRightSidebarVisible = true
  }

  /// Toggle sidebar visibility
  func toggleSidebar() {
    isRightSidebarVisible.toggle()
  }

  /// Close the sidebar
  func closeSidebar() {
    isRightSidebarVisible = false
  }

  // MARK: - Left Sidebar - Database Schema

  /// Toggle left sidebar visibility
  func toggleLeftSidebar() {
    isLeftSidebarVisible.toggle()
  }

  /// Load database schema (tables and columns)
  func loadDatabaseSchema() async {
    guard connectionState.isConnected else {
      databaseTables = []
      return
    }

    isLoadingSchema = true

    do {
      // Fetch tables
      var tables = try await connectionManager.fetchTables()

      // Fetch columns and row count for each table
      for index in tables.indices {
        let table = tables[index]
        do {
          let columns = try await connectionManager.fetchColumns(
            tableSchema: table.schema,
            tableName: table.name
          )
          tables[index].columns = columns

          // Fetch row count
          let rowCount = try await connectionManager.fetchRowCount(
            tableSchema: table.schema,
            tableName: table.name
          )
          tables[index].rowCount = rowCount
        } catch {
          // If fetching columns fails, continue with other tables
          print("Failed to fetch columns for \(table.qualifiedName): \(error)")
        }
      }

      databaseTables = tables
    } catch {
      print("Failed to load database schema: \(error)")
      databaseTables = []
    }

    isLoadingSchema = false
  }

  /// Refresh database schema
  func refreshDatabaseSchema() async {
    await loadDatabaseSchema()
  }

  /// Toggle table expansion state
  func toggleTableExpansion(tableId: UUID) {
    if let index = databaseTables.firstIndex(where: { $0.id == tableId }) {
      databaseTables[index].isExpanded.toggle()
    }
  }

  /// Insert text into selected cell at cursor position
  func insertTextIntoSelectedCell(_ text: String) {
    // Post notification to insert text - will be handled by CellView
    NotificationCenter.default.post(
      name: .insertTextIntoCell,
      object: nil,
      userInfo: ["text": text]
    )
  }
}
