// DatabaseConnectionManager+Cancel.swift
// Cancel stops the server work: PostgresNIO 1.33.1 exposes no CancelRequest, so the only public
// way to stop a running backend is closing its connection. The session is then reopened with
// the current config (session brakes re-applied, epoch advanced), like the capped-read reset.
// Closing rolls back the app transaction or the user's open transaction: the ViewModel warns
// first (`QueryCancelWarning`) and passes what the user saw, so a changed state is refused.

import Foundation

/// What a statement that was running when the user cancelled reports (see `lastCancel`)
nonisolated struct QueryCancelRecord: Sendable, Equatable {
  /// `connectionEpoch` of the closed connection
  let epoch: UInt64
  /// App transaction changes rolled back with the closed session
  let pendingCount: Int
  /// A transaction the user opened with BEGIN (Protected mode off) was rolled back
  let userTxRolledBack: Bool

  var error: DatabaseError {
    .queryCancelled(pendingCount: pendingCount, userTxRolledBack: userTxRolledBack)
  }
}

/// Read in one actor turn before asking the user (see `cancelRunningStatement`)
nonisolated struct RunningStatementStatus: Sendable, Equatable {
  let state: TransactionState
  let userTxOpen: Bool
  /// `commitGuard.generation`: changes with the transaction state
  let generation: UInt64
  /// A gated statement or inline edit is running
  let inFlight: Bool
}

nonisolated enum QueryCancelOutcome: Sendable, Equatable {
  /// The connection was closed and reopened (or reported lost if reopening failed)
  case cancelled
  /// No gated statement is running: nothing was closed
  case nothingRunning
  /// The transaction state changed since the status the user saw: nothing was closed, ask again
  case transactionChanged
}

extension DatabaseConnectionManager {
  func runningStatementStatus() -> RunningStatementStatus {
    RunningStatementStatus(
      state: txState, userTxOpen: userTxOpen, generation: commitGuard.generation,
      inFlight: commitGuard.inFlight > 0)
  }

  /// Stop the running statement on the server: close the connection and reconnect with the
  /// current config. The statement (and the rest of its script) fails with
  /// `DatabaseError.queryCancelled`; a `SessionResetEvent` (`.cancelled`) is published. If the
  /// reconnect fails, the session is reported lost (`SessionLostEvent`).
  /// - Parameters: the `RunningStatementStatus` the user confirmed.
  /// - Returns: `.nothingRunning` / `.transactionChanged` without closing anything.
  func cancelRunningStatement(
    expectedGeneration: UInt64, expectedUserTxOpen: Bool
  ) async -> QueryCancelOutcome {
    guard commitGuard.inFlight > 0, _connection != nil, let config else { return .nothingRunning }
    guard commitGuard.generation == expectedGeneration, userTxOpen == expectedUserTxOpen else {
      return .transactionChanged
    }
    let stateBefore = txState
    let record = QueryCancelRecord(
      epoch: connectionEpoch, pendingCount: stateBefore.pending.count,
      userTxRolledBack: userTxOpen)
    lastCancel = record
    await AppLogger.shared.info("Cancelling the running statement", category: "Database")
    // Not cancelled with the caller: `connect` sleeps between retries
    let reconnect = Task { try await self.connect(config: config) }
    do {
      // `connect` disconnects first (forget + close: the server stops the backend's work)
      try await reconnect.value
      sessionResetsContinuation.yield(
        SessionResetEvent(
          epoch: connectionEpoch, userTxRolledBack: record.userTxRolledBack,
          reason: .cancelled(pendingCount: record.pendingCount)))
    } catch {
      guard _connection == nil else { return .cancelled }
      let lost = SessionLostEvent(
        state: stateBefore, userTxOpen: record.userTxRolledBack, epoch: connectionEpoch)
      lastSessionLoss = lost
      sessionEventsContinuation.yield(lost)
      await AppLogger.shared.warning(
        "Reconnect after cancel failed: \(error.localizedDescription)", category: "Database")
    }
    return .cancelled
  }

  /// The error for a statement of a script started on connection `epoch`, if the user
  /// cancelled that connection (nil otherwise)
  func cancelError(since epoch: UInt64) -> DatabaseError? {
    guard let lastCancel, lastCancel.epoch == epoch else { return nil }
    return lastCancel.error
  }
}
