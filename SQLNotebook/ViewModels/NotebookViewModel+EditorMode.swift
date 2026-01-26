//
//  NotebookViewModel+EditorMode.swift
//  SQLNotebook
//

import AppKit
import Foundation

// MARK: - Editor Mode

extension NotebookViewModel {
  /// Get selected text from editor, or content based on Simple Mode setting
  /// - Simple Mode OFF: Return entire content if no selection
  /// - Simple Mode ON: Return query at cursor position if no selection
  func getEditorQueryText() -> String? {
    // Try to get selected text from editor
    if let textView = editorTextView {
      let selectedRange = textView.selectedRange()
      if selectedRange.length > 0, let textStorage = textView.textStorage {
        let selectedText = textStorage.string as NSString
        return selectedText.substring(with: selectedRange)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // No selection - behavior depends on Simple Mode setting
    if AppSettings.shared.editorSimpleMode {
      // Simple Mode: Return query at cursor position
      return getQueryAtCursor()
    } else {
      // Normal Mode: Return entire content
      return editorContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// Get the SQL query(ies) on the current line where cursor is positioned
  /// Returns the content of the current line (may contain multiple statements)
  /// Returns nil if the line is empty or contains only comments/whitespace
  func getQueryAtCursor() -> String? {
    guard let textView = editorTextView,
      let textStorage = textView.textStorage
    else {
      return nil
    }

    let fullText = textStorage.string
    guard !fullText.isEmpty else { return nil }

    let cursorPosition = textView.selectedRange().location
    guard cursorPosition <= fullText.count else { return nil }

    // Get the line range containing the cursor
    let nsString = fullText as NSString
    let lineRange = nsString.lineRange(for: NSRange(location: cursorPosition, length: 0))
    let lineContent = nsString.substring(with: lineRange)

    // Trim and check if line has executable content (not just comments/whitespace)
    let trimmed = lineContent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Check if the line contains only comments
    if connectionManager.isCommentOnlyStatement(trimmed) {
      return nil
    }

    return trimmed
  }

  /// Clear all editor results (used when Simple Mode runs on empty/comment-only line)
  private func clearEditorResults() {
    editorResult = nil
    editorStatementResults = []
    selectedStatementIndex = 0
    totalExecutionTime = 0
    editorPaginationInfo = nil
    editorStatementPaginationInfo.removeAll()
  }

  /// Run query in editor mode (selection if any, otherwise all content)
  func runEditorQuery() async {
    let query = getEditorQueryText()

    // In Simple Mode, clear results if no executable query on current line
    if AppSettings.shared.editorSimpleMode && (query == nil || query!.isEmpty) {
      clearEditorResults()
      return
    }

    guard let query = query, !query.isEmpty else { return }
    guard connectionState == .connected else {
      showToast("Not connected to database", type: .error)
      return
    }

    // Check for modification queries and show confirmation if needed
    let isModification = isModificationQuery(query)
    if isModification && !AppSettings.shared.bypassDestructiveQueryConfirmation {
      // Show confirmation dialog
      pendingQuery = query
      pendingQueryCellId = nil  // No cell ID in editor mode
      showQueryConfirmationDialog = true
      return
    }

    await executeEditorQuery(query)
  }

  /// Execute the pending editor query after confirmation
  func executeConfirmedEditorQuery() async {
    guard !pendingQuery.isEmpty else { return }
    await executeEditorQuery(pendingQuery)
    pendingQuery = ""
    pendingQueryCellId = nil
  }

  /// Execute query in editor mode (internal)
  private func executeEditorQuery(_ query: String) async {
    let startTime = Date()

    do {
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(query) {
        // Execute all statements and get detailed results
        let (statementResults, totalTime) =
          try await connectionManager
          .executeMultipleStatementsDetailed(query, maxRows: AppSettings.shared.editorMaxRowLimit)

        totalExecutionTime = totalTime

        // Clear pagination state for multi-statement queries
        editorStatementPaginationInfo.removeAll()

        // Convert to StatementResult array
        editorStatementResults = statementResults.enumerated().map { index, tuple in
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

        // Build pagination info for each statement with LIMIT
        for statementResult in editorStatementResults {
          let cellResult = statementResult.result
          if let paginationInfo = await buildPaginationInfo(
            for: statementResult.queryText, result: cellResult)
          {
            editorStatementPaginationInfo[statementResult.id] = paginationInfo
          }
        }

        // Select the last statement by default (psql behavior)
        selectedStatementIndex = editorStatementResults.count - 1

        // Set editorResult to the selected statement's result for backward compatibility
        if !editorStatementResults.isEmpty {
          editorResult = editorStatementResults[selectedStatementIndex].result

          // Update View Query sidebar if it's open for editor mode
          updateEditorExecutedQuerySidebarIfNeeded(result: editorResult!)
        }

      } else {
        // Single statement - use existing logic
        let maxRows = AppSettings.shared.editorMaxRowLimit
        await AppLogger.shared.debug(
          "Editor mode executing query with maxRows: \(maxRows)", category: "Query")
        let result = try await connectionManager.executeQuery(
          query, maxRows: maxRows)

        let executionTime = Date().timeIntervalSince(startTime)

        // Clear multi-statement state
        editorStatementResults = []
        selectedStatementIndex = 0
        totalExecutionTime = executionTime

        let cellResult = CellResult(
          columns: result.columns,
          rows: result.rows,
          executionTime: executionTime,
          rowCount: result.rows.count,
          timestamp: Date(),
          error: nil,
          wasLimited: result.wasLimited,
          sourceQuery: query,
          tableName: nil,  // Not available from QueryResult
          primaryKeyColumns: [],
          rowIdentifiers: result.rowIdentifiers,
          userLimitExceeded: result.userLimitExceeded,
          userRequestedLimit: result.userRequestedLimit,
          affectedRows: result.affectedRows,
          limitWasCapped: result.limitWasCapped,
          actualLimitUsed: result.actualLimitUsed
        )

        await AppLogger.shared.debug(
          "CellResult created: userLimitExceeded=\(result.userLimitExceeded), userRequestedLimit=\(result.userRequestedLimit?.description ?? "nil"), rowCount=\(result.rows.count)",
          category: "Query")

        editorResult = cellResult

        // Build pagination info if applicable
        editorPaginationInfo = await buildPaginationInfo(for: query, result: cellResult)

        // Update View Query sidebar if it's open for editor mode
        updateEditorExecutedQuerySidebarIfNeeded(result: cellResult)
      }

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      // Clear multi-statement state on error
      editorStatementResults = []
      selectedStatementIndex = 0
      totalExecutionTime = executionTime
      editorPaginationInfo = nil
      editorStatementPaginationInfo.removeAll()

      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query
      )
    }
  }

  /// Select a specific statement result in editor mode
  func selectEditorStatement(at index: Int) {
    guard index >= 0 && index < editorStatementResults.count else { return }
    selectedStatementIndex = index
    editorResult = editorStatementResults[index].result

    // Update the View Query sidebar if it's currently open for editor mode
    updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)
  }

  // MARK: - Pagination Support

  /// Navigate to a specific page for editor result
  func navigateToPage(_ page: Int) async {
    guard let paginationInfo = editorPaginationInfo else { return }
    guard page > 0 && page <= paginationInfo.totalPages else { return }
    guard page != paginationInfo.currentPage else { return }

    // Build query with LIMIT and OFFSET
    let query = paginationInfo.queryForPage(page)

    // Execute query
    await executeEditorQueryForPagination(query, page: page, paginationInfo: paginationInfo)
  }

  /// Navigate to a specific page for a multi-statement result
  func navigateToPageForStatement(statementId: UUID, page: Int) async {
    guard let paginationInfo = editorStatementPaginationInfo[statementId] else { return }
    guard page > 0 && page <= paginationInfo.totalPages else { return }
    guard page != paginationInfo.currentPage else { return }

    // Build query with LIMIT and OFFSET
    let query = paginationInfo.queryForPage(page)

    // Execute query
    await executeEditorQueryForStatementPagination(
      query, statementId: statementId, page: page, paginationInfo: paginationInfo)
  }

  /// Execute a paginated query for editor mode
  private func executeEditorQueryForPagination(
    _ query: String, page: Int, paginationInfo: PaginationInfo
  ) async {
    let startTime = Date()

    do {
      let result = try await connectionManager.executeQuery(
        query, maxRows: AppSettings.shared.editorMaxRowLimit)
      let executionTime = Date().timeIntervalSince(startTime)

      // Update pagination info with new page
      editorPaginationInfo = PaginationInfo(
        currentPage: page,
        totalRows: paginationInfo.totalRows,
        rowsPerPage: paginationInfo.rowsPerPage,
        baseQuery: paginationInfo.baseQuery
      )

      // Update result
      editorResult = CellResult(
        columns: result.columns,
        rows: result.rows,
        executionTime: executionTime,
        rowCount: result.rows.count,
        timestamp: Date(),
        error: nil,
        wasLimited: false,
        sourceQuery: query,
        tableName: nil,
        primaryKeyColumns: [],
        rowIdentifiers: result.rowIdentifiers,
        userLimitExceeded: false,
        userRequestedLimit: paginationInfo.rowsPerPage,
        affectedRows: nil,
        limitWasCapped: false,
        actualLimitUsed: paginationInfo.rowsPerPage
      )

      // Update the View Query sidebar if it's currently open for editor mode
      updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)
      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query
      )

      // Update the View Query sidebar even on error
      updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)
    }
  }

  /// Execute a paginated query for a specific statement in multi-statement mode
  private func executeEditorQueryForStatementPagination(
    _ query: String, statementId: UUID, page: Int, paginationInfo: PaginationInfo
  ) async {
    let startTime = Date()

    do {
      let result = try await connectionManager.executeQuery(
        query, maxRows: AppSettings.shared.editorMaxRowLimit)
      let executionTime = Date().timeIntervalSince(startTime)

      // Update pagination info with new page
      editorStatementPaginationInfo[statementId] = PaginationInfo(
        currentPage: page,
        totalRows: paginationInfo.totalRows,
        rowsPerPage: paginationInfo.rowsPerPage,
        baseQuery: paginationInfo.baseQuery
      )

      // Update statement result
      if let index = editorStatementResults.firstIndex(where: { $0.id == statementId }) {
        let newResult = CellResult(
          columns: result.columns,
          rows: result.rows,
          executionTime: executionTime,
          rowCount: result.rows.count,
          timestamp: Date(),
          error: nil,
          wasLimited: false,
          sourceQuery: query,
          tableName: nil,
          primaryKeyColumns: [],
          rowIdentifiers: result.rowIdentifiers,
          userLimitExceeded: false,
          userRequestedLimit: paginationInfo.rowsPerPage,
          affectedRows: nil,
          limitWasCapped: false,
          actualLimitUsed: paginationInfo.rowsPerPage
        )

        editorStatementResults[index] = StatementResult(
          id: statementId,
          queryText: paginationInfo.baseQuery,
          result: newResult,
          statementIndex: editorStatementResults[index].statementIndex
        )

        // Update selected result if this is the current statement
        if selectedStatementIndex == index {
          editorResult = newResult

          // Update the View Query sidebar if it's currently open for editor mode
          updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)
        }
      }

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)
      let errorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query
      )

      // Update statement result with error
      if let index = editorStatementResults.firstIndex(where: { $0.id == statementId }) {
        editorStatementResults[index] = StatementResult(
          id: statementId,
          queryText: paginationInfo.baseQuery,
          result: errorResult,
          statementIndex: editorStatementResults[index].statementIndex
        )

        // Update selected result if this is the current statement
        if selectedStatementIndex == index {
          editorResult = errorResult

          // Update the View Query sidebar even on error
          updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)
        }
      }
    }
  }

  /// Build pagination info for a SELECT query with LIMIT
  /// Returns nil if pagination is not applicable
  func buildPaginationInfo(for query: String, result: CellResult) async -> PaginationInfo? {
    // Remove leading/trailing comments to get actual SQL statement
    let cleanQuery = removeLeadingTrailingComments(from: query)

    await AppLogger.shared.debug(
      "Checking pagination for query: \(cleanQuery.prefix(50))...", category: "Pagination")

    // Only applicable for SELECT queries
    guard connectionManager.isSelectQuery(cleanQuery) else {
      await AppLogger.shared.debug(
        "Not a SELECT query, skipping pagination", category: "Pagination")
      return nil
    }

    // Check if we have a LIMIT (either user-provided or auto-added)
    let limit: Int
    if result.userLimitExceeded, let requestedLimit = result.userRequestedLimit {
      // Query was limited (either auto-added or user's LIMIT was capped)
      // Use the ACTUAL limit that was applied (not user's original limit)
      limit = requestedLimit
      await AppLogger.shared.debug(
        "Building pagination: query was limited to \(limit)", category: "Pagination")
    } else if let userLimit = connectionManager.extractLimitValue(cleanQuery) {
      // User provided LIMIT in query and it was within maxRows
      limit = userLimit
      await AppLogger.shared.debug(
        "Building pagination: query has user LIMIT \(limit)", category: "Pagination")
    } else {
      // No LIMIT and not limited
      await AppLogger.shared.debug(
        "No LIMIT found in query and not limited, skipping pagination", category: "Pagination")
      return nil
    }

    // Extract base query (without LIMIT/OFFSET)
    let baseQuery = removeLimit(from: cleanQuery)

    // Get total count using COUNT(*) query
    guard let totalRows = await getTotalRowCount(baseQuery: baseQuery) else {
      await AppLogger.shared.debug(
        "Failed to get total count, skipping pagination", category: "Pagination")
      return nil
    }

    await AppLogger.shared.debug(
      "Pagination built: \(totalRows) total rows, \(limit) per page", category: "Pagination")

    return PaginationInfo(
      currentPage: 1,
      totalRows: totalRows,
      rowsPerPage: limit,
      baseQuery: baseQuery
    )
  }

  /// Remove leading and trailing comments from query
  /// This extracts the actual SQL statement from a query that may have comments
  private func removeLeadingTrailingComments(from query: String) -> String {
    // Safety check for empty query
    guard !query.isEmpty else { return query }

    let lines = query.split(separator: "\n", omittingEmptySubsequences: false)

    // Safety check for single line or no lines
    guard !lines.isEmpty else { return query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var firstNonCommentIndex: Int?
    var lastNonCommentIndex: Int?

    // Find first non-comment line
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !trimmed.hasPrefix("--") {
        firstNonCommentIndex = index
        break
      }
    }

    // Find last non-comment line
    for (index, line) in lines.enumerated().reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !trimmed.hasPrefix("--") {
        lastNonCommentIndex = index
        break
      }
    }

    // Extract the range of non-comment lines
    guard let firstIndex = firstNonCommentIndex,
      let lastIndex = lastNonCommentIndex,
      firstIndex <= lastIndex
    else {
      // All lines are comments or empty - return original query
      return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let relevantLines = lines[firstIndex...lastIndex]
    return relevantLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Remove LIMIT and OFFSET clauses from query
  private func removeLimit(from query: String) -> String {
    var result = query

    // Remove LIMIT clause (case-insensitive)
    result = result.replacingOccurrences(
      of: "\\s+LIMIT\\s+\\d+", with: "", options: [.regularExpression, .caseInsensitive])

    // Remove OFFSET clause (case-insensitive)
    result = result.replacingOccurrences(
      of: "\\s+OFFSET\\s+\\d+", with: "", options: [.regularExpression, .caseInsensitive])

    // Remove trailing semicolon (important for COUNT queries)
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasSuffix(";") {
      result = String(result.dropLast())
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Get total row count for a query using COUNT(*)
  private func getTotalRowCount(baseQuery: String) async -> Int? {
    // Safety check: ensure connection is active
    guard connectionState == .connected else {
      await AppLogger.shared.debug(
        "Connection not active, cannot get total count", category: "Pagination")
      return nil
    }

    // Wrap query in SELECT COUNT(*) FROM (...)
    let countQuery = "SELECT COUNT(*) FROM (\(baseQuery)) AS _count_query"

    await AppLogger.shared.debug(
      "Executing count query: \(countQuery.prefix(100))...", category: "Pagination")

    do {
      // Count query only returns 1 row, but we still pass editorMaxRowLimit for consistency
      let result = try await connectionManager.executeQuery(
        countQuery, maxRows: AppSettings.shared.editorMaxRowLimit)

      // Extract count from first row, first column
      guard let firstRow = result.rows.first,
        let firstValue = firstRow.first
      else {
        await AppLogger.shared.debug("Count query returned no rows", category: "Pagination")
        return nil
      }

      switch firstValue {
      case .int(let count):
        await AppLogger.shared.debug("Got total count: \(count)", category: "Pagination")
        return count
      case .double(let count):
        await AppLogger.shared.debug("Got total count (double): \(count)", category: "Pagination")
        return Int(count)
      default:
        await AppLogger.shared.debug(
          "Count value is not int/double: \(firstValue)", category: "Pagination")
        return nil
      }
    } catch {
      await AppLogger.shared.debug(
        "Failed to get total count: \(error.localizedDescription)",
        category: "Pagination"
      )
      return nil
    }
  }

  // MARK: - Sidebar Update

  /// Update the View Query sidebar if it's currently showing editor mode query (cellId is nil)
  /// This ensures the sidebar shows the latest executed query after re-running in editor mode
  func updateEditorExecutedQuerySidebarIfNeeded(result: CellResult) {
    // Check if sidebar is showing executed query for editor mode (cellId is nil)
    guard case .executedQuery(_, let sidebarCellId, _, _) = rightSidebarContent,
      sidebarCellId == nil
    else {
      return
    }

    // Get the actual executed query (with LIMIT adjusted if needed)
    guard let sourceQuery = result.sourceQuery else { return }

    let actualQuery: String
    if result.limitWasCapped, let actualLimit = result.actualLimitUsed {
      actualQuery = CellResultViews.replaceLimitInQuery(sourceQuery, newLimit: actualLimit)
    } else {
      actualQuery = sourceQuery
    }

    // Remove comments for display
    let displayQuery = SQLSyntaxHighlighter.removeComments(actualQuery)

    // Update sidebar content
    rightSidebarContent = .executedQuery(
      query: displayQuery,
      cellId: nil,
      limitWasCapped: result.limitWasCapped,
      actualLimit: result.actualLimitUsed
    )
  }
}
