// CancelMessageTests.swift
// The cancel message and record depend on the engine: an interrupt that keeps the session and
// its transaction (MySQL KILL QUERY, MongoDB killOp) says the connection was kept and reports
// nothing rolled back. SQLite, DuckDB (interrupt) and PostgreSQL (reconnect) keep the reset
// text. Fake sessions, no server.

import Foundation
import Testing

@testable import Dblore

@Suite("Cancel Message")
struct CancelMessageTests {
  private static let resetText =
    "Query cancelled — connection was reset (temp tables, SET, search_path lost)."

  @Test(
    "interruptKeepsTransaction is true only for MySQL and MongoDB",
    arguments: DatabaseType.allCases)
  func interruptKeepsTransactionPerEngine(type: DatabaseType) {
    #expect(type.interruptKeepsTransaction == (type == .mysql || type == .mongodb))
  }

  @Test("A kept connection says so and nothing else")
  func keptMessage() {
    let error = DatabaseError.queryCancelled(
      pendingCount: 0, userTxRolledBack: false, connectionKept: true)
    #expect(error.localizedDescription == "Query cancelled. The connection was kept.")
  }

  @Test("Without connectionKept the reset text is unchanged")
  func resetMessageUnchanged() {
    #expect(
      DatabaseError.queryCancelled(pendingCount: 0, userTxRolledBack: false)
        .localizedDescription == Self.resetText)
    #expect(
      DatabaseError.queryCancelled(pendingCount: 2, userTxRolledBack: true)
        .localizedDescription
        == Self.resetText + " 2 pending changes were rolled back. "
        + "Your open transaction was rolled back.")
  }

  /// Only engines with transactions: without them (MongoDB) Protected mode never holds a
  /// pending change, and the gate refuses the write this test stages.
  @Test(
    "Cancel with one pending Protected change builds the engine's record",
    .timeLimit(.minutes(1)),
    arguments: DatabaseType.allCases.filter { $0.capabilities.supportsTransactions })
  func recordPerEngine(type: DatabaseType) async throws {
    let strategy = type.capabilities.cancelStrategy
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: strategy), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    // In-memory and read-only: no file grant for SQLite / DuckDB
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    #expect(await connection.transactionSnapshot().pending.count == 1)

    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: protected)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let interrupts = strategy == .interrupt
    // The fake's close does not end its slow read: end it as the server would
    if !interrupts { await session.interrupt() }
    let error = await #expect(throws: DatabaseError.self) { try await running.value }

    let generation = await connection.batchCancellationGeneration
    let kept = type.interruptKeepsTransaction
    let expected = QueryCancelRecord(
      epoch: status.epoch, pendingCount: kept ? 0 : 1, userTxRolledBack: false,
      interruptGeneration: interrupts ? generation : nil, connectionKept: kept)
    #expect(await connection.lastCancel == expected)
    let message = error?.localizedDescription ?? ""
    #expect(message == expected.error.localizedDescription)
    if kept {
      #expect(message == "Query cancelled. The connection was kept.")
    } else {
      #expect(message == Self.resetText + " 1 pending change was rolled back.")
    }
    await connection.disconnect()
  }
}
