// DatabaseSessionContractTests.swift
// The connection actor talks to `any DatabaseSession`. These tests use a fake session and no
// server (except the gated DuckDB test and a temp SQLite file for interrupt cancel): the gate
// and Protected-mode confirmation stay on the actor, ahead of any session call.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Session Contract")
struct DatabaseSessionContractTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  private func config(
    protectionLevel: ConnectionProtectionLevel = .none, safeMode: SafeMode? = .silent,
    protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
      protectionLevel: protectionLevel, safeMode: safeMode, protectedMode: protectedMode)
  }

  private func manager(
    _ factory: FakeDatabaseSessionFactory
  ) -> DatabaseConnectionManager {
    DatabaseConnectionManager(sessionFactory: factory)
  }

  @Test("The gate blocks a protected statement until it is confirmed")
  @MainActor
  func gateBlocksUntilConfirmed() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let connection = manager(factory)
    try await connection.connect(config: config())

    let blocked = await #expect(throws: DatabaseError.self) {
      try await connection.execute(
        userSQL: "DELETE FROM accounts",
        policy: ProtectionPolicy(protectionLevel: .readOnly))
    }
    guard case .blockedByProtection = blocked else {
      Issue.record("Expected blockedByProtection, got \(String(describing: blocked))")
      return
    }
    #expect(factory.statements.isEmpty)

    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = connection
    viewModel.connectionState = .connected
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM accounts WHERE id = 1"
    viewModel.notebook.connectionConfig = config(protectionLevel: .readOnly, safeMode: .alertRead)
    #expect(viewModel.protectionBlockMessage(for: viewModel.notebook.cells[0].content) != nil)
    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(factory.statements.isEmpty)

    viewModel.notebook.connectionConfig = config(safeMode: .alertRead)
    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(factory.statements.isEmpty)

    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()
    #expect(factory.statements.contains { $0.contains("DELETE FROM accounts WHERE id = 1") })
  }

  @Test("Reconnect bumps the connection epoch and swaps the session")
  func epochBumpsOnReconnect() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let connection = manager(factory)
    try await connection.connect(config: config())
    let epoch = await connection.connectionEpoch
    let first = try #require(factory.sessions.first)

    try await connection.connect(config: config())

    #expect(await connection.connectionEpoch > epoch)
    #expect(await connection.isConnected)
    #expect(factory.sessions.count == 2)
    #expect(first.didClose)
    #expect(factory.sessions[1].didOpen)
    #expect(factory.sessions[1] !== first)
  }

  @Test("A connectionLost close event publishes the session-loss event")
  func connectionLostPublishesSessionLoss() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let connection = manager(factory)
    try await connection.connect(config: config())
    let session = try #require(factory.sessions.first)
    let events = connection.sessionEvents
    let waiter = Task {
      var iterator = events.makeAsyncIterator()
      return await iterator.next()
    }

    session.emit(.connectionLost)
    let event = await waiter.value

    let loss = try #require(event)
    #expect(loss.message.contains("The connection to the database was lost."))
    #expect(loss.message.contains("Reconnect to continue."))
    #expect(await connection.lastSessionLoss == loss)
    #expect(await connection.isConnected == false)
  }

  @Test("Cancel calls interrupt when the session's cancel strategy is interrupt")
  func cancelCallsInterrupt() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = manager(factory)
    try await connection.connect(config: config())
    let session = try #require(factory.sessions.first)

    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)

    #expect(outcome == .cancelled)
    #expect(session.interruptCount == 1)
    #expect(factory.sessions.count == 1)
    #expect(await connection.connectionEpoch == status.epoch)
    let error = await #expect(throws: DatabaseError.self) { try await running.value }
    guard case .queryCancelled = error else {
      Issue.record("Expected queryCancelled, got \(String(describing: error))")
      return
    }
  }

  @Test("A capped read resets outside a transaction and uses a cursor inside one")
  func cappedReadWithAndWithoutTransaction() async throws {
    let columns = [ColumnInfo(name: "id", type: "INTEGER")]
    let rows = (1...5).map { [CellValue.int($0)] }
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(supportsServerCursor: true), columns: columns, rows: rows)
    let connection = manager(factory)
    try await connection.connect(config: config())
    let before = await connection.connectionEpoch

    let capped = try await connection.execute(
      userSQL: "SELECT * FROM t", policy: open, maxRows: 2)
    #expect(capped.rows.count == 2)
    #expect(capped.truncated)
    #expect(capped.sessionReset)
    #expect(await connection.connectionEpoch > before)
    #expect(await connection.isConnected)
    let first = try #require(factory.sessions.first)
    #expect(first.queries == ["SELECT * FROM t"])
    #expect(first.openCursorCount == 0)
    #expect(first.didClose)
    #expect(factory.sessions.count == 2)

    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    let epoch = await connection.connectionEpoch
    let inside = try await connection.execute(
      userSQL: "SELECT * FROM t", policy: open, maxRows: 2)
    let current = try #require(factory.sessions.last)
    #expect(inside.rows.count == 2)
    #expect(inside.truncated)
    #expect(inside.sessionReset == false)
    #expect(await connection.connectionEpoch == epoch)
    #expect(await connection.cursorReadCount == 1)
    #expect(current.openCursorCount == 1)
    #expect(current.fetchCounts == [3])
    #expect(current.closeCursorCount == 1)
    #expect(current.queries.isEmpty)
    #expect(current.statements.contains("SELECT * FROM t"))
  }

  @Test("Protected commit and rollback send no SQL until confirmed")
  func protectedCommitAndRollbackWaitUntilConfirmed() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let connection = manager(factory)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    try await connection.connect(config: config(protectedMode: true))

    _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: protected)
    #expect(factory.statements.contains("BEGIN"))
    #expect(factory.statements.contains("INSERT INTO t VALUES (1)"))
    #expect(factory.statements.filter { $0 == "INSERT INTO t VALUES (1)" }.count == 1)
    #expect(!factory.statements.contains("COMMIT"))
    #expect(!factory.statements.contains("ROLLBACK"))

    let status = await connection.transactionStatus()
    await #expect(throws: DatabaseError.self) {
      try await connection.commitAppTransaction(expectedGeneration: status.generation &+ 99)
    }
    #expect(!factory.statements.contains("COMMIT"))

    await connection.setTransactionEndHook { kind in
      switch kind {
      case .commit:
        #expect(!factory.statements.contains("COMMIT"))
      case .rollback:
        #expect(!factory.statements.contains("ROLLBACK"))
      }
    }
    try await connection.commitAppTransaction(expectedGeneration: status.generation)
    #expect(factory.statements.contains("COMMIT"))
    #expect(factory.statements.filter { $0 == "INSERT INTO t VALUES (1)" }.count == 1)

    _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    #expect(!factory.statements.contains("ROLLBACK"))
    try await connection.rollbackAppTransaction()
    #expect(factory.statements.contains("ROLLBACK"))
    #expect(factory.statements.filter { $0 == "UPDATE t SET a = 1" }.count == 1)
  }

  @Test(
    "DuckDB behind the actor: a capped read keeps the session and cancel interrupts",
    .requiresDuckDBPlugin)
  func duckDBSessionThroughActor() async throws {
    let connection = DatabaseConnectionManager(sessionFactory: DuckDBContractFactory())
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        safeMode: .silent, protectedMode: false, statementTimeoutSeconds: 30))
    _ = try await connection.execute(
      userSQL: "CREATE TEMP TABLE kept AS SELECT 1 AS id", policy: open)
    let epoch = await connection.connectionEpoch

    let capped = try await connection.execute(
      userSQL: "SELECT * FROM range(100000)", policy: open, maxRows: 10)
    #expect(capped.rows.count == 10)
    #expect(capped.truncated)
    #expect(capped.sessionReset == false)
    #expect(await connection.connectionEpoch == epoch)
    let kept = try await connection.execute(userSQL: "SELECT id FROM kept", policy: open)
    #expect(kept.rows == [[.int(1)]])

    let running = Task {
      try await connection.execute(
        userSQL:
          "SELECT count(*) FROM range(100000000000) t(a) WHERE md5(a::VARCHAR) LIKE 'xyz%'",
        policy: open)
    }
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
    guard case .queryCancelled = error else {
      Issue.record("Expected queryCancelled, got \(String(describing: error))")
      return
    }
    #expect(await connection.connectionEpoch == epoch)
    // The interrupted session stays open with its temp table, and the next script runs.
    let after = try await connection.execute(userSQL: "SELECT id FROM kept", policy: open)
    #expect(after.rows == [[.int(1)]])
    await connection.disconnect()
  }

  @Test(
    "An interrupt cancel stops only the running script: the next one on the connection runs",
    .timeLimit(.minutes(1)))
  func interruptCancelDoesNotPoisonTheConnection() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-interrupt-cancel-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let connection = DatabaseConnectionManager()
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, safeMode: .silent, protectedMode: false,
        statementTimeoutSeconds: 10))
    let epoch = await connection.connectionEpoch

    let running = Task {
      try await connection.execute(
        userSQL: """
          WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 1000000000)
          SELECT max(x) FROM c
          """,
        policy: open)
    }
    var status = await connection.runningStatementStatus()
    while !status.inFlight {
      try await Task.sleep(for: .milliseconds(10))
      status = await connection.runningStatementStatus()
    }
    // Repeat: an interrupt that lands before SQLite starts the statement does nothing.
    while await connection.runningStatementStatus().inFlight {
      _ = await connection.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      try await Task.sleep(for: .milliseconds(25))
    }
    let error = await #expect(throws: DatabaseError.self) { try await running.value }
    guard case .queryCancelled = error else {
      Issue.record("Expected queryCancelled, got \(String(describing: error))")
      return
    }
    #expect(await connection.connectionEpoch == epoch)

    let next = try await connection.execute(userSQL: "SELECT 1", policy: open)
    #expect(next.rows == [[.int(1)]])
    await connection.disconnect()
  }
}

/// Real DuckDB sessions on the dev plugin, for the actor contract.
private struct DuckDBContractFactory: DatabaseSessionFactory {
  func makeSession(config: ConnectionConfig) throws -> any DatabaseSession {
    DuckDBSession(config: config) { try DuckDBTestPlugin.library() }
  }
}
