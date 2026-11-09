//
//  NotebookViewModel+Execution.swift
//  Dblore
//

import Foundation
import os

/// Binds captured when a confirmation dialog is created, sent later instead of live parameters.
/// Cell runs copy the dialog snapshot in `runCell` (state is cleared after enqueue), with the
/// connection the dialog was built for (`QueryConfirmationState.connectGeneration`). Explain
/// copies it when the dialog is shown, because confirmation clears state before `runExplained`.
/// The maps are static, so a tab close clears them from `deinit` (not the main actor). A lock
/// covers that and every later read.
nonisolated enum ConfirmedParameterSnapshot {
  private struct CellBind: Sendable {
    var query: String
    var values: [String: SQLBindValue]
    /// The connection the dialog was built for; nil: not a dialog's run (Run All, Explain)
    var admitted: UInt64?
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
    _ owner: NotebookViewModel, cellId: UUID, query: String, values: [String: SQLBindValue],
    admitted: UInt64? = nil
  ) {
    let key = ObjectIdentifier(owner)
    store.withLock { state in
      var map = state.cells[key] ?? [:]
      map[cellId] = CellBind(query: query, values: values, admitted: admitted)
      state.cells[key] = map
    }
  }

  /// Removes the entry either way. A different query must not keep the old binds.
  @MainActor
  static func takeCell(
    _ owner: NotebookViewModel, cellId: UUID, query: String
  ) -> (values: [String: SQLBindValue], admitted: UInt64?)? {
    let key = ObjectIdentifier(owner)
    return store.withLock { state in
      guard var map = state.cells[key], let armed = map.removeValue(forKey: cellId) else {
        return nil
      }
      state.cells[key] = map.isEmpty ? nil : map
      guard armed.query == query else { return nil }
      return (armed.values, armed.admitted)
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
  /// A run, or a confirmation dialog's Execute, whose connection changed after its checks were
  /// made (`connectGenerationForRun`): nothing was sent
  nonisolated static let connectionChangedWhileWaitingMessage =
    "The connection changed before the query was sent. Run it again."

  /// What a failed run shows: a single statement the send refused because the connection
  /// changed (`DatabaseError.sessionChanged`) was not run at all, so it can simply run again
  nonisolated static func runErrorMessage(_ error: any Error, multipleStatements: Bool) -> String {
    if !multipleStatements, case DatabaseError.sessionChanged = error {
      return connectionChangedWhileWaitingMessage
    }
    return error.localizedDescription
  }

  /// What a notebook cell or editor result read keeps per cell and in total (`appReadLimits`).
  /// Nil on MongoDB: its documents feed the document editor and tree view, which could write a
  /// cut value back.
  var resultReadLimits: CappedReadLimits? {
    notebook.connectionConfig?.databaseType.capabilities.queryLanguage == .mongosh
      ? nil : appReadLimits
  }

  /// Run a specific cell by adding it to the execution queue
  func runCell(id: UUID) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    guard notebook.cells[index].cellType == .sql else { return }

    let query = notebook.cells[index].content

    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult(
        "Not connected to database", sourceQuery: query, aiSessionKey: aiSessionKey)
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
        self, cellId: id, query: query, values: queryConfirmationState.parameterValues,
        admitted: queryConfirmationState.connectGeneration)
    } else {
      ConfirmedParameterSnapshot.dropCell(self, cellId: id)
    }

    // Enqueue the cell execution
    executionQueue.enqueue(cellId: id, query: query)
  }

  /// Internal method to execute a task (called by ExecutionQueue). Posts the long-query
  /// notification of a single cell run, or of the Run All batch after its last cell.
  func executeTask(_ task: ExecutionTask) async -> CellResult? {
    let start = ContinuousClock.now
    let result = await runTask(task)
    let cancelled =
      Task.isCancelled
      || executionQueue.tasks.first(where: { $0.id == task.id })?.state == .cancelled
    guard let batchId = task.batchId else {
      if !cancelled, let result {
        notifyCompletion(elapsed: start.duration(to: .now), outcome: Self.completionOutcome(result))
      }
      return result
    }
    guard var batch = runAllNotification, batch.id == batchId else { return result }
    if cancelled {
      runAllNotification = nil
      return result
    }
    if let result { batch.add(Self.completionOutcome(result)) }
    let morePending = executionQueue.tasks.contains {
      $0.batchId == batchId && $0.state == .pending
    }
    guard !morePending else {
      runAllNotification = batch
      return result
    }
    runAllNotification = nil
    notifyCompletion(elapsed: batch.start.duration(to: .now), outcome: batch.outcome)
    return result
  }

  private func runTask(_ task: ExecutionTask) async -> CellResult? {
    // Returns before takeCell still have to drop the stash (missing cell, no connection,
    // another tab's transaction, a refused batch, or a cancel that never reached takeCell).
    defer { ConfirmedParameterSnapshot.dropCell(self, cellId: task.cellId) }
    guard let queuedIndex = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
      return nil
    }
    // Before the query is sent: an error that lands after a switch stays the old connection's
    let aiSessionKey = self.aiSessionKey

    guard let connectionManager = connectionManager else {
      let errorResult = CellResult.errorResult(
        "No database connection available", sourceQuery: task.query, aiSessionKey: aiSessionKey)
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
    // The session the run's checks are made for, read before it shows as waiting: one reopened
    // after this (Cancel, a capped read) refuses the run below, like a connect does
    let admittedEpoch: UInt64
    if let expectedEpoch {
      admittedEpoch = expectedEpoch
    } else {
      admittedEpoch = await connectionManager.connectionEpoch
    }
    // The cell list may have changed while the admission awaited: the cell may be gone or moved
    guard var index = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
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
    let parameters =
      snapshotted?.values ?? boundParameterValues(for: task.query, cellId: task.cellId)

    notebook.cells[index].isRunning = true
    // The connection this run was checked for (its confirmation dialog's, else now): it is
    // never sent on another one
    let admitted = snapshotted?.admitted ?? connectGenerationForRun()
    // Shown as running first; the first run after a DuckDB connect then waits for its loads.
    // Stop meanwhile only cancels the queue (`cancelCell`): nothing of this run was sent.
    connectLoadsWaitTaskId = task.id
    // INFO: Log sanitized query being executed (redact sensitive data). Before the wait: no
    // suspension between the checks below and the send
    let sanitizedQuery = AppLogger.shared.sanitizeQuery(task.query)
    await AppLogger.shared.info(
      "Executing query from cell \(task.cellId): `\(sanitizedQuery)`", category: "Execution")
    let connectionKept = await awaitConnectLoads(admitted)
    if connectLoadsWaitTaskId == task.id { connectLoadsWaitTaskId = nil }
    // The connection the statements are sent on: read before the checks below, and the send
    // refuses any other one (`expectedEpoch`), so a connect started after them sends nothing
    let runEpoch: UInt64
    if let expectedEpoch {
      runEpoch = expectedEpoch
    } else {
      runEpoch = await connectionManager.connectionEpoch
    }
    // Cancelled meanwhile (e.g. the pending transaction is being resolved): send nothing
    guard !Task.isCancelled else {
      if let current = notebook.cells.firstIndex(where: { $0.id == task.cellId }) {
        notebook.cells[current].isRunning = false
      }
      return nil
    }
    // The cell may have moved or gone while the run waited
    guard let current = notebook.cells.firstIndex(where: { $0.id == task.cellId }) else {
      return nil
    }
    index = current
    // What was checked before the wait (confirmation, protection) was for the previous connection.
    // A connect starts by moving the generation: one started since the wait ended refuses too.
    guard connectionKept, runEpoch == admittedEpoch, connectGenerationForRun() == admitted else {
      notebook.cells[index].result = .errorResult(
        Self.connectionChangedWhileWaitingMessage, sourceQuery: task.query,
        aiSessionKey: aiSessionKey)
      notebook.cells[index].isRunning = false
      onDocumentChanged?()
      return nil
    }
    // Another tab may have begun a transaction while the run waited
    guard !refuseWhileTransactionPendingElsewhere() else {
      notebook.cells[index].isRunning = false
      return nil
    }

    var result: CellResult?
    let policy = protectionPolicy
    let caller = id
    // The statements that ran (or may have, for a script that threw): their tables are written
    var ranStatements: [String] = []
    // A script that threw: which of its statements may have run is read after the run
    var scriptError: (any Error)?

    // The statements run on their own task, not cancelled with the queue: only Cancel (close +
    // reconnect, `cancelRunningStatement`) stops the server work, and the server
    // `statement_timeout` (applied on connect) is the time limit.
    let maxRows = effectiveRowCap
    let readLimits = resultReadLimits
    do {
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(task.query, dialect: sqlDialect) {
        let detailed = try await Task {
          try await connectionManager.executeDetailed(
            userSQL: task.query, parameters: parameters, policy: policy, maxRows: maxRows,
            caller: caller, expectedEpoch: runEpoch, readLimits: readLimits)
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
              affectedRows: tuple.result.affectedRows,
              aiSessionKey: aiSessionKey
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
        ranStatements = statementResults.map(\.queryText)
      } else {
        // Single statement - use original logic
        // Connection identity before the query: the edit target must resolve on the same one
        let epoch = runEpoch
        let queryResult = try await Task {
          try await connectionManager.execute(
            userSQL: task.query, parameters: parameters, policy: policy, maxRows: maxRows,
            caller: caller, expectedEpoch: runEpoch, deferEnrichment: true,
            readLimits: readLimits)
        }.value
        ranStatements = [task.query]

        executionCounter += 1

        // Session-only inline edit target (nil = not editable): the rows are shown with what
        // is cached, the server validates it in the background (`patchResultTargets`)
        let ((target, lookup), columns, pending) = await provisionalTargets(
          for: task.query, result: queryResult, connectionManager: connectionManager,
          epoch: epoch)

        // Convert QueryResult to CellResult
        result = CellResult(
          columns: columns,
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
          lookupRelation: lookup,
          aiSessionKey: aiSessionKey
        ).withCapInfo(from: queryResult)
        result?.typesPending = pending

        carryCellDetailEditTarget(from: notebook.cells[index].result, to: result)
        notebook.cells[index].result = result
        if pending, let result {
          patchResultTargets(
            [
              ResultTargetsRead(query: task.query, result: queryResult, timestamp: result.timestamp)
            ],
            cellId: task.cellId, epoch: epoch, connectionManager: connectionManager)
        }
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
        Self.runErrorMessage(
          error,
          multipleStatements: connectionManager.hasMultipleStatements(
            task.query, dialect: sqlDialect)),
        executionTime: executionTime,
        sourceQuery: task.query,
        aiSessionKey: aiSessionKey
      )
      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
      // Clear multi-statement data on error
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      recordFailure(
        error, sql: task.query, duration: error.executionTime ?? 0, source: .cell)
      scriptError = error
    } catch {
      // Handle general errors
      executionCounter += 1
      result = .errorResult(
        error.localizedDescription, sourceQuery: task.query, aiSessionKey: aiSessionKey)
      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
      // Clear multi-statement data on error
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
      recordFailure(error, sql: task.query, duration: 0, source: .cell)
      scriptError = error
    }

    // A capped read reset the session: the queued cells must not run on the new one
    stopQueueIfSessionReset(cellId: task.cellId)
    notebook.cells[index].isRunning = false
    if let scriptError {
      ranStatements = await WrittenRelations.statementsMaybeRun(
        failedScript: task.query, error: scriptError, dialect: sqlDialect)
    }
    if !ranStatements.isEmpty { await onRelationsWritten?(ranStatements, id, runEpoch, false) }
    await onStatementsExecuted?()

    // Notify document changed to trigger save
    onDocumentChanged?()

    // Check file size after execution and show warning if needed
    checkFileSizeAfterExecution()

    // Update View Query sidebar if it's showing query for this cell
    updateExecutedQuerySidebarIfNeeded(cellId: task.cellId, result: result)
    syncCellDetail(cellId: task.cellId, result: result)
    syncRowDetail(cellId: task.cellId, result: result)

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

// MARK: - Long-query notifications

/// Totals of a Run All batch, posted once when its last cell finishes
struct RunAllNotificationBatch {
  let id: UUID
  let start: ContinuousClock.Instant
  private var rows = 0
  private var affected = 0
  private var failed = false

  init(id: UUID, start: ContinuousClock.Instant = .now) {
    self.id = id
    self.start = start
  }

  mutating func add(_ outcome: QueryCompletionOutcome) {
    switch outcome {
    case .rows(let count): rows += count
    case .affected(let count): affected += count
    case .failed: failed = true
    case .cancelled: break
    }
  }

  /// Failed if any cell failed, else the rows read (affected rows when nothing was read)
  var outcome: QueryCompletionOutcome {
    if failed { return .failed }
    return rows == 0 && affected > 0 ? .affected(affected) : .rows(rows)
  }
}

extension NotebookViewModel {
  /// Counts only: the error text and SQL of `result` never reach the notification
  nonisolated static func completionOutcome(_ result: CellResult) -> QueryCompletionOutcome {
    if result.error != nil { return .failed }
    if result.columns.isEmpty, let affected = result.affectedRows { return .affected(affected) }
    return .rows(result.rowCount)
  }

  /// The user cancelled the statement (Cancel closed the session)
  nonisolated static func isCancellation(_ error: Error) -> Bool {
    switch error as? DatabaseError {
    case .queryCancelled, .batchCancelled: true
    default: false
    }
  }

  /// Posts in a task with the settings and app state at completion; never blocks the run
  func notifyCompletion(elapsed: Duration, outcome: QueryCompletionOutcome) {
    guard let tab = notificationTab() else { return }
    let settings = notificationSettings()
    let appActive = isAppActive()
    let seconds = elapsed / .seconds(1)
    let notifier = queryNotifier
    lastCompletionNotification = Task {
      await notifier.notifyIfNeeded(
        tabID: tab.id, tabName: tab.name, elapsed: seconds, outcome: outcome,
        settings: settings, appActive: appActive)
    }
  }
}
