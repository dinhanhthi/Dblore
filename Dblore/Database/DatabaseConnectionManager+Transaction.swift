// DatabaseConnectionManager+Transaction.swift
// Protected mode: user statements that may change data run inside an app-owned transaction
// that waits for Commit / Rollback. Rules live in `ProtectedTransactionRules` (pure).

import Foundation
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
  /// A read cut by the row cap with no app transaction resets the session
  /// (`resetSessionIfCapped`) and ends the script: the rest is listed in `skippedStatements`.
  /// `binds` lines up with `statements` (a missing slot is sent unbound). When `originalTexts`
  /// is set, `queryText` and skipped-statement text come from it; the text sent stays
  /// `statement.text`.
  /// - Throws: `DatabaseError.queryCancelled` once the user cancelled (the session was closed);
  ///   `DatabaseError.sessionChanged` when the connection changed between two statements, or
  ///   is not `expectedEpoch` (a Run All batch's connection) on entry (nothing sent);
  ///   `DatabaseError.transactionEnding` while Commit / Rollback is in progress and
  ///   `DatabaseError.transactionPendingInAnotherTab` (nothing sent);
  ///   `DatabaseError.transactionAborted` while the app transaction is aborted;
  ///   a statement error (after moving the app transaction to `.aborted`).
  func runUserStatements(
    _ statements: [ClassifiedStatement], protectedMode: Bool, maxRows: Int, caller: UUID?,
    expectedEpoch: UInt64? = nil, binds: [[SQLBindValue]] = [], originalTexts: [String]? = nil
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    guard session != nil else { throw DatabaseError.notConnected }
    guard !statements.isEmpty else { throw DatabaseError.emptyQuery }
    if let expectedEpoch, expectedEpoch != connectionEpoch {
      throw DatabaseError.sessionChanged(skippedStatements: statements.count)
    }
    try refuseIfConnectionClosed()
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    // The connection this script runs on: a cancel closes or interrupts it
    // (see `cancelError(since:generation:)`)
    let epoch = connectionEpoch
    let cancelGeneration = batchCancellationGeneration
    // Its statements are refused after a DuckDB interrupt cancel since (`withSession`)
    let admission = UserStatementAdmission(epoch: epoch, generation: cancelGeneration)
    try await adoptUserTransactionIfNeeded(protectedMode: protectedMode, caller: caller)

    let start = Date()
    var openedHere = false
    var results: [(queryText: String, result: QueryResult)] = []
    func shownText(at index: Int) -> String {
      guard let originalTexts, originalTexts.indices.contains(index) else {
        return statements[index].text
      }
      return originalTexts[index]
    }
    for (index, statement) in statements.enumerated() {
      await scriptCheckpointHook?(.beforeStatement(caller: caller, index: results.count))
      // Cancelled, reset or reconnected between two statements: the rest must not run on the
      // new session (outside the user's BEGIN, without its temp tables / SET)
      try refuseIfSessionChanged(
        since: epoch, generation: cancelGeneration, remaining: statements.count - results.count)
      // Another tab may have opened the transaction while this script was suspended
      try refuseIfOwnedByAnotherCaller(caller)
      let action =
        protectedMode
        ? ProtectedTransactionRules.action(for: statement, inTransaction: !txState.isIdle) : .run
      if action == .open {
        do {
          try await beginAppTransaction(caller: caller)
        } catch {
          throw cancelError(since: epoch, generation: cancelGeneration) ?? error
        }
        openedHere = true
      }
      // The schema may change: results read inside a pending transaction lose their cached
      // edit tables (see `cachedEditTable`)
      if ProtectedTransactionRules.invalidatesEditTables(statement) {
        editTableCache.removeAll()
        mysqlTableColumns.removeAll()
      }
      // BEGIN suspended: the connection may have changed meanwhile
      try refuseIfSessionChanged(
        since: epoch, generation: cancelGeneration, remaining: statements.count - results.count)
      var result: QueryResult
      let userCommit =
        !protectedMode && userTxOpen
        && ProtectedTransactionRules.committedUserTransaction(
          statement, dialect: Self.dialect(of: config))
      // A MySQL BEGIN commits the open transaction too: a loss meanwhile leaves it unknown
      let commitsUserTransaction =
        userCommit
        || (!protectedMode && userTxOpen
          && ProtectedTransactionRules.beginCommitsOpenTransaction(
            statement, dialect: Self.dialect(of: config)))
      // DuckDB: a cancel aborted this transaction and a COMMIT would answer success. Never
      // sent: rolled back instead (`settleInterruptAbort`)
      if commitsUserTransaction, interruptRollbackOwed == connectionEpoch {
        await settleInterruptAbort()
        throw Self.commitAfterInterruptError
      }
      // DuckDB: a user ROLLBACK while the cancel's ROLLBACK is owed is that ROLLBACK: sent alone
      // it would fail with no transaction left
      if interruptRollbackOwed == connectionEpoch,
        ProtectedTransactionRules.rolledBackUserTransaction(
          statement, dialect: Self.dialect(of: config))
      {
        await settleInterruptAbort()
        results.append(
          (
            queryText: shownText(at: index),
            result: QueryResult(
              columns: [], rows: [], rowCount: 0, executionTime: 0, affectedRows: 0)
          ))
        continue
      }
      await scriptCheckpointHook?(.beforeSend(caller: caller, index: results.count))
      // What the user's COMMIT did to the Data Rewind entries (`sendUserCommit`)
      var commitState: RewindEntry.State? = .committed
      do {
        if commitsUserTransaction { userCommitsInFlight += 1 }
        defer { if commitsUserTransaction { userCommitsInFlight -= 1 } }
        let inTransaction = !txState.isIdle || userTxOpen
        let statementBinds = binds.indices.contains(index) ? binds[index] : []
        if userCommit, statement.kind == .tcl {
          let sent = await Self.$userStatementAdmission.withValue(admission) {
            await sendUserCommit(statement.text, binds: statementBinds)
          }
          commitState = sent.rewindState
          result = try sent.result.get()
        } else {
          result = try await Self.$userStatementAdmission.withValue(admission) {
            try await executeSingleStatement(
              statement.text, maxRows: maxRows, inTransaction: inTransaction,
              binds: statementBinds)
          }
        }
      } catch {
        // The session is gone, or the interrupt's effect on the transaction is observed
        if let cancelled = await cancelErrorAfterInterrupt(
          since: epoch, generation: cancelGeneration)
        {
          throw cancelled
        }
        // A MySQL deadlock already ended the user's transaction and discarded its Data Rewind
        // entries, on the raw error (`queryFailure`)
        if !protectedMode {
          noteUserTransaction(after: statement, succeeded: false, commitState: commitState)
          await confirmUserTransactionWithServer(after: statement, succeeded: false)
        }
        throw await transactionFailure(error, openedHere: openedHere)
      }
      // A cancel interrupted the connection while this COMMIT was in flight
      if commitsUserTransaction {
        try await noteUserCommitAfterInterrupt(since: epoch, generation: cancelGeneration)
      }
      if action != .run {
        recordPending(
          StatementSummary(
            statement: ClassifiedStatement(
              text: shownText(at: index), kind: statement.kind,
              hasReturning: statement.hasReturning,
              hasTopLevelReturning: statement.hasTopLevelReturning,
              affectsAllRows: statement.affectsAllRows,
              nonTransactional: statement.nonTransactional,
              resetsSessionBrakes: statement.resetsSessionBrakes,
              changesPrivileges: statement.changesPrivileges, createsTable: statement.createsTable),
            affectedRows: statement.kind == .dml ? result.affectedRows : nil,
            dialect: Self.dialect(of: config)))
      }
      if !protectedMode {
        noteUserTransaction(after: statement, succeeded: true, commitState: commitState)
        await confirmUserTransactionWithServer(after: statement, succeeded: true)
      }
      noteSchemaChange(statement)
      result = await resetSessionIfCapped(result, statement: statement)
      if result.sessionReset {
        // The rest would run outside the user's session state (temp tables, SET, BEGIN)
        result.skippedStatements = ((index + 1)..<statements.count).map { shownText(at: $0) }
        results.append((queryText: shownText(at: index), result: result))
        break
      }
      results.append((queryText: shownText(at: index), result: result))
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
  ///   A COMMIT that throws is followed by ROLLBACK (unless the connection was lost): SQLite
  ///   keeps the transaction open after a deferred foreign key failure, PostgreSQL has already
  ///   ended it. The state is `.idle` afterwards. The Data Rewind entries are discarded only
  ///   when the server rejected the COMMIT (`isServerRejection`), else they stay pending.
  func commitAppTransaction(expectedGeneration: UInt64) async throws {
    // The server ended the session (and its transaction): never report a silent success
    if session == nil, let loss = lastSessionLoss {
      throw DatabaseError.connectionLost(loss.message)
    }
    try refuseIfEnding()
    if !txState.isIdle, commitGuard.refusesCommit(expectedGeneration: expectedGeneration) {
      throw DatabaseError.commitRefusedTransactionChanged
    }
    // DuckDB: a cancel aborted the transaction (an edit, or a statement it missed): rolled back
    if !txState.isIdle, interruptRollbackOwed == connectionEpoch {
      await settleInterruptAbort()
      throw Self.commitAfterInterruptError
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
      let metadata: CommandResult
      let startTime = Date()
      do {
        metadata = try await withSession { session in
          try await session.command("COMMIT", binds: [])
        }
      } catch {
        let lost = isConnectionLost
        // Unknown whether committed unless the server rejected it (MySQL reports a lost
        // connection later), so the Data Rewind entries stay pending (unconfirmed)
        let rejected = !lost && Self.isServerRejection(error)
        let failure = transactionControlError(error, sql: "COMMIT", startTime: startTime)
        if !lost { _ = try? await sendTransactionControl("ROLLBACK") }
        txState = .idle
        discardAppSchemaChange()
        closeRewindEntries(as: rejected ? .discarded : nil)
        if lost {
          throw DatabaseError.transactionAborted(
            "The connection was lost during Commit; it is unknown whether the "
              + "\(pending.count) pending statement(s) were committed.")
        }
        throw DatabaseError.transactionAborted(
          "Commit failed and the \(pending.count) pending statement(s) were rolled back: "
            + failure.localizedDescription)
      }
      txState = .idle
      // COMMIT of a transaction the server already aborted answers with a ROLLBACK tag
      guard metadata.tag == "COMMIT" else {
        discardAppSchemaChange()
        closeRewindEntries(as: .discarded)
        throw DatabaseError.transactionAborted(
          "The server rolled back the transaction instead of committing it (a statement had "
            + "failed); the \(pending.count) pending statement(s) were discarded.")
      }
      closeRewindEntries(as: .committed)
      promoteAppSchemaChange()
    }
  }

  /// A COMMIT of a transaction a DuckDB interrupt cancel aborted (`settleInterruptAbort`)
  static let commitAfterInterruptError = DatabaseError.transactionAborted(
    "The commit may not have been applied: cancelling the running statement rolled back the "
      + "open transaction. Check the data before running it again.")

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
    // DuckDB: a cancel aborted the transaction, its ROLLBACK is the one owed
    if interruptRollbackOwed == connectionEpoch {
      await settleInterruptAbort()
      return
    }
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
      discardAppSchemaChange()
      closeRewindEntries(as: .discarded)
      throw lostConnectionError(pendingCount: previous.pending.count, error)
    }
    txState = .idle
    discardAppSchemaChange()
    closeRewindEntries(as: .discarded)
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

  /// A script started on connection `epoch` at cancellation `generation` stops once the user
  /// cancelled that connection (its close may still be in progress) or the connection changed (another tab's capped read,
  /// reconnect): `DatabaseError.queryCancelled`, else `DatabaseError.sessionChanged`
  /// (`remaining` statements not run).
  func refuseIfSessionChanged(since epoch: UInt64, generation: UInt64, remaining: Int) throws {
    if let cancelled = cancelError(since: epoch, generation: generation) { throw cancelled }
    guard connectionEpoch != epoch else { return }
    throw DatabaseError.sessionChanged(skippedStatements: remaining)
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
    // MongoDB has no transactions: `appOwnedBeginSQL` is a sentinel that is never sent.
    guard config?.databaseType.capabilities.supportsTransactions != false else {
      throw DatabaseError.transactionAborted(
        "This database has no transactions, so nothing was sent. Use Confirm instead of Review.")
    }
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    txOwner = caller
    do {
      _ = try await sendTransactionControl(appOwnedBeginSQL)
    } catch {
      if txState.isIdle { txOwner = nil }
      throw error
    }
    do {
      try await suspendIdleTimeoutIfSupported()
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

  /// Update `userTxOpen`, and when a user `COMMIT` / `END` persisted schema changes, ask the
  /// sidebar to reload. `ROLLBACK` drops those changes instead. `commitState`: what a user
  /// COMMIT did to the open Data Rewind entries (`sendUserCommit`; nil: unknown).
  func noteUserTransaction(
    after statement: ClassifiedStatement, succeeded: Bool, commitState: RewindEntry.State?
  ) {
    let wasOpen = userTxOpen
    let dialect = Self.dialect(of: config)
    userTxOpen = ProtectedTransactionRules.userTxOpen(
      after: statement, current: userTxOpen, succeeded: succeeded, dialect: dialect)
    guard wasOpen else { return }
    // A MySQL BEGIN commits the open transaction, then opens the next one
    let commits =
      ProtectedTransactionRules.committedUserTransaction(statement, dialect: dialect)
      || ProtectedTransactionRules.beginCommitsOpenTransaction(statement, dialect: dialect)
    if succeeded && commits {
      if schemaDirtyInUserTx { schemaRefreshPending = true }
      schemaDirtyInUserTx = false
      closeRewindEntries(as: commitState)
    } else if !userTxOpen {
      schemaDirtyInUserTx = false
      closeRewindEntries(as: commits ? commitState : .discarded)
    } else if succeeded
      && ProtectedTransactionRules.rolledBackUserTransaction(statement, dialect: dialect)
    {
      // ROLLBACK AND CHAIN: a transaction is open again, but what ran before it is gone
      closeRewindEntries(as: .discarded)
    }
  }

  /// MySQL: after a statement whose effect on the transaction is uncertain
  /// (`ProtectedTransactionRules.commitIsUncertain`), `userTxOpen` is what the server reports.
  /// A transaction the server no longer has was committed implicitly: its schema changes are
  /// visible now. Unchanged when the server cannot be asked or the connection changed meanwhile.
  func confirmUserTransactionWithServer(
    after statement: ClassifiedStatement, succeeded: Bool
  ) async {
    guard
      ProtectedTransactionRules.commitIsUncertain(
        statement, succeeded: succeeded, dialect: Self.dialect(of: config)),
      session is MySQLSession
    else { return }
    let epoch = connectionEpoch
    let reported = try? await withSession { session in
      try await (session as? MySQLSession)?.isInTransaction()
    }
    guard let open = reported ?? nil, epoch == connectionEpoch else { return }
    if userTxOpen && !open {
      if schemaDirtyInUserTx { schemaRefreshPending = true }
      schemaDirtyInUserTx = false
      closeRewindEntries(as: .committed)
    }
    userTxOpen = open
  }

  /// Remember a successful statement that changes tables, views, or routines.
  /// Uncommitted work waits for Commit; autocommit asks the sidebar to reload now.
  func noteSchemaChange(_ statement: ClassifiedStatement) {
    guard ProtectedTransactionRules.changesVisibleSchema(statement) else { return }
    if !txState.isIdle {
      schemaDirtyInAppTx = true
    } else if userTxOpen {
      schemaDirtyInUserTx = true
    } else {
      schemaRefreshPending = true
    }
  }

  func noteSchemaSQL(_ statements: [BoundStatement]) {
    for statement in statements {
      guard let classified = classification(of: statement) else { continue }
      noteSchemaChange(classified)
    }
  }

  /// `statement.classified`, or `sql` classified with the connection's dialect
  func classification(of statement: BoundStatement) -> ClassifiedStatement? {
    statement.classified
      ?? SQLStatementClassifier.classify(statement.sql, dialect: Self.dialect(of: config)).first
  }

  /// Hands a committed schema change to the sidebar. Nothing is taken while an app
  /// transaction could still roll it back.
  func takeSchemaRefresh() -> Bool {
    guard schemaRefreshPending, txState.isIdle else { return false }
    schemaRefreshPending = false
    return true
  }

  func restoreSchemaRefresh() {
    schemaRefreshPending = true
  }

  func promoteAppSchemaChange() {
    if schemaDirtyInAppTx { schemaRefreshPending = true }
    schemaDirtyInAppTx = false
  }

  func discardAppSchemaChange() {
    schemaDirtyInAppTx = false
  }

  /// Update the state after a statement failed and return the error to throw.
  /// Inside the app transaction: connection lost → `.idle` (pending lost); the transaction was
  /// opened by this run and nothing is pending → rolled back automatically (nothing to lose);
  /// otherwise → `.aborted`.
  func transactionFailure(_ error: Error, openedHere: Bool) async -> Error {
    guard case .appTx(let pending) = txState else { return error }
    if isConnectionLost {
      txState = .idle
      discardAppSchemaChange()
      closeRewindEntries(as: .discarded)
      return lostConnectionError(pendingCount: pending.count, error)
    }
    if openedHere && pending.isEmpty, (try? await sendTransactionControl("ROLLBACK")) != nil {
      txState = .idle
      discardAppSchemaChange()
      closeRewindEntries(as: .discarded)
      return error
    }
    txState = .aborted(reason: error.localizedDescription, pending: pending)
    // The server undid the statements. Rollback does not put them back.
    discardAppSchemaChange()
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
    // What already ran was not classified here, so Commit reloads the sidebar.
    schemaDirtyInAppTx = true
    schemaDirtyInUserTx = false
    do {
      try await suspendIdleTimeoutIfSupported()
    } catch {
      throw await transactionFailure(error, openedHere: false)
    }
  }

  /// App-owned transaction start. SQLite takes the writer lock immediately. DuckDB uses the
  /// standard form. MySQL uses `START TRANSACTION` (`BEGIN` is ambiguous inside compound
  /// statements). A user-typed `BEGIN` is never rewritten. MongoDB has no transactions: its
  /// sentinel is never sent (`beginAppTransaction` refuses first) and is no mongosh command.
  var appOwnedBeginSQL: String {
    switch config?.databaseType {
    case .postgresql, nil: "BEGIN"
    case .sqlite: "BEGIN IMMEDIATE"
    case .duckdb: "BEGIN TRANSACTION"
    case .mysql: "START TRANSACTION"
    case .mongodb: "-- dblore: MongoDB has no transactions"
    }
  }

  /// PostgreSQL suspends the idle-in-transaction timeout for the app transaction.
  /// SQLite and DuckDB have no session brake, so nothing is sent.
  func suspendIdleTimeoutIfSupported() async throws {
    guard session?.capabilities.supportsSessionBrakes == true,
      let sql = suspendIdleTimeoutSQLForEngine
    else { return }
    _ = try await sendTransactionControl(sql)
  }

  /// The statement that suspends the idle-in-transaction timeout, or nil when the engine has
  /// none. MySQL's `wait_timeout` is session-level and never ends a transaction on its own.
  private var suspendIdleTimeoutSQLForEngine: String? {
    switch config?.databaseType {
    case .postgresql, nil: Self.suspendIdleTimeoutSQL
    case .sqlite, .duckdb, .mysql, .mongodb: nil
    }
  }

  private var isConnectionLost: Bool {
    guard session != nil else { return true }
    guard let postgres = postgresSession else { return false }
    return postgres.connection?.isClosed ?? true
  }

  /// A raw session error the server answered: a PostgreSQL error response (with its SQLSTATE),
  /// a MySQL ERR packet (an error code) or any SQLite result (a local library, no network). A
  /// COMMIT answered with an error did not commit. Anything else (I/O, a closed connection, a
  /// timeout) is unknown: the answer may have been lost after the server committed.
  nonisolated static func isServerRejection(_ error: Error) -> Bool {
    switch error {
    case let error as PSQLError: error.code == .server && error.serverInfo?[.sqlState] != nil
    case let error as MySQLSessionError: error.code != nil
    case is SQLiteSessionError: true
    default: false
    }
  }

  /// Send a user `COMMIT` / `END` with the result `executeCommand` gives, and what it did to
  /// the open Data Rewind entries: committed; discarded when the server rejected it
  /// (`isServerRejection`) or answered with a ROLLBACK tag (PostgreSQL, for a transaction a
  /// failed statement aborted); nil when unknown. SQLite keeps the transaction open after a
  /// COMMIT that fails (SQLITE_BUSY, a deferred foreign key): it can be retried, so nil too.
  private func sendUserCommit(
    _ sql: String, binds: [SQLBindValue]
  ) async -> (result: Result<QueryResult, Error>, rewindState: RewindEntry.State?) {
    let startTime = Date()
    do {
      let command = try await withSession { session in
        try await session.command(sql, binds: binds)
      }
      let result = QueryResult(
        columns: [], rows: [], rowCount: 0, executionTime: Date().timeIntervalSince(startTime),
        affectedRows: StatementRoute.commandAffectedRows(command))
      return (.success(result), command.tag == "ROLLBACK" ? .discarded : .committed)
    } catch {
      return (
        .failure(unwrapFailure(error, fallbackSQL: sql, startTime: startTime)),
        Self.isServerRejection(error) && !(error is SQLiteSessionError) ? .discarded : nil
      )
    }
  }

  /// The server may close the session on its own (e.g. `idle_in_transaction_session_timeout`
  /// while a user transaction idles). Nothing is sent: the session is forgotten
  /// (`markSessionLost`, which also ends the user transaction) and the caller gets
  /// `DatabaseError.connectionLost` asking to reconnect.
  func refuseIfConnectionClosed() throws {
    guard let connection = _postgresConnection, connection.isClosed else { return }
    throw sessionLostError(connection, epoch: connectionEpoch)
  }

  private func lostConnectionError(pendingCount: Int, _ error: Error) -> DatabaseError {
    .transactionAborted(
      "The connection was lost; the \(pendingCount) pending statement(s) were rolled back by "
        + "the server. \(error.localizedDescription)")
  }

  func sendTransactionControl(_ sql: String) async throws -> CommandResult {
    let startTime = Date()
    // A ROLLBACK (also to a savepoint) writes nothing: a staged batch's cleanup after a DuckDB
    // interrupt cancel is still sent (`withSession`)
    let admission = sql.hasPrefix("ROLLBACK") ? nil : Self.userStatementAdmission
    do {
      return try await Self.$userStatementAdmission.withValue(admission) {
        try await withSession { session in
          try await session.command(sql, binds: [])
        }
      }
    } catch {
      throw transactionControlError(error, sql: sql, startTime: startTime)
    }
  }

  /// The error `sendTransactionControl` throws for the raw `error` of `sql`
  private func transactionControlError(
    _ error: Error, sql: String, startTime: Date
  ) -> DatabaseError {
    switch error {
    case let error as DatabaseError:
      error
    case let error as PSQLError:
      .queryFailed(formatPostgresError(error, query: sql), Date().timeIntervalSince(startTime))
    default:
      .queryFailed(error.localizedDescription, Date().timeIntervalSince(startTime))
    }
  }
}
