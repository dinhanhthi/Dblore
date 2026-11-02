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
    refreshEditorComparison()
  }

  /// Run query in editor mode (selection if any, otherwise all content)
  func runEditorQuery() async {
    // Data viewer tab: Run (Cmd+R) reloads the page, there is no editor text
    if dataViewer != nil {
      await refreshDataViewer()
      return
    }
    // Object source tab: the definition is shown, never run
    guard !isReadOnlySource else { return }
    let query = getEditorQueryText()

    // In Simple Mode, clear results if no executable query on current line
    if AppSettings.shared.editorSimpleMode && (query == nil || query!.isEmpty) {
      clearEditorResults()
      return
    }

    guard let query = query, !query.isEmpty else { return }
    await runUserEditorQuery(query)
  }

  /// Runs `query` as a typed editor run: the protection check, missing parameters and the
  /// Safe Mode confirmation, then the gate in `executeEditorQuery`. Also how an AI proposal the
  /// user approved runs (`WorkspaceManager.runAIProposal`), so it gets no other path.
  func runUserEditorQuery(_ query: String) async {
    guard !isEditorQueryRunning else { return }
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

  /// Execute the pending editor query after confirmation, on the connection the dialog was
  /// built for only
  func executeConfirmedEditorQuery() async {
    guard !queryConfirmationState.pendingQuery.isEmpty else { return }
    guard !refuseConfirmationOfChangedConnection() else { return }
    let query = queryConfirmationState.pendingQuery
    let parameters = queryConfirmationState.parameterValues
    let admitted = queryConfirmationState.connectGeneration
    await executeEditorQuery(query, parameters: parameters, admitted: admitted)
    queryConfirmationState.clear()
  }

  /// The editor run's `awaitConnectLoads`, which Stop ends (`cancelEditorQuery`), then the
  /// connection epoch the run is sent with. Nil: send nothing (stopped, the connection changed
  /// meanwhile or another tab's transaction began).
  /// `admitted`: the connection a confirmation dialog was built for; nil reads it here, right
  /// where the run shows as running, before any suspension.
  private func waitForConnectLoads(
    admitted confirmed: UInt64?, connectionManager: DatabaseConnectionManager
  ) async -> UInt64? {
    let admitted = confirmed ?? connectGenerationForRun()
    let wait = Task { await awaitConnectLoads(admitted) }
    editorConnectLoadsWait = wait
    let connectionKept = await withTaskCancellationHandler {
      await wait.value
    } onCancel: {
      wait.cancel()
    }
    if editorConnectLoadsWait == wait { editorConnectLoadsWait = nil }
    // Read before the checks below, which are synchronous: a connect started before them moved
    // the generation and is refused there, one started after them moves the epoch the send
    // checks (`expectedEpoch`)
    let epoch = await connectionManager.connectionEpoch
    guard !wait.isCancelled, !Task.isCancelled else { return nil }
    guard connectionKept, connectGenerationForRun() == admitted else {
      showToast(Self.connectionChangedWhileWaitingMessage, type: .error)
      return nil
    }
    return refuseWhileTransactionPendingElsewhere() ? nil : epoch
  }

  /// Execute query in editor mode; `maxRows` overrides the effective row cap (data viewer page).
  /// `source` is `.editor` for a user run and `.internal` for a data-viewer page, which is not
  /// recorded. `pageState` is the SQL data viewer state `query` is the `pageSQL` of, taken
  /// before the page read: its length columns leave the result before anything reads it.
  /// `admitted`: the connection the confirmation dialog of a confirmed run was built for.
  func executeEditorQuery(
    _ query: String, maxRows: Int? = nil, source: QueryHistoryRecordSource = .editor,
    parameters boundParameters: [String: SQLBindValue]? = nil,
    pageState: DataViewerState? = nil, admitted: UInt64? = nil
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
    let maxRows = maxRows ?? effectiveRowCap
    let multipleStatements = connectionManager.hasMultipleStatements(query, dialect: sqlDialect)
    // Connection identity before the query: edit targets must resolve on the same one. Shown as
    // running first; a user run after a DuckDB connect then waits for its loads. Never an
    // internal read: the restored data-viewer pages are among those loads.
    let epoch: UInt64
    if source == .internal {
      epoch = await connectionManager.connectionEpoch
    } else {
      guard
        let checked = await waitForConnectLoads(
          admitted: admitted, connectionManager: connectionManager)
      else { return }
      epoch = checked
    }
    // A user run is sent on the connection its checks were made for, or not at all: the send
    // refuses any epoch but this one (`expectedEpoch`), so it never runs on a connection a
    // connect opened after the checks. An internal read is sent on whatever connection is open.
    let expectedEpoch = source == .internal ? nil : epoch
    // Before the query is sent: an error that lands after a switch stays the old connection's
    let aiSessionKey = self.aiSessionKey

    let startTime = Date()
    let notifyStart = ContinuousClock.now
    // Long-query notification of a user run; nil after a cancel
    var completion: QueryCompletionOutcome?
    // The statements that ran (or may have, for a script that threw): their tables are written
    var ranStatements: [String] = []
    // A script that threw: which of its statements may have run is read after the run
    var scriptError: (any Error)?
    // The connection the statements were sent on (nil: nothing was sent)
    var runEpoch: UInt64?

    do {
      // A lazy page always comes with its state, and as the state's own SQL; anything else
      // would show its prefixes as whole values
      if let pageState, pageState.pageSQL != query { throw LazyPageError.unexpectedShape }
      if pageState == nil, source == .internal, query.contains("dblore_byte_length_") {
        throw LazyPageError.unexpectedShape
      }
      // Check if this is a multi-statement query
      if multipleStatements {
        if pageState?.lazyColumns != nil { throw LazyPageError.unexpectedShape }
        runEpoch = epoch
        // Execute all statements and get detailed results
        let (statementResults, totalTime) =
          try await connectionManager
          .executeDetailed(
            userSQL: query, parameters: parameters, policy: protectionPolicy,
            maxRows: maxRows, caller: id, expectedEpoch: expectedEpoch)
        ranStatements = statementResults.map(\.queryText)

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
                lookupRelation: lookup,
                aiSessionKey: aiSessionKey
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
          syncRowDetail(cellId: nil, result: editorResult)
        }
        recordResults(results.map { (sql: $0.queryText, result: $0.result) }, source: source)
        completion = results.last.map { Self.completionOutcome($0.result) }

      } else {
        // Single statement - use existing logic
        await AppLogger.shared.debug(
          "Editor mode executing query with maxRows: \(maxRows)", category: "Query")
        runEpoch = epoch
        var result = try await connectionManager.execute(
          userSQL: query, parameters: parameters, policy: protectionPolicy, maxRows: maxRows,
          caller: id, expectedEpoch: expectedEpoch)
        ranStatements = [query]
        var truncation: DataViewerState.Truncation?
        if let pageState {
          (result, truncation) = try await strippedDataViewerPage(
            result, state: pageState, epoch: epoch, connectionManager: connectionManager)
        }

        let executionTime = Date().timeIntervalSince(startTime)

        // Session-only inline edit target (nil = not editable)
        let (target, lookup) = await resultTargets(
          for: query, result: result, connectionManager: connectionManager, epoch: epoch)

        // The viewer moved to another table or page meanwhile: this page is not shown or
        // recorded (`loadDataViewerPage` reads the new one)
        if let pageState, dataViewer?.loadKey != pageState.loadKey { return }

        // Clear multi-statement state
        editorStatementResults = []
        selectedStatementIndex = 0
        totalExecutionTime = executionTime

        var cellResult = CellResult(
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
          lookupRelation: lookup,
          aiSessionKey: aiSessionKey
        ).withCapInfo(from: result)
        cellResult.truncation = truncation
        if pageState != nil { resetLazyCells() }
        editorResult = cellResult

        // Update View Query sidebar if it's open for editor mode
        updateEditorExecutedQuerySidebarIfNeeded(result: cellResult)
        syncCellDetail(cellId: nil, result: cellResult)
        syncRowDetail(cellId: nil, result: cellResult)
        recordResults([(sql: query, result: cellResult)], source: source)
        completion = Self.completionOutcome(cellResult)
      }

    } catch {
      // A page of a table or page the viewer has left is not shown or recorded, failed or not
      if let pageState, dataViewer?.loadKey != pageState.loadKey { return }
      let executionTime = Date().timeIntervalSince(startTime)

      // Clear multi-statement state on error
      editorStatementResults = []
      selectedStatementIndex = 0
      totalExecutionTime = executionTime

      editorResult = CellResult.errorResult(
        Self.runErrorMessage(error, multipleStatements: multipleStatements),
        executionTime: executionTime,
        sourceQuery: query,
        aiSessionKey: aiSessionKey
      )
      recordFailure(error, sql: query, duration: executionTime, source: source)
      completion = Self.isCancellation(error) ? nil : .failed
      scriptError = error
    }
    if source == .editor, let completion {
      notifyCompletion(elapsed: notifyStart.duration(to: .now), outcome: completion)
    }
    // A re-run keeps the pin; compare against the new result
    refreshEditorComparison()
    if let scriptError {
      ranStatements = await WrittenRelations.statementsMaybeRun(
        failedScript: query, error: scriptError, dialect: sqlDialect)
    }
    if let runEpoch, !ranStatements.isEmpty {
      await onRelationsWritten?(ranStatements, id, runEpoch)
    }
    await onStatementsExecuted?()
  }

  /// Select a specific statement result in editor mode
  func selectEditorStatement(at index: Int) {
    guard index >= 0 && index < editorStatementResults.count else { return }
    selectedStatementIndex = index
    editorResult = editorStatementResults[index].result
    refreshEditorComparison()

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
