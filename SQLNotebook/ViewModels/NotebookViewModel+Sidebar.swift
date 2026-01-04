//
//  NotebookViewModel+Sidebar.swift
//  SQLNotebook
//

import AppKit
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

  /// Show settings in sidebar
  func showSettings() {
    rightSidebarContent = .settings
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
  @MainActor
  func toggleLeftSidebar() {
    isLeftSidebarVisible.toggle()
    AppSettings.shared.isLeftSidebarVisible = isLeftSidebarVisible
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
  func handleCellValueEdit(
    columnName: String,
    columnType: String,
    newValue: String,
    originalValue: CellValue,
    tableName: String?,
    rowData: [String: CellValue]?,
    primaryKeyColumns: [String],
    rowIdentifier: CellValue?,
    cellId: UUID?
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

    // If we have table name and row data, attempt to update database (use resolved values)
    if let tableName = resolvedTableName, let rowData = rowData, !tableName.isEmpty {
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
