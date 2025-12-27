//
//  NotebookViewModel+Execution.swift
//  SQLNotebook
//

import Foundation

// MARK: - Cell Execution

extension NotebookViewModel {
  /// Run a specific cell
  func runCell(id: UUID) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    guard notebook.cells[index].cellType == .sql else { return }
    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult("Not connected to database")
      return
    }

    notebook.cells[index].isRunning = true

    let query = notebook.cells[index].content

    do {
      // Execute query using DatabaseConnectionManager
      let queryResult = try await connectionManager.executeQuery(query)

      executionCounter += 1

      // Extract table name from query (simple SELECT parsing)
      let tableName = extractTableName(from: query)

      // Fetch primary key columns if we have a table name
      var primaryKeyColumns: [String] = []
      if let tableName = tableName {
        primaryKeyColumns = (try? await connectionManager.fetchPrimaryKeyColumns(tableName: tableName)) ?? []
      }

      // Convert QueryResult to CellResult
      let result = CellResult(
        columns: queryResult.columns,
        rows: queryResult.rows,
        executionTime: queryResult.executionTime,
        rowCount: queryResult.rowCount,
        timestamp: Date(),
        wasLimited: queryResult.wasLimited,
        sourceQuery: query,
        tableName: tableName,
        primaryKeyColumns: primaryKeyColumns
      )

      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
    } catch let error as DatabaseError {
      // Handle database-specific errors
      let executionTime = error.executionTime ?? 0
      notebook.cells[index].result = .errorResult(
        error.localizedDescription,
        executionTime: executionTime
      )
    } catch {
      // Handle general errors
      notebook.cells[index].result = .errorResult(error.localizedDescription)
    }

    notebook.cells[index].isRunning = false
  }

  /// Run all SQL cells sequentially
  func runAllCells() async {
    for cell in notebook.cells where cell.cellType == .sql {
      await runCell(id: cell.id)
    }
  }

  /// Clear output from a specific cell
  func clearCellOutput(id: UUID, registerUndo: Bool = true) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let previousResult = notebook.cells[index].result
    let previousExecutionCount = notebook.cells[index].executionCount

    notebook.cells[index].result = nil
    notebook.cells[index].executionCount = nil

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.restoreCellOutput(
          id: id,
          result: previousResult,
          executionCount: previousExecutionCount,
          registerUndo: true
        )
      }
      undoManager.setActionName("Clear Output")
      onDocumentChanged?()
    }
  }

  /// Helper: Restore cell output (used for undo of clear)
  func restoreCellOutput(
    id: UUID, result: CellResult?, executionCount: Int?, registerUndo: Bool
  ) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    notebook.cells[index].result = result
    notebook.cells[index].executionCount = executionCount

    // Register redo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.clearCellOutput(id: id, registerUndo: true)
      }
    }
  }

  /// Clear all cell outputs
  func clearAllOutputs(registerUndo: Bool = true) {
    var previousOutputs: [(id: UUID, result: CellResult?, executionCount: Int?)] = []

    for index in notebook.cells.indices {
      let cell = notebook.cells[index]
      previousOutputs.append(
        (id: cell.id, result: cell.result, executionCount: cell.executionCount))
      notebook.cells[index].result = nil
      notebook.cells[index].executionCount = nil
    }

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.restoreAllOutputs(outputs: previousOutputs, registerUndo: true)
      }
      undoManager.setActionName("Clear All Outputs")
      onDocumentChanged?()
    }
  }

  /// Helper: Restore all cell outputs (used for undo of clear all)
  func restoreAllOutputs(
    outputs: [(id: UUID, result: CellResult?, executionCount: Int?)], registerUndo: Bool
  ) {
    for output in outputs {
      if let index = notebook.cells.firstIndex(where: { $0.id == output.id }) {
        notebook.cells[index].result = output.result
        notebook.cells[index].executionCount = output.executionCount
      }
    }

    // Register redo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.clearAllOutputs(registerUndo: true)
      }
    }
  }

  // MARK: - Helper Methods

  /// Extract table name from a SQL query (simple SELECT parsing)
  /// Only works for simple SELECT queries like "SELECT * FROM table_name" or "SELECT col FROM schema.table"
  private func extractTableName(from query: String) -> String? {
    // Normalize query: trim whitespace and convert to lowercase
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // Check if it's a SELECT query
    guard normalized.hasPrefix("select") else {
      return nil
    }

    // Find "FROM" keyword
    guard let fromRange = normalized.range(of: "from") else {
      return nil
    }

    // Get everything after "FROM"
    let afterFrom = String(normalized[fromRange.upperBound...])
      .trimmingCharacters(in: .whitespaces)

    // Extract first word (table name) - stop at whitespace, comma, semicolon, or parenthesis
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()"))
    if let endIndex = afterFrom.rangeOfCharacter(from: separators)?.lowerBound {
      let tableName = String(afterFrom[..<endIndex])
      return tableName.isEmpty ? nil : tableName
    } else {
      // No separator found, use the whole string
      let tableName = afterFrom.trimmingCharacters(in: separators)
      return tableName.isEmpty ? nil : tableName
    }
  }
}
