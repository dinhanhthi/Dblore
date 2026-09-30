//
//  NotebookViewModel+Explain.swift
//  Dblore
//
//  Explain and Explain Analyze use the same protection check, Safe Mode confirmation,
//  execution, and history recording as a normal run. EXPLAIN ANALYZE runs the inner
//  statement, so it is never sent through executeInternal.
//

import Foundation

extension NotebookViewModel {
  /// Explain the statement the Run action would run: the editor selection (or the current
  /// line / file), or the selected notebook cell.
  func explainSelectedStatement(analyze: Bool) async {
    if viewMode == .editor {
      guard dataViewer == nil, let text = getEditorQueryText(), !text.isEmpty else { return }
      await explain(statement: text, analyze: analyze, buffers: analyze)
      return
    }
    guard let id = selectedCellId,
      let cell = notebook.cells.first(where: { $0.id == id }),
      cell.cellType == .sql
    else { return }
    await explain(statement: cell.content, analyze: analyze, buffers: analyze, cellId: id)
  }

  /// Build an explain script and run it through `protectionBlockMessage`, Safe Mode, then
  /// `execute` / `executeDetailed`. `buffers` is on for Explain Analyze. Data-changing ANALYZE
  /// rolls back unless `rollbackAfterAnalyze` is false or a protected transaction is open.
  func explain(
    statement: String,
    analyze: Bool,
    buffers: Bool,
    rollbackAfterAnalyze: Bool = true,
    cellId: UUID? = nil
  ) async {
    let request: ExplainRequest
    do {
      request = try ExplainRequest(
        statement: statement, analyze: analyze, buffers: buffers,
        rollbackAfterAnalyze: rollbackAfterAnalyze)
    } catch let error as ExplainRequestError {
      showToast(error.message, type: .error)
      return
    } catch {
      showToast(error.localizedDescription, type: .error)
      return
    }

    let sql = request.sqlToRun(
      protectedTransactionOpen: await protectedTransactionOpen(), dialect: explainDialect)
    if let message = protectionBlockMessage(for: sql) {
      showToast(message, type: .error)
      return
    }
    let targetCell = viewMode == .editor ? nil : (cellId ?? selectedCellId)
    if presentConfirmationIfNeeded(for: sql, cellId: targetCell) {
      pendingExplainSQL = sql
      return
    }
    await runExplained(sql, cellId: targetCell)
  }

  /// Protected mode owns the transaction even before the first statement opens it.
  /// An open user transaction is the same: do not send another BEGIN / ROLLBACK.
  private func protectedTransactionOpen() async -> Bool {
    if notebook.connectionConfig?.protectedMode == true { return true }
    guard let connectionManager else { return false }
    let snapshot = await connectionManager.transactionSnapshot()
    if !snapshot.isIdle { return true }
    return await connectionManager.runningStatementStatus().userTxOpen
  }

  private var explainDialect: SQLDialect {
    notebook.connectionConfig?.databaseType.dialect ?? .postgresql
  }

  /// Editor runs and cell runs both record the explain SQL through the normal history path.
  /// Called again after Safe Mode confirmation (`executePendingQuery`).
  func runExplained(_ sql: String, cellId: UUID?) async {
    guard !refuseWhileTransactionPendingElsewhere() else { return }
    if viewMode != .editor, let cellId {
      await runCellStatement(id: cellId, query: sql)
      return
    }
    guard connectionState.isConnected else {
      showToast("Not connected to database", type: .error)
      return
    }
    let source: QueryHistoryRecordSource = viewMode == .editor ? .editor : .cell
    await executeEditorQuery(sql, source: source)
  }

  /// Same send path as `runCell`, with the explain script in place of the cell text.
  private func runCellStatement(id: UUID, query: String) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }),
      notebook.cells[index].cellType == .sql
    else { return }
    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult("Not connected to database", sourceQuery: query)
      onDocumentChanged?()
      return
    }
    guard !executionQueue.isInQueue(cellId: id) else { return }
    executionQueue.enqueue(cellId: id, query: query)
  }
}
