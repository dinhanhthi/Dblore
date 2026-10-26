// DuckDBInterruptTransactionTests.swift
// An interrupt cancel inside a transaction: DuckDB aborts the transaction, reads too, and a later
// COMMIT on it answers success while it rolls back. The app rolls the aborted transaction back
// itself, so nothing claims the changes were committed, and it warns that the cancel will roll
// back (never "may"). Dev plugin only.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB interrupt inside a transaction", .requiresDuckDBPlugin, .serialized)
struct DuckDBInterruptTransactionTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  /// Hashes every row of a huge range; runs far longer than any test waits.
  private static let longWrite =
    "INSERT INTO t SELECT count(*) FROM range(100000000000) r(a) WHERE md5(a::VARCHAR) LIKE 'xyz%'"
  private static let longRead =
    "SELECT count(*) FROM range(100000000000) r(a) WHERE md5(a::VARCHAR) LIKE 'xyz%'"

  @Test("An interrupted write rolls back the transaction; a later COMMIT does not succeed")
  func interruptedWriteRollsBack() async throws {
    let connection = try await connectInTransaction()
    let (error, _) = try await interrupt(Self.longWrite, on: connection, policy: open)
    try await expectRolledBack(error, on: connection)
  }

  @Test("An interrupted read rolls back the transaction too, after a definite warning")
  func interruptedReadRollsBack() async throws {
    let connection = try await connectInTransaction()
    let (error, status) = try await interrupt(Self.longRead, on: connection, policy: open)
    #expect(status.interruptRollsBack)
    let warning = QueryCancelWarning.make(
      state: status.state, userTxOpen: status.userTxOpen,
      keepsTransaction: status.keepsTransaction, interrupts: status.interrupts,
      interruptRollsBack: status.interruptRollsBack)
    #expect(warning?.title == "Cancelling will roll back the open transaction")
    try await expectRolledBack(error, on: connection)
  }

  @Test("Protected mode: an interrupted write rolls back the pending change")
  func protectedInterruptedWriteDiscardsPending() async throws {
    let connection = try await connect(protectedMode: true)
    _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: protected)
    #expect(await connection.transactionSnapshot().pending.count == 1)

    let (error, _) = try await interrupt(Self.longWrite, on: connection, policy: protected)
    #expect(error.localizedDescription == "Query cancelled. 1 pending change was rolled back.")
    #expect(await connection.transactionSnapshot().isIdle)
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }

  /// A statement queued behind the stopped one (another tab) is a send in flight when the
  /// stopped statement ends: the aborted transaction must still be rolled back, or every later
  /// statement fails "Current transaction is aborted"
  @Test("Another send in flight: the transaction is rolled back and the connection still works")
  func rollbackWithAnotherSendInFlight() async throws {
    let connection = try await connectInTransaction()
    let running = Task { try await connection.execute(userSQL: Self.longRead, policy: open) }
    while !(await connection.runningStatementStatus().inFlight) {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(300))
    let queued = Task {
      try await connection.execute(userSQL: "SELECT 1", policy: open, caller: UUID())
    }
    while await connection.activeSends < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    _ = try? await running.value
    _ = try? await queued.value

    #expect(await connection.runningStatementStatus().userTxOpen == false)
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }

  /// The statement-timeout watchdog interrupts like a cancel: DuckDB aborts the transaction and
  /// a later COMMIT would answer success
  @Test("A statement timeout inside BEGIN rolls back the transaction; a later COMMIT fails")
  func timeoutInsideBeginRollsBack() async throws {
    let connection = try await connectInTransaction(timeoutSeconds: 1)
    let error = await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: Self.longRead, policy: open)
    }
    #expect(error?.localizedDescription.hasSuffix("Your open transaction was rolled back.") == true)
    try await expectNoTransaction(on: connection, rows: 0)
  }

  /// Execution errors abort a DuckDB transaction; parse, catalog and binder errors leave it
  /// usable (checked against DuckDB 1.5), so only the first is rolled back
  @Test(
    "A failed statement inside BEGIN rolls back an aborted transaction and keeps a usable one",
    arguments: [
      ("INSERT INTO t VALUES ('not a number')", true),
      ("SELECT missing_column FROM t", false),
    ])
  func failedStatementInsideBegin(sql: String, aborts: Bool) async throws {
    let connection = try await connectInTransaction()
    let policy = open
    await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: sql, policy: policy)
    }
    if aborts {
      try await expectNoTransaction(on: connection, rows: 0)
    } else {
      #expect(await connection.runningStatementStatus().userTxOpen)
      _ = try await connection.execute(userSQL: "COMMIT", policy: open)
      let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
      #expect(count.rows == [[.int(1)]])
      await connection.disconnect()
    }
  }

  /// Protected mode: the aborted app transaction is rolled back too. One the failed statement
  /// opened itself held nothing: rolled back quietly, the error unchanged
  @Test(
    "Protected mode: a failed statement rolls back the aborted app transaction",
    arguments: [0, 1])
  func protectedFailedStatementRollsBack(pending: Int) async throws {
    let connection = try await connect(protectedMode: true)
    if pending == 1 {
      _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: protected)
    }
    #expect(await connection.transactionSnapshot().pending.count == pending)
    let policy = protected
    let error = await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: "INSERT INTO t VALUES ('not a number')", policy: policy)
    }
    let message = error?.localizedDescription ?? ""
    if pending == 1 {
      #expect(message.hasSuffix("1 pending change was rolled back."))
    } else {
      #expect(!message.contains("rolled back"))
    }
    #expect(await connection.transactionSnapshot().isIdle)
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }

  // MARK: - Helpers

  /// An in-memory database with table `t` (committed)
  private func connect(
    protectedMode: Bool, timeoutSeconds: Int = 30
  ) async throws -> DatabaseConnectionManager {
    let connection = DatabaseConnectionManager(sessionFactory: Factory())
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: protectedMode,
        statementTimeoutSeconds: timeoutSeconds))
    _ = try await connection.execute(userSQL: "CREATE TABLE t (x BIGINT)", policy: open)
    // Protected mode stages the CREATE too: commit it, so only the test's change is pending
    if protectedMode {
      try await connection.commitAppTransaction(
        expectedGeneration: await connection.transactionStatus().generation)
    }
    return connection
  }

  /// `connect`, then BEGIN and one row inserted in the transaction
  private func connectInTransaction(
    timeoutSeconds: Int = 30
  ) async throws
    -> DatabaseConnectionManager
  {
    let connection = try await connect(protectedMode: false, timeoutSeconds: timeoutSeconds)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: open)
    #expect(await connection.runningStatementStatus().userTxOpen)
    return connection
  }

  /// Runs `sql`, cancels it once while DuckDB is inside the statement, and returns the error
  /// with the status the cancel confirmed. One cancel only: a second interrupt could land on
  /// the next statement.
  private func interrupt(
    _ sql: String, on connection: DatabaseConnectionManager, policy: ProtectionPolicy
  ) async throws -> (DatabaseError, RunningStatementStatus) {
    let running = Task { try await connection.execute(userSQL: sql, policy: policy) }
    var status = await connection.runningStatementStatus()
    while !status.inFlight {
      try await Task.sleep(for: .milliseconds(10))
      status = await connection.runningStatementStatus()
    }
    try await Task.sleep(for: .milliseconds(300))
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let error = await #expect(throws: DatabaseError.self) { try await running.value }
    return (try #require(error), status)
  }

  /// The user's transaction was rolled back and reported so; COMMIT fails instead of
  /// answering success, and the row inserted in it is gone
  private func expectRolledBack(
    _ error: DatabaseError, on connection: DatabaseConnectionManager
  ) async throws {
    guard case .queryCancelled(_, let rolledBack, let kept) = error else {
      Issue.record("Expected queryCancelled, got \(error)")
      return
    }
    #expect(rolledBack)
    // The interrupt kept the session: nothing says it was reset
    #expect(kept)
    #expect(error.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(await connection.runningStatementStatus().userTxOpen == false)
    let policy = open
    await #expect(throws: (any Error).self) {
      try await connection.execute(userSQL: "COMMIT", policy: policy)
    }
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }

  /// No transaction is left open: COMMIT fails instead of answering success, and the table
  /// holds `rows` rows
  private func expectNoTransaction(
    on connection: DatabaseConnectionManager, rows: Int
  ) async throws {
    #expect(await connection.runningStatementStatus().userTxOpen == false)
    let policy = open
    await #expect(throws: (any Error).self) {
      try await connection.execute(userSQL: "COMMIT", policy: policy)
    }
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(rows)]])
    await connection.disconnect()
  }

  /// Real DuckDB sessions on the dev plugin
  private struct Factory: DatabaseSessionFactory {
    func makeSession(config: ConnectionConfig) throws -> any DatabaseSession {
      DuckDBSession(config: config) { try DuckDBTestPlugin.library() }
    }
  }
}
