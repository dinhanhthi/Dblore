//
//  NotebookViewModel+Cancel.swift
//  SQLNotebook
//
//  Cancel stops the server work: the running statement's connection is closed and reopened by
//  the actor (`DatabaseConnectionManager.cancelRunningStatement`). The Swift task alone would
//  leave the backend running. When that discards pending Protected changes or the user's open
//  transaction, the user confirms first ("Cancel query & discard" / "Keep running").
//

import AppKit
import Foundation

extension NotebookViewModel {
  /// Cancel button of a cell: a queued cell is only dequeued (nothing was sent); the running
  /// cell stops on the server, with the queued cells after it (Run All).
  func cancelCell(id: UUID) {
    guard executionQueue.isExecuting(cellId: id) else {
      executionQueue.cancel(cellId: id)
      if let index = notebook.cells.firstIndex(where: { $0.id == id }) {
        notebook.cells[index].isRunning = false
      }
      return
    }
    Task { await cancelRunningStatement(cancelQueue: true) }
  }

  /// Run button clicked while the editor run is in flight: always confirmed first
  func cancelEditorQuery() {
    guard isEditorQueryRunning else { return }
    Task { await cancelRunningStatement(cancelQueue: false, alwaysConfirm: true) }
  }

  /// Cancel all pending and executing cells in the queue only (nothing is sent to the server;
  /// used before resolving the pending transaction, which then commits, rolls back or closes)
  func cancelAllCells() {
    executionQueue.cancelAll()

    // Update UI state for all cells
    for index in notebook.cells.indices {
      notebook.cells[index].isRunning = false
    }
  }

  /// Stop the running statement on the server, after confirmation when that discards pending
  /// changes (asked again if the transaction changed while the prompt was open).
  /// - Parameter cancelQueue: also cancel the notebook queue (the running cell and the queued
  ///   ones: they would run on the reopened session); with nothing on the server, only the
  ///   queue is cancelled.
  /// - Parameter alwaysConfirm: ask even when nothing pending would be discarded
  /// - Returns: true if the connection was closed to stop a statement.
  @discardableResult
  func cancelRunningStatement(cancelQueue: Bool, alwaysConfirm: Bool = false) async -> Bool {
    guard let connectionManager else { return false }
    while true {
      let status = await connectionManager.runningStatementStatus()
      guard status.inFlight else {
        if cancelQueue { cancelAllCells() }
        return false
      }
      let ownedByAnotherTab = status.owner.map { $0 != id } ?? false
      if let warning = QueryCancelWarning.make(
        state: status.state, userTxOpen: status.userTxOpen, ownedByAnotherTab: ownedByAnotherTab)
        ?? (alwaysConfirm ? .sessionReset : nil)
      {
        guard await confirmCancel(warning) else { return false }
      }
      // Before the reset: a queued cell must not start on the reopened session
      if cancelQueue { cancelAllCells() }
      let outcome = await connectionManager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      switch outcome {
      case .cancelled: return true
      case .nothingRunning: return false
      case .transactionChanged: continue
      }
    }
  }

  private func confirmCancel(_ warning: QueryCancelWarning) async -> Bool {
    if let cancelQueryPrompt { return await cancelQueryPrompt(warning) }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = warning.title
    alert.informativeText = warning.detail
    // Return keeps the query running; the destructive answer needs a click
    alert.addButton(withTitle: QueryCancelWarning.keepTitle)
    let discard = alert.addButton(
      withTitle: warning == .sessionReset
        ? QueryCancelWarning.stopTitle : QueryCancelWarning.confirmTitle)
    discard.hasDestructiveAction = true
    let response: NSApplication.ModalResponse
    if let window = NSApp.keyWindow {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }
    return response == .alertSecondButtonReturn
  }
}
