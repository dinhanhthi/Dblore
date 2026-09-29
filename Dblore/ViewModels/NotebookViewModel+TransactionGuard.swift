//
//  NotebookViewModel+TransactionGuard.swift
//  Dblore
//
//  While another tab of the workspace has a pending Protected transaction, this tab runs
//  nothing (cells, editor, Run All, inline edits). The actor enforces the same
//  rule with the tab token (`id`); this check only gives the message before anything starts.
//

import Foundation

extension NotebookViewModel {
  nonisolated static let transactionPendingElsewhereMessage =
    "Commit or roll back pending changes first"

  /// True (with a toast) if another tab has a pending transaction: the caller must stop.
  func refuseWhileTransactionPendingElsewhere() -> Bool {
    guard isTransactionPendingElsewhere else { return false }
    showToast(Self.transactionPendingElsewhereMessage, type: .warning)
    return true
  }
}
