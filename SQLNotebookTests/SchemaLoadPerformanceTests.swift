// SchemaLoadPerformanceTests.swift
// Catalog query counter (`catalogQueryCount`) and the number of catalog queries a schema load
// sends, by table count. Records today's O(N) behavior; the count assert is replaced in Phase 3.
// Against the docker test database (TEST_DB_* env, port 5435 in CI/autopilot).

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Schema Load Performance - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct SchemaLoadPerformanceTests {
  private static let testSchema = "perf_schema_load_test"

  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: false,
      statementTimeoutSeconds: 45
    )
  }

  private func connect() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    return manager
  }

  /// The fetch sequence of `WorkspaceManager.loadDatabaseSchema`. The 7 list fetches are a constant
  /// number of queries; the per-table/per-view loops only cover `testSchema`, so parallel suites
  /// creating or dropping objects in the shared database cannot change the count.
  /// Returns the number of tables of `testSchema`.
  private func runSchemaLoadSequence(_ manager: DatabaseConnectionManager) async throws -> Int {
    let ownSchema = Self.testSchema
    let tables = try await manager.fetchTables().filter { $0.schema == ownSchema }
    let views = try await manager.fetchViews().filter { $0.schema == ownSchema }
    _ = try await manager.fetchFunctions()
    _ = try await manager.fetchProcedures()
    _ = try await manager.fetchUsers()
    _ = try await manager.fetchRoles()
    _ = try await manager.fetchForeignKeys()
    for table in tables {
      _ = try await manager.fetchColumns(tableSchema: table.schema, tableName: table.name)
      _ = try await manager.fetchRowCount(tableSchema: table.schema, tableName: table.name)
    }
    for view in views {
      _ = try await manager.fetchColumns(tableSchema: view.schema, tableName: view.name)
    }
    return tables.count
  }

  @Test("catalog counter counts each catalog query")
  func catalogCounterCountsEachQuery() async throws {
    let manager = try await connect()
    await manager.resetCatalogQueryCount()
    _ = try await manager.fetchTables()
    #expect(await manager.catalogQueryCount == 1)
    await manager.disconnect()
  }

  @Test("schema load query count by table count")
  func schemaLoadQueryCountByTableCount() async throws {
    let manager = try await connect()
    let schema = Self.testSchema
    _ = try await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    _ = try await manager.executeInternal("CREATE SCHEMA \(schema)")

    func createTables(_ range: ClosedRange<Int>) async throws {
      for index in range {
        _ = try await manager.executeInternal(
          "CREATE TABLE \(schema).t\(index) (id int PRIMARY KEY, v int)")
      }
    }
    func measure() async throws -> (tables: Int, count: Int) {
      await manager.resetCatalogQueryCount()
      let tables = try await runSchemaLoadSequence(manager)
      return (tables, await manager.catalogQueryCount)
    }

    var small: (tables: Int, count: Int) = (0, 0)
    var large: (tables: Int, count: Int) = (0, 0)
    do {
      try await createTables(1...1)
      small = try await measure()
      try await createTables(2...12)
      large = try await measure()
    } catch {
      _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
      await manager.disconnect()
      throw error
    }
    _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await manager.disconnect()

    for result in [small, large] {
      let line = "SCHEMA_LOAD_QUERY_COUNT tables=\(result.tables) count=\(result.count)"
      print(line)
      // The app-hosted test runner does not forward stdout to xcodebuild
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    #expect(small.tables == 1)
    #expect(large.tables == 12)
    // Today's behavior: 4 catalog queries per table (replaced in Phase 3)
    #expect(large.count - small.count == 4 * 11)
    #expect(large.count > small.count)
  }
}
