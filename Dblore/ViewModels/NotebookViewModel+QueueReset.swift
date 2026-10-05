//
//  NotebookViewModel+QueueReset.swift
//  Dblore
//
//  Queued cells never run on a different session than the one they were queued for (they would
//  run without the SET / search_path / temp tables / BEGIN of the cells before them):
//  - a cell whose capped read reset the session cancels the queued cells after it;
//  - a Run All batch runs on the connection its first cell started on: a cell that would start
//    on another one (capped read reset, cancel, reconnect after a session loss, another tab's
//    reset) is refused and the rest of the queue is cancelled.
//

import Foundation

/// Whether a queued task may run (see `admitBatchTask`)
enum BatchAdmission {
  /// Run it; with `expectedEpoch`, the actor sends nothing if the connection changed meanwhile
  case run(expectedEpoch: UInt64?)
  /// Not run: the batch's connection is gone. `result` says so on the cell.
  case refused(CellResult)
}

extension NotebookViewModel {
  /// Admission of `task` before anything is sent. A single cell run always runs. The first cell
  /// of a Run All batch records the connection epoch it starts on; a later cell of that batch
  /// starting on another connection is refused (result set on the cell) and every queued cell
  /// is cancelled.
  func admitBatchTask(
    _ task: ExecutionTask, on connectionManager: DatabaseConnectionManager
  ) async -> BatchAdmission {
    guard let batchId = task.batchId else { return .run(expectedEpoch: nil) }
    let current = await connectionManager.connectionEpoch
    guard let batch = runAllBatch, batch.id == batchId else {
      runAllBatch = (id: batchId, epoch: current)
      return .run(expectedEpoch: current)
    }
    guard batch.epoch != current else { return .run(expectedEpoch: current) }

    let message = CellResult.queuedCellsNotRunMessage(1 + cancelPendingCells())
    let result = CellResult.errorResult(message, sourceQuery: task.query)
    if let index = notebook.cells.firstIndex(where: { $0.id == task.cellId }) {
      notebook.cells[index].result = result
      notebook.cells[index].statementResults = []
      notebook.cells[index].selectedStatementIndex = 0
      notebook.cells[index].totalExecutionTime = nil
    }
    showToast(message, type: .warning)
    onDocumentChanged?()
    return .refused(result)
  }

  /// The cell `cellId` just ran: if its capped read reset the session, cancel every queued cell
  /// and add how many were not run to its notice (and a toast).
  func stopQueueIfSessionReset(cellId: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }),
      notebook.cells[index].result?.sessionReset == true
        || notebook.cells[index].statementResults.contains(where: \.result.sessionReset)
    else { return }
    let count = cancelPendingCells()
    guard count > 0 else { return }

    notebook.cells[index].result?.skippedQueuedCells = count
    // A reset always ends the script: the resetting statement is the last one
    if let last = notebook.cells[index].statementResults.last, last.result.sessionReset {
      var result = last.result
      result.skippedQueuedCells = count
      notebook.cells[index].statementResults[notebook.cells[index].statementResults.count - 1] =
        StatementResult(
          id: last.id, queryText: last.queryText, result: result,
          statementIndex: last.statementIndex)
    }
    showToast(CellResult.queuedCellsNotRunMessage(count), type: .warning)
  }
}
