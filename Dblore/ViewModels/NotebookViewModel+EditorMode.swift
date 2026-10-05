//
//  NotebookViewModel+EditorMode.swift
//  Dblore
//

import AppKit
import Foundation

// MARK: - Editor Mode

extension NotebookViewModel {
  /// Clear all editor results (used when Simple Mode runs on empty/comment-only line)
  private func clearEditorResults() {
    editorResult = nil
    editorStatementResults = []
    selectedStatementIndex = 0
    totalExecutionTime = 0
  }

  /// Run query in editor mode (selection if any, otherwise all content)
  func runEditorQuery() async {
    // Data viewer tab: Run (Cmd+R) reloads the page, there is no editor text
    if dataViewer != nil {
      await refreshDataViewer()
      return
    }
    let query = getEditorQueryText()

    // In Simple Mode, clear results if no executable query on current line
    if AppSettings.shared.editorSimpleMode && (query == nil || query!.isEmpty) {
      clearEditorResults()
      return
    }

    guard let query = query, !query.isEmpty, !isEditorQueryRunning else { return }
    guard connectionState == .connected else {
      showToast("Not connected to database", type: .error)
      return
    }
    guard !refuseWhileTransactionPendingElsewhere() else { return }

    // Protection level is enforced by the database gate; fail fast with its message
    if let message = protectionBlockMessage(for: query) {
      showToast(message, type: .error)
      return
    }
    if refuseMissingParameters(query, cellId: nil) != nil { return }

    // Safe Mode: confirm based on every statement (see statementsNeedingConfirmation)
    if presentConfirmationIfNeeded(for: query, cellId: nil) { return }

    await executeEditorQuery(query)
  }

  /// Execute the pending editor query after confirmation
  func executeConfirmedEditorQuery() async {
    guard !queryConfirmationState.pendingQuery.isEmpty else { return }
    let query = queryConfirmationState.pendingQuery
    let parameters = queryConfirmationState.parameterValues
    await executeEditorQuery(query, parameters: parameters)
    queryConfirmationState.clear()
  }

  /// Execute query in editor mode; `maxRows` overrides the effective row cap (data viewer page).
  /// `source` is `.editor` for a user run and `.internal` for a data-viewer page, which is not
  /// recorded.
  func executeEditorQuery(
    _ query: String, maxRows: Int? = nil, source: QueryHistoryRecordSource = .editor,
    parameters boundParameters: [String: SQLBindValue]? = nil
  ) async {
    guard let connectionManager = connectionManager else {
      showToast("No database connection available", type: .error)
      return
    }
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    // No client-side timeout: the server `statement_timeout` is the brake, Cancel stops it
    isEditorQueryRunning = true
    defer { isEditorQueryRunning = false }
    // A confirmed run passes the binds captured with the dialog. Nil reads the live values.
    if boundParameters == nil, refuseMissingParameters(query, cellId: nil) != nil { return }
    let parameters = boundParameters ?? boundParameterValues(for: query, cellId: nil)

    let startTime = Date()

    do {
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(query) {
        // Connection identity before the query: edit targets must resolve on the same one
        let epoch = await connectionManager.connectionEpoch
        // Execute all statements and get detailed results
        let (statementResults, totalTime) =
          try await connectionManager
          .executeDetailed(
            userSQL: query, parameters: parameters, policy: protectionPolicy,
            maxRows: maxRows ?? effectiveRowCap, caller: id)

        totalExecutionTime = totalTime

        // Convert to StatementResult array with primary key columns
        var results: [StatementResult] = []
        for (index, tuple) in statementResults.enumerated() {
          // Session-only inline edit target (nil = not editable)
          let (target, lookup) = await resultTargets(
            for: tuple.queryText, result: tuple.result, connectionManager: connectionManager,
            epoch: epoch)

          results.append(
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
                tableName: target?.qualifiedName,
                primaryKeyColumns: target?.primaryKeyColumns ?? [],
                affectedRows: tuple.result.affectedRows,
                editTarget: target,
                lookupRelation: lookup
              ).withCapInfo(from: tuple.result),
              statementIndex: index
            ))
        }
        editorStatementResults = results

        // Select the last statement by default (psql behavior)
        selectedStatementIndex = editorStatementResults.count - 1

        // Set editorResult to the selected statement's result for backward compatibility
        if !editorStatementResults.isEmpty {
          editorResult = editorStatementResults[selectedStatementIndex].result

          // Update View Query sidebar if it's open for editor mode
          updateEditorExecutedQuerySidebarIfNeeded(result: editorResult!)
          syncCellDetail(cellId: nil, result: editorResult)
        }
        recordResults(results.map { (sql: $0.queryText, result: $0.result) }, source: source)

      } else {
        // Single statement - use existing logic
        let maxRows = maxRows ?? effectiveRowCap
        await AppLogger.shared.debug(
          "Editor mode executing query with maxRows: \(maxRows)", category: "Query")
        let epoch = await connectionManager.connectionEpoch
        let result = try await connectionManager.execute(
          userSQL: query, parameters: parameters, policy: protectionPolicy, maxRows: maxRows,
          caller: id)

        let executionTime = Date().timeIntervalSince(startTime)

        // Clear multi-statement state
        editorStatementResults = []
        selectedStatementIndex = 0
        totalExecutionTime = executionTime

        // Session-only inline edit target (nil = not editable)
        let (target, lookup) = await resultTargets(
          for: query, result: result, connectionManager: connectionManager, epoch: epoch)

        let cellResult = CellResult(
          columns: result.columns,
          rows: result.rows,
          executionTime: executionTime,
          rowCount: result.rows.count,
          timestamp: Date(),
          error: nil,
          wasLimited: result.wasLimited,
          sourceQuery: query,
          tableName: target?.qualifiedName,
          primaryKeyColumns: target?.primaryKeyColumns ?? [],
          affectedRows: result.affectedRows,
          editTarget: target,
          lookupRelation: lookup
        ).withCapInfo(from: result)

        editorResult = cellResult

        // Update View Query sidebar if it's open for editor mode
        updateEditorExecutedQuerySidebarIfNeeded(result: cellResult)
        syncCellDetail(cellId: nil, result: cellResult)
        recordResults([(sql: query, result: cellResult)], source: source)
      }

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      // Clear multi-statement state on error
      editorStatementResults = []
      selectedStatementIndex = 0
      totalExecutionTime = executionTime

      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query
      )
      recordFailure(error, sql: query, duration: executionTime, source: source)
    }
    await onStatementsExecuted?()
  }

  /// Select a specific statement result in editor mode
  func selectEditorStatement(at index: Int) {
    guard index >= 0 && index < editorStatementResults.count else { return }
    selectedStatementIndex = index
    editorResult = editorStatementResults[index].result

    // Update the View Query sidebar if it's currently open for editor mode
    updateExecutedQuerySidebarIfNeeded(cellId: nil, result: editorResult)
  }

  // MARK: - Sidebar Update

  /// Update the View Query sidebar if it's currently showing editor mode query (cellId is nil)
  /// This ensures the sidebar shows the latest executed query after re-running in editor mode
  func updateEditorExecutedQuerySidebarIfNeeded(result: CellResult) {
    // Check if sidebar is showing executed query for editor mode (cellId is nil)
    guard case .executedQuery(_, let sidebarCellId) = rightSidebarContent,
      sidebarCellId == nil
    else {
      return
    }

    // The executed query (sent as written)
    guard let sourceQuery = result.sourceQuery else { return }

    // Remove comments for display
    rightSidebarContent = .executedQuery(
      query: SQLSyntaxHighlighter.removeComments(sourceQuery), cellId: nil)
  }
}
