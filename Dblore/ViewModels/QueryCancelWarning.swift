//
//  QueryCancelWarning.swift
//  Dblore
//
//  Cancel stops the server work, which rolls back the pending Protected transaction or the
//  user's open transaction: the warning shown first (pure rule). An interrupt that keeps the
//  transaction (MySQL, MongoDB) discards nothing. Another interrupt keeps the connection:
//  PostgreSQL's cancel and DuckDB's interrupt always roll back the open transaction, SQLite's
//  may. A cancel without one closes the connection.
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

  /// The same for PostgreSQL, whose server cancels the statement from a side connection
  static let serverCancel = QueryCancelWarning(
    title: "Stop the running query?",
    detail: "The server stops the statement. The connection is kept, and any open transaction "
      + "is rolled back. If the server cannot stop it, the connection is reset instead (temp "
      + "tables, SET and search_path are lost).", buttonTitle: stopTitle)

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
  ///   (DuckDB, PostgreSQL)
  static func make(
    state: TransactionState, userTxOpen: Bool, ownedByAnotherTab: Bool = false,
    keepsTransaction: Bool = false, interrupts: Bool = false, interruptRollsBack: Bool = false
  ) -> QueryCancelWarning? {
    guard !keepsTransaction else { return nil }
    let hedged = interrupts && !interruptRollsBack
    let verb = rollbackVerb(interrupts: interrupts, interruptRollsBack: interruptRollsBack)
    let button = hedged ? stopTitle : confirmTitle
    if !state.isIdle {
      let owner = ownedByAnotherTab ? "another tab's " : ""
      return QueryCancelWarning(
        title: "Cancelling \(verb) \(owner)\(pendingChanges(state))",
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

  /// What stopping a running query does, after its line in the quit, close or disconnect
  /// prompt: the rollback `make` would warn about, with its count and verb; nil when `make`
  /// warns nothing (no pending change, no open transaction, or an interrupt that keeps it)
  static func stopConsequence(
    state: TransactionState, userTxOpen: Bool, keepsTransaction: Bool = false,
    interrupts: Bool = false, interruptRollsBack: Bool = false
  ) -> String? {
    guard !keepsTransaction, !state.isIdle || userTxOpen else { return nil }
    let verb = rollbackVerb(interrupts: interrupts, interruptRollsBack: interruptRollsBack)
    let lost = state.isIdle ? "the open transaction" : pendingChanges(state)
    return "will be stopped; this \(verb) \(lost)"
  }

  private static func rollbackVerb(interrupts: Bool, interruptRollsBack: Bool) -> String {
    interrupts && !interruptRollsBack ? "may roll back" : "will roll back"
  }

  private static func pendingChanges(_ state: TransactionState) -> String {
    let count = state.pending.count
    return "\(count) pending change\(count == 1 ? "" : "s")"
  }
}
