//
//  QueryCancelWarning.swift
//  Dblore
//
//  Cancel closes the connection to stop the server work, which rolls back the pending
//  Protected transaction or the user's open transaction: the warning shown first (pure rule).
//  An interrupt that keeps the transaction (MySQL, MongoDB) discards nothing.
//

import Foundation

nonisolated struct QueryCancelWarning: Sendable, Equatable {
  static let confirmTitle = "Cancel query & discard"
  static let keepTitle = "Keep running"
  static let stopTitle = "Stop query"

  /// Asked before stopping the editor run when nothing pending would be discarded
  static let sessionReset = QueryCancelWarning(
    title: "Stop the running query?",
    detail: "The connection is reset to stop the query on the server (temp tables, SET and "
      + "search_path are lost).")

  /// Asked before stopping the editor run when the cancel only interrupts the statement
  static let statementInterrupt = QueryCancelWarning(
    title: "Stop the running query?",
    detail: "The server stops the statement. The connection, its pending changes and any open "
      + "transaction are kept.")

  let title: String
  /// What is discarded (the itemized pending list for an app transaction)
  let detail: String

  /// nil when cancelling loses nothing but the session state (temp tables, SET, search_path),
  /// or nothing at all (`keepsTransaction`)
  /// - Parameter ownedByAnotherTab: the app transaction was opened by another tab. A user
  ///   transaction (Protected off) has no owner: any tab may have sent its BEGIN.
  /// - Parameter keepsTransaction: the cancel interrupts only the statement (MySQL, MongoDB)
  static func make(
    state: TransactionState, userTxOpen: Bool, ownedByAnotherTab: Bool = false,
    keepsTransaction: Bool = false
  ) -> QueryCancelWarning? {
    guard !keepsTransaction else { return nil }
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
