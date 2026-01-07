//
//  NotebookViewModel+Execution.swift
//  SQLNotebook
//

import Foundation

// MARK: - Cell Execution

extension NotebookViewModel {
  /// Run a specific cell by adding it to the execution queue
  func runCell(id: UUID) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    guard notebook.cells[index].cellType == .sql else { return }
    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult("Not connected to database")
      return
    }

    // Check if cell is already in queue
    if executionQueue.isInQueue(cellId: id) {
      return
    }

    // IMPORTANT: Force blur to ensure text content is saved before execution
    // This is needed because text binding only updates on blur (to prevent undo/redo issues)
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)

    // Give a tiny delay to allow the blur callback to update the binding
    // This ensures cell.content is up-to-date before we execute the query
    try? await Task.sleep(for: .milliseconds(50))

    let query = notebook.cells[index].content

    // Enqueue the cell execution
    executionQueue.enqueue(cellId: id, query: query)
  }

  /// Cancel execution for a specific cell
  func cancelCell(id: UUID) {
    executionQueue.cancel(cellId: id)

    // Update UI state
    if let index = notebook.cells.firstIndex(where: { $0.id == id }) {
      notebook.cells[index].isRunning = false
    }
  }

  /// Cancel all pending and executing cells
  func cancelAllCells() {
    executionQueue.cancelAll()

    // Update UI state for all cells
    for index in notebook.cells.indices {
      notebook.cells[index].isRunning = false
    }
  }

  /// Internal method to execute a task (called by ExecutionQueue)
  func executeTask(_ task: ExecutionTask) async -> CellResult? {
    guard let index = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
      return nil
    }

    notebook.cells[index].isRunning = true

    // DEBUG: Log the query being executed
    print("🔍 [NotebookViewModel] Executing query from cell \(task.cellId): `\(task.query)`")

    var result: CellResult?

    do {
      // Execute query using DatabaseConnectionManager
      // Use app's maxRowLimit setting
      let queryResult = try await connectionManager.executeQuery(
        task.query,
        maxRows: AppSettings.shared.maxRowLimit
      )

      executionCounter += 1

      // Extract table name from query (simple SELECT parsing)
      let tableName = extractTableName(from: task.query)

      // Fetch primary key columns if we have a table name
      var primaryKeyColumns: [String] = []
      if let tableName = tableName {
        primaryKeyColumns =
          (try? await connectionManager.fetchPrimaryKeyColumns(tableName: tableName)) ?? []
      }

      // Convert QueryResult to CellResult
      result = CellResult(
        columns: queryResult.columns,
        rows: queryResult.rows,
        executionTime: queryResult.executionTime,
        rowCount: queryResult.rowCount,
        timestamp: Date(),
        wasLimited: queryResult.wasLimited,
        sourceQuery: task.query,
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
      result = .errorResult(
        error.localizedDescription,
        executionTime: executionTime
      )
      notebook.cells[index].result = result
    } catch {
      // Handle general errors
      result = .errorResult(error.localizedDescription)
      notebook.cells[index].result = result
    }

    notebook.cells[index].isRunning = false

    // Check file size after execution and show warning if needed
    checkFileSizeAfterExecution()

    return result
  }

  /// Run all SQL cells sequentially by adding them to the queue
  func runAllCells() async {
    // Force blur to ensure text content is saved
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)
    try? await Task.sleep(for: .milliseconds(50))

    // Enqueue all SQL cells
    for cell in notebook.cells where cell.cellType == .sql {
      if !executionQueue.isInQueue(cellId: cell.id) {
        executionQueue.enqueue(cellId: cell.id, query: cell.content)
      }
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

  // MARK: - File Size Monitoring

  /// Check file size after cell execution and show warning dialogs if needed
  func checkFileSizeAfterExecution() {
    let fileSize = estimatedFileSize

    // Check if we exceeded large threshold (and haven't shown dialog yet)
    if fileSize > FileOptimizationService.largeSizeThreshold && !hasShownLargeDialog {
      hasShownLargeDialog = true
      showFileSizeLargeDialog = true
      return  // Don't show warning dialog if we're already showing large dialog
    }

    // Check if we exceeded warning threshold (and haven't shown dialog yet)
    if fileSize > FileOptimizationService.warningSizeThreshold && !hasShownWarningDialog {
      hasShownWarningDialog = true
      showFileSizeWarningDialog = true
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
      "union", "intersect", "except", "window", "for",
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
    let cleanedTableName =
      tableName
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

    return cleanedTableName.isEmpty ? nil : cleanedTableName
  }
}
