// SQLDumpRoundTripTests.swift
// Dump with `SQLDumpWriter`, restore through `executeGatedRestore` into an empty database, then
// compare every table and view: row count and a checksum computed by the database over the
// text form of every row. PostgreSQL: `md5(string_agg(t::text, '|' ORDER BY t::text))`.
// MySQL / MariaDB: `MD5(GROUP_CONCAT(CONCAT_WS('|', IFNULL(HEX(CAST(col AS BINARY)), 'N'), ...)
// ORDER BY ...))` per column (HEX never prints `N`, so NULL and an empty string differ; the
// BINARY cast keeps a number's digits, where HEX of a number would print its integer part).
// SQLite: `quote()` of every column, sorted. Fixtures: the 15.2 fidelity values, a child table
// whose name sorts before its parent, a self-referencing foreign key row, a SQLite trigger with
// a multi-statement body, and on PostgreSQL an enum, a domain, a non-public schema, a
// partitioned table with a PK and an index on the parent, and a view built on another view.
// Every database and file is dropped on every path. PostgreSQL and MySQL are opt-in
// (`.requiresPostgres`, `.requiresMySQL`); SQLite runs locally.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct SQLDumpRoundTripTests {
  typealias Server = MySQLSessionTests.Server

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - SQLite

  private static let sqliteSeed = [
    "PRAGMA journal_mode = WAL", "PRAGMA wal_autocheckpoint = 0",
    """
    CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT, data BLOB,
      ratio REAL, note TEXT, lower_body TEXT GENERATED ALWAYS AS (lower(body)) VIRTUAL)
    """,
    """
    INSERT INTO notes (id, body, data, ratio, note) VALUES
      (1, 'Hello', X'00FF10', 0.1 + 0.2, ''), (2, 'it''s', NULL, 1e300, NULL),
      (3, 'Ünïcode 😀', X'', -0.0, 'line
    break'), (7, 'gone', NULL, NULL, NULL)
    """,
    "DELETE FROM notes WHERE id = 7",
    // The child's name sorts before its parent's
    "CREATE TABLE a_child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL"
      + " REFERENCES b_parent (id))",
    "CREATE TABLE b_parent (id INTEGER PRIMARY KEY, label TEXT)",
    "INSERT INTO b_parent VALUES (1, 'p'), (2, 'q')",
    "INSERT INTO a_child VALUES (1, 2), (2, 1)",
    "CREATE TABLE employees (id INTEGER PRIMARY KEY, manager_id INTEGER REFERENCES employees (id))",
    "INSERT INTO employees VALUES (1, 1), (2, 1)",
    "CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, what TEXT)",
    """
    CREATE TRIGGER notes_audit AFTER INSERT ON notes BEGIN
      INSERT INTO audit (what) VALUES ('insert ' || NEW.id);
      UPDATE audit SET what = what || ';' WHERE id = last_insert_rowid();
    END
    """,
    "INSERT INTO notes (id, body) VALUES (4, 'audited')",
    "CREATE VIRTUAL TABLE notes_fts USING fts5(body)",
    "INSERT INTO notes_fts (body) VALUES ('searchable')",
    "CREATE INDEX idx_notes_body ON notes (body)",
    "CREATE VIEW v_notes AS SELECT body FROM notes",
    "CREATE VIEW v_v_notes AS SELECT upper(body) AS b FROM v_notes",
  ]

  @Test("SQLite dump restores into an empty file with the same rows", .timeLimit(.minutes(1)))
  func sqliteRoundTrip() async throws {
    let directory = try Self.temporaryDirectory()
    let source = directory.appendingPathComponent("source.db")
    let target = directory.appendingPathComponent("target.db")
    let restorer = DatabaseConnectionManager()
    do {
      let live = SQLiteSession(config: Self.sqliteConfig(source))
      try await live.open()
      for statement in Self.sqliteSeed { _ = try await live.command(statement, binds: []) }
      let destination = directory.appendingPathComponent("dump.sql")
      _ = try await SQLDumpWriter(
        config: Self.sqliteConfig(source), material: nil, sshCredential: nil,
        sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
      ).write(to: destination)
      await live.close()
      let text = try String(contentsOf: destination, encoding: .utf8)

      FileManager.default.createFile(atPath: target.path, contents: Data())
      try await restorer.connect(config: Self.sqliteConfig(target))
      let summary = try await restorer.executeGatedRestore(
        script: text, policy: open, connectionEpoch: await restorer.connectionEpoch)
      #expect(summary.count(.trigger) == 1)
      await restorer.disconnect()

      let tables = try Self.sqliteRelations(source)
      #expect(tables == (try Self.sqliteRelations(target)))
      #expect(
        tables == [
          "a_child", "audit", "b_parent", "employees", "notes", "v_notes", "v_v_notes",
        ])
      for table in tables {
        let expected = try Self.sqliteChecksum(source, table)
        #expect(try Self.sqliteChecksum(target, table) == expected, "\(table)")
      }
      let counters = "SELECT name || '=' || seq FROM sqlite_sequence ORDER BY name"
      #expect(try Self.sqliteRows(target, counters) == Self.sqliteRows(source, counters))
      // The trigger came back whole: both statements of its body run
      for database in [source, target] {
        try Self.sqliteExec(database, "INSERT INTO notes (id, body) VALUES (9, 'new')")
      }
      let audit = "SELECT what FROM audit ORDER BY id"
      #expect(try Self.sqliteRows(target, audit) == ["insert 4;", "insert 9;"])
      #expect(try Self.sqliteRows(target, audit) == Self.sqliteRows(source, audit))
    } catch {
      await restorer.disconnect()
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    try? FileManager.default.removeItem(at: directory)
  }

  private static func sqliteConfig(_ url: URL) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
  }

  /// Tables (without virtual and shadow tables) and views, by name
  private static func sqliteRelations(_ database: URL) throws -> [String] {
    try sqliteRows(
      database,
      """
      SELECT m.name FROM sqlite_master m
      JOIN pragma_table_list l ON l.schema = 'main' AND l.name = m.name
      WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite_%'
        AND l.type IN ('table', 'view') AND m.sql NOT LIKE 'CREATE VIRTUAL%'
      ORDER BY m.name
      """)
  }

  /// `count|rows`: every row as the `quote()` of each column (hidden and generated ones too),
  /// sorted
  private static func sqliteChecksum(_ database: URL, _ table: String) throws -> String {
    let columns = try sqliteRows(
      database, "SELECT name FROM pragma_table_xinfo('\(table)') ORDER BY cid")
    let row = columns.map { "quote(\"\($0)\")" }.joined(separator: " || '|' || ")
    return try sqliteRows(
      database,
      """
      SELECT (SELECT count(*) FROM "\(table)") || '|' || coalesce(
        (SELECT group_concat(r, char(10)) FROM (SELECT \(row) AS r FROM "\(table)" ORDER BY r)),
        '')
      """
    ).joined()
  }

  private static func sqliteExec(_ database: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(database.path, &handle) == SQLITE_OK, let db = handle else {
      throw SQLiteSessionError(extendedCode: SQLITE_CANTOPEN, message: "open failed")
    }
    defer { sqlite3_close_v2(db) }
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(db, sql, nil, nil, &message)
    let text = message.map { String(cString: $0) } ?? ""
    sqlite3_free(message)
    guard code == SQLITE_OK else { throw SQLiteSessionError(extendedCode: code, message: text) }
  }

  /// First column of every row, as text
  private static func sqliteRows(_ database: URL, _ sql: String) throws -> [String] {
    var handle: OpaquePointer?
    guard sqlite3_open(database.path, &handle) == SQLITE_OK, let db = handle else {
      throw SQLiteSessionError(extendedCode: SQLITE_CANTOPEN, message: "open failed")
    }
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement
    else {
      throw SQLiteSessionError(
        extendedCode: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(prepared) }
    var rows: [String] = []
    while sqlite3_step(prepared) == SQLITE_ROW {
      rows.append(sqlite3_column_text(prepared, 0).map { String(cString: $0) } ?? "<null>")
    }
    return rows
  }

  // MARK: - PostgreSQL

  private static let postgresSeed = [
    "CREATE SCHEMA app",
    "CREATE TYPE app.mood AS ENUM ('ok', 'it''s bad')",
    "CREATE DOMAIN app.positive AS integer CHECK (VALUE > 0)",
    "CREATE TABLE app.customers (id serial PRIMARY KEY, big bigserial, name text NOT NULL)",
    """
    CREATE TABLE app.orders (
      id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      customer_id integer REFERENCES app.customers (id) DEFERRABLE INITIALLY DEFERRED,
      amount numeric(38,18), special numeric, ratio double precision, price money,
      at timestamp(6), atz timestamptz(6), span interval, tags text[], doc json, docb jsonb,
      raw bytea, note text, mood app.mood, qty app.positive,
      total numeric GENERATED ALWAYS AS (amount * 2) STORED, room integer,
      EXCLUDE USING btree (room WITH =)
    )
    """,
    "CREATE INDEX orders_note_idx ON app.orders (note DESC NULLS LAST) INCLUDE (room)",
    "CREATE VIEW app.big_orders AS SELECT id, amount FROM app.orders WHERE amount > 1",
    // A view built on another view
    "CREATE VIEW app.big_order_ids AS SELECT id FROM app.big_orders",
    // Partitioned table with a PK and an index on the parent
    """
    CREATE TABLE app.events (id integer, logdate date, PRIMARY KEY (id, logdate),
      CONSTRAINT events_id_check CHECK (id > 0)) PARTITION BY RANGE (logdate)
    """,
    """
    CREATE TABLE app.events_2026 PARTITION OF app.events
      FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')
    """,
    "CREATE INDEX events_logdate_idx ON app.events (logdate)",
    "INSERT INTO app.events VALUES (1, '2026-06-01'), (2, '2026-07-01')",
    "INSERT INTO app.customers (name) VALUES ('Ada'), ('Bob')",
    """
    INSERT INTO app.orders (customer_id, amount, special, ratio, price, at, atz, span, tags, doc,
      docb, raw, note, mood, qty, room)
    VALUES (1, 1.123456789012345678, 'NaN', 0.1, 1234.56, '2026-10-15 12:34:56.123456',
      '2026-10-15 12:34:56.654321+00', '1 year 2 mons 3 days 04:05:06.789', '{a,"b c",NULL}',
      '{"k": [1, 2.50]}', '{"k": [1, 2.50]}', decode('deadbeef', 'hex'), '', 'it''s bad', 5, 1),
      (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'ok', NULL, 2)
    """,
    // The child's name sorts before its parent's; a row that references itself
    "CREATE TABLE app.b_parent (id integer PRIMARY KEY, label text)",
    """
    CREATE TABLE app.a_child (id integer PRIMARY KEY,
      parent_id integer NOT NULL REFERENCES app.b_parent (id))
    """,
    "CREATE TABLE public.employees (id integer PRIMARY KEY,"
      + " manager_id integer REFERENCES public.employees (id))",
    "INSERT INTO app.b_parent VALUES (1, 'p'), (2, 'q')",
    "INSERT INTO app.a_child VALUES (1, 2), (2, 1)",
    "INSERT INTO public.employees VALUES (1, 1), (2, 1)",
    // NOT VALID checks that the rows above break
    "ALTER TABLE app.customers ADD CONSTRAINT customers_id_check CHECK (id > 1) NOT VALID",
    "ALTER DOMAIN app.positive ADD CONSTRAINT positive_small CHECK (VALUE < 3) NOT VALID",
    "ALTER TABLE app.events ADD CONSTRAINT events_id_big CHECK (id > 5) NOT VALID",
    // Plain strings with a backslash in the catalog's text (standard_conforming_strings on): a
    // CHECK, a column DEFAULT and a view body
    """
    CREATE TABLE app.patterns (id integer PRIMARY KEY,
      code text CONSTRAINT patterns_code_digits CHECK (code ~ '^\\d+$'), note text DEFAULT 'a\\b')
    """,
    "INSERT INTO app.patterns (id, code) VALUES (1, '42')",
    "CREATE VIEW app.lines AS SELECT id, note || '\\n' AS line FROM app.patterns",
  ]

  @Test(
    "PostgreSQL dump restores into an empty database with the same rows", .requiresPostgres,
    .timeLimit(.minutes(2)))
  func postgresRoundTrip() async throws {
    let name = "roundtrip_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.postgresConfig(TestDatabase.database))
    let restorer = DatabaseConnectionManager()
    let directory = try Self.temporaryDirectory()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name)")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored)")
      _ = try await Self.values(Self.postgresConfig(name), Self.postgresSeed)
      let text = try await Self.dump(Self.postgresConfig(name), into: directory)

      try await restorer.connect(config: Self.postgresConfig(restored))
      let summary = try await restorer.executeGatedRestore(
        script: text, policy: open, connectionEpoch: await restorer.connectionEpoch)
      #expect(summary.count(.sequenceValue) == 3)
      #expect(!summary.pending)
      await restorer.disconnect()

      let list = """
        SELECT string_agg(quote_ident(n.nspname) || '.' || quote_ident(c.relname), ','
          ORDER BY n.nspname, c.relname)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p', 'v') AND n.nspname IN ('app', 'public')
        """
      let relations = try await Self.values(Self.postgresConfig(name), [list])
      #expect(relations == (try await Self.values(Self.postgresConfig(restored), [list])))
      guard case .string(let joined) = relations.first else {
        throw DatabaseError.notConnected
      }
      // Sorted here: the database collation may order `_` after letters
      let names = joined.components(separatedBy: ",").sorted()
      #expect(
        names == [
          "app.a_child", "app.b_parent", "app.big_order_ids", "app.big_orders", "app.customers",
          "app.events", "app.events_2026", "app.lines", "app.orders", "app.patterns",
          "public.employees",
        ])
      let checksums = names.map {
        "SELECT count(*)::text || ' ' || coalesce(md5(string_agg(t::text, '|' ORDER BY t::text)),"
          + " '') FROM \($0) t"
      }
      let expected = try await Self.values(Self.postgresConfig(name), checksums)
      #expect(try await Self.values(Self.postgresConfig(restored), checksums) == expected)
      #expect(expected.allSatisfy { $0 != .null })
      // The backslashes came back as written: the same CHECK, DEFAULT and view text
      let definitions = """
        SELECT (SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conname = 'patterns_code_digits')
          || ' | ' || (SELECT pg_get_expr(adbin, adrelid) FROM pg_attrdef
            WHERE adrelid = 'app.patterns'::regclass)
          || ' | ' || pg_get_viewdef('app.lines'::regclass)
        """
      let source = try await Self.values(Self.postgresConfig(name), [definitions])
      #expect(try await Self.values(Self.postgresConfig(restored), [definitions]) == source)
      guard case .string(let text) = source.first else { throw DatabaseError.notConnected }
      #expect(text.contains("'^\\d+$'") && text.contains("'a\\b'") && text.contains("'\\n'"))
    } catch {
      await restorer.disconnect()
      await Self.dropPostgres(admin, [name, restored], directory)
      throw error
    }
    await Self.dropPostgres(admin, [name, restored], directory)
  }

  private static func postgresConfig(_ database: String) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, safeMode: .silent, protectedMode: false)
  }

  private static func dropPostgres(
    _ admin: DatabaseConnectionManager, _ databases: [String], _ directory: URL
  ) async {
    for database in databases {
      _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database) WITH (FORCE)")
    }
    await admin.disconnect()
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - MySQL / MariaDB

  private static let mysqlSeed = [
    "CREATE TABLE customers (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50) NOT NULL)",
    """
    CREATE TABLE orders (
      id BIGINT AUTO_INCREMENT PRIMARY KEY, customer_id INT, amount DECIMAL(38,18),
      ratio DOUBLE, at DATETIME(6), ts TIMESTAMP(6) NULL, doc JSON, raw BLOB, flags BIT(10),
      note VARCHAR(20), total DECIMAL(39,18) GENERATED ALWAYS AS (amount * 2) STORED,
      KEY orders_note_idx (note),
      CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id)
    )
    """,
    "CREATE VIEW big_orders AS SELECT id, amount FROM orders WHERE amount > 1",
    "INSERT INTO customers (name) VALUES ('Ada'), ('Bob')",
    // A 0 in an AUTO_INCREMENT column restores as 0 only under NO_AUTO_VALUE_ON_ZERO
    "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_AUTO_VALUE_ON_ZERO')",
    "INSERT INTO customers (id, name) VALUES (0, 'Zero')",
    """
    INSERT INTO orders (customer_id, amount, ratio, at, ts, doc, raw, flags, note) VALUES
      (1, 1.123456789012345678, 0.1, '2026-10-15 12:34:56.123456',
        '2026-10-15 12:34:56.654321', '{"k": [1, 2.50]}', X'DEADBEEF', b'101', 'a\\\\b''c\u{1F600}'),
      (2, NULL, NULL, NULL, NULL, NULL, X'', NULL, '')
    """,
    // The child's name sorts before its parent's; a row that references itself
    "CREATE TABLE b_parent (id INT PRIMARY KEY, label VARCHAR(10))",
    """
    CREATE TABLE a_child (id INT PRIMARY KEY, parent_id INT NOT NULL,
      CONSTRAINT a_child_fk FOREIGN KEY (parent_id) REFERENCES b_parent (id))
    """,
    """
    CREATE TABLE employees (id INT PRIMARY KEY, manager_id INT,
      CONSTRAINT employees_fk FOREIGN KEY (manager_id) REFERENCES employees (id))
    """,
    "INSERT INTO b_parent VALUES (1, 'p'), (2, 'q')",
    "INSERT INTO a_child VALUES (1, 2), (2, 1)",
    "INSERT INTO employees VALUES (1, 1), (2, 1)",
  ]

  @Test(
    "MySQL dump restores into an empty database with the same rows", .requiresMySQL,
    .timeLimit(.minutes(2)), arguments: [Server.mysql, .mariadb])
  func mysqlRoundTrip(server: Server) async throws {
    let name = "roundtrip_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: MySQLManagerTests.rootConfig(server))
    let restorer = DatabaseConnectionManager()
    let directory = try Self.temporaryDirectory()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name) CHARACTER SET utf8mb4")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored) CHARACTER SET utf8mb4")
      let config = Self.mysqlConfig(server, name)
      // A view on a view whose name sorts first: MySQL orders it by VIEW_TABLE_USAGE, MariaDB
      // by the views its VIEW_DEFINITION names
      let viewOnView = ["CREATE VIEW big_order_ids AS SELECT id FROM big_orders"]
      _ = try await Self.values(config, Self.mysqlSeed + viewOnView)
      let text = try await Self.dump(config, into: directory)

      let restoredConfig = Self.mysqlConfig(server, restored)
      try await restorer.connect(config: restoredConfig)
      let summary = try await restorer.executeGatedRestore(
        script: text, policy: open, connectionEpoch: await restorer.connectionEpoch)
      #expect(summary.statementsRun == summary.statementCount)
      await restorer.disconnect()

      let relations = try await Self.mysqlRelations(config)
      #expect(relations == (try await Self.mysqlRelations(restoredConfig)))
      #expect(
        relations.map(\.name)
          == [
            "a_child", "b_parent", "big_order_ids", "big_orders", "customers", "employees",
            "orders",
          ])
      let checksums =
        ["SET SESSION group_concat_max_len = 1073741824"]
        + relations.map { relation in
          let row =
            "CONCAT_WS('|', "
            + relation.columns.map { "IFNULL(HEX(CAST(`\($0)` AS BINARY)), 'N')" }
            .joined(separator: ", ") + ")"
          return
            "SELECT CONCAT(COUNT(*), ' ', IFNULL(MD5(GROUP_CONCAT(\(row) ORDER BY \(row)"
            + " SEPARATOR '\\n')), '')) FROM `\(relation.name)`"
        }
      let expected = try await Self.values(config, checksums)
      #expect(try await Self.values(restoredConfig, checksums) == expected)
      #expect(expected.dropFirst().allSatisfy { $0 != .null })
    } catch {
      await restorer.disconnect()
      await Self.dropMySQL(admin, [name, restored], directory)
      throw error
    }
    await Self.dropMySQL(admin, [name, restored], directory)
  }

  private struct MySQLRelation: Equatable {
    var name: String
    var columns: [String]
  }

  /// Tables and views of the database, each with its columns in order
  private static func mysqlRelations(_ config: ConnectionConfig) async throws -> [MySQLRelation] {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    do {
      let rows = try await manager.executeInternal(
        """
        SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION
        """
      ).rows
      await manager.disconnect()
      var relations: [MySQLRelation] = []
      for row in rows {
        guard row.count == 2, case .string(let table) = row[0], case .string(let column) = row[1]
        else { continue }
        if relations.last?.name == table {
          relations[relations.count - 1].columns.append(column)
        } else {
          relations.append(MySQLRelation(name: table, columns: [column]))
        }
      }
      // Sorted here: the column collation may order `_` after letters
      return relations.sorted { $0.name < $1.name }
    } catch {
      await manager.disconnect()
      throw error
    }
  }

  private static func mysqlConfig(_ server: Server, _ database: String) -> ConnectionConfig {
    var config = MySQLManagerTests.rootConfig(server)
    config.database = database
    config.protectedMode = false
    return config
  }

  private static func dropMySQL(
    _ admin: DatabaseConnectionManager, _ databases: [String], _ directory: URL
  ) async {
    for database in databases {
      _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(database)")
    }
    await admin.disconnect()
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - Helpers

  /// The dump text of the database at `config`
  private static func dump(_ config: ConnectionConfig, into directory: URL) async throws -> String {
    let destination = directory.appendingPathComponent("dump.sql")
    _ = try await SQLDumpWriter(
      config: config, material: nil, sshCredential: nil,
      sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
    ).write(to: destination)
    return try String(contentsOf: destination, encoding: .utf8)
  }

  /// The first value of each statement's result, on one new connection to `config`
  private static func values(
    _ config: ConnectionConfig, _ statements: [String]
  ) async throws -> [CellValue] {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    do {
      var values: [CellValue] = []
      for statement in statements {
        values.append(try await manager.executeInternal(statement).rows.first?.first ?? .null)
      }
      await manager.disconnect()
      return values
    } catch {
      await manager.disconnect()
      throw error
    }
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-dump-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
