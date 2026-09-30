// ProtectedTransactionTests.swift
// Protected mode transaction state machine (P1), caller token and catalog pause (P4) against
// the docker test database
// (TEST_DB_* env, port 5435 in CI/autopilot). A second manager checks what is committed.

import Foundation
import PostgresNIO
import Testing

@testable import Dblore

@Suite("Protected Transaction - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct ProtectedTransactionTests {
  private static func config(protectedMode: Bool = true, idleTimeout: Int = 600) -> ConnectionConfig
  {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      protectedMode: protectedMode,
      idleInTransactionTimeoutSeconds: idleTimeout
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Connects `manager` (Protected per `protectedMode`) and an unprotected observer, and
  /// creates `table (id int PRIMARY KEY, v int)` with row (1, 10) through the observer.
  private func setUp(
    _ table: String, protectedMode: Bool = true, idleTimeout: Int = 600
  ) async throws -> (
    manager: DatabaseConnectionManager, observer: DatabaseConnectionManager
  ) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: Self.config(protectedMode: protectedMode, idleTimeout: idleTimeout))
    return (manager, observer)
  }

  private func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func value(
    _ manager: DatabaseConnectionManager, _ table: String
  ) async throws -> CellValue? {
    try await manager.executeInternal("SELECT v FROM \(table) WHERE id = 1").rows.first?.first
  }

  private func isIdle(_ manager: DatabaseConnectionManager) async -> Bool {
    await manager.transactionSnapshot().isIdle
  }

  private func isAborted(_ manager: DatabaseConnectionManager) async -> Bool {
    if case .aborted = await manager.transactionSnapshot() { return true }
    return false
  }

  // MARK: - Protected ON

  @Test("UPDATE then Rollback: row unchanged, state back to idle")
  func updateThenRollback() async throws {
    let table = "p1_tx_rollback"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)

    let pending = await manager.transactionSnapshot().pending
    #expect(pending.count == 1)
    #expect(pending.first?.kindLabel == "UPDATE")
    #expect(try await value(observer, table) == .int(10))

    try await manager.rollbackAppTransaction()
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(10))
    #expect(try await value(manager, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  @Test("UPDATE then Commit: row changed for another session")
  func updateThenCommit() async throws {
    let table = "p1_tx_commit"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.executeDetailed(
      userSQL: "UPDATE \(table) SET v = 30 WHERE id = 1", policy: open)
    #expect(try await value(observer, table) == .int(10))

    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(30))
    await tearDown(table, manager, observer)
  }

  @Test("SELECT after UPDATE in the same transaction sees the uncommitted change")
  func selectSeesPendingChange() async throws {
    let table = "p1_tx_select"
    let (manager, observer) = try await setUp(table)
    let result = try await manager.execute(
      userSQL: "UPDATE \(table) SET v = 40 WHERE id = 1; SELECT v FROM \(table) WHERE id = 1",
      policy: open)
    #expect(result.rows.first?.first == .int(40))
    let later = try await manager.execute(
      userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: open)
    #expect(later.rows.first?.first == .int(40))
    #expect(await manager.transactionSnapshot().pending.count == 1)
    #expect(try await value(observer, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  @Test("Reads alone never open a transaction")
  func readsDoNotOpenTransaction() async throws {
    let table = "p1_tx_reads"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "SELECT v FROM \(table)", policy: open)
    #expect(await isIdle(manager))
    await tearDown(table, manager, observer)
  }

  @Test("User BEGIN and VACUUM are blocked: nothing is sent, no transaction opened")
  func userTransactionControlAndVacuumBlocked() async throws {
    let table = "p1_tx_blocked"
    let (manager, observer) = try await setUp(table)
    for sql in ["BEGIN", "VACUUM \(table)", "UPDATE \(table) SET v = 50 WHERE id = 1; COMMIT"] {
      await #expect(throws: DatabaseError.self) {
        _ = try await manager.execute(userSQL: sql, policy: open)
      }
      #expect(await isIdle(manager))
    }
    #expect(try await value(manager, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  @Test("Error mid-transaction: aborted, statements and Commit refused, Rollback returns to idle")
  func errorAbortsTransaction() async throws {
    let table = "p1_tx_abort"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 60 WHERE id = 1", policy: open)
    await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(userSQL: "SELECT 1 / 0", policy: open)
    }
    #expect(await isAborted(manager))
    #expect(await manager.transactionSnapshot().pending.count == 1)

    await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
    }
    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }
    #expect(await isAborted(manager))

    try await manager.rollbackAppTransaction()
    #expect(await isIdle(manager))
    #expect(try await value(manager, table) == .int(10))
    let after = try await manager.execute(userSQL: "SELECT 1", policy: open)
    #expect(after.rows.first?.first == .int(1))
    await tearDown(table, manager, observer)
  }

  @Test("Failure of the statement that opened the transaction rolls it back: state idle")
  func firstStatementFailureRollsBack() async throws {
    let table = "p1_tx_first_fail"
    let (manager, observer) = try await setUp(table)
    await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(userSQL: "UPDATE p1_tx_missing SET v = 1", policy: open)
    }
    #expect(await isIdle(manager))
    let after = try await manager.execute(userSQL: "SELECT 1", policy: open)
    #expect(after.rows.first?.first == .int(1))
    await tearDown(table, manager, observer)
  }

  @Test("Commit of a transaction the server silently aborted is reported, not claimed")
  func commitDetectsServerRollback() async throws {
    let table = "p1_tx_silent_abort"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 65 WHERE id = 1", policy: open)
    // App-owned SQL bypasses the state machine: the server aborts, txState stays .appTx
    _ = try? await manager.executeInternal("SELECT 1 / 0")
    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  @Test("Read-only policy blocks the write before any BEGIN")
  func readOnlyBlocksBeforeBegin() async throws {
    let table = "p1_tx_readonly"
    let (manager, observer) = try await setUp(table)
    await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 70 WHERE id = 1",
        policy: ProtectionPolicy(protectionLevel: .readOnly))
    }
    #expect(await isIdle(manager))
    await tearDown(table, manager, observer)
  }

  @Test("Disconnect resets the transaction state (server rolls back)")
  func disconnectResetsState() async throws {
    let table = "p1_tx_disconnect"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 80 WHERE id = 1", policy: open)
    await manager.disconnect()
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  @Test("Inline edit joins a pending app transaction and is recorded")
  func inlineEditJoinsPendingTransaction() async throws {
    let table = "p1_tx_inline"
    let (manager, observer) = try await setUp(table)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)
    let edit = try CellUpdateStatement.make(
      qualifiedName: "public.\(table)", columnName: "v", newValue: "12", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1), "v": .int(11)])
    let rows = try await manager.executeGatedUpdate(
      edit, policy: open, connectionEpoch: await manager.connectionEpoch)
    #expect(rows == 1)
    #expect(await manager.transactionSnapshot().pending.count == 2)
    try await manager.rollbackAppTransaction()
    #expect(try await value(observer, table) == .int(10))
    await tearDown(table, manager, observer)
  }

  // MARK: - Caller token (P4)

  @Test("Another caller token is refused while the app transaction is pending")
  func otherCallerRefused() async throws {
    let table = "p4_tx_caller"
    let (manager, observer) = try await setUp(table)
    do {
      try await checkOtherCallerRefused(table, manager, observer)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  private func checkOtherCallerRefused(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async throws {
    let origin = UUID()
    let other = UUID()
    _ = try await manager.execute(
      userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open, caller: origin)

    let refused = await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 99 WHERE id = 1", policy: open, caller: other)
    }
    #expect(isPendingElsewhere(refused))
    let refusedRead = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeDetailed(userSQL: "SELECT 1", policy: open, caller: other)
    }
    #expect(isPendingElsewhere(refusedRead))
    let edit = try CellUpdateStatement.make(
      qualifiedName: "public.\(table)", columnName: "v", newValue: "98", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1), "v": .int(20)])
    let refusedEdit = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedUpdate(
        edit, policy: open, connectionEpoch: await manager.connectionEpoch, caller: other)
    }
    #expect(isPendingElsewhere(refusedEdit))

    // Nothing was sent: still one pending statement, not aborted; the origin still runs
    guard case .appTx(let pending) = await manager.transactionSnapshot() else {
      Issue.record("Expected appTx")
      return
    }
    #expect(pending.count == 1)
    let read = try await manager.execute(
      userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: open, caller: origin)
    #expect(read.rows.first?.first == .int(20))

    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(try await value(observer, table) == .int(20))
    // Idle again: any caller may open the next transaction
    _ = try await manager.execute(
      userSQL: "UPDATE \(table) SET v = 30 WHERE id = 1", policy: open, caller: other)
    #expect(await manager.transactionSnapshot().pending.count == 1)
  }

  @Test("Catalog queries refuse while the app transaction is pending; Commit still works")
  func catalogRefusedWhilePending() async throws {
    let table = "p4_tx_catalog"
    let (manager, observer) = try await setUp(table)
    do {
      try await checkCatalogRefused(table, manager, observer)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  private func checkCatalogRefused(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async throws {
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)

    let tables = await #expect(throws: DatabaseError.self) {
      _ = try await manager.fetchTables()
    }
    #expect(isMetadataPaused(tables))
    // A name that does not exist would fail on the server (and abort the transaction)
    let rowCount = await #expect(throws: DatabaseError.self) {
      _ = try await manager.fetchRowCount(tableSchema: "public", tableName: "p4_does_not_exist")
    }
    #expect(isMetadataPaused(rowCount))
    let editTable = await #expect(throws: DatabaseError.self) {
      _ = try await manager.fetchEditTable(tableName: table)
    }
    #expect(isMetadataPaused(editTable))

    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(try await value(observer, table) == .int(20))
    #expect(try await manager.fetchTables().contains { $0.name == table })
  }

  private func isPendingElsewhere(_ error: DatabaseError?) -> Bool {
    if case .transactionPendingInAnotherTab? = error { return true }
    return false
  }

  private func isMetadataPaused(_ error: DatabaseError?) -> Bool {
    if case .metadataPausedDuringTransaction? = error { return true }
    return false
  }

  // MARK: - Commit of the reviewed list only

  private func isCommitRefused(_ error: DatabaseError?) -> Bool {
    if case .commitRefusedTransactionChanged? = error { return true }
    return false
  }

  @Test(
    "Commit with a stale generation is refused and commits nothing; the fresh one commits",
    .timeLimit(.minutes(1)))
  func commitRefusesStaleGeneration() async throws {
    let table = "p3_tx_stale_generation"
    let (manager, observer) = try await setUp(table)
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let reviewed = await manager.transactionStatus().generation
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 30 WHERE id = 1", policy: open)

      let refused = await #expect(throws: DatabaseError.self) {
        try await manager.commitAppTransaction(expectedGeneration: reviewed)
      }
      #expect(isCommitRefused(refused))
      #expect(refused?.localizedDescription.contains("review again") == true)
      #expect(await manager.transactionSnapshot().pending.count == 2)
      #expect(try await value(observer, table) == .int(10))

      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
      #expect(await isIdle(manager))
      #expect(try await value(observer, table) == .int(30))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Commit while a gated statement of the transaction is running is refused",
    .timeLimit(.minutes(1)))
  func commitRefusedWhileStatementInFlight() async throws {
    let table = "p3_tx_in_flight"
    let (manager, observer) = try await setUp(table)
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let reviewed = await manager.transactionStatus().generation
      let running = Task {
        try await manager.execute(
          userSQL: "UPDATE \(table) SET v = 40 WHERE id = 1 AND pg_sleep(1.5) IS NOT NULL",
          policy: open)
      }
      try await Task.sleep(for: .milliseconds(400))
      let refused = await #expect(throws: DatabaseError.self) {
        try await manager.commitAppTransaction(expectedGeneration: reviewed)
      }
      #expect(isCommitRefused(refused))
      _ = try await running.value
      #expect(await manager.transactionSnapshot().pending.count == 2)
      #expect(try await value(observer, table) == .int(10))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Commit / Rollback in progress

  // Deterministic technique: `setTransactionEndHook` makes the manager suspend inside
  // Commit / Rollback right after it marked the transaction `.ending` and before COMMIT /
  // ROLLBACK is sent. The test waits until the hook is reached (so every call below enters the
  // actor while the end is in progress), then releases it.

  private struct EndHold {
    let reached: AsyncStream<Void>
    let release: AsyncStream<Void>.Continuation
  }

  private func holdTransactionEnd(_ manager: DatabaseConnectionManager) async -> EndHold {
    let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
    let (released, releaseContinuation) = AsyncStream<Void>.makeStream()
    await manager.setTransactionEndHook { _ in
      reachedContinuation.yield()
      for await _ in released { break }
    }
    return EndHold(reached: reached, release: releaseContinuation)
  }

  private func isEnding(_ error: DatabaseError?, _ kind: TransactionEndKind) -> Bool {
    if case .transactionEnding(let ending)? = error { return ending == kind }
    return false
  }

  @Test(
    "Statements, edits and BEGIN entering while COMMIT is awaited are refused; next write opens a new tx",
    .timeLimit(.minutes(1)))
  func entryRefusedWhileCommitting() async throws {
    let table = "p3_tx_committing"
    let (manager, observer) = try await setUp(table)
    do {
      try await checkEntryRefusedWhileCommitting(table, manager, observer)
    } catch {
      Issue.record(error)
    }
    await manager.setTransactionEndHook(nil)
    await tearDown(table, manager, observer)
  }

  private func checkEntryRefusedWhileCommitting(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async throws {
    let origin = UUID()
    _ = try await manager.execute(
      userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open, caller: origin)
    let hold = await holdTransactionEnd(manager)
    let reviewed = await manager.transactionStatus().generation
    let committing = Task {
      try await manager.commitAppTransaction(expectedGeneration: reviewed)
    }
    var reached = hold.reached.makeAsyncIterator()
    _ = await reached.next()
    #expect(await manager.transactionSnapshot().endingKind == .commit)

    let refused = await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 50 WHERE id = 1", policy: open, caller: origin)
    }
    #expect(isEnding(refused, .commit))
    let edit = try CellUpdateStatement.make(
      qualifiedName: "public.\(table)", columnName: "v", newValue: "51", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1), "v": .int(20)])
    let refusedEdit = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedUpdate(
        edit, policy: open, connectionEpoch: await manager.connectionEpoch, caller: origin)
    }
    #expect(isEnding(refusedEdit, .commit))
    let refusedBegin = await #expect(throws: DatabaseError.self) {
      try await manager.beginAppTransaction(caller: origin)
    }
    #expect(isEnding(refusedBegin, .commit))
    let refusedCommit = await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
    }
    #expect(isEnding(refusedCommit, .commit))
    let refusedRollback = await #expect(throws: DatabaseError.self) {
      try await manager.rollbackAppTransaction()
    }
    #expect(isEnding(refusedRollback, .commit))
    let catalog = await #expect(throws: DatabaseError.self) {
      _ = try await manager.fetchTables()
    }
    #expect(isMetadataPaused(catalog))
    #expect(try await value(observer, table) == .int(10))

    hold.release.yield()
    hold.release.finish()
    try await committing.value
    #expect(await isIdle(manager))
    // The refused write was never sent (not autocommitted after COMMIT)
    #expect(try await value(observer, table) == .int(20))

    // Idle again: the next write opens a NEW app transaction, invisible until its Commit
    await manager.setTransactionEndHook(nil)
    _ = try await manager.execute(
      userSQL: "UPDATE \(table) SET v = 60 WHERE id = 1", policy: open, caller: origin)
    guard case .appTx(let pending) = await manager.transactionSnapshot() else {
      Issue.record("Expected a new appTx")
      return
    }
    #expect(pending.count == 1)
    #expect(try await value(observer, table) == .int(20))
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
    #expect(try await value(observer, table) == .int(60))
  }

  @Test(
    "Statements and edits entering while ROLLBACK is awaited are refused; nothing autocommits",
    .timeLimit(.minutes(1)))
  func entryRefusedWhileRollingBack() async throws {
    let table = "p3_tx_rolling_back"
    let (manager, observer) = try await setUp(table)
    do {
      try await checkEntryRefusedWhileRollingBack(table, manager, observer)
    } catch {
      Issue.record(error)
    }
    await manager.setTransactionEndHook(nil)
    await tearDown(table, manager, observer)
  }

  private func checkEntryRefusedWhileRollingBack(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async throws {
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
    let hold = await holdTransactionEnd(manager)
    let rollingBack = Task { try await manager.rollbackAppTransaction() }
    var reached = hold.reached.makeAsyncIterator()
    _ = await reached.next()
    #expect(await manager.transactionSnapshot().endingKind == .rollback)

    let refused = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeDetailed(
        userSQL: "UPDATE \(table) SET v = 70 WHERE id = 1", policy: open)
    }
    #expect(isEnding(refused, .rollback))
    let edit = try CellUpdateStatement.make(
      qualifiedName: "public.\(table)", columnName: "v", newValue: "71", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1), "v": .int(20)])
    let refusedEdit = await #expect(throws: DatabaseError.self) {
      _ = try await manager.executeGatedUpdate(
        edit, policy: open, connectionEpoch: await manager.connectionEpoch)
    }
    #expect(isEnding(refusedEdit, .rollback))

    hold.release.yield()
    hold.release.finish()
    try await rollingBack.value
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(10))
    #expect(try await value(manager, table) == .int(10))
  }

  @Test(
    "Rollback while a gated statement of the transaction is running is refused",
    .timeLimit(.minutes(1)))
  func rollbackRefusedWhileStatementInFlight() async throws {
    let table = "p3_tx_rollback_in_flight"
    let (manager, observer) = try await setUp(table)
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let running = Task {
        try await manager.executeDetailed(
          userSQL: "UPDATE \(table) SET v = 40 WHERE id = 1 AND pg_sleep(1.5) IS NOT NULL; "
            + "UPDATE \(table) SET v = 41 WHERE id = 1",
          policy: open)
      }
      try await Task.sleep(for: .milliseconds(400))
      let refused = await #expect(throws: DatabaseError.self) {
        try await manager.rollbackAppTransaction()
      }
      if case .rollbackRefusedStatementRunning? = refused {
      } else {
        Issue.record("Expected rollbackRefusedStatementRunning, got \(String(describing: refused))")
      }
      _ = try await running.value
      #expect(await manager.transactionSnapshot().pending.count == 3)
      #expect(try await value(observer, table) == .int(10))
      try await manager.rollbackAppTransaction()
      #expect(await isIdle(manager))
      #expect(try await value(observer, table) == .int(10))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Protected OFF

  @Test("Protected off: autocommit, and user BEGIN / COMMIT are tracked")
  func protectedOffAutocommitAndTracking() async throws {
    let table = "p1_tx_off"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 90 WHERE id = 1", policy: open)
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(90))

    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    #expect(await manager.userTxOpen)
    _ = try await manager.execute(userSQL: "UPDATE \(table) SET v = 91 WHERE id = 1", policy: open)
    #expect(await isIdle(manager))
    #expect(try await value(observer, table) == .int(90))
    _ = try await manager.execute(userSQL: "COMMIT", policy: open)
    #expect(!(await manager.userTxOpen))
    #expect(try await value(observer, table) == .int(91))
    await tearDown(table, manager, observer)
  }

  // MARK: - Idle-in-transaction timeout (P5)

  private func show(_ manager: DatabaseConnectionManager, _ setting: String) async throws -> String?
  {
    let value = try await manager.executeInternal("SHOW \(setting)").rows.first?.first
    if case .string(let text) = value { return text }
    return nil
  }

  private let idleSetting = "idle_in_transaction_session_timeout"

  /// setUp with `idleInTransactionTimeoutSeconds = 1`, run `body`, always tearDown (a thrown
  /// error is recorded, so the connection is still closed before the manager is released).
  private func withIdleTimeout1s(
    _ table: String, protectedMode: Bool,
    _ body: (DatabaseConnectionManager, DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let (manager, observer) = try await setUp(table, protectedMode: protectedMode, idleTimeout: 1)
    do {
      try await body(manager, observer)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Idle timeout 1s: pending app transaction survives 2.5s idle, Commit restores 1s",
    .timeLimit(.minutes(1)))
  func idleTimeoutSuspendedUntilCommit() async throws {
    let table = "p5_idle_commit"
    try await withIdleTimeout1s(table, protectedMode: true) { manager, observer in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      // The app-owned SET LOCAL is not a pending statement
      let pending = await manager.transactionSnapshot().pending
      #expect(pending.count == 1)
      #expect(pending.first?.kindLabel == "UPDATE")
      #expect(try await show(manager, idleSetting) == "0")

      try await Task.sleep(for: .milliseconds(2500))
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
      #expect(await isIdle(manager))
      #expect(try await value(observer, table) == .int(20))
      #expect(try await show(manager, idleSetting) == "1s")
    }
  }

  @Test(
    "Idle timeout 1s: pending app transaction survives 2.5s idle, Rollback restores 1s",
    .timeLimit(.minutes(1)))
  func idleTimeoutSuspendedUntilRollback() async throws {
    let table = "p5_idle_rollback"
    try await withIdleTimeout1s(table, protectedMode: true) { manager, observer in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      #expect(await manager.transactionSnapshot().pending.count == 1)

      try await Task.sleep(for: .milliseconds(2500))
      try await manager.rollbackAppTransaction()
      #expect(await isIdle(manager))
      #expect(try await value(observer, table) == .int(10))
      #expect(try await show(manager, idleSetting) == "1s")
    }
  }

  @Test(
    "Adopted user transaction also suspends the idle timeout until Commit", .timeLimit(.minutes(1)))
  func idleTimeoutSuspendedForAdoptedTransaction() async throws {
    let table = "p5_idle_adopt"
    try await withIdleTimeout1s(table, protectedMode: false) { manager, observer in
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      await manager.updateConnectedProtection(
        from: Self.config(protectedMode: true, idleTimeout: 1))
      // Adoption happens at the entry of the next run, before its first statement
      _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
      guard case .appTx(let pending) = await manager.transactionSnapshot() else {
        Issue.record("Expected the user transaction to be adopted as appTx")
        return
      }
      // Intentional change: the unreviewed earlier contents show as one synthetic entry
      #expect(pending.count == 1)
      #expect(pending.first?.isEarlierChanges == true)
      #expect(pending.first?.affectedRows == nil)
      #expect(
        PendingTransactionSummary(state: .appTx(pending: pending)).headline.contains("unknown"))

      try await Task.sleep(for: .milliseconds(2500))
      try await manager.commitAppTransaction(
        expectedGeneration: await manager.transactionStatus().generation)
      #expect(try await value(observer, table) == .int(20))
      #expect(try await show(manager, idleSetting) == "1s")
    }
  }

  @Test(
    "Protected off: a user transaction idle for 2.5s is terminated by the server",
    .timeLimit(.minutes(1)))
  func idleTimeoutKillsUserTransaction() async throws {
    let table = "p5_idle_user_tx"
    try await withIdleTimeout1s(table, protectedMode: false) { manager, _ in
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      #expect(await manager.userTxOpen)

      try await Task.sleep(for: .milliseconds(2500))
      // The server closed the session: nothing is sent, the caller is asked to reconnect (C0:
      // the session is forgotten as soon as it closes, so the manager may already be
      // disconnected)
      #expect(await manager._connection?.isClosed ?? true)
      let error = await #expect(throws: DatabaseError.self) {
        _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
      }
      switch error {
      case .connectionLost?, .notConnected?: break
      default:
        Issue.record("Expected connectionLost / notConnected, got \(String(describing: error))")
      }
      #expect(!(await manager.userTxOpen))
    }
  }
}
