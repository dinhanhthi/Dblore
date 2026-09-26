// DatabaseConnectionManager+Transaction.swift
// Protected mode: user statements that may change data run inside an app-owned transaction
// that waits for Commit / Rollback. Rules live in `ProtectedTransactionRules` (pure).

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  // MARK: - Snapshot

  /// Current transaction state with its pending statements (for the pending-changes banner).
  func transactionSnapshot() -> TransactionState {
    txState
  }

  /// Transaction state, the caller token that opened it and its generation (pass it to
  /// `commitAppTransaction(expectedGeneration:)`) and whether a gated statement or edit is in
  /// flight (Commit / Rollback are refused meanwhile), read in one actor turn.
  func transactionStatus() -> (
    state: TransactionState, owner: UUID?, generation: UInt64, inFlight: Bool
  ) {
    (txState, txOwner, commitGuard.generation, commitGuard.inFlight > 0)
  }

  // MARK: - Running authorized user statements

  /// Run statements the gate already authorized, one by one, exactly as classified.
  /// With `protectedMode`, the first statement that may change data opens the app transaction
  /// (BEGIN, app-owned) and every such statement is recorded as pending. Without it, statements
  /// autocommit and user transaction control is tracked in `userTxOpen`.
  /// `caller` identifies the tab: while the app transaction is pending only the caller that
  /// opened it may run statements (checked again before every statement).
  /// - Throws: `DatabaseError.transactionEnding` while Commit / Rollback is in progress and
  ///   `DatabaseError.transactionPendingInAnotherTab` (nothing sent);
  ///   `DatabaseError.transactionAborted` while the app transaction is aborted;
  ///   a statement error (after moving the app transaction to `.aborted`).
  func runUserStatements(
    _ statements: [ClassifiedStatement], protectedMode: Bool, maxRows: Int, caller: UUID?
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    guard _connection != nil else { throw DatabaseError.notConnected }
    guard !statements.isEmpty else { throw DatabaseError.emptyQuery }
    try refuseIfConnectionClosed()
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    try await adoptUserTransactionIfNeeded(protectedMode: protectedMode, caller: caller)

    let start = Date()
    var openedHere = false
    var results: [(queryText: String, result: QueryResult)] = []
    for statement in statements {
      // Another tab may have opened the transaction while this script was suspended
      try refuseIfOwnedByAnotherCaller(caller)
      let action =
        protectedMode
        ? ProtectedTransactionRules.action(for: statement, inTransaction: !txState.isIdle) : .run
      if action == .open {
        try await beginAppTransaction(caller: caller)
        openedHere = true
      }
      // The schema may change: results read inside a pending transaction lose their cached
      // edit tables (see `cachedEditTable`)
      if ProtectedTransactionRules.invalidatesEditTables(statement) {
        editTableCache.removeAll()
      }
      let result: QueryResult
      do {
        result = try await executeSingleStatement(statement.text, maxRows: maxRows)
      } catch {
        if !protectedMode {
          userTxOpen = ProtectedTransactionRules.userTxOpen(
            after: statement, current: userTxOpen, succeeded: false)
        }
        throw await transactionFailure(error, openedHere: openedHere)
      }
      if action != .run {
        recordPending(
          StatementSummary(
            statement: statement, affectedRows: statement.kind == .dml ? result.affectedRows : nil))
      }
      if !protectedMode {
        userTxOpen = ProtectedTransactionRules.userTxOpen(
          after: statement, current: userTxOpen, succeeded: true)
      }
      results.append((queryText: statement.text, result: result))
    }
    return (results: results, totalTime: Date().timeIntervalSince(start))
  }

  // MARK: - Commit / Rollback

  /// Commit the app transaction the user reviewed: `expectedGeneration` is the
  /// `transactionStatus().generation` the Commit confirmation showed. No-op when idle.
  /// While COMMIT is awaited the state is `.ending(.commit)`, so gated entries are refused.
  /// - Throws: `DatabaseError.transactionEnding` while Commit / Rollback is already in progress;
  ///   `DatabaseError.commitRefusedTransactionChanged` (nothing sent) while a gated
  ///   statement or edit is running, or when the transaction changed since the review;
  ///   `DatabaseError.transactionAborted` when the transaction is aborted (only Rollback
  ///   is possible), when the server rolled it back instead, or when the connection was lost.
  ///   A failed COMMIT ends the transaction on the server, so the state is `.idle` afterwards.
  func commitAppTransaction(expectedGeneration: UInt64) async throws {
    try refuseIfEnding()
    if !txState.isIdle, commitGuard.refusesCommit(expectedGeneration: expectedGeneration) {
      throw DatabaseError.commitRefusedTransactionChanged
    }
    switch txState {
    case .idle:
      return
    case .aborted(let reason, _):
      throw DatabaseError.transactionAborted(
        "Commit is not possible: a statement failed in the pending transaction (\(reason)). "
          + "Roll back to continue.")
    case .ending(let kind, _):
      throw DatabaseError.transactionEnding(kind)
    case .appTx(let pending):
      // Marked before the first suspension: statements entering meanwhile are refused
      txState = .ending(kind: .commit, pending: pending)
      await transactionEndHook?(.commit)
      let metadata: PostgresQueryMetadata
      do {
        metadata = try await sendTransactionControl("COMMIT")
      } catch {
        txState = .idle
        if isConnectionLost {
          throw DatabaseError.transactionAborted(
            "The connection was lost during Commit; it is unknown whether the "
              + "\(pending.count) pending statement(s) were committed.")
        }
        throw DatabaseError.transactionAborted(
          "Commit failed and the \(pending.count) pending statement(s) were rolled back: "
            + error.localizedDescription)
      }
      txState = .idle
      // COMMIT of a transaction the server already aborted answers with a ROLLBACK tag
      guard metadata.command == "COMMIT" else {
        throw DatabaseError.transactionAborted(
          "The server rolled back the transaction instead of committing it (a statement had "
            + "failed); the \(pending.count) pending statement(s) were discarded.")
      }
    }
  }

  /// Roll back the app transaction (also allowed when aborted). No-op when idle.
  /// - Throws: `DatabaseError.transactionEnding` while Commit / Rollback is in progress and
  ///   `DatabaseError.rollbackRefusedStatementRunning` while a gated statement or edit runs (its
  ///   next statement would autocommit after ROLLBACK), nothing sent;
  ///   `DatabaseError.transactionAborted` when the connection was lost (the server
  ///   discarded the pending statements; state is `.idle`); a ROLLBACK error otherwise (state
  ///   unchanged).
  func rollbackAppTransaction() async throws {
    let previous = txState
    guard !previous.isIdle else { return }
    try refuseIfEnding()
    if commitGuard.refusesRollback { throw DatabaseError.rollbackRefusedStatementRunning }
    // Marked before the first suspension: statements entering meanwhile are refused
    txState = .ending(kind: .rollback, pending: previous.pending)
    await transactionEndHook?(.rollback)
    do {
      _ = try await sendTransactionControl("ROLLBACK")
    } catch {
      guard isConnectionLost else {
        if txState.endingKind == .rollback { txState = previous }
        throw error
      }
      txState = .idle
      throw lostConnectionError(pendingCount: previous.pending.count, error)
    }
    txState = .idle
  }

  /// Test hook (see `transactionEndHook`): lets a test hold Commit / Rollback in the `.ending`
  /// state and call gated entries meanwhile. Nil in the app.
  func setTransactionEndHook(_ hook: (@Sendable (TransactionEndKind) async -> Void)?) {
    transactionEndHook = hook
  }

  /// While COMMIT / ROLLBACK is awaited every gated entry is refused before anything is sent:
  /// it would be queued after the end and run in autocommit, outside Protected mode.
  func refuseIfEnding() throws {
    if let kind = txState.endingKind { throw DatabaseError.transactionEnding(kind) }
  }

  // MARK: - Hooks for the gated paths

  /// While the app transaction is pending (or its BEGIN is in flight), only the caller that
  /// opened it may send gated statements.
  func refuseIfOwnedByAnotherCaller(_ caller: UUID?) throws {
    guard !txState.isIdle || txOwner != nil, txOwner != caller else { return }
    throw DatabaseError.transactionPendingInAnotherTab
  }

  /// While the app transaction is aborted the server refuses everything but ROLLBACK.
  func refuseIfAborted() throws {
    if case .aborted(let reason, _) = txState {
      throw DatabaseError.transactionAborted(
        "The pending transaction failed (\(reason)). Only Rollback is possible; nothing was "
          + "executed.")
    }
  }

  /// Send the app-owned BEGIN (never through the gate) and enter `.appTx` owned by `caller`.
  /// The owner is claimed before BEGIN is sent, so another caller interleaving at the
  /// suspension is refused instead of joining the transaction.
  /// Right after BEGIN the idle-in-transaction timeout is suspended for this transaction (see
  /// `suspendIdleTimeoutSQL`); if that fails the transaction is rolled back and the error thrown,
  /// so the user statement is never sent.
  func beginAppTransaction(caller: UUID?) async throws {
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    txOwner = caller
    do {
      _ = try await sendTransactionControl("BEGIN")
    } catch {
      if txState.isIdle { txOwner = nil }
      throw error
    }
    do {
      _ = try await sendTransactionControl(Self.suspendIdleTimeoutSQL)
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      if txState.isIdle { txOwner = nil }
      throw error
    }
    // The same caller may have opened (and recorded into) the transaction meanwhile
    if txState.isIdle { txState = .appTx(pending: []) }
  }

  func recordPending(_ summary: StatementSummary) {
    if case .appTx(let pending) = txState {
      txState = .appTx(pending: pending + [summary])
    }
  }

  /// Update the state after a statement failed and return the error to throw.
  /// Inside the app transaction: connection lost → `.idle` (pending lost); the transaction was
  /// opened by this run and nothing is pending → rolled back automatically (nothing to lose);
  /// otherwise → `.aborted`.
  func transactionFailure(_ error: Error, openedHere: Bool) async -> Error {
    guard case .appTx(let pending) = txState else { return error }
    if isConnectionLost {
      txState = .idle
      return lostConnectionError(pendingCount: pending.count, error)
    }
    if openedHere && pending.isEmpty, (try? await sendTransactionControl("ROLLBACK")) != nil {
      txState = .idle
      return error
    }
    txState = .aborted(reason: error.localizedDescription, pending: pending)
    return error
  }

  // MARK: - Private

  /// App-owned, sent right after the app's BEGIN (and when a user transaction is adopted): the
  /// user may take time to decide Commit / Rollback, so the server must not end the session.
  /// `SET LOCAL` reverts at transaction end, so the configured value (applied on connect) is
  /// back after Commit / Rollback with no restore statement. Never recorded as pending.
  /// `statement_timeout` / `lock_timeout` stay active for every statement inside the transaction.
  static let suspendIdleTimeoutSQL = "SET LOCAL idle_in_transaction_session_timeout = 0"

  /// Protected mode was turned on while a transaction the user opened is still open: it becomes
  /// the app transaction (no second BEGIN), so Commit / Rollback close it. What ran in it before
  /// was never reviewed: it is pending as one `StatementSummary.earlierChanges()` entry (rows
  /// unknown), so the banner and prompts never show it as empty. The user's BEGIN ran
  /// without the idle-timeout suspension, so it is sent here; if it fails (the user transaction
  /// had already failed, or the connection is gone) the state follows `transactionFailure`
  /// (`.aborted`: only Rollback; or `.idle` when the connection was lost) and the error is thrown.
  func adoptUserTransactionIfNeeded(protectedMode: Bool, caller: UUID?) async throws {
    guard protectedMode, userTxOpen, txState.isIdle else { return }
    txState = .appTx(pending: [.earlierChanges()])
    txOwner = caller
    userTxOpen = false
    do {
      _ = try await sendTransactionControl(Self.suspendIdleTimeoutSQL)
    } catch {
      throw await transactionFailure(error, openedHere: false)
    }
  }

  private var isConnectionLost: Bool {
    _connection?.isClosed ?? true
  }

  /// The server may close the session on its own (e.g. `idle_in_transaction_session_timeout`
  /// while a user transaction idles). PostgresNIO never completes a query written to a closed
  /// channel, so nothing is sent: the caller gets an error asking to reconnect. The user
  /// transaction, if any, ended with the session.
  func refuseIfConnectionClosed() throws {
    guard isConnectionLost else { return }
    userTxOpen = false
    throw DatabaseError.connectionFailed(
      "The server closed the connection (for example after the idle-in-transaction timeout). "
        + "Reconnect to continue.")
  }

  private func lostConnectionError(pendingCount: Int, _ error: Error) -> DatabaseError {
    .transactionAborted(
      "The connection was lost; the \(pendingCount) pending statement(s) were rolled back by "
        + "the server. \(error.localizedDescription)")
  }

  func sendTransactionControl(_ sql: String) async throws -> PostgresQueryMetadata {
    guard let connection = _connection else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    let startTime = Date()
    do {
      return try await connection.query(
        PostgresQuery(unsafeSQL: sql), logger: Logger(label: "sqlnotebook.transaction")
      ).get().metadata
    } catch let error as PSQLError {
      throw DatabaseError.queryFailed(
        formatPostgresError(error, query: sql), Date().timeIntervalSince(startTime))
    } catch {
      throw DatabaseError.queryFailed(
        error.localizedDescription, Date().timeIntervalSince(startTime))
    }
  }
}
