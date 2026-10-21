// DatabaseConnectionManager+Cancel.swift
// Cancel stops the server work: PostgresNIO 1.33.1 exposes no CancelRequest, so the only public
// way to stop a running backend is closing its connection. The session is then reopened with
// the current config (session brakes re-applied, epoch advanced), like the capped-read reset.
// Closing rolls back the app transaction or the user's open transaction: the ViewModel warns
// first (`QueryCancelWarning`) and passes what the user saw, so a changed state is refused.
// SQLite and DuckDB interrupt instead: what that did to an open transaction is asked from the
// SQLite session once the statement stopped (`cancelErrorAfterInterrupt`). DuckDB's interrupt
// always aborts it: a ROLLBACK is owed from the cancel on (`settleInterruptAbort`).

import Foundation

/// What a statement that was running when the user cancelled reports (see `lastCancel`)
nonisolated struct QueryCancelRecord: Sendable, Equatable {
  /// `connectionEpoch` of the closed (or interrupted) connection
  let epoch: UInt64
  /// App transaction changes rolled back with the closed session (after an interrupt: what the
  /// session reported, see `cancelErrorAfterInterrupt`)
  var pendingCount: Int
  /// A transaction the user opened with BEGIN (Protected mode off) was rolled back
  var userTxRolledBack: Bool
  /// Interrupt cancel only: `batchCancellationGeneration` after this cancel. The epoch does not
  /// change, so a script started at this generation (after the cancel) is not cancelled.
  /// Nil for a reconnect cancel: the new connection has a new epoch.
  var interruptGeneration: UInt64? = nil
  /// Interrupt cancel: the session was kept. `pendingCount` / `userTxRolledBack` are what the
  /// interrupt rolled back: nothing when the engine keeps the transaction
  /// (`interruptKeepsTransaction`) or the session reported it still open
  var connectionKept = false
  /// Interrupt cancel: `pendingCount` / `userTxRolledBack` follow what the stopped statement
  /// observed (`cancelErrorAfterInterrupt`); another statement this cancel stopped keeps them
  var reconciled = false

  var error: DatabaseError {
    .queryCancelled(
      pendingCount: pendingCount, userTxRolledBack: userTxRolledBack,
      connectionKept: connectionKept)
  }
}

/// Where a user statement was admitted (`DatabaseConnectionManager.userStatementAdmission`)
nonisolated struct UserStatementAdmission: Sendable {
  /// `connectionEpoch`
  let epoch: UInt64
  /// `batchCancellationGeneration`
  let generation: UInt64
}

/// Read in one actor turn before asking the user (see `cancelRunningStatement`)
nonisolated struct RunningStatementStatus: Sendable, Equatable {
  let state: TransactionState
  let userTxOpen: Bool
  /// `commitGuard.generation`: changes with the transaction state
  let generation: UInt64
  /// `connectionEpoch` the running statement uses: changes with every reset (an idle to idle
  /// reset leaves `generation` unchanged)
  let epoch: UInt64
  /// Caller token (tab) that opened the app transaction (nil when none)
  let owner: UUID?
  /// A gated statement or inline edit is running
  let inFlight: Bool
  /// Cancel interrupts only the statement and keeps the session, its pending changes and any
  /// open transaction (MySQL `KILL QUERY`, MongoDB `killOp`)
  var keepsTransaction = false
  /// Cancel interrupts the statement and keeps the session (`CancelStrategy.interrupt`); without
  /// `keepsTransaction` the interrupt may roll back the open transaction (SQLite, DuckDB)
  var interrupts = false
  /// The interrupt always rolls back the open transaction (DuckDB,
  /// `DatabaseType.interruptAbortsTransaction`)
  var interruptRollsBack = false
}

nonisolated enum QueryCancelOutcome: Sendable, Equatable {
  /// The connection was closed and reopened (or reported lost if reopening failed)
  case cancelled
  /// No gated statement is running, or not on the connection the user saw: nothing was closed
  case nothingRunning
  /// The transaction state changed since the status the user saw: nothing was closed, ask again
  case transactionChanged
}

extension DatabaseConnectionManager {
  func runningStatementStatus() -> RunningStatementStatus {
    RunningStatementStatus(
      state: txState, userTxOpen: userTxOpen, generation: commitGuard.generation,
      epoch: connectionEpoch, owner: txOwner, inFlight: commitGuard.inFlight > 0,
      keepsTransaction: session?.capabilities.cancelStrategy == .interrupt
        && config?.databaseType.interruptKeepsTransaction == true,
      interrupts: session?.capabilities.cancelStrategy == .interrupt,
      interruptRollsBack: session?.capabilities.cancelStrategy == .interrupt
        && config?.databaseType.interruptAbortsTransaction == true)
  }

  /// Stop the running statement on the server: close the connection and reconnect with the
  /// current config. The statement (and the rest of its script) fails with
  /// `DatabaseError.queryCancelled`; a `SessionResetEvent` (`.cancelled`) is published. If the
  /// reconnect fails, the session is reported lost (`SessionLostEvent`).
  /// - Parameters: the `RunningStatementStatus` the user confirmed.
  /// - Returns: `.nothingRunning` (also when the connection changed since the status) /
  ///   `.transactionChanged` without closing anything.
  func cancelRunningStatement(
    expectedGeneration: UInt64, expectedUserTxOpen: Bool, expectedEpoch: UInt64
  ) async -> QueryCancelOutcome {
    guard commitGuard.inFlight > 0, session != nil, let config else { return .nothingRunning }
    // Reset meanwhile (e.g. a double-click Cancel): the statement the user saw is gone, and what
    // runs now on the new connection was not confirmed
    guard connectionEpoch == expectedEpoch else { return .nothingRunning }
    guard commitGuard.generation == expectedGeneration, userTxOpen == expectedUserTxOpen else {
      return .transactionChanged
    }
    let stateBefore = txState
    let interrupts = session?.capabilities.cancelStrategy == .interrupt
    // MySQL KILL QUERY: the pending changes and the user's transaction stay
    let kept = interrupts && config.databaseType.interruptKeepsTransaction
    batchCancellationGeneration &+= 1
    let record = QueryCancelRecord(
      epoch: connectionEpoch, pendingCount: kept ? 0 : stateBefore.pending.count,
      userTxRolledBack: kept ? false : userTxOpen,
      interruptGeneration: interrupts ? batchCancellationGeneration : nil,
      connectionKept: interrupts)
    lastCancel = record
    // DuckDB aborts the open transaction now, and a COMMIT on it would answer success: owed in
    // the actor turn that moved the cancel generation, so nothing admitted at the new
    // generation reaches the session first (`settleInterruptAbort`)
    if interrupts, config.databaseType.interruptAbortsTransaction, userTxOpen || !txState.isIdle {
      interruptRollbackOwed = connectionEpoch
    }
    await AppLogger.shared.info("Cancelling the running statement", category: "Database")
    await scriptCheckpointHook?(.cancelling)
    if interrupts {
      await session?.interrupt()
      return .cancelled
    }
    // PostgreSQL stays reconnect: close the session and open another one.
    // Not cancelled with the caller: `connect` sleeps between retries
    let certificate = activeUnrememberedCertificate
    let sshCredential = activeUnrememberedSSHCredential
    let reconnect = Task {
      try await self.reconnectWithActiveCertificate(
        config: config, material: certificate, sshCredential: sshCredential)
    }
    do {
      // `connect` disconnects first (forget + close: the server stops the backend's work)
      try await reconnect.value
      sessionResetsContinuation.yield(
        SessionResetEvent(
          epoch: connectionEpoch, userTxRolledBack: record.userTxRolledBack,
          reason: .cancelled(pendingCount: record.pendingCount)))
    } catch {
      guard session == nil else { return .cancelled }
      let lost = SessionLostEvent(
        state: stateBefore, userTxOpen: record.userTxRolledBack, epoch: connectionEpoch)
      lastSessionLoss = lost
      sessionEventsContinuation.yield(lost)
      await AppLogger.shared.warning(
        "Reconnect after cancel failed: \(error.localizedDescription)", category: "Database")
    }
    return .cancelled
  }

  /// The error for a statement of a script started on connection `epoch` at cancellation
  /// `generation` (`batchCancellationGeneration`), if the user cancelled that connection while
  /// the script ran (nil otherwise)
  func cancelError(since epoch: UInt64, generation: UInt64) -> DatabaseError? {
    guard let lastCancel, lastCancel.epoch == epoch else { return nil }
    if let interrupted = lastCancel.interruptGeneration, interrupted == generation { return nil }
    return lastCancel.error
  }

  /// `cancelError(since:generation:)` for the statement the cancel stopped. After an interrupt
  /// cancel inside a SQLite transaction, the record and the transaction state follow what the
  /// session reports (`transactionOpenAfterInterrupt`): still open, nothing was rolled back;
  /// gone, the app transaction / `userTxOpen` are cleared and their Data Rewind entries
  /// discarded; unchanged when it cannot tell; nothing rolled back when a user COMMIT was in
  /// flight meanwhile (it may have ended the transaction itself). DuckDB's interrupt always aborted it:
  /// `settleInterruptAbort`, unless a send or a COMMIT settled it first. The first stopped
  /// statement settles the record (`reconciled`): another statement this cancel stopped
  /// reports it as is.
  func cancelErrorAfterInterrupt(since epoch: UInt64, generation: UInt64) async -> DatabaseError? {
    guard let error = cancelError(since: epoch, generation: generation) else { return nil }
    if config?.databaseType.interruptAbortsTransaction == true {
      await settleInterruptAbort()
      return cancelError(since: epoch, generation: generation)
    }
    guard let record = lastCancel, let interrupted = record.interruptGeneration,
      !record.reconciled, config?.databaseType.interruptKeepsTransaction != true,
      userTxOpen || !txState.isIdle, let session
    else { return error }
    // A user COMMIT queued behind the stopped statement ends the transaction too: the session
    // cannot tell its end from the interrupt's. Nothing is discarded or claimed rolled back
    if userCommitsInFlight > 0 { return settleInterruptRecordAsKept() ?? error }
    // The transaction asked about: a COMMIT / ROLLBACK meanwhile changes one of them
    let txGeneration = commitGuard.generation
    let userTx = userTxOpen
    let observed = await session.transactionOpenAfterInterrupt()
    // Reset or reconnected meanwhile: the old state no longer applies
    guard connectionEpoch == epoch, var current = lastCancel, current.epoch == epoch,
      current.interruptGeneration == interrupted
    else { return cancelError(since: epoch, generation: generation) }
    // Another statement stopped by this cancel settled it while this one asked
    if current.reconciled { return current.error }
    if userCommitsInFlight > 0 { return settleInterruptRecordAsKept() ?? current.error }
    // The transaction ended or changed meanwhile: its own statement reported it, and what it
    // committed must not be discarded here
    guard commitGuard.generation == txGeneration, userTxOpen == userTx, let open = observed
    else { return cancelError(since: epoch, generation: generation) }
    if open {
      current.pendingCount = 0
      current.userTxRolledBack = false
    } else {
      current.pendingCount = txState.pending.count
      current.userTxRolledBack = userTxOpen
      clearTransactionRolledBackByInterrupt()
    }
    current.reconciled = true
    lastCancel = current
    return current.error
  }

  /// DuckDB, once a cancel interrupted a statement inside a transaction (`interruptRollbackOwed`
  /// for the current connection): the engine aborted it, and a COMMIT on it would answer
  /// success. In one actor turn the app transaction / `userTxOpen` are cleared, their Data
  /// Rewind entries discarded and the cancel record settled (`reconciled`); then ROLLBACK is
  /// sent once, straight to the session (it ends the aborted transaction; "no transaction is
  /// active" changes nothing; any other failure is logged). The session runs one call at a time
  /// in arrival order, so a statement sent afterwards runs after the ROLLBACK. Called by the
  /// stopped statement, before any send (`withSession`) and by a COMMIT / Rollback; no-op
  /// when nothing is owed. An owed ROLLBACK of an older connection is dropped.
  /// - Returns: whether an app transaction or `userTxOpen` was cleared
  @discardableResult
  func settleInterruptAbort() async -> Bool {
    guard let owed = interruptRollbackOwed else { return false }
    interruptRollbackOwed = nil
    guard owed == connectionEpoch, let session else { return false }
    let cleared = !txState.isIdle || userTxOpen
    if var record = lastCancel, record.epoch == owed, record.interruptGeneration != nil,
      !record.reconciled
    {
      record.pendingCount = txState.pending.count
      record.userTxRolledBack = userTxOpen
      record.reconciled = true
      lastCancel = record
    }
    clearTransactionRolledBackByInterrupt()
    activeSends += 1
    defer { activeSends -= 1 }
    do {
      _ = try await session.command("ROLLBACK", binds: [])
    } catch {
      // "No transaction is active" changes nothing; anything else may leave it open
      if !session.formatError(error).localizedCaseInsensitiveContains("no transaction is active") {
        await AppLogger.shared.warning(
          "The rollback owed after a cancel failed (\(type(of: error)))", category: "Database")
      }
    }
    return cleared
  }

  /// A user COMMIT (or a MySQL BEGIN committing) that answered success, once a cancel
  /// interrupted the connection. DuckDB, when the interrupt landed while the COMMIT was in
  /// flight (`cancelError(since:generation:)` of its script): the interrupt aborted the
  /// transaction first, so the COMMIT committed nothing: settled (`settleInterruptAbort`) and
  /// `commitAfterInterruptError` thrown. Elsewhere (SQLite) the COMMIT found the transaction
  /// open, so the interrupt rolled nothing back (`settleInterruptRecordAsKept`).
  func noteUserCommitAfterInterrupt(since epoch: UInt64, generation: UInt64) async throws {
    guard let record = lastCancel, record.epoch == connectionEpoch,
      record.interruptGeneration != nil
    else { return }
    guard config?.databaseType.interruptAbortsTransaction == true else {
      settleInterruptRecordAsKept()
      return
    }
    guard cancelError(since: epoch, generation: generation) != nil else { return }
    await settleInterruptAbort()
    throw Self.commitAfterInterruptError
  }

  /// The current connection's interrupt cancel record, unless already settled (`reconciled`),
  /// now says nothing was rolled back; nothing is discarded.
  /// - Returns: the record's error (nil without an interrupt record for this connection)
  @discardableResult
  private func settleInterruptRecordAsKept() -> DatabaseError? {
    guard var record = lastCancel, record.epoch == connectionEpoch,
      record.interruptGeneration != nil
    else { return nil }
    if !record.reconciled {
      record.pendingCount = 0
      record.userTxRolledBack = false
      record.reconciled = true
      lastCancel = record
    }
    return record.error
  }

  /// Set while a user statement is sent (`runUserStatements`, `runStagedBatch`): the connection
  /// epoch and cancel generation (`batchCancellationGeneration`) it was admitted at. After a
  /// DuckDB interrupt cancel since then, or one whose transaction this send rolled back, it is
  /// refused (`withSession`)
  @TaskLocal static var userStatementAdmission: UserStatementAdmission?

  /// A statement meant for the transaction a DuckDB interrupt cancel rolled back
  /// (`withSession`): not sent, it would autocommit
  static let sentAfterInterruptError = DatabaseError.transactionAborted(
    "Nothing was sent: cancelling the running statement rolled back the open transaction. "
      + "Run it again.")

  /// The interrupt rolled back the open transaction: app transaction and `userTxOpen` cleared,
  /// their Data Rewind entries discarded
  private func clearTransactionRolledBackByInterrupt() {
    if !txState.isIdle {
      txState = .idle
      discardAppSchemaChange()
    }
    if userTxOpen {
      userTxOpen = false
      schemaDirtyInUserTx = false
    }
    closeRewindEntries(as: .discarded)
  }
}
