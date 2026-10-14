// EngineRoutingTests.swift
// Each engine gets its own catalog SQL and transaction start. DuckDB is refused with
// `engineUnavailable` while its plugin is not installed; it never falls back to PostgreSQL.

import Foundation
import Testing

@testable import Dblore

@Suite("Engine routing")
struct EngineRoutingTests {
  private func connectFake(_ type: DatabaseType) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()))
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return manager
  }

  @Test("DuckDB routes to the DuckDB introspector, never PostgreSQL catalog SQL")
  func duckdbIntrospector() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    #expect(await manager.introspector is DuckDBSchemaIntrospector)
    _ = try await manager.fetchTables()
    let catalogReads = factory.sessions.flatMap(\.queries)
    #expect(catalogReads.contains { $0.contains("duckdb_tables()") })
    #expect(!catalogReads.contains { $0.contains("pg_") })
  }

  @Test("App transactions use each engine's own BEGIN")
  func appOwnedBegin() async throws {
    #expect(try await connectFake(.postgresql).appOwnedBeginSQL == "BEGIN")
    #expect(try await connectFake(.sqlite).appOwnedBeginSQL == "BEGIN IMMEDIATE")
    #expect(try await connectFake(.duckdb).appOwnedBeginSQL == "BEGIN TRANSACTION")
    #expect(try await connectFake(.mysql).appOwnedBeginSQL == "START TRANSACTION")
  }

  /// Statements sent by an app-owned BEGIN on a fake session whose capabilities claim brakes.
  private func appBeginStatements(_ type: DatabaseType) async throws -> [String] {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let before = factory.statements.count
    try await manager.beginAppTransaction(caller: nil)
    return Array(factory.statements.dropFirst(before))
  }

  @Test("PostgreSQL suspends the idle-in-transaction timeout after the app BEGIN")
  func postgresqlSuspendsIdleTimeout() async throws {
    #expect(
      try await appBeginStatements(.postgresql) == [
        "BEGIN", "SET LOCAL idle_in_transaction_session_timeout = 0",
      ])
  }

  @Test("MySQL sends nothing after the app BEGIN: it has no idle-in-transaction timeout")
  func mysqlSendsNoIdleTimeoutSuspension() async throws {
    #expect(try await appBeginStatements(.mysql) == ["START TRANSACTION"])
  }

  @Test("MySQL routes to the MySQL introspector bound to the connected database")
  func mysqlIntrospector() async throws {
    let manager = try await connectFake(.mysql)
    let introspector = try #require(await manager.introspector as? MySQLSchemaIntrospector)
    #expect(introspector.database == "db")
  }

  @Test("Connecting to MySQL opens a MySQL session (a closed port fails to connect)")
  func mysqlConnectRefused() async throws {
    let manager = DatabaseConnectionManager(sessionFactory: AppDatabaseSessionFactory())
    do {
      try await manager.connect(config: mysqlConfig)
      Issue.record("MySQL connect should fail")
    } catch DatabaseError.connectionFailed {}
    #expect(await manager.session == nil)
  }

  @Test("Testing a MySQL connection probes the server (a closed port fails to connect)")
  func mysqlTestConnectionRefused() async throws {
    let manager = DatabaseConnectionManager(sessionFactory: AppDatabaseSessionFactory())
    do {
      _ = try await manager.testConnection(config: mysqlConfig)
      Issue.record("MySQL test connection should fail")
    } catch DatabaseError.connectionFailed {}
  }

  private var mysqlConfig: ConnectionConfig {
    ConnectionConfig(
      databaseType: .mysql, host: "127.0.0.1", port: 1, database: "db", username: "u",
      sslMode: .disable, timeoutSeconds: 5)
  }

  /// The app factory with the DuckDB plugin not installed.
  private func managerWithoutDuckDBPlugin() -> DatabaseConnectionManager {
    DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(duckDBLibraryLoader: { nil }))
  }

  @Test("Connecting to DuckDB without its plugin fails with engineUnavailable")
  func duckdbConnectRefused() async throws {
    let manager = managerWithoutDuckDBPlugin()
    let config = ConnectionConfig(databaseType: .duckdb, host: "", database: "/tmp/x.duckdb")
    do {
      try await manager.connect(config: config)
      Issue.record("DuckDB connect should fail")
    } catch DatabaseError.engineUnavailable(let type) {
      #expect(type == .duckdb)
    }
    #expect(await manager.session == nil)
  }

  @Test("Testing a DuckDB connection without its plugin fails with engineUnavailable")
  func duckdbTestConnectionRefused() async throws {
    let manager = managerWithoutDuckDBPlugin()
    let config = ConnectionConfig(databaseType: .duckdb, host: "", database: "/tmp/x.duckdb")
    do {
      _ = try await manager.testConnection(config: config)
      Issue.record("DuckDB test connection should fail")
    } catch DatabaseError.engineUnavailable(let type) {
      #expect(type == .duckdb)
    }
  }
}
