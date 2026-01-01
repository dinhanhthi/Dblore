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

    // IMPORTANT: Force blur to ensure text content is saved before execution
    // This is needed because text binding only updates on blur (to prevent undo/redo issues)
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)

    // Give a tiny delay to allow the blur callback to update the binding
    // This ensures cell.content is up-to-date before we execute the query
    try? await Task.sleep(for: .milliseconds(50))

    notebook.cells[index].isRunning = true

    let query = notebook.cells[index].content

    // DEBUG: Log the query being executed
    print("🔍 [NotebookViewModel] Executing query from cell \(id): `\(query)`")

    do {
      // Execute query using DatabaseConnectionManager
      // Use app's maxRowLimit setting
      let queryResult = try await connectionManager.executeQuery(
        query,
        maxRows: AppSettings.shared.maxRowLimit
      )

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
        primaryKeyColumns: primaryKeyColumns,
        rowIdentifiers: queryResult.rowIdentifiers,
        userLimitExceeded: queryResult.userLimitExceeded,
        userRequestedLimit: queryResult.userRequestedLimit,
        affectedRows: queryResult.affectedRows
      )

      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter

      // Show toast if user's LIMIT was exceeded and capped
      if queryResult.userLimitExceeded, let requestedLimit = queryResult.userRequestedLimit {
        let maxLimit = AppSettings.shared.maxRowLimit
        showToast(
          "Query limit capped from \(requestedLimit) to \(maxLimit) rows. Increase in Settings.",
          type: .warning
        )
      }
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
        MainActor.assumeIsolated {
          target.restoreCellOutput(
            id: id,
            result: previousResult,
            executionCount: previousExecutionCount,
            registerUndo: true
          )
        }
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
        MainActor.assumeIsolated {
          target.clearCellOutput(id: id, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.restoreAllOutputs(outputs: previousOutputs, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.clearAllOutputs(registerUndo: true)
        }
      }
    }
  }

  // MARK: - Helper Methods

  /// Extract table name from a SQL query (simple SELECT parsing)
  /// Works for SELECT queries with WHERE, ORDER BY, LIMIT, GROUP BY, HAVING, etc.
  /// Returns nil for JOINs, subqueries, or other complex queries
  func extractTableName(from query: String) -> String? {
    // Normalize query: trim whitespace and convert to lowercase for parsing
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // Check if it's a SELECT query
    guard normalized.hasPrefix("select") else {
      return nil
    }

    // Find "FROM" keyword using word boundary pattern
    // Use regex to find FROM as a separate word (not part of another word)
    guard let fromRange = normalized.range(of: "\\bfrom\\b", options: .regularExpression) else {
      return nil
    }

    // Get everything after "FROM"
    let afterFrom = String(normalized[fromRange.upperBound...])
      .trimmingCharacters(in: .whitespaces)

    // Define SQL keywords that indicate end of table name
    let endKeywords = [
      "where", "order", "group", "having", "limit", "offset",
      "union", "intersect", "except", "window", "for"
    ]

    // Find the position of the first keyword or separator
    var endPosition = afterFrom.endIndex

    // Check for SQL keywords (word boundaries)
    for keyword in endKeywords {
      if let keywordRange = afterFrom.range(of: "\\b\(keyword)\\b", options: .regularExpression) {
        if keywordRange.lowerBound < endPosition {
          endPosition = keywordRange.lowerBound
        }
      }
    }

    // Also check for other separators (comma for multi-table, semicolon, parenthesis for subquery)
    let separators = CharacterSet(charactersIn: ",;()")
    if let separatorRange = afterFrom.rangeOfCharacter(from: separators) {
      if separatorRange.lowerBound < endPosition {
        endPosition = separatorRange.lowerBound
      }
    }

    // Extract table name (everything from start to endPosition)
    let tableName = String(afterFrom[..<endPosition])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Return nil if empty or if it contains JOIN keyword (multi-table query)
    if tableName.isEmpty || tableName.contains("join") {
      return nil
    }

    // Handle quoted identifiers (strip quotes)
    let cleanedTableName = tableName
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

    return cleanedTableName.isEmpty ? nil : cleanedTableName
  }
}
