// MCPReadOnlySessionTests.swift
// MCP sessions: every PostgreSQL / MySQL query runs inside a read-only transaction that is
// always rolled back, SQLite opens read-only, DuckDB is refused.

import Foundation
import Testing

@testable import Dblore

/// Records the config of every session it builds, then delegates to a fake factory.
private final class ConfigRecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let fake: FakeDatabaseSessionFactory
  private let lock = NSLock()
  private var recorded: [ConnectionConfig] = []

  init(_ fake: FakeDatabaseSessionFactory) {
    self.fake = fake
  }

  var configs: [ConnectionConfig] {
    lock.withLock { recorded }
  }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    lock.withLock { recorded.append(config) }
    return fake.makeSession(config: config)
  }
}

@MainActor
@Suite("MCP read-only sessions")
struct MCPReadOnlySessionTests {
  nonisolated static let wrapped: [(DatabaseType, String)] = [
    (.postgresql, "BEGIN TRANSACTION READ ONLY"),
    (.mysql, "START TRANSACTION READ ONLY"),
  ]

  private func config(_ type: DatabaseType) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  private func fakeFactory() -> FakeDatabaseSessionFactory {
    FakeDatabaseSessionFactory(
      capabilities: .contract(), rows: [[.int(1)], [.int(2)], [.int(3)]], failingQuery: "boom")
  }

  private func session(
    _ type: DatabaseType, inner: FakeDatabaseSessionFactory
  ) async throws -> any DatabaseSession {
    try await MCPReadOnlySessionFactory(inner: inner).makeSession(config: config(type))
  }

  @Test("A query read to the end runs between BEGIN READ ONLY and ROLLBACK", arguments: wrapped)
  func wrapsFullRead(type: DatabaseType, begin: String) async throws {
    let inner = fakeFactory()
    let session = try await session(type, inner: inner)
    let source = try await session.query("SELECT 1", binds: [])
    var count = 0
    for try await _ in source.rows { count += 1 }
    #expect(count == 3)
    #expect(inner.statements == [begin, "SELECT 1", "ROLLBACK"])
  }

  @Test("A failing query is rolled back", arguments: wrapped)
  func rollsBackOnError(type: DatabaseType, begin: String) async throws {
    let inner = fakeFactory()
    let session = try await session(type, inner: inner)
    await #expect(throws: FakeQueryError.self) {
      _ = try await session.query("SELECT boom", binds: [])
    }
    #expect(inner.statements == [begin, "SELECT boom", "ROLLBACK"])
  }

  @Test(
    "A read stopped early is rolled back before the next query starts", arguments: wrapped)
  func rollsBackOnEarlyStop(type: DatabaseType, begin: String) async throws {
    let inner = fakeFactory()
    let session = try await session(type, inner: inner)
    do {
      let source = try await session.query("SELECT 1", binds: [])
      for try await _ in source.rows { break }
    }
    let next = try await session.query("SELECT 2", binds: [])
    for try await _ in next.rows {}
    #expect(
      inner.statements == [begin, "SELECT 1", "ROLLBACK", begin, "SELECT 2", "ROLLBACK"])
  }

  @Test(
    "A failed BEGIN does not block the next query", .timeLimit(.minutes(1)), arguments: wrapped)
  func failedBeginDoesNotWedge(type: DatabaseType, begin: String) async throws {
    let inner = fakeFactory()
    let session = try await session(type, inner: inner)
    inner.sessions.first?.failNextCommand(containing: begin)
    await #expect(throws: FakeQueryError.self) {
      _ = try await session.query("SELECT 1", binds: [])
    }
    let next = try await session.query("SELECT 2", binds: [])
    for try await _ in next.rows {}
    #expect(inner.statements == [begin, begin, "SELECT 2", "ROLLBACK"])
  }

  @Test(
    "A failed ROLLBACK closes the session and the manager reports it lost",
    .timeLimit(.minutes(1)))
  func failedRollbackClosesSession() async throws {
    let inner = fakeFactory()
    let manager = DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(inner: inner))
    try await manager.connect(config: config(.mysql))
    inner.sessions.first?.failNextCommand(containing: "ROLLBACK")
    _ = try await manager.execute(
      userSQL: "SELECT 1", policy: ProtectionPolicy(protectionLevel: .readOnly), maxRows: 10)
    #expect(inner.sessions.first?.didClose == true)
    while await manager.isConnected { await Task.yield() }
  }

  @Test("Commands and server cursors are refused before anything is sent", arguments: wrapped)
  func refusesCommandsAndCursors(type: DatabaseType, begin: String) async throws {
    let inner = fakeFactory()
    let session = try await session(type, inner: inner)
    await #expect(throws: MCPConnectionError.commandRefused) {
      _ = try await session.command("DELETE FROM t", binds: [])
    }
    await #expect(throws: MCPConnectionError.cursorRefused) {
      _ = try await session.openCursor("SELECT 1", binds: [])
    }
    #expect(inner.statements.isEmpty)
  }

  @Test("A connection manager connects and reads through the decorator")
  func managerReadsInsideReadOnlyTransaction() async throws {
    let inner = fakeFactory()
    let manager = DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(inner: inner))
    try await manager.connect(config: config(.postgresql))
    let result = try await manager.execute(
      userSQL: "SELECT 1", policy: ProtectionPolicy(protectionLevel: .readOnly), maxRows: 10)
    #expect(result.rows.count == 3)
    #expect(inner.statements == ["BEGIN TRANSACTION READ ONLY", "SELECT 1", "ROLLBACK"])
  }

  @Test("A PostgreSQL read cut by the row cap reconnects on a fresh read-only session")
  func postgresCappedReadResetsSession() async throws {
    let inner = fakeFactory()
    let manager = DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(inner: inner))
    try await manager.connect(config: config(.postgresql))
    let result = try await manager.execute(
      userSQL: "SELECT 1", policy: ProtectionPolicy(protectionLevel: .readOnly), maxRows: 2)
    #expect(result.truncated && result.sessionReset)
    let sessions = inner.sessions
    #expect(sessions.count == 2)
    #expect(sessions.first?.didClose == true)
    // The ROLLBACK after the close races it; the closed session ends the transaction anyway
    #expect(sessions.first?.statements.prefix(2) == ["BEGIN TRANSACTION READ ONLY", "SELECT 1"])
    #expect(sessions.last?.statements.isEmpty == true)
  }

  @Test("A MySQL read cut by the row cap is rolled back before the next query")
  func mysqlCappedReadKeepsSession() async throws {
    let inner = fakeFactory()
    let manager = DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(inner: inner))
    try await manager.connect(config: config(.mysql))
    let policy = ProtectionPolicy(protectionLevel: .readOnly)
    let capped = try await manager.execute(userSQL: "SELECT 1", policy: policy, maxRows: 2)
    _ = try await manager.execute(userSQL: "SELECT 2", policy: policy, maxRows: 10)
    #expect(capped.truncated && !capped.sessionReset)
    #expect(inner.sessions.count == 1)
    let begin = "START TRANSACTION READ ONLY"
    #expect(
      inner.statements == [
        begin, "SELECT 1", "ROLLBACK", begin, "SELECT 2", "ROLLBACK",
      ])
  }

  @Test("SQLite opens a read-only copy of the config and sends no transaction")
  func sqliteOpensReadOnly() async throws {
    let recording = ConfigRecordingFactory(fakeFactory())
    var sqlite = config(.sqlite)
    sqlite.readOnlyFile = false
    let session = try await MCPReadOnlySessionFactory(inner: recording).makeSession(
      config: sqlite)
    let source = try await session.query("SELECT 1", binds: [])
    for try await _ in source.rows {}
    #expect(recording.configs.map(\.readOnlyFile) == [true])
    #expect(recording.fake.statements == ["SELECT 1"])
  }

  @Test("DuckDB is refused without building a session")
  func duckdbRefused() async throws {
    let inner = fakeFactory()
    await #expect(throws: MCPConnectionError.duckDBNotSupported) {
      _ = try await MCPReadOnlySessionFactory(inner: inner).makeSession(config: config(.duckdb))
    }
    #expect(inner.sessions.isEmpty)
  }
}
