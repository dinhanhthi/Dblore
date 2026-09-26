//
//  NotebookViewModel+NotebookPagination.swift
//  SQLNotebook
//
//  Pagination support for notebook mode (similar to editor mode)
//

import Foundation

// MARK: - Notebook Pagination

extension NotebookViewModel {
  // MARK: - Get Pagination Info

  /// Get pagination info for a specific cell
  /// - Returns: PaginationInfo for single statement, or nil if not applicable
  func getPaginationInfo(for cellId: UUID) -> PaginationInfo? {
    guard let cell = notebook.cells.first(where: { $0.id == cellId }) else {
      return nil
    }

    // Multi-statement mode - return pagination for selected statement
    if !cell.statementResults.isEmpty {
      let selectedStatement = cell.statementResults[cell.selectedStatementIndex]
      return cellStatementPaginationInfo[cellId]?[selectedStatement.id]
    }

    // Single statement mode
    return cellPaginationInfo[cellId]
  }

  // MARK: - Page Navigation

  /// Navigate to a specific page for a cell's single statement result
  func navigateToPageForCell(cellId: UUID, page: Int) async {
    guard let paginationInfo = cellPaginationInfo[cellId] else { return }
    guard page > 0 && page <= paginationInfo.totalPages else { return }
    guard page != paginationInfo.currentPage else { return }

    guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return }
    guard let sourceQuery = cell.result?.sourceQuery else { return }

    // Build query with LIMIT and OFFSET
    let query = paginationInfo.queryForPage(page)

    await executeCellQueryForPagination(
      cellId: cellId,
      query: query,
      page: page,
      paginationInfo: paginationInfo,
      sourceQuery: sourceQuery
    )
  }

  /// Navigate to a specific page for a cell's multi-statement result
  func navigateToPageForCellStatement(cellId: UUID, statementId: UUID, page: Int) async {
    guard let statementsPagination = cellStatementPaginationInfo[cellId],
      let paginationInfo = statementsPagination[statementId]
    else {
      return
    }
    guard page > 0 && page <= paginationInfo.totalPages else { return }
    guard page != paginationInfo.currentPage else { return }

    guard let cell = notebook.cells.first(where: { $0.id == cellId }) else { return }
    guard let statementResult = cell.statementResults.first(where: { $0.id == statementId }) else {
      return
    }

    // Build query with LIMIT and OFFSET
    let query = paginationInfo.queryForPage(page)

    await executeCellStatementQueryForPagination(
      cellId: cellId,
      statementId: statementId,
      query: query,
      page: page,
      paginationInfo: paginationInfo,
      statementQuery: statementResult.queryText
    )
  }

  // MARK: - Pagination Query Execution

  /// Execute a paginated query for a cell (single statement mode)
  private func executeCellQueryForPagination(
    cellId: UUID,
    query: String,
    page: Int,
    paginationInfo: PaginationInfo,
    sourceQuery: String
  ) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }),
      let connectionManager = connectionManager
    else { return }

    let startTime = Date()

    do {
      let epoch = await connectionManager.connectionEpoch
      let result = try await connectionManager.execute(
        userSQL: query, policy: protectionPolicy, maxRows: AppSettings.shared.maxRowLimit)
      let executionTime = Date().timeIntervalSince(startTime)

      // Update pagination info with new page
      cellPaginationInfo[cellId] = PaginationInfo(
        currentPage: page,
        totalRows: paginationInfo.totalRows,
        rowsPerPage: paginationInfo.rowsPerPage,
        baseQuery: paginationInfo.baseQuery
      )
      // Sync pagination info to cell for persistence
      notebook.cells[index].paginationInfo = cellPaginationInfo[cellId]

      // Inline edit target, checked on the statement that produced these rows
      let target = await editTarget(
        for: query, result: result, connectionManager: connectionManager, epoch: epoch)

      // Update cell result - use paginated query as sourceQuery for View Query sidebar
      let cellResult = CellResult(
        columns: result.columns,
        rows: result.rows,
        executionTime: executionTime,
        rowCount: result.rows.count,
        timestamp: Date(),
        error: nil,
        wasLimited: false,
        sourceQuery: query,  // Use paginated query (with LIMIT/OFFSET) for sidebar
        tableName: target?.qualifiedName,
        primaryKeyColumns: target?.primaryKeyColumns ?? [],
        rowIdentifiers: result.rowIdentifiers,
        userLimitExceeded: false,
        userRequestedLimit: paginationInfo.rowsPerPage,
        affectedRows: nil,
        limitWasCapped: false,
        actualLimitUsed: paginationInfo.rowsPerPage,
        editTarget: target
      )

      notebook.cells[index].result = cellResult

      // Notify document changed
      onDocumentChanged?()

      // Update View Query sidebar if it's showing query for this cell
      updateExecutedQuerySidebarIfNeeded(cellId: cellId, result: cellResult)

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      // Set error result - use paginated query for sidebar
      let errorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query  // Use paginated query (with LIMIT/OFFSET)
      )

      notebook.cells[index].result = errorResult

      // Notify document changed
      onDocumentChanged?()

      // Update View Query sidebar even on error
      updateExecutedQuerySidebarIfNeeded(cellId: cellId, result: errorResult)
    }
  }

  /// Execute a paginated query for a cell's multi-statement result
  private func executeCellStatementQueryForPagination(
    cellId: UUID,
    statementId: UUID,
    query: String,
    page: Int,
    paginationInfo: PaginationInfo,
    statementQuery: String
  ) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }),
      let connectionManager = connectionManager
    else { return }
    guard
      let statementIndex = notebook.cells[index].statementResults.firstIndex(where: {
        $0.id == statementId
      })
    else {
      return
    }

    let startTime = Date()

    do {
      let result = try await connectionManager.execute(
        userSQL: query, policy: protectionPolicy, maxRows: AppSettings.shared.maxRowLimit)
      let executionTime = Date().timeIntervalSince(startTime)

      // Update pagination info with new page
      cellStatementPaginationInfo[cellId]?[statementId] = PaginationInfo(
        currentPage: page,
        totalRows: paginationInfo.totalRows,
        rowsPerPage: paginationInfo.rowsPerPage,
        baseQuery: paginationInfo.baseQuery
      )
      // Sync statement pagination info to cell for persistence
      notebook.cells[index].statementPaginationInfo = cellStatementPaginationInfo[cellId] ?? [:]

      // Create new cell result - use paginated query for View Query sidebar
      let newResult = CellResult(
        columns: result.columns,
        rows: result.rows,
        executionTime: executionTime,
        rowCount: result.rows.count,
        timestamp: Date(),
        error: nil,
        wasLimited: false,
        sourceQuery: query,  // Use paginated query (with LIMIT/OFFSET) for sidebar
        tableName: nil,
        primaryKeyColumns: [],
        rowIdentifiers: result.rowIdentifiers,
        userLimitExceeded: false,
        userRequestedLimit: paginationInfo.rowsPerPage,
        affectedRows: nil,
        limitWasCapped: false,
        actualLimitUsed: paginationInfo.rowsPerPage
      )

      // Update statement result
      let oldStatementResult = notebook.cells[index].statementResults[statementIndex]
      notebook.cells[index].statementResults[statementIndex] = StatementResult(
        id: statementId,
        queryText: statementQuery,
        result: newResult,
        statementIndex: oldStatementResult.statementIndex
      )

      // Update cell's result if this is the selected statement
      if notebook.cells[index].selectedStatementIndex == statementIndex {
        notebook.cells[index].result = newResult
      }

      // Notify document changed
      onDocumentChanged?()

      // Update View Query sidebar if it's showing query for this cell
      updateExecutedQuerySidebarIfNeeded(cellId: cellId, result: newResult)

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      // Create error result - use paginated query for sidebar
      let errorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query  // Use paginated query (with LIMIT/OFFSET)
      )

      // Update statement result with error
      let oldStatementResult = notebook.cells[index].statementResults[statementIndex]
      notebook.cells[index].statementResults[statementIndex] = StatementResult(
        id: statementId,
        queryText: statementQuery,
        result: errorResult,
        statementIndex: oldStatementResult.statementIndex
      )

      // Update cell's result if this is the selected statement
      if notebook.cells[index].selectedStatementIndex == statementIndex {
        notebook.cells[index].result = errorResult
      }

      // Notify document changed
      onDocumentChanged?()

      // Update View Query sidebar even on error
      updateExecutedQuerySidebarIfNeeded(cellId: cellId, result: errorResult)
    }
  }
}
