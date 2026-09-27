//
//  QueryCancelWarning.swift
//  SQLNotebook
//
//  Cancel closes the connection to stop the server work, which rolls back the pending
//  Protected transaction or the user's open transaction: the warning shown first (pure rule).
//

import Foundation

nonisolated struct QueryCancelWarning: Sendable, Equatable {
  static let confirmTitle = "Cancel query & discard"
  static let keepTitle = "Keep running"

  let title: String
  /// What is discarded (the itemized pending list for an app transaction)
  let detail: String

  /// nil when cancelling loses nothing but the session state (temp tables, SET, search_path)
  static func make(state: TransactionState, userTxOpen: Bool) -> QueryCancelWarning? {
    if !state.isIdle {
      let count = state.pending.count
      return QueryCancelWarning(
        title: "Cancelling will roll back \(count) pending change\(count == 1 ? "" : "s")",
        detail: PendingTransactionSummary(state: state).reviewText)
    }
    guard userTxOpen else { return nil }
    return QueryCancelWarning(
      title: "Cancelling will roll back your open transaction",
      detail: "The connection is closed to stop the query, so the server rolls back the "
        + "transaction you opened with BEGIN (temp tables, SET and search_path are lost too).")
  }
}
