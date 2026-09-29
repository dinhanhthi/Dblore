// SchemaLoadPerformanceTests.swift
// Catalog query counter (`catalogQueryCount`), the constant number of catalog queries a schema
// load sends (7 list queries + 1 bulk columns query, independent of table count), and the bulk
// pg_catalog fetchers (fetchTables / fetchViews / fetchAllColumns) against the docker test database
// (TEST_DB_* env, port 5435 in CI/autopilot). Each test only asserts on its own uniquely named
// schema because other suites mutate the shared database in parallel.

import Foundation
import Testing

@testable import Dblore

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

  /// The fetch sequence of `WorkspaceManager.loadDatabaseSchema`: 7 list queries + 1 bulk columns
  /// query. Returns the tables of `schema` (filtered, so parallel suites cannot change the result).
  private func runSchemaLoadSequence(
    _ manager: DatabaseConnectionManager, schema: String
  ) async throws -> [DatabaseTable] {
    let tables = try await manager.fetchTables().filter { $0.schema == schema }
    _ = try await manager.fetchViews()
    _ = try await manager.fetchFunctions()
    _ = try await manager.fetchProcedures()
    _ = try await manager.fetchUsers()
    _ = try await manager.fetchRoles()
    _ = try await manager.fetchForeignKeys()
    _ = try await manager.fetchAllColumns()
    return tables
  }

  /// Runs `body` with a fresh, uniquely named schema that is dropped on every path.
  private func withSchema(
    _ schema: String,
    _ body: @MainActor (DatabaseConnectionManager, String) async throws -> Void
  ) async throws {
    let manager = try await connect()
    _ = try await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    _ = try await manager.executeInternal("CREATE SCHEMA \(schema)")
    do {
      try await body(manager, schema)
    } catch {
      _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
      await manager.disconnect()
      throw error
    }
    _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await manager.disconnect()
  }

  private func columns(
    _ manager: DatabaseConnectionManager, _ schema: String, _ relation: String
  ) async throws -> [DatabaseColumn] {
    try await manager.fetchAllColumns()["\(schema).\(relation)"] ?? []
  }

  @Test("catalog counter counts each catalog query")
  func catalogCounterCountsEachQuery() async throws {
    let manager = try await connect()
    await manager.resetCatalogQueryCount()
    _ = try await manager.fetchTables()
    #expect(await manager.catalogQueryCount == 1)
    await manager.disconnect()
  }

  @Test("schema load sends exactly 8 catalog queries for 1 and for 12 tables")
  func schemaLoadSendsExactlyEightQueries() async throws {
    var results: [(tables: Int, count: Int)] = []
    try await withSchema(Self.testSchema) { manager, schema in
      func measure() async throws -> (tables: Int, count: Int) {
        await manager.resetCatalogQueryCount()
        let tables = try await runSchemaLoadSequence(manager, schema: schema)
        return (tables.count, await manager.catalogQueryCount)
      }
      _ = try await manager.executeInternal("CREATE TABLE \(schema).t1 (id int PRIMARY KEY, v int)")
      results.append(try await measure())
      for index in 2...12 {
        _ = try await manager.executeInternal(
          "CREATE TABLE \(schema).t\(index) (id int PRIMARY KEY, v int)")
      }
      results.append(try await measure())
    }
    for result in results {
      let line = "SCHEMA_LOAD_QUERY_COUNT tables=\(result.tables) count=\(result.count)"
      print(line)
      // The app-hosted test runner does not forward stdout to xcodebuild
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    #expect(results.map(\.tables) == [1, 12])
    #expect(results.map(\.count) == [8, 8])
  }

  @Test("table named with a quote gets its columns")
  func quotedNamesGetColumns() async throws {
    try await withSchema("perf_quote_names_test") { manager, schema in
      _ = try await manager.executeInternal(
        "CREATE TABLE \(schema).\"we\"\"ird\" (\"c\"\"ol\" int NOT NULL)")
      let tables = try await manager.fetchTables().filter { $0.schema == schema }
      #expect(tables.map(\.name) == ["we\"ird"])
      let cols = try await columns(manager, schema, "we\"ird")
      #expect(cols.map(\.name) == ["c\"ol"])
      #expect(cols.first?.type == "INTEGER")
    }
  }

  @Test("estimate is nil for a fresh table and non-nil after ANALYZE")
  func rowEstimate() async throws {
    try await withSchema("perf_row_estimate_test") { manager, schema in
      _ = try await manager.executeInternal("CREATE TABLE \(schema).fresh (id int)")
      let version = try await manager.executeInternal(
        "SELECT current_setting('server_version_num')")
      var versionNum = 0
      if case .string(let text) = version.rows[0][0] { versionNum = Int(text) ?? 0 }
      @MainActor func estimate() async throws -> Int? {
        let tables = try await manager.fetchTables()
        for table in tables where table.schema == schema && table.name == "fresh" {
          return table.rowCount
        }
        return nil
      }
      if versionNum >= 140000 {
        #expect(try await estimate() == nil)
      }
      _ = try await manager.executeInternal(
        "INSERT INTO \(schema).fresh SELECT generate_series(1, 25)")
      _ = try await manager.executeInternal("ANALYZE \(schema).fresh")
      #expect(try await estimate() == 25)
    }
  }

  @Test("PK / unique / identity / nullable flags and type strings")
  func columnFlagsAndTypes() async throws {
    try await withSchema("perf_column_flags_test") { manager, schema in
      _ = try await manager.executeInternal(
        """
        CREATE TABLE \(schema).flags (
          id int GENERATED ALWAYS AS IDENTITY,
          tenant int NOT NULL,
          email text UNIQUE,
          price numeric(10,2) NOT NULL,
          name varchar(255),
          created timestamptz,
          tags int[],
          PRIMARY KEY (id, tenant)
        )
        """)
      let cols = try await columns(manager, schema, "flags")
      #expect(cols.map(\.name) == ["id", "tenant", "email", "price", "name", "created", "tags"])
      let byName = Dictionary(uniqueKeysWithValues: cols.map { ($0.name, $0) })
      #expect(byName["id"]?.isPrimaryKey == true)
      #expect(byName["id"]?.isIdentity == true)
      #expect(byName["id"]?.isNullable == false)
      #expect(byName["tenant"]?.isPrimaryKey == true)
      #expect(byName["tenant"]?.isNullable == false)
      #expect(byName["email"]?.isUnique == true)
      #expect(byName["email"]?.isPrimaryKey == false)
      #expect(byName["email"]?.isNullable == true)
      #expect(byName["name"]?.isUnique == false)
      #expect(byName["price"]?.type == "NUMERIC(10,2)")
      #expect(byName["name"]?.type == "CHARACTER VARYING(255)")
      #expect(byName["created"]?.type == "TIMESTAMP W TZ")
      #expect(byName["tags"]?.type == "INTEGER[]")
    }
  }

  @Test("views get columns and materialized views are not listed")
  func viewsAndMaterializedViews() async throws {
    try await withSchema("perf_views_test") { manager, schema in
      _ = try await manager.executeInternal("CREATE TABLE \(schema).base (id int, v text)")
      _ = try await manager.executeInternal(
        "CREATE VIEW \(schema).vw AS SELECT id, v FROM \(schema).base")
      _ = try await manager.executeInternal(
        "CREATE MATERIALIZED VIEW \(schema).mv AS SELECT id FROM \(schema).base")
      let views = try await manager.fetchViews().filter { $0.schema == schema }
      #expect(views.map(\.name) == ["vw"])
      #expect(views.first?.definition == nil)
      #expect(try await columns(manager, schema, "vw").map(\.name) == ["id", "v"])
      #expect(
        try await manager.fetchTables().filter { $0.schema == schema }.map(\.name) == ["base"])
    }
  }

  @Test("fetchTables matches information_schema.tables BASE TABLE in its own schema")
  func tablesMatchInformationSchema() async throws {
    try await withSchema("perf_info_schema_test") { manager, schema in
      _ = try await manager.executeInternal("CREATE TABLE \(schema).a (id int)")
      _ = try await manager.executeInternal("CREATE TABLE \(schema).b (id int)")
      _ = try await manager.executeInternal(
        "CREATE TABLE \(schema).p (id int) PARTITION BY RANGE (id)")
      _ = try await manager.executeInternal("CREATE VIEW \(schema).v AS SELECT 1 AS x")
      let result = try await manager.executeInternal(
        """
        SELECT table_name::text FROM information_schema.tables
        WHERE table_schema = '\(schema)' AND table_type = 'BASE TABLE' ORDER BY table_name
        """)
      let expected: [String] = result.rows.compactMap {
        if case .string(let text) = $0[0] { return text }
        return nil
      }
      let actual = try await manager.fetchTables().filter { $0.schema == schema }.map(\.name)
      #expect(expected == ["a", "b", "p"])
      #expect(actual == expected)
    }
  }

  // MARK: - Visibility parity with information_schema

  private func names(_ result: QueryResult) -> [String] {
    result.rows.compactMap {
      if case .string(let text) = $0[0] { return text }
      return nil
    }
  }

  @Test("a role with column-level or DELETE-only grants sees what information_schema shows")
  func lowPrivilegeRoleVisibility() async throws {
    let unique = UUID().uuidString.prefix(8).lowercased()
    let schema = "perf_priv_\(unique)"
    let role = "perf_lowpriv_\(unique)"
    let admin = try await connect()
    var roleManager: DatabaseConnectionManager?
    do {
      _ = try await admin.executeInternal("CREATE ROLE \(role) LOGIN PASSWORD 'pw_\(unique)'")
      _ = try await admin.executeInternal("CREATE SCHEMA \(schema)")
      _ = try await admin.executeInternal("CREATE TABLE \(schema).t_col (id int, a int, b int)")
      _ = try await admin.executeInternal("CREATE TABLE \(schema).t_del (id int, a int)")
      _ = try await admin.executeInternal("GRANT USAGE ON SCHEMA \(schema) TO \(role)")
      _ = try await admin.executeInternal("GRANT SELECT (id) ON \(schema).t_col TO \(role)")
      _ = try await admin.executeInternal("GRANT DELETE ON \(schema).t_del TO \(role)")

      var roleConfig = Self.config()
      roleConfig.username = role
      roleConfig.password = "pw_\(unique)"
      let manager = DatabaseConnectionManager()
      try await manager.connect(config: roleConfig)
      roleManager = manager

      let all = try await manager.fetchAllColumns()
      #expect(all["\(schema).t_col"]?.map(\.name) == ["id"])
      let infoColumns = names(
        try await manager.executeInternal(
          """
          SELECT table_name::text || '.' || column_name::text FROM information_schema.columns
          WHERE table_schema = '\(schema)' ORDER BY 1
          """))
      let ours = all.filter { $0.key.hasPrefix("\(schema).") }
        .flatMap { entry in
          entry.value.map { "\(entry.key.dropFirst(schema.count + 1)).\($0.name)" }
        }
        .sorted()
      #expect(ours == infoColumns)
      #expect(all["\(schema).t_del"] == nil)

      let infoTables = names(
        try await manager.executeInternal(
          """
          SELECT table_name::text FROM information_schema.tables
          WHERE table_schema = '\(schema)' AND table_type = 'BASE TABLE' ORDER BY 1
          """))
      let tables = try await manager.fetchTables().filter { $0.schema == schema }.map(\.name)
      #expect(tables == infoTables)
    } catch {
      await cleanUpRole(admin, roleManager, role: role, schema: schema)
      throw error
    }
    await cleanUpRole(admin, roleManager, role: role, schema: schema)
  }

  private func cleanUpRole(
    _ admin: DatabaseConnectionManager, _ roleManager: DatabaseConnectionManager?,
    role: String, schema: String
  ) async {
    await roleManager?.disconnect()
    _ = try? await admin.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    _ = try? await admin.executeInternal("DROP OWNED BY \(role)")
    _ = try? await admin.executeInternal("DROP ROLE IF EXISTS \(role)")
    await admin.disconnect()
  }

  @Test("other sessions' temp tables are hidden, the own session's are listed")
  func temporaryTables() async throws {
    let unique = UUID().uuidString.prefix(8).lowercased()
    let otherTemp = "perf_tmp_other_\(unique)"
    let ownTemp = "perf_tmp_own_\(unique)"
    let manager = try await connect()
    let other = try await connect()
    defer { Task { await other.disconnect() } }
    do {
      _ = try await other.executeInternal("CREATE TEMP TABLE \(otherTemp) (id int)")
      _ = try await manager.executeInternal("CREATE TEMP TABLE \(ownTemp) (id int)")

      let tables = try await manager.fetchTables().map(\.name)
      #expect(!tables.contains(otherTemp))
      #expect(tables.contains(ownTemp))
      let columns = try await manager.fetchAllColumns()
      #expect(!columns.keys.contains { $0.hasSuffix(".\(otherTemp)") })
      #expect(columns.keys.contains { $0.hasSuffix(".\(ownTemp)") })
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  // MARK: - WorkspaceManager.loadDatabaseSchema (real path)

  @Test("loadDatabaseSchema sends 8 catalog queries and attaches columns and estimates")
  func workspaceLoadSchema() async throws {
    let schema = "perf_ws_load_test"
    let admin = try await connect()
    _ = try await admin.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    _ = try await admin.executeInternal("CREATE SCHEMA \(schema)")
    let workspace = WorkspaceManager(workspace: Workspace())
    do {
      try await workspace.connect(config: Self.config(), globalSafeMode: .silent)
      let version = try await admin.executeInternal("SELECT current_setting('server_version_num')")
      var versionNum = 0
      if case .string(let text) = version.rows[0][0] { versionNum = Int(text) ?? 0 }

      func load() async -> (count: Int, tables: [DatabaseTable]) {
        await workspace.connectionManager.resetCatalogQueryCount()
        await workspace.loadDatabaseSchema()
        let count = await workspace.connectionManager.catalogQueryCount
        return (count, workspace.databaseTables.filter { $0.schema == schema })
      }

      _ = try await admin.executeInternal(
        "CREATE TABLE \(schema).t1 (id int PRIMARY KEY, v text NOT NULL)")
      let one = await load()
      #expect(one.count == 8)
      #expect(one.tables.map(\.name) == ["t1"])
      #expect(one.tables.first?.columns.map(\.name) == ["id", "v"])
      #expect(one.tables.first?.columns.map(\.isPrimaryKey) == [true, false])
      if versionNum >= 140000 { #expect(one.tables.first?.rowCount == nil) }

      for index in 2...12 {
        _ = try await admin.executeInternal(
          "CREATE TABLE \(schema).t\(index) (id int PRIMARY KEY, v text NOT NULL)")
      }
      let twelve = await load()
      #expect(twelve.count == 8)
      #expect(twelve.tables.count == 12)
      for table in twelve.tables {
        #expect(table.columns.map(\.name) == ["id", "v"])
        #expect(table.columns.first?.isPrimaryKey == true)
      }

      _ = try await admin.executeInternal(
        "INSERT INTO \(schema).t1 SELECT g, 'x' FROM generate_series(1, 25) g")
      _ = try await admin.executeInternal("ANALYZE \(schema).t1")
      let analyzed = await load()
      #expect(analyzed.tables.first { $0.name == "t1" }?.rowCount == 25)
    } catch {
      Issue.record(error)
    }
    await workspace.disconnect(resolution: .rollback)
    _ = try? await admin.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await admin.disconnect()
  }
}
