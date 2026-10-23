//
//  QueryCancelWarning.swift
//  Dblore
//
//  Cancel closes the connection to stop the server work, which rolls back the pending
//  Protected transaction or the user's open transaction: the warning shown first (pure rule).
//  An interrupt that keeps the transaction (MySQL, MongoDB) discards nothing. Another interrupt
//  keeps the connection: DuckDB's always rolls back the open transaction, SQLite's may.
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
      + "search_path are lost).", buttonTitle: stopTitle)

  /// Asked before stopping the editor run when the cancel only interrupts the statement
  static let statementInterrupt = QueryCancelWarning(
    title: "Stop the running query?",
    detail: "The server stops the statement. The connection, its pending changes and any open "
      + "transaction are kept.", buttonTitle: stopTitle)

  /// The same for an engine that runs in the app (SQLite, DuckDB): nothing is open
  static let inProcessInterrupt = QueryCancelWarning(
    title: "Stop the running query?",
    detail: "The statement is stopped. The connection is kept.", buttonTitle: stopTitle)

  let title: String
  /// What is discarded (the itemized pending list for an app transaction)
  let detail: String
  /// The button that cancels: it says "discard" only when the rollback is certain
  var buttonTitle = QueryCancelWarning.confirmTitle

  /// nil when cancelling loses nothing but the session state (temp tables, SET, search_path),
  /// or nothing at all (`keepsTransaction`)
  /// - Parameter ownedByAnotherTab: the app transaction was opened by another tab. A user
  ///   transaction (Protected off) has no owner: any tab may have sent its BEGIN.
  /// - Parameter keepsTransaction: the cancel interrupts only the statement (MySQL, MongoDB)
  /// - Parameter interrupts: the cancel interrupts the statement and keeps the connection; without
  ///   `keepsTransaction` the engine may roll back the open transaction (SQLite)
  /// - Parameter interruptRollsBack: the interrupt always rolls the open transaction back
  ///   (DuckDB)
  static func make(
    state: TransactionState, userTxOpen: Bool, ownedByAnotherTab: Bool = false,
    keepsTransaction: Bool = false, interrupts: Bool = false, interruptRollsBack: Bool = false
  ) -> QueryCancelWarning? {
    guard !keepsTransaction else { return nil }
    let hedged = interrupts && !interruptRollsBack
    let verb = hedged ? "may roll back" : "will roll back"
    let button = hedged ? stopTitle : confirmTitle
    if !state.isIdle {
      let count = state.pending.count
      let owner = ownedByAnotherTab ? "another tab's " : ""
      return QueryCancelWarning(
        title: "Cancelling \(verb) \(owner)\(count) pending change\(count == 1 ? "" : "s")",
        detail: PendingTransactionSummary(state: state).reviewText, buttonTitle: button)
    }
    guard userTxOpen else { return nil }
    if interrupts {
      let effect =
        hedged
        ? "The database may roll back the transaction opened with BEGIN in this tab or another "
          + "tab (it does when the interrupted statement was writing)."
        : "The database rolls back the transaction opened with BEGIN in this tab or another tab."
      return QueryCancelWarning(
        title: "Cancelling \(verb) the open transaction",
        detail: "The statement is stopped and the connection is kept. " + effect,
        buttonTitle: button)
    }
    return QueryCancelWarning(
      title: "Cancelling will roll back the open transaction",
      detail: "The connection is closed to stop the query, so the server rolls back the "
        + "transaction opened with BEGIN in this tab or another tab (temp tables, SET and "
        + "search_path are lost too).")
  }
}
