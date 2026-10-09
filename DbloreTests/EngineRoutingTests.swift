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

  @Test("PostgreSQL routes to the PostgreSQL introspector")
  func postgresqlIntrospector() async throws {
    let manager = try await connectFake(.postgresql)
    #expect(await manager.introspector is PostgresSchemaIntrospector)
  }

  @Test("SQLite routes to the SQLite introspector")
  func sqliteIntrospector() async throws {
    let manager = try await connectFake(.sqlite)
    #expect(await manager.introspector is SQLiteSchemaIntrospector)
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

  @Test("App transactions start with BEGIN IMMEDIATE on SQLite and BEGIN elsewhere")
  func appOwnedBegin() async throws {
    #expect(try await connectFake(.postgresql).appOwnedBeginSQL == "BEGIN")
    #expect(try await connectFake(.sqlite).appOwnedBeginSQL == "BEGIN IMMEDIATE")
    #expect(try await connectFake(.duckdb).appOwnedBeginSQL == "BEGIN TRANSACTION")
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

  @Test("The error tells the user to install the plugin")
  func engineUnavailableMessage() {
    #expect(
      DatabaseError.engineUnavailable(.duckdb).errorDescription
        == "DuckDB support is not installed. Install the DuckDB plugin in Settings > Plugins.")
  }
}
