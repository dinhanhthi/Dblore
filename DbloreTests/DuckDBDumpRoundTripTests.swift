// DuckDBDumpRoundTripTests.swift
// A DuckDB database (dev plugin) dumped on the tab's own session and restored through the gate
// into a fresh in-memory database: row counts and checksums of every table (ENUM, BLOB with
// empty, 0x00 and 0xFF bytes, NULL next to '', unicode, quotes and backslashes, timestamps with
// and without a time zone, decimals, inf / nan / -0.0, lists, structs, a generated column), the
// sequences' next values, foreign keys and views whose order is creation, not name, order,
// indexes, ENUM types and INSERT batches of 500. A read-only file dumps too and refuses a
// restore. A view that reads a file outside the session's grants by its path fails at the
// sandbox and rolls the whole restore back; a statement a dump never writes (or a view that runs
// SQL from a string) is refused before anything is sent; a statement that fails rolls the
// restore back and nothing after it runs; DuckDB has no SAVEPOINT.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDBDumpRoundTripTests", .requiresDuckDBPlugin, .serialized)
@MainActor
struct DuckDBDumpRoundTripTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static let source = """
    CREATE SCHEMA s2;
    CREATE TYPE mood AS ENUM ('sad', 'ok', 'it''s');
    CREATE TYPE s2.color AS ENUM ('red', 'green');
    CREATE TYPE unused AS ENUM ();
    CREATE SEQUENCE seq1 START 5 INCREMENT 2;
    CREATE SEQUENCE s2.never;
    CREATE SEQUENCE down INCREMENT BY -1 MINVALUE -100 MAXVALUE -1 START -1;
    CREATE TABLE s2.parent(id INTEGER PRIMARY KEY, name VARCHAR);
    CREATE TABLE s2.child(id INTEGER, parent INTEGER REFERENCES s2.parent(id));
    CREATE TABLE owners(id INTEGER PRIMARY KEY);
    CREATE TABLE items(
      id INTEGER PRIMARY KEY DEFAULT nextval('seq1'),
      parent INTEGER REFERENCES owners(id),
      m mood, c s2.color, b BLOB, txt VARCHAR, d DECIMAL(18,4), big HUGEINT, f DOUBLE, r REAL,
      ts TIMESTAMP, tz TIMESTAMPTZ, dt DATE, tm TIME, iv INTERVAL, u UUID, ok BOOLEAN,
      l INTEGER[], st STRUCT(a INTEGER, b VARCHAR),
      g INTEGER GENERATED ALWAYS AS (id * 2) VIRTUAL,
      CHECK (length(txt) < 1000));
    CREATE TABLE "Quoted ""Name""\"(x INTEGER);
    CREATE TABLE many(n INTEGER, s VARCHAR);
    CREATE TABLE query_log(id INTEGER PRIMARY KEY);
    CREATE TABLE read_receipts(id INTEGER, q INTEGER REFERENCES query_log(id));
    INSERT INTO query_log VALUES (1), (2);
    INSERT INTO read_receipts VALUES (1, 2), (2, NULL);
    INSERT INTO many SELECT i, 'row ' || i FROM range(1200) t(i);
    INSERT INTO s2.parent VALUES (1, 'a'), (2, 'b');
    INSERT INTO s2.child VALUES (10, 1), (11, 2), (12, NULL);
    INSERT INTO owners VALUES (1), (2);
    INSERT INTO items (parent, m, c, b, txt, d, big, f, r, ts, tz, dt, tm, iv, u, ok, l, st)
    VALUES
      (1, 'it''s', 'red', '\\x00\\xFF\\x5C\\x27abc'::BLOB, 'it''s a \\ path; -- not a comment',
        1.2345, 123456789012345678901234567890, 'inf', 0.1, '2024-01-02 03:04:05.123456',
        '2024-01-02 03:04:05.123456+02', '2024-02-29', '01:02:03.5',
        INTERVAL '1 year 2 months 3 days 04:05:06.789', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
        true, [1, NULL, 3], {'a': 1, 'b': 'x''y, z'}),
      (2, NULL, NULL, ''::BLOB, '', -0.0001, -1, 'nan', -0.0, NULL, NULL, NULL, NULL, NULL,
        NULL, false, [], NULL),
      (NULL, 'sad', 'green', '\\x00'::BLOB, NULL, NULL, NULL, -0.0, 1e30, '1970-01-01 00:00:00',
        '1999-12-31 23:59:59.999999-08', '0001-01-01', '00:00:00', INTERVAL '-1 day', NULL,
        NULL, NULL, {'a': NULL, 'b': NULL}),
      (NULL, NULL, NULL, NULL, 'Unicode: héllo 日本 🦆 "q" \\x41', 99999999999999.9999, NULL,
        1e300, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    SELECT nextval('down');
    CREATE UNIQUE INDEX items_expr ON items((id + 1), txt);
    CREATE INDEX many_s ON many(s);
    CREATE VIEW zz_base AS SELECT id, txt FROM items;
    CREATE VIEW a_dependent AS SELECT count(*) AS n FROM zz_base;
    CREATE VIEW s2.v2 (a) AS SELECT name FROM s2.parent;
    """

  private static let tables = [
    "items", "owners", "s2.parent", "s2.child", "\"Quoted \"\"Name\"\"\"", "many", "query_log",
    "read_receipts",
  ]

  @Test("An in-memory database restores into a fresh one with the same rows and objects")
  func inMemoryRoundTrip() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await original.disconnect() } }
    _ = try await original.execute(userSQL: Self.source, policy: open)

    let script = try await dump(original, config(DuckDBSession.inMemoryPath), in: directory)
    #expect(script.hasPrefix("-- Dblore SQL dump 1 engine=DuckDB created="))
    // 1,200 rows of `many` in INSERTs of at most 500 rows
    #expect(script.components(separatedBy: "INSERT INTO \"main\".\"many\"").count - 1 == 3)
    // The dump ran on the tab's session and left no transaction open there
    _ = try await original.execute(userSQL: "INSERT INTO many VALUES (-1, 'after')", policy: open)
    _ = try await original.execute(userSQL: "DELETE FROM many WHERE n = -1", policy: open)

    let restored = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await restored.disconnect() } }
    let summary = try await restored.executeGatedRestore(
      script: script, policy: open, connectionEpoch: await restored.connectionEpoch)
    #expect(summary.statementsRun == summary.statementCount)
    try await expectSameDatabase(original, restored)
    let next = "SELECT nextval('seq1'), nextval('s2.never'), nextval('down')"
    #expect(try await rows(restored, next) == rows(original, next))
    #expect(try await rows(restored, next) == [[.int(15), .int(2), .int(-3)]])
  }

  @Test("A file opened read-only dumps on its own session and refuses a restore")
  func readOnlyFileDumps() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("source.duckdb").path
    let writer = try await connect(config(path, readOnlyFile: false))
    _ = try await writer.execute(userSQL: Self.source, policy: open)
    await writer.disconnect()

    let file = try await connect(config(path, readOnlyFile: true))
    defer { Task { await file.disconnect() } }
    let script = try await dump(file, config(path, readOnlyFile: true), in: directory)
    let restored = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await restored.disconnect() } }
    _ = try await restored.executeGatedRestore(
      script: script, policy: open, connectionEpoch: await restored.connectionEpoch)
    try await expectSameDatabase(file, restored)

    let error = await #expect(throws: DatabaseError.self) {
      _ = try await file.executeGatedRestore(
        script: script, policy: open, connectionEpoch: await file.connectionEpoch)
    }
    guard case .blockedByProtection(_, _, let reason)? = error else {
      Issue.record("Expected a read-only refusal, got \(String(describing: error))")
      return
    }
    #expect(reason == SQLRestorePlan.duckdbReadOnlyFileMessage)
  }

  @Test("A view that reads a file outside the grants fails at the sandbox and rolls back")
  func sandboxStopsACraftedView() async throws {
    let restored = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await restored.disconnect() } }
    let script = [
      SQLDumpAssembler.header(engine: .duckdb, created: Date()),
      "CREATE TABLE x(a INTEGER);",
      "INSERT INTO \"main\".\"x\" (\"a\") VALUES\n('1');",
      "CREATE VIEW leak AS SELECT * FROM '/etc/hosts.csv';",
    ].map { $0 + "\n" }.joined()
    // The whitelist reads it as a dump (a path is a plain string): the session refuses it
    #expect(try SQLRestorePlan(script: script, engine: .duckdb).summary.statementCount == 3)
    let error = await #expect(throws: DatabaseError.self) {
      _ = try await restored.executeGatedRestore(
        script: script, policy: open, connectionEpoch: await restored.connectionEpoch)
    }
    #expect(String(describing: error).contains("disabled by configuration"))
    let tables = try await restored.execute(
      userSQL: "SELECT count(*) FROM duckdb_tables() WHERE NOT internal", policy: open)
    #expect(tables.rows == [[.int(0)]])
  }

  @Test("A statement a dump never writes is refused before anything is sent")
  func craftedStatementRefused() async throws {
    let restored = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await restored.disconnect() } }
    _ = try await restored.execute(userSQL: "CREATE TABLE keep(a INTEGER)", policy: open)
    _ = try await restored.execute(userSQL: "CREATE SEQUENCE victim", policy: open)
    for statement in [
      "DROP TABLE keep;",
      // Runs SQL from a string each time the view is read
      "CREATE VIEW v AS SELECT * FROM json_execute_serialized_sql(json_serialize_sql("
        + "'SELECT nextval(''main.victim'')'));",
      // A sequence the dump did not create
      "CREATE TABLE y(id INTEGER DEFAULT(nextval('victim')));",
    ] {
      let script = [
        SQLDumpAssembler.header(engine: .duckdb, created: Date()),
        "CREATE TABLE x(a INTEGER);", statement,
      ].map { $0 + "\n" }.joined()
      await #expect(throws: SQLRestoreError.self, "\(statement)") {
        _ = try await restored.executeGatedRestore(
          script: script, policy: open, connectionEpoch: await restored.connectionEpoch)
      }
    }
    let tables = try await restored.execute(
      userSQL: "SELECT table_name FROM duckdb_tables() WHERE NOT internal", policy: open)
    #expect(tables.rows == [[.string("keep")]])
    let views = try await restored.execute(
      userSQL: "SELECT count(*) FROM duckdb_views() WHERE NOT internal", policy: open)
    #expect(views.rows == [[.int(0)]])
    // The view's payload runs (the gate is what stops it), and the victim never advanced
    let payload = try await restored.execute(
      userSQL: "SELECT * FROM json_execute_serialized_sql(json_serialize_sql('SELECT 42'))",
      policy: open)
    #expect(payload.rows == [[.int(42)]])
    let victim = try await restored.execute(
      userSQL: "SELECT nextval('victim')", policy: open)
    #expect(victim.rows == [[.int(1)]])
  }

  @Test("A statement that fails rolls the whole restore back and nothing after it runs")
  func failingStatementRollsBack() async throws {
    let restored = try await connect(config(DuckDBSession.inMemoryPath))
    defer { Task { await restored.disconnect() } }
    _ = try await restored.execute(userSQL: "CREATE SEQUENCE victim", policy: open)
    // The plan accepts the table (its sequence comes first); the CREATE SEQUENCE fails at run
    // time because `victim` exists, so the table never binds to the existing sequence
    let script = [
      SQLDumpAssembler.header(engine: .duckdb, created: Date()),
      "CREATE TABLE x(a INTEGER);",
      "CREATE SEQUENCE \"main\".\"victim\" START WITH 1 INCREMENT BY 1 MINVALUE 1"
        + " MAXVALUE 9 NO CYCLE;",
      "CREATE TABLE y(id INTEGER DEFAULT(nextval('victim')));",
      "INSERT INTO \"main\".\"y\" DEFAULT VALUES;",
    ].map { $0 + "\n" }.joined()
    #expect(try SQLRestorePlan(script: script, engine: .duckdb).summary.statementCount == 4)
    await #expect(throws: (any Error).self) {
      _ = try await restored.executeGatedRestore(
        script: script, policy: open, connectionEpoch: await restored.connectionEpoch)
    }
    let tables = try await restored.execute(
      userSQL: "SELECT count(*) FROM duckdb_tables() WHERE NOT internal", policy: open)
    #expect(tables.rows == [[.int(0)]])
    let victim = try await restored.execute(userSQL: "SELECT nextval('victim')", policy: open)
    #expect(victim.rows == [[.int(1)]])
  }

  @Test("DuckDB has no SAVEPOINT, so a restore refuses Protected mode and open transactions")
  func noSavepoint() async throws {
    let session = DuckDBSession(config: config(DuckDBSession.inMemoryPath)) {
      try DuckDBTestPlugin.library()
    }
    try await session.open()
    _ = try await session.command("BEGIN TRANSACTION", binds: [])
    await #expect(throws: DuckDBSessionError.self) {
      _ = try await session.command("SAVEPOINT dblore_batch", binds: [])
    }
    // A prepared statement holds one statement: a split the whitelist misread cannot run two
    await #expect(throws: DuckDBSessionError.self) {
      _ = try await session.command("SELECT 1; SELECT 2", binds: [])
    }
    await session.close()
  }

  // MARK: - Helpers

  private func expectSameDatabase(
    _ original: DatabaseConnectionManager, _ restored: DatabaseConnectionManager
  ) async throws {
    for table in Self.tables {
      let sql = """
        SELECT count(*), md5(coalesce(string_agg(CAST(r AS VARCHAR), chr(10)
          ORDER BY CAST(r AS VARCHAR)), '')) FROM \(table) AS r
        """
      let expected = try await rows(original, sql)
      #expect(try await rows(restored, sql) == expected, "\(table)")
    }
    let count = try await rows(restored, "SELECT count(*) FROM items")
    #expect(count == [[.int(4)]])
    for sql in [
      // The value each sequence hands out next (a read-only file cannot run nextval)
      """
      SELECT schema_name, sequence_name, coalesce(last_value + increment_by, start_value),
        increment_by, min_value, max_value, cycle
      FROM duckdb_sequences() WHERE database_name = current_database() ORDER BY ALL
      """,
      """
      SELECT schema_name, type_name, to_json(labels)::VARCHAR FROM duckdb_types()
      WHERE database_name = current_database() AND NOT internal ORDER BY ALL
      """,
      """
      SELECT schema_name, table_name, sql FROM duckdb_tables()
      WHERE database_name = current_database() AND NOT internal ORDER BY ALL
      """,
      """
      SELECT schema_name, view_name, sql FROM duckdb_views()
      WHERE database_name = current_database() AND NOT internal ORDER BY ALL
      """,
      """
      SELECT schema_name, index_name, sql FROM duckdb_indexes()
      WHERE database_name = current_database() ORDER BY ALL
      """,
      "SELECT n FROM a_dependent", "SELECT a FROM s2.v2 ORDER BY a",
    ] {
      let expected = try await rows(original, sql)
      #expect(!expected.isEmpty, "\(sql)")
      #expect(try await rows(restored, sql) == expected, "\(sql)")
    }
  }

  private func rows(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws -> [[CellValue]] {
    try await manager.execute(userSQL: sql, policy: open).rows
  }

  /// The dump of `manager`'s own session, as text
  private func dump(
    _ manager: DatabaseConnectionManager, _ config: ConnectionConfig, in directory: URL
  ) async throws -> String {
    let destination = directory.appendingPathComponent("dump-\(UUID().uuidString).sql")
    let writer = SQLDumpWriter(tabManager: manager, config: config)
    _ = try await writer.write(to: destination)
    return try String(contentsOf: destination, encoding: .utf8)
  }

  /// The app's session factory with the dev plugin as the installed one.
  private func connect(_ config: ConnectionConfig) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(duckDBLibraryLoader: {
        { try DuckDBTestPlugin.library() }
      }))
    try await manager.connect(config: config)
    return manager
  }

  private func config(_ path: String, readOnlyFile: Bool = false) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: path, sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false, statementTimeoutSeconds: 30,
      readOnlyFile: readOnlyFile)
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-dump-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
