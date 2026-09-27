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
  /// - Parameter ownedByAnotherTab: the app transaction was opened by another tab. A user
  ///   transaction (Protected off) has no owner: any tab may have sent its BEGIN.
  static func make(
    state: TransactionState, userTxOpen: Bool, ownedByAnotherTab: Bool = false
  ) -> QueryCancelWarning? {
    if !state.isIdle {
      let count = state.pending.count
      let owner = ownedByAnotherTab ? "another tab's " : ""
      return QueryCancelWarning(
        title:
          "Cancelling will roll back \(owner)\(count) pending change\(count == 1 ? "" : "s")",
        detail: PendingTransactionSummary(state: state).reviewText)
    }
    guard userTxOpen else { return nil }
    return QueryCancelWarning(
      title: "Cancelling will roll back the open transaction",
      detail: "The connection is closed to stop the query, so the server rolls back the "
        + "transaction opened with BEGIN in this tab or another tab (temp tables, SET and "
        + "search_path are lost too).")
  }
}
