// DatabaseConnectionManager+Cancel.swift
// Cancel stops the server work and keeps the session where it can. PostgresNIO 1.33.1 exposes no
// CancelRequest: PostgreSQL runs `pg_cancel_backend` from a short side connection
// (`DatabaseSession.cancelBackend`). When that cancels nothing (no pid, no match, side connection
// refused, 5 s bound) while the statement still runs, or for a session without an interrupt, the
// connection is closed and reopened with the current config (session brakes re-applied, epoch
// advanced), like the capped-read reset. Closing rolls back the app transaction or the user's
// open transaction: the ViewModel warns first (`QueryCancelWarning`) and passes what the user
// saw, so a changed state is refused. SQLite and DuckDB interrupt instead: what that did to an
// open transaction is asked from the SQLite session once the statement stopped
// (`cancelErrorAfterInterrupt`). DuckDB's interrupt and PostgreSQL's cancel always abort it: a
// ROLLBACK is owed from the cancel on (`settleInterruptAbort`), unless a PostgreSQL COMMIT in
// flight then answers COMMIT. A DuckDB statement timeout or execution error aborts it too
// (`settleAbortAfterFailure`).

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
  /// The interrupt always rolls back the open transaction (DuckDB, PostgreSQL,
  /// `DatabaseType.interruptAbortsTransaction`)
  var interruptRollsBack = false
  /// The server cancels the statement from a side connection (PostgreSQL); the connection is
  /// reset when it cannot
  var cancelsOnServer = false
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
        && config?.databaseType.interruptAbortsTransaction == true,
      cancelsOnServer: session?.capabilities.cancelStrategy == .interrupt
        && config?.databaseType == .postgresql)
  }

  /// Stop the running statement on the server: interrupt it and keep the session (PostgreSQL:
  /// `cancelBackend`), else close the connection and reconnect with the current config. The
  /// statement (and the rest of its script) fails with `DatabaseError.queryCancelled`; a reset
  /// publishes a `SessionResetEvent` (`.cancelled`). If the reconnect fails, the session is
  /// reported lost (`SessionLostEvent`).
  /// Known limit: PostgreSQL cancels the oldest statement in flight on the shared connection,
  /// which may be another tab's or an app read queued ahead of the confirmed one, as the other
  /// interrupt engines stop whatever runs on the connection.
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
    var record = QueryCancelRecord(
      epoch: connectionEpoch, pendingCount: kept ? 0 : stateBefore.pending.count,
      userTxRolledBack: kept ? false : userTxOpen,
      interruptGeneration: interrupts ? batchCancellationGeneration : nil,
      connectionKept: interrupts)
    lastCancel = record
    // PostgreSQL: what the server cancel matches, read in this turn, before anything else can be
    // queued behind the running statement (the ROLLBACK owed below, a catalog read), and the
    // statement a failed cancel resets for (the matched one, else the one running)
    let serverCancel =
      interrupts && config.databaseType == .postgresql ? session?.prepareCancelBackend() : nil
    let runningToken =
      interrupts && config.databaseType == .postgresql
      ? serverCancel?.token ?? session?.runningStatementToken() : nil
    // DuckDB and PostgreSQL abort the open transaction now, and a COMMIT on it would answer
    // success: owed in the actor turn that moved the cancel generation, so nothing admitted at
    // the new generation reaches the session first (`settleInterruptAbort`)
    if interrupts, config.databaseType.interruptAbortsTransaction, userTxOpen || !txState.isIdle {
      interruptRollbackOwed = connectionEpoch
    }
    await AppLogger.shared.info("Cancelling the running statement", category: "Database")
    await scriptCheckpointHook?(.cancelling)
    if interrupts {
      guard config.databaseType == .postgresql else {
        await session?.interrupt()
        return .cancelled
      }
      if let session, let serverCancel,
        await cancelBackendScoped(session, target: serverCancel, config: config)
      {
        return .cancelled
      }
      // Nothing was cancelled: reset instead, unless the connection went meanwhile
      guard connectionEpoch == record.epoch, let live = self.session else { return .cancelled }
      // or the statement running at the cancel ended on its own (often why nothing matched),
      // whatever started since (another tab's): the session is kept, and the ROLLBACK owed since
      // the cancel ends the transaction the user was told is rolled back
      guard let runningToken, live.statementInFlight(runningToken) else {
        await AppLogger.shared.info(
          "The statement ended before the server cancel: the connection is kept",
          category: "Database")
        return .cancelled
      }
      if interruptRollbackOwed == record.epoch { interruptRollbackOwed = nil }
      let current = lastCancel.flatMap { $0.epoch == record.epoch ? $0 : nil } ?? record
      record = QueryCancelRecord(
        epoch: record.epoch, pendingCount: current.pendingCount,
        userTxRolledBack: current.userTxRolledBack)
      lastCancel = record
    }
    // Close the session and open another one.
    // Not cancelled with the caller: `connect` sleeps between retries
    let certificate = activeUnrememberedCertificate
    let sshCredential = activeUnrememberedSSHCredential
    let vaultSecret = activeUnrememberedVaultSecret
    let reconnect = Task {
      try await self.reconnectWithActiveCertificate(
        config: config, material: certificate, sshCredential: sshCredential,
        vaultSecret: vaultSecret)
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

  /// `session.cancelBackend(target)` with this connection's client certificate in scope as a reset
  /// scopes it (`reconnectWithActiveCertificate`), under the Vault lease's account for a Vault
  /// row: the side connection of a connection whose certificate is not remembered finds it.
  /// Never a side manager: that would take another Vault lease.
  private func cancelBackendScoped(
    _ session: any DatabaseSession, target: CancelBackendTarget, config: ConnectionConfig
  ) async -> Bool {
    let scoped = activeUnrememberedCertificate.map {
      ClientCertificateStoreFactory.ScopedMaterial(account: $0.account, material: $0.material)
    }
    defer { scoped?.clear() }
    let sessionConfig = vaultLease?.overlay(on: config) ?? config
    return await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      let cancelled = try? await withLeaseAccounts(sessionConfig, saved: config) {
        await session.cancelBackend(target)
      }
      return cancelled ?? false
    }
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

  /// DuckDB and PostgreSQL, once a cancel interrupted a statement inside a transaction
  /// (`interruptRollbackOwed` for the current connection): the engine aborted it, and a COMMIT
  /// on it would answer success. In one actor turn the app transaction / `userTxOpen` are
  /// cleared, their Data Rewind entries discarded and the cancel record settled (`reconciled`);
  /// then ROLLBACK is sent once, straight to the session (it ends the aborted transaction; "no
  /// transaction is active" changes nothing; any other failure is logged). The session runs one
  /// call at a time in arrival order, so a statement sent afterwards runs after the ROLLBACK.
  /// Called by the stopped statement, before any send (`withSession`) and by a COMMIT /
  /// Rollback; no-op when nothing is owed. An owed ROLLBACK of an older connection is dropped.
  /// PostgreSQL, while a user COMMIT is in flight: still owed, nothing settled; that COMMIT's
  /// answer decides (`noteUserCommitAfterInterrupt`, or `cancelErrorAfterInterrupt` on error).
  /// - Returns: whether an app transaction or `userTxOpen` was cleared
  @discardableResult
  func settleInterruptAbort() async -> Bool {
    guard let owed = interruptRollbackOwed else { return false }
    if config?.databaseType == .postgresql, userCommitsInFlight > 0, owed == connectionEpoch {
      return false
    }
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

  /// DuckDB, after a user statement failed inside a transaction (a statement timeout too): when
  /// the session reports the transaction aborted (`DuckDBSession.transactionAborted`), it is
  /// rolled back now like after a cancel (`settleInterruptAbort`), so a later COMMIT never
  /// answers success. Unchanged when the transaction changed meanwhile (its own statement
  /// reported it) or a cancel owes the ROLLBACK.
  /// - Returns: `error`, saying what was rolled back when it held changes
  func settleAbortAfterFailure(_ error: Error) async -> Error {
    guard config?.databaseType == .duckdb, userTxOpen || !txState.isIdle else { return error }
    let epoch = connectionEpoch
    let txGeneration = commitGuard.generation
    let userTx = userTxOpen
    let pendingCount = txState.pending.count
    let aborted = try? await withSession { session in
      await (session as? DuckDBSession)?.transactionAborted()
    }
    guard aborted == true, connectionEpoch == epoch, commitGuard.generation == txGeneration,
      userTxOpen == userTx, interruptRollbackOwed == nil
    else { return error }
    interruptRollbackOwed = epoch
    await settleInterruptAbort()
    // An app transaction the failed statement opened held nothing: rolled back quietly, as
    // `transactionFailure` does
    if !userTx && pendingCount == 0 { return error }
    let note =
      userTx
      ? "Your open transaction was rolled back."
      : pendingCount == 1
        ? "1 pending change was rolled back."
        : "The pending transaction was rolled back (\(pendingCount) pending changes)."
    if case .queryFailed(let message, let time) = error as? DatabaseError {
      return DatabaseError.queryFailed("\(message) \(note)", time)
    }
    return DatabaseError.transactionAborted("\(error.localizedDescription) \(note)")
  }

  /// A user COMMIT (or a MySQL BEGIN committing) that answered success, once a cancel
  /// interrupted the connection. DuckDB, when the interrupt landed while the COMMIT was in
  /// flight (`cancelError(since:generation:)` of its script): the interrupt aborted the
  /// transaction first, so the COMMIT committed nothing: settled (`settleInterruptAbort`) and
  /// `commitAfterInterruptError` thrown; PostgreSQL too when the COMMIT answered ROLLBACK
  /// (`commitState` `.discarded`). A PostgreSQL COMMIT that answered COMMIT committed (the
  /// cancel came after its commit record, or matched nothing): the ROLLBACK owed since the
  /// cancel is dropped. There and elsewhere (SQLite, where the COMMIT found the transaction
  /// open) the interrupt rolled nothing back (`settleInterruptRecordAsKept`).
  func noteUserCommitAfterInterrupt(
    since epoch: UInt64, generation: UInt64, commitState: RewindEntry.State?
  ) async throws {
    guard let record = lastCancel, record.epoch == connectionEpoch,
      record.interruptGeneration != nil
    else { return }
    let committedOnServer = config?.databaseType == .postgresql && commitState == .committed
    guard config?.databaseType.interruptAbortsTransaction == true, !committedOnServer else {
      if committedOnServer, interruptRollbackOwed == connectionEpoch { interruptRollbackOwed = nil }
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
  /// DuckDB or PostgreSQL interrupt cancel since then, or one whose transaction this send rolled
  /// back, it is refused (`withSession`)
  @TaskLocal static var userStatementAdmission: UserStatementAdmission?

  /// A statement meant for the transaction a DuckDB or PostgreSQL cancel rolled back
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
