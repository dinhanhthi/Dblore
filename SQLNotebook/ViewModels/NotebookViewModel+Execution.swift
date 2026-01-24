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

    let query = notebook.cells[index].content

    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult("Not connected to database", sourceQuery: query)
      onDocumentChanged?()
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

    // INFO: Log sanitized query being executed (redact sensitive data)
    let sanitizedQuery = AppLogger.shared.sanitizeQuery(task.query)
    await AppLogger.shared.info(
      "Executing query from cell \(task.cellId): `\(sanitizedQuery)`", category: "Execution")

    var result: CellResult?

    do {
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(task.query) {
        // Execute all statements with timeout (10.1.5 optimization)
        let (statementResults, totalTime) =
          try await Task.withTimeout(seconds: 60) {
            try await self.connectionManager
              .executeMultipleStatementsDetailed(
                task.query, maxRows: AppSettings.shared.maxRowLimit)
          }

        executionCounter += 1

        // Convert to StatementResult array
        let convertedStatements = statementResults.enumerated().map { index, tuple in
          StatementResult(
            queryText: tuple.queryText,
            result: CellResult(
              columns: tuple.result.columns,
              rows: tuple.result.rows,
              executionTime: tuple.result.executionTime,
              rowCount: tuple.result.rows.count,
              timestamp: Date(),
              error: nil,
              wasLimited: tuple.result.wasLimited,
              sourceQuery: tuple.queryText,
              tableName: nil,
              primaryKeyColumns: [],
              rowIdentifiers: tuple.result.rowIdentifiers,
              userLimitExceeded: tuple.result.userLimitExceeded,
              userRequestedLimit: tuple.result.userRequestedLimit,
              affectedRows: tuple.result.affectedRows,
              limitWasCapped: tuple.result.limitWasCapped,
              actualLimitUsed: tuple.result.actualLimitUsed
            ),
            statementIndex: index
          )
        }

        // Store all statement results
        notebook.cells[index].statementResults = convertedStatements
        notebook.cells[index].totalExecutionTime = totalTime
        // Select the last statement by default
        notebook.cells[index].selectedStatementIndex = convertedStatements.count - 1
        // Set result to the last statement's result for backward compatibility
        result = convertedStatements.last?.result
        notebook.cells[index].result = result
        notebook.cells[index].executionCount = executionCounter

        // Build pagination info for each statement with LIMIT
        for statementResult in convertedStatements {
          if let paginationInfo = await buildPaginationInfo(
            for: statementResult.queryText, result: statementResult.result)
          {
            if cellStatementPaginationInfo[task.cellId] == nil {
              cellStatementPaginationInfo[task.cellId] = [:]
            }
            cellStatementPaginationInfo[task.cellId]?[statementResult.id] = paginationInfo
          }
        }
        // Sync statement pagination info to cell for persistence
        notebook.cells[index].statementPaginationInfo =
          cellStatementPaginationInfo[task.cellId] ?? [:]
        // Clear single statement pagination info for multi-statement
        notebook.cells[index].paginationInfo = nil

        // Check for any limit exceeded warnings
        for statementResult in convertedStatements {
          if statementResult.result.userLimitExceeded,
            let requestedLimit = statementResult.result.userRequestedLimit
          {
            let maxLimit = AppSettings.shared.maxRowLimit
            showToast(
              "Query limit capped from \(requestedLimit) to \(maxLimit) rows. Increase in Settings.",
              type: .warning
            )
            break  // Only show once
          }
        }
      } else {
        // Single statement - use original logic
        // Execute query with timeout (10.1.5 optimization)
        let queryResult = try await Task.withTimeout(seconds: 60) {
          try await self.connectionManager.executeQuery(
            task.query,
            maxRows: AppSettings.shared.maxRowLimit
          )
        }

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
          affectedRows: queryResult.affectedRows,
          limitWasCapped: queryResult.limitWasCapped,
          actualLimitUsed: queryResult.actualLimitUsed
        )

        notebook.cells[index].result = result
        notebook.cells[index].executionCount = executionCounter
        // Clear multi-statement data for single statement
        notebook.cells[index].statementResults = []
        notebook.cells[index].selectedStatementIndex = 0
        notebook.cells[index].totalExecutionTime = nil

        // Build pagination info if applicable
        if let paginationInfo = await buildPaginationInfo(for: task.query, result: result!) {
          cellPaginationInfo[task.cellId] = paginationInfo
        } else {
          // Clear pagination info if not applicable
          cellPaginationInfo.removeValue(forKey: task.cellId)
        }
        // Clear statement pagination info for single statement
        cellStatementPaginationInfo.removeValue(forKey: task.cellId)
        // Sync pagination info to cell for persistence
        notebook.cells[index].paginationInfo = cellPaginationInfo[task.cellId]
        // Clear statement pagination info for single statement
        notebook.cells[index].statementPaginationInfo = [:]

        // Show toast if user's LIMIT was exceeded and capped
        if queryResult.userLimitExceeded, let requestedLimit = queryResult.userRequestedLimit {
          let maxLimit = AppSettings.shared.maxRowLimit
          showToast(
            "Query limit capped from \(requestedLimit) to \(maxLimit) rows. Increase in Settings.",
            type: .warning
          )
        }
      }
    } catch is TaskTimeoutError {
      // Handle query timeout (10.1.5 optimization)
      executionCounter += 1
      result = .errorResult(
        "Query execution timed out after 60 seconds",
        sourceQuery: task.query
      )
      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
      // Clear multi-statement data on error
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      // Clear pagination info on error
      cellPaginationInfo.removeValue(forKey: task.cellId)
      cellStatementPaginationInfo.removeValue(forKey: task.cellId)
      await AppLogger.shared.error(
        "Query timed out for cell \(task.cellId)", category: "Execution")
    } catch let error as DatabaseError {
      // Handle database-specific errors
      executionCounter += 1
      let executionTime = error.executionTime ?? 0
      result = .errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: task.query
      )
      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
      // Clear multi-statement data on error
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      // Clear pagination info on error
      cellPaginationInfo.removeValue(forKey: task.cellId)
      cellStatementPaginationInfo.removeValue(forKey: task.cellId)
    } catch {
      // Handle general errors
      executionCounter += 1
      result = .errorResult(error.localizedDescription, sourceQuery: task.query)
      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
      // Clear multi-statement data on error
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      // Clear pagination info on error
      cellPaginationInfo.removeValue(forKey: task.cellId)
      cellStatementPaginationInfo.removeValue(forKey: task.cellId)
    }

    notebook.cells[index].isRunning = false

    // Notify document changed to trigger save
    onDocumentChanged?()

    // Check file size after execution and show warning if needed
    checkFileSizeAfterExecution()

    // Update View Query sidebar if it's showing query for this cell
    updateExecutedQuerySidebarIfNeeded(cellId: task.cellId, result: result)

    return result
  }

  /// Run all SQL cells sequentially by adding them to the queue
  func runAllCells() async {
    // Force blur to ensure text content is saved
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)
    try? await Task.sleep(for: .milliseconds(50))

    // Reset execution counter to start counting from 1 again
    executionCounter = 0

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
      onDocumentChanged?()
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
      onDocumentChanged?()
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

  // MARK: - Sidebar Update

  /// Select a specific statement result in a cell (for multi-statement queries)
  func selectCellStatement(cellId: UUID, at index: Int) {
    guard let cellIndex = notebook.cells.firstIndex(where: { $0.id == cellId }) else { return }
    guard index >= 0 && index < notebook.cells[cellIndex].statementResults.count else { return }

    notebook.cells[cellIndex].selectedStatementIndex = index
    notebook.cells[cellIndex].result = notebook.cells[cellIndex].statementResults[index].result

    // Update the View Query sidebar if it's currently open for this cell
    updateExecutedQuerySidebarIfNeeded(cellId: cellId, result: notebook.cells[cellIndex].result)
  }

  /// Update the View Query sidebar if it's currently showing query for the given cell or editor mode
  /// This ensures the sidebar shows the latest executed query after re-running a cell or switching statements
  func updateExecutedQuerySidebarIfNeeded(cellId: UUID?, result: CellResult?) {
    // Check if sidebar is showing executed query
    guard case .executedQuery(_, let sidebarCellId, _, _) = rightSidebarContent else {
      return
    }

    // Check if the sidebar is showing query for this specific cell (or editor mode if both are nil)
    guard sidebarCellId == cellId else {
      return
    }

    // Get the actual executed query (with LIMIT adjusted if needed)
    guard let sourceQuery = result?.sourceQuery else { return }

    let actualQuery: String
    if let result = result, result.limitWasCapped, let actualLimit = result.actualLimitUsed {
      actualQuery = CellResultViews.replaceLimitInQuery(sourceQuery, newLimit: actualLimit)
    } else {
      actualQuery = sourceQuery
    }

    // Remove comments for display
    let displayQuery = SQLSyntaxHighlighter.removeComments(actualQuery)

    // Update sidebar content
    rightSidebarContent = .executedQuery(
      query: displayQuery,
      cellId: cellId,
      limitWasCapped: result?.limitWasCapped ?? false,
      actualLimit: result?.actualLimitUsed
    )
  }
}
