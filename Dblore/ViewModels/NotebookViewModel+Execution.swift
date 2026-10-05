//
//  NotebookViewModel+Execution.swift
//  Dblore
//

import Foundation
import os

/// Binds captured when a confirmation dialog is created, sent later instead of live parameters.
/// Cell runs copy the dialog snapshot in `runCell` (state is cleared after enqueue). Explain
/// copies it when the dialog is shown, because confirmation clears state before `runExplained`.
/// The maps are static, so a tab close clears them from `deinit` (not the main actor). A lock
/// covers that and every later read.
nonisolated enum ConfirmedParameterSnapshot {
  private struct CellBind: Sendable {
    var query: String
    var values: [String: SQLBindValue]
  }

  private struct ExplainBind: Sendable {
    var sql: String
    var values: [String: SQLBindValue]
  }

  private struct Store: Sendable {
    var cells: [ObjectIdentifier: [UUID: CellBind]] = [:]
    var explains: [ObjectIdentifier: ExplainBind] = [:]
  }

  private static let store = OSAllocatedUnfairLock(initialState: Store())

  /// Drops every snapshot for `owner`.
  static func reset(_ owner: ObjectIdentifier) {
    store.withLock { state in
      state.cells[owner] = nil
      state.explains[owner] = nil
    }
  }

  /// Drops the explain snapshot and any cell snapshot that is not still queued.
  static func release(_ owner: ObjectIdentifier, keeping cellIds: Set<UUID>) {
    store.withLock { state in
      state.explains[owner] = nil
      guard var map = state.cells[owner] else { return }
      map = map.filter { cellIds.contains($0.key) }
      state.cells[owner] = map.isEmpty ? nil : map
    }
  }

  @MainActor
  static func stashCell(
    _ owner: NotebookViewModel, cellId: UUID, query: String, values: [String: SQLBindValue]
  ) {
    let key = ObjectIdentifier(owner)
    store.withLock { state in
      var map = state.cells[key] ?? [:]
      map[cellId] = CellBind(query: query, values: values)
      state.cells[key] = map
    }
  }

  /// Removes the entry either way. A different query must not keep the old binds.
  @MainActor
  static func takeCell(
    _ owner: NotebookViewModel, cellId: UUID, query: String
  ) -> [String: SQLBindValue]? {
    let key = ObjectIdentifier(owner)
    return store.withLock { state in
      guard var map = state.cells[key], let armed = map.removeValue(forKey: cellId) else {
        return nil
      }
      state.cells[key] = map.isEmpty ? nil : map
      guard armed.query == query else { return nil }
      return armed.values
    }
  }

  /// Drops a snapshot a cancelled run left behind, so the next unconfirmed run reads live values.
  @MainActor
  static func dropCell(_ owner: NotebookViewModel, cellId: UUID) {
    let key = ObjectIdentifier(owner)
    store.withLock { state in
      guard var map = state.cells[key] else { return }
      map[cellId] = nil
      state.cells[key] = map.isEmpty ? nil : map
    }
  }

  @MainActor
  static func armExplain(
    _ owner: NotebookViewModel, sql: String, values: [String: SQLBindValue]
  ) {
    let key = ObjectIdentifier(owner)
    store.withLock { state in
      state.explains[key] = ExplainBind(sql: sql, values: values)
    }
  }

  @MainActor
  static func disarmExplain(_ owner: NotebookViewModel) {
    let key = ObjectIdentifier(owner)
    store.withLock { state in
      state.explains[key] = nil
    }
  }

  /// Removes the entry either way. A different script must not keep the old binds.
  @MainActor
  static func takeExplain(_ owner: NotebookViewModel, sql: String) -> [String: SQLBindValue]? {
    let key = ObjectIdentifier(owner)
    return store.withLock { state in
      guard let armed = state.explains.removeValue(forKey: key) else { return nil }
      guard armed.sql == sql else { return nil }
      return armed.values
    }
  }
}

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

    // Resign first responder. textDidChange already wrote the binding, so the cell content is current.
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)

    // The dialog still holds the binds taken when it opened. Enqueue copies them: clear() runs
    // before the queue sends, and a later edit of the cell's values must not change this run.
    if queryConfirmationState.pendingCellId == id, queryConfirmationState.pendingQuery == query {
      ConfirmedParameterSnapshot.stashCell(
        self, cellId: id, query: query, values: queryConfirmationState.parameterValues)
    } else {
      ConfirmedParameterSnapshot.dropCell(self, cellId: id)
    }

    // Enqueue the cell execution
    executionQueue.enqueue(cellId: id, query: query)
  }

  /// Internal method to execute a task (called by ExecutionQueue)
  func executeTask(_ task: ExecutionTask) async -> CellResult? {
    // Returns before takeCell still have to drop the stash (missing cell, no connection,
    // another tab's transaction, a refused batch, or a cancel that never reached takeCell).
    defer { ConfirmedParameterSnapshot.dropCell(self, cellId: task.cellId) }
    guard let queuedIndex = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
      return nil
    }

    guard let connectionManager = connectionManager else {
      let errorResult = CellResult.errorResult(
        "No database connection available", sourceQuery: task.query)
      notebook.cells[queuedIndex].result = errorResult
      onDocumentChanged?()
      return errorResult
    }
    // Another tab's pending transaction: nothing is sent, the cell keeps its result
    guard !refuseWhileTransactionPendingElsewhere() else { return nil }
    // A Run All cell only runs on the connection its batch started on
    let expectedEpoch: UInt64?
    switch await admitBatchTask(task, on: connectionManager) {
    case .run(let epoch): expectedEpoch = epoch
    case .refused(let result): return result
    }
    // The cell list may have changed while the admission awaited: the cell may be gone or moved
    guard let index = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
      return nil
    }
    let snapshotted = ConfirmedParameterSnapshot.takeCell(
      self, cellId: task.cellId, query: task.query)
    // Cancelled during admission: the stash may already have been dropped. Do not turn that
    // into a missing-parameter error, and do not send.
    if Task.isCancelled {
      return nil
    }
    if snapshotted == nil, refuseMissingParameters(task.query, cellId: task.cellId) != nil {
      return notebook.cells[index].result
    }
    let parameters = snapshotted ?? boundParameterValues(for: task.query, cellId: task.cellId)

    notebook.cells[index].isRunning = true

    // INFO: Log sanitized query being executed (redact sensitive data)
    let sanitizedQuery = AppLogger.shared.sanitizeQuery(task.query)
    await AppLogger.shared.info(
      "Executing query from cell \(task.cellId): `\(sanitizedQuery)`", category: "Execution")
    // Cancelled meanwhile (e.g. the pending transaction is being resolved): send nothing
    guard !Task.isCancelled else {
      if let current = notebook.cells.firstIndex(where: { $0.id == task.cellId }) {
        notebook.cells[current].isRunning = false
      }
      return nil
    }

    var result: CellResult?
    let policy = protectionPolicy
    let caller = id

    // The statements run on their own task, not cancelled with the queue: only Cancel (close +
    // reconnect, `cancelRunningStatement`) stops the server work, and the server
    // `statement_timeout` (applied on connect) is the time limit.
    let maxRows = effectiveRowCap
    do {
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(task.query) {
        let detailed = try await Task {
          try await connectionManager.executeDetailed(
            userSQL: task.query, parameters: parameters, policy: policy, maxRows: maxRows,
            caller: caller, expectedEpoch: expectedEpoch)
        }.value
        let statementResults = detailed.results
        let totalTime = detailed.totalTime

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
              affectedRows: tuple.result.affectedRows
            ).withCapInfo(from: tuple.result),
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
        recordResults(
          convertedStatements.map { (sql: $0.queryText, result: $0.result) }, source: .cell)
      } else {
        // Single statement - use original logic
        // Connection identity before the query: the edit target must resolve on the same one
        let epoch = await connectionManager.connectionEpoch
        let queryResult = try await Task {
          try await connectionManager.execute(
            userSQL: task.query, parameters: parameters, policy: policy, maxRows: maxRows,
            caller: caller, expectedEpoch: expectedEpoch)
        }.value

        executionCounter += 1

        // Session-only, server-validated inline edit target (nil = not editable)
        let (target, lookup) = await resultTargets(
          for: task.query, result: queryResult, connectionManager: connectionManager,
          epoch: epoch)

        // Convert QueryResult to CellResult
        result = CellResult(
          columns: queryResult.columns,
          rows: queryResult.rows,
          executionTime: queryResult.executionTime,
          rowCount: queryResult.rowCount,
          timestamp: Date(),
          wasLimited: queryResult.wasLimited,
          sourceQuery: task.query,
          tableName: target?.qualifiedName,
          primaryKeyColumns: target?.primaryKeyColumns ?? [],
          affectedRows: queryResult.affectedRows,
          editTarget: target,
          lookupRelation: lookup
        ).withCapInfo(from: queryResult)

        carryCellDetailEditTarget(from: notebook.cells[index].result, to: result)
        notebook.cells[index].result = result
        notebook.cells[index].executionCount = executionCounter
        // Clear multi-statement data for single statement
        notebook.cells[index].statementResults = []
        notebook.cells[index].selectedStatementIndex = 0
        notebook.cells[index].totalExecutionTime = nil
        if let result {
          recordResults([(sql: task.query, result: result)], source: .cell)
        }
      }
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
      recordFailure(
        error, sql: task.query, duration: error.executionTime ?? 0, source: .cell)
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
      recordFailure(error, sql: task.query, duration: 0, source: .cell)
    }

    // A capped read reset the session: the queued cells must not run on the new one
    stopQueueIfSessionReset(cellId: task.cellId)
    notebook.cells[index].isRunning = false
    await onStatementsExecuted?()

    // Notify document changed to trigger save
    onDocumentChanged?()

    // Check file size after execution and show warning if needed
    checkFileSizeAfterExecution()

    // Update View Query sidebar if it's showing query for this cell
    updateExecutedQuerySidebarIfNeeded(cellId: task.cellId, result: result)
    syncCellDetail(cellId: task.cellId, result: result)

    return result
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
  /// Only recalculates every 5 executions for performance (10.3.4 optimization)
  func checkFileSizeAfterExecution() {
    // Increment counter and check if we should recalculate
    fileSizeExecutionCounter += 1
    guard fileSizeExecutionCounter >= fileSizeCheckInterval else { return }

    // Reset counter and recalculate
    fileSizeExecutionCounter = 0
    recalculateFileSize()

    let fileSize = estimatedFileSize

    // Check if we exceeded large threshold (and haven't shown dialog yet)
    if fileSize > FileOptimizationService.largeSizeThreshold && !fileSizeState.hasShownLargeDialog {
      fileSizeState.hasShownLargeDialog = true
      fileSizeState.showLargeDialog = true
      return  // Don't show warning dialog if we're already showing large dialog
    }

    // Check if we exceeded warning threshold (and haven't shown dialog yet)
    if fileSize > FileOptimizationService.warningSizeThreshold
      && !fileSizeState.hasShownWarningDialog
    {
      fileSizeState.hasShownWarningDialog = true
      fileSizeState.showWarningDialog = true
    }
  }

  // MARK: - Helper Methods

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
    guard case .executedQuery(_, let sidebarCellId) = rightSidebarContent else {
      return
    }

    // Check if the sidebar is showing query for this specific cell (or editor mode if both are nil)
    guard sidebarCellId == cellId else {
      return
    }

    // The executed query (sent as written)
    guard let sourceQuery = result?.sourceQuery else { return }

    // Remove comments for display
    rightSidebarContent = .executedQuery(
      query: SQLSyntaxHighlighter.removeComments(sourceQuery), cellId: cellId)
  }
}
