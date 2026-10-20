// MCPReadOnlyIntegrationTests.swift
// The MCP read-only layers against the docker PostgreSQL (TEST_DB_*, 5435) and MySQL 8.4 /
// MariaDB 11.4 (TEST_MYSQL_* / TEST_MARIADB_PORT, 3307 / 3308) servers. Layer 3 alone: a
// manager on `MCPReadOnlySessionFactory` sent statements the classifier calls reads, so only
// the server's read-only transaction stops their side effects (nextval, an INSERT inside a
// function; set_config is allowed by PostgreSQL and reverted by the ROLLBACK). Then the whole
// stack (`MCPToolService` over `MCPSQLReadSource` and `MCPConnectionPool`): non-read statements
// and PostgreSQL side-effect function calls are refused before sending, and nothing reaches
// the server; a PostgreSQL read cut by `max_rows` resets the session and the next one works. Fixtures are created with a
// plain manager under unique names and dropped on every path. Opt-in per engine
// (`.requiresPostgres`, `.requiresMySQL`).

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MCPReadOnlyIntegrationTests {
  typealias Server = MySQLSessionTests.Server

  private static let readOnly = ProtectionPolicy(protectionLevel: .readOnly)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - PostgreSQL, layer 3

  @Test(
    "PostgreSQL read-only session: nextval and an INSERT in a function fail, set_config reverts",
    .requiresPostgres, .timeLimit(.minutes(1)))
  func postgresSessionLayer() async throws {
    try await withPostgresFixture { schema, observer in
      let manager = Self.readOnlyManager()
      do {
        try await manager.connect(config: Self.postgresConfig())

        try await Self.expectReadOnlyFailure(
          manager, "SELECT nextval('\(schema).seq')", serverText: "read-only transaction")
        try await Self.expectReadOnlyFailure(
          manager, "SELECT \(schema).add_row()", serverText: "read-only transaction")
        #expect(try await Self.count(observer, "\(schema).items") == 0)
        // The sequence was not advanced either.
        #expect(
          try await observer.executeInternal("SELECT last_value, is_called FROM \(schema).seq")
            .rows == [[.int(1), .bool(false)]])

        let before = try await Self.applicationName(manager)
        #expect(before != "mcp-test")
        let set = try await manager.execute(
          userSQL: "SELECT set_config('application_name', 'mcp-test', false)",
          policy: Self.readOnly)
        #expect(set.rows == [[.string("mcp-test")]])
        #expect(try await Self.applicationName(manager) == before)
      } catch {
        await manager.disconnect()
        throw error
      }
      await manager.disconnect()
    }
  }

  // MARK: - PostgreSQL, tool service

  @Test(
    "PostgreSQL run_query: writes, DDL and several statements are refused before sending",
    .requiresPostgres, .timeLimit(.minutes(1)))
  func postgresToolService() async throws {
    try await withPostgresFixture { schema, observer in
      _ = try await observer.executeInternal("INSERT INTO \(schema).items (id, v) VALUES (1, 10)")
      try await withToolService(Self.postgresConfig()) { run, runCapped in
        // Positive control: the service reaches the server.
        let read = await run("SELECT v FROM \(schema).items WHERE id = 1")
        #expect(!read.isError, "\(read.text)")
        #expect(read.text.contains("10"))

        try await Self.expectRefusals(
          run, observer, schema: schema, table: "\(schema).items",
          createdTable: "\(schema).created",
          tableExists:
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '\(schema)' "
            + "AND table_name = 'created'")

        // Side-effect functions the classifier calls reads are refused by the MCP denylist.
        let refused = MCPToolError.sideEffectFunction.localizedDescription
        let lockKey = 918_273_645
        for sql in [
          "SELECT nextval('\(schema).seq')", "SELECT pg_advisory_lock(\(lockKey))",
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid()",
          "SELECT ts_rewrite('a'::tsquery, $$SELECT pg_try_advisory_lock(\(lockKey))::text::tsquery, "
            + "'b'::tsquery$$)",
        ] {
          let result = await run(sql)
          #expect(result.isError && result.text == refused, "\(sql): \(result.text)")
        }
        #expect(
          try await observer.executeInternal(
            "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = \(lockKey)"
          ).rows == [[.int(0)]])
        #expect(
          try await observer.executeInternal(
            "SELECT last_value, is_called FROM \(schema).seq"
          ).rows == [[.int(1), .bool(false)]])

        // max_rows 1 of 2 rows: the capped read resets the session, the next read still works.
        _ = try await observer.executeInternal(
          "INSERT INTO \(schema).items (id, v) VALUES (2, 20)")
        let capped = await runCapped("SELECT id FROM \(schema).items ORDER BY id", 1)
        #expect(!capped.isError, "\(capped.text)")
        #expect(capped.text.contains(#""row_count":1"#), "\(capped.text)")
        #expect(capped.text.contains(#""rows_truncated":true"#), "\(capped.text)")
        let after = await run("SELECT COUNT(*) FROM \(schema).items")
        #expect(!after.isError, "\(after.text)")
        #expect(after.text.contains("[[2]]"), "\(after.text)")
      }
    }
  }

  // MARK: - MySQL / MariaDB, layer 3

  @Test(
    "MySQL read-only session: a function that writes fails and changes nothing",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlSessionLayer(server: Server) async throws {
    try await withMySQLFixture(server) { prefix, observer in
      let manager = Self.readOnlyManager()
      do {
        try await manager.connect(config: MySQLManagerTests.config(server))

        try await Self.expectReadOnlyFailure(
          manager, "SELECT \(prefix)_add(1)", serverText: "READ ONLY")
        #expect(try await Self.count(observer, "\(prefix)_items") == 1)
        try await Self.expectReadOnlyFailure(
          manager, "SELECT \(prefix)_bump()", serverText: "READ ONLY")
        #expect(
          try await observer.executeInternal("SELECT v FROM \(prefix)_items WHERE id = 1").rows
            == [[.int(10)]])

        if server == .mariadb {
          // The gate's side-effect denylist refuses NEXTVAL, so the session gets it directly.
          await #expect(throws: DatabaseError.self) {
            try await manager.execute(
              userSQL: "SELECT NEXTVAL(\(prefix)_seq)", policy: Self.readOnly)
          }
          try await Self.expectSessionFailure(
            MySQLManagerTests.config(server), "SELECT NEXTVAL(\(prefix)_seq)",
            serverText: "READ ONLY")
          // The first value is still free.
          #expect(
            try await observer.executeInternal("SELECT NEXTVAL(\(prefix)_seq)").rows
              == [[.int(1)]])
        }

        // The session still reads after the failures.
        let read = try await manager.execute(
          userSQL: "SELECT COUNT(*) FROM \(prefix)_items", policy: Self.readOnly)
        #expect(read.rows == [[.int(1)]])
      } catch {
        await manager.disconnect()
        throw error
      }
      await manager.disconnect()
    }
  }

  // MARK: - MySQL / MariaDB, tool service

  @Test(
    "MySQL run_query: writes, DDL and several statements are refused before sending",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func mysqlToolService(server: Server) async throws {
    try await withMySQLFixture(server) { prefix, observer in
      try await withToolService(MySQLManagerTests.config(server)) { run, _ in
        let read = await run("SELECT v FROM \(prefix)_items WHERE id = 1")
        #expect(!read.isError, "\(read.text)")
        #expect(read.text.contains("10"))

        try await Self.expectRefusals(
          run, observer, schema: nil, table: "\(prefix)_items",
          createdTable: "\(prefix)_created",
          tableExists:
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name = '\(prefix)_created'")

        let write = await run("SELECT \(prefix)_add(2)")
        #expect(write.isError)
        #expect(write.text.contains("READ ONLY"), "\(write.text)")
        #expect(try await Self.count(observer, "\(prefix)_items") == 1)
      }
    }
  }

  // MARK: - Shared checks

  /// INSERT, UPDATE, CREATE TABLE and a read followed by a write are refused; the table keeps
  /// its one row (1, 10) and `createdTable` does not exist.
  private static func expectRefusals(
    _ run: (String) async -> MCPToolResult, _ observer: DatabaseConnectionManager,
    schema: String?, table: String, createdTable: String, tableExists: String
  ) async throws {
    let notRead = MCPToolError.notRead.localizedDescription
    for sql in [
      "INSERT INTO \(table) (id, v) VALUES (2, 20)",
      "UPDATE \(table) SET v = 99 WHERE id = 1",
      "DELETE FROM \(table)",
      "CREATE TABLE \(createdTable) (id INT)",
    ] {
      let refused = await run(sql)
      #expect(refused.isError, "\(sql)")
      #expect(refused.text == notRead, "\(sql): \(refused.text)")
    }
    let several = await run(
      "SELECT 1; INSERT INTO \(table) (id, v) VALUES (3, 30); CREATE TABLE \(createdTable) (id INT)"
    )
    #expect(several.isError)
    #expect(several.text == MCPToolError.multipleStatements.localizedDescription)

    #expect(
      try await observer.executeInternal("SELECT id, v FROM \(table) ORDER BY id").rows
        == [[.int(1), .int(10)]])
    #expect(try await observer.executeInternal(tableExists).rows == [[.int(0)]])
  }

  /// `sql` passes the read-only gate, reaches the server and fails there with `serverText`.
  private static func expectReadOnlyFailure(
    _ manager: DatabaseConnectionManager, _ sql: String, serverText: String
  ) async throws {
    do {
      let result = try await manager.execute(userSQL: sql, policy: readOnly)
      Issue.record("\(sql) ran in the read-only transaction: \(result.rows)")
    } catch DatabaseError.blockedByProtection {
      Issue.record("\(sql) was refused by the gate, not by the server")
    } catch {
      #expect(
        error.localizedDescription.contains(serverText),
        "\(sql): \(error.localizedDescription)")
    }
  }

  /// `sql` sent straight to a decorated session (no gate) fails with `serverText`.
  private static func expectSessionFailure(
    _ config: ConnectionConfig, _ sql: String, serverText: String
  ) async throws {
    let session = try await MCPReadOnlySessionFactory(inner: AppDatabaseSessionFactory())
      .makeSession(config: config)
    try await session.open()
    do {
      let source = try await session.query(sql, binds: [])
      var rows: [[CellValue]] = []
      for try await row in source.rows { rows.append(row) }
      Issue.record("\(sql) ran in the read-only transaction: \(rows)")
    } catch {
      let message = session.formatError(error)
      #expect(message.contains(serverText), "\(sql): \(message)")
    }
    await session.close()
  }

  private static func count(
    _ observer: DatabaseConnectionManager, _ table: String
  ) async throws
    -> Int?
  {
    let rows = try await observer.executeInternal("SELECT COUNT(*) FROM \(table)").rows
    guard case .int(let value) = rows.first?.first else { return nil }
    return value
  }

  private static func applicationName(
    _ manager: DatabaseConnectionManager
  ) async throws
    -> String?
  {
    let rows = try await manager.execute(
      userSQL: "SELECT current_setting('application_name')", policy: readOnly
    ).rows
    guard case .string(let value) = rows.first?.first else { return nil }
    return value
  }

  // MARK: - Fixtures

  /// A manager on read-only sessions, as the MCP pool builds it.
  private static func readOnlyManager() -> DatabaseConnectionManager {
    DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(inner: AppDatabaseSessionFactory()))
  }

  /// Runs `body` with `run_query` callers (default and given `max_rows`) over the real pool for
  /// `config`. The pool is closed on every path.
  private func withToolService(
    _ config: ConnectionConfig,
    _ body: (
      _ run: (String) async -> MCPToolResult,
      _ runCapped: (String, Int) async -> MCPToolResult
    ) async throws -> Void
  ) async throws {
    // The service lists entries without passwords; the pool's lookup loads it.
    let entry = ConnectionHistoryEntry(config: config)
    var withPassword = entry
    withPassword.config.password = config.password
    let saved = withPassword
    let id = entry.id
    let pool = MCPConnectionPool(entry: { $0 == id ? saved : nil })
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool), recorder: InMemoryQueryHistoryRecorder(),
      historyEnabled: { false })
    let runCapped: (String, Int) async -> MCPToolResult = { sql, maxRows in
      await service.call(
        "run_query",
        arguments: [
          "connection_id": .string(id.uuidString), "sql": .string(sql),
          "max_rows": .number(Double(maxRows)),
        ])
    }
    let run: (String) async -> MCPToolResult = { sql in
      await service.call(
        "run_query",
        arguments: ["connection_id": .string(id.uuidString), "sql": .string(sql)])
    }
    do {
      try await body(run, runCapped)
    } catch {
      await pool.closeAll()
      throw error
    }
    await pool.closeAll()
  }

  private static func postgresConfig() -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, safeMode: .silent, protectedMode: false, statementTimeoutSeconds: 45)
  }

  /// A unique schema with `items (id, v)`, `seq` and `add_row()` (INSERTs into `items`),
  /// dropped on every path.
  private func withPostgresFixture(
    _ body: (_ schema: String, _ observer: DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let schema = "mcp_ro_\(UUID().uuidString.prefix(8).lowercased())"
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.postgresConfig())
    do {
      for statement in [
        "CREATE SCHEMA \(schema)",
        "CREATE TABLE \(schema).items (id integer PRIMARY KEY, v integer)",
        "CREATE SEQUENCE \(schema).seq",
        """
        CREATE FUNCTION \(schema).add_row() RETURNS integer LANGUAGE plpgsql
        AS $$ BEGIN INSERT INTO \(schema).items (id, v) VALUES (100, 1); RETURN 1; END $$
        """,
      ] {
        _ = try await observer.executeInternal(statement)
      }
      try await body(schema, observer)
    } catch {
      _ = try? await observer.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
      await observer.disconnect()
      throw error
    }
    _ = try? await observer.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
    await observer.disconnect()
  }

  /// `<prefix>_items (id, v)` holding (1, 10), functions `<prefix>_add(n)` (INSERT) and
  /// `<prefix>_bump()` (UPDATE), and on MariaDB the sequence `<prefix>_seq`. Functions are
  /// created as root, DETERMINISTIC (binary logging is on in MySQL 8.4). All dropped on every
  /// path.
  private func withMySQLFixture(
    _ server: Server,
    _ body: (_ prefix: String, _ observer: DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let prefix = "mcp_ro_\(UUID().uuidString.prefix(8).lowercased())"
    let database = TestMySQLDatabase.database
    let setup = [
      "CREATE TABLE \(database).\(prefix)_items (id INT PRIMARY KEY, v INT)",
      "INSERT INTO \(database).\(prefix)_items VALUES (1, 10)",
      """
      CREATE FUNCTION \(database).\(prefix)_add(n INT) RETURNS INT DETERMINISTIC MODIFIES SQL DATA
      BEGIN
        INSERT INTO \(database).\(prefix)_items VALUES (n + 100, n);
        RETURN n;
      END
      """,
      """
      CREATE FUNCTION \(database).\(prefix)_bump() RETURNS INT DETERMINISTIC MODIFIES SQL DATA
      BEGIN
        UPDATE \(database).\(prefix)_items SET v = v + 1;
        RETURN 1;
      END
      """,
    ]
    let teardown = [
      "DROP FUNCTION IF EXISTS \(database).\(prefix)_add",
      "DROP FUNCTION IF EXISTS \(database).\(prefix)_bump",
      "DROP TABLE IF EXISTS \(database).\(prefix)_items",
      "DROP TABLE IF EXISTS \(database).\(prefix)_created",
    ]
    let sequence =
      server == .mariadb ? ["CREATE SEQUENCE \(database).\(prefix)_seq"] : []
    let dropSequence =
      server == .mariadb ? ["DROP SEQUENCE IF EXISTS \(database).\(prefix)_seq"] : []

    // A session, not a manager: the manager would split the function bodies at `;`.
    let root = MySQLSession(config: MySQLManagerTests.rootConfig(server))
    let observer = DatabaseConnectionManager()
    do {
      try await root.open()
      try await observer.connect(config: MySQLManagerTests.config(server))
      for statement in setup + sequence {
        _ = try await root.command(statement, binds: [])
      }
      try await body(prefix, observer)
    } catch {
      for statement in teardown + dropSequence {
        _ = try? await root.command(statement, binds: [])
      }
      await observer.disconnect()
      await root.close()
      throw error
    }
    for statement in teardown + dropSequence {
      _ = try? await root.command(statement, binds: [])
    }
    await observer.disconnect()
    await root.close()
  }
}
