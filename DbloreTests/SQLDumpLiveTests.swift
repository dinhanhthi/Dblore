// SQLDumpLiveTests.swift
// SQLDumpWriter against the docker PostgreSQL (TEST_DB_*, 5435) and MySQL 8.4 / MariaDB 11.4
// (TEST_MYSQL_* / TEST_MARIADB_PORT, 3307 / 3308) servers. Each test creates its own database,
// seeds a PK, FK, index, view, serial and bigserial (PostgreSQL), GENERATED ALWAYS identity or
// AUTO_INCREMENT, a generated column and fidelity values (numeric(38,18), NaN, money,
// microsecond timestamps, interval, arrays, json/jsonb, bytea/BLOB, BIT, empty string versus
// NULL) and NOT VALID table, partitioned-table and domain checks that seeded rows break, dumps
// it and checks that each value and DDL detail appears in the dump exactly. The
// dump is then run into a second new database and the rows and counters compared. Both
// databases are dropped on every path. Opt-in per engine (`.requiresPostgres`, `.requiresMySQL`).

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct SQLDumpLiveTests {
  typealias Server = MySQLSessionTests.Server

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
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
    """
    CREATE TABLE app.events (id integer, logdate date, PRIMARY KEY (id, logdate),
      CONSTRAINT events_id_check CHECK (id > 0)) PARTITION BY RANGE (logdate)
    """,
    """
    CREATE TABLE app.events_2026 PARTITION OF app.events
      FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')
    """,
    "CREATE INDEX events_logdate_idx ON app.events (logdate)",
    "INSERT INTO app.events VALUES (1, '2026-06-01')",
    "INSERT INTO app.customers (name) VALUES ('Ada'), ('Bob')",
    """
    INSERT INTO app.orders (customer_id, amount, special, ratio, price, at, atz, span, tags, doc,
      docb, raw, note, mood, qty, room)
    VALUES (1, 1.123456789012345678, 'NaN', 0.1, 1234.56, '2026-10-15 12:34:56.123456',
      '2026-10-15 12:34:56.654321+00', '1 year 2 mons 3 days 04:05:06.789', '{a,"b c",NULL}',
      '{"k": [1, 2.50]}', '{"k": [1, 2.50]}', decode('deadbeef', 'hex'), '', 'it''s bad', 5, 1),
      (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'ok', NULL, 2)
    """,
    // NOT VALID checks that rows above break (Ada id 1, qty 5, event id 1): a restore that
    // validated them before or after the data would fail
    "ALTER TABLE app.customers ADD CONSTRAINT customers_id_check CHECK (id > 1) NOT VALID",
    "ALTER DOMAIN app.positive ADD CONSTRAINT positive_small CHECK (VALUE < 3) NOT VALID",
    "ALTER TABLE app.events ADD CONSTRAINT events_id_big CHECK (id > 5) NOT VALID",
  ]

  @Test(
    "PostgreSQL dump keeps every value and DDL detail and restores", .requiresPostgres,
    .timeLimit(.minutes(2)))
  func postgresDump() async throws {
    let name = "dump_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: Self.postgresConfig(TestDatabase.database))
    let directory = try Self.temporaryDirectory()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name)")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored)")
      try await Self.run(Self.postgresConfig(name), Self.postgresSeed)

      let destination = directory.appendingPathComponent("dump.sql")
      let progress = try await SQLDumpWriter(
        config: Self.postgresConfig(name), material: nil, sshCredential: nil,
        sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
      ).write(to: destination)
      // The partitioned parent holds no rows of its own: customers, events_2026, orders
      #expect(progress == SQLDumpProgress(tablesDone: 3, tableCount: 3, rowsWritten: 5))
      let text = try String(contentsOf: destination, encoding: .utf8)

      #expect(text.hasPrefix("-- Dblore SQL dump 1 engine=PostgreSQL created="))
      for expected in [
        "CREATE SCHEMA IF NOT EXISTS \"app\";",
        "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok', 'it''s bad');",
        "CREATE DOMAIN \"app\".\"positive\" AS integer CONSTRAINT \"positive_check\""
          + " CHECK ((VALUE > 0));",
        "CREATE SEQUENCE \"app\".\"customers_id_seq\" AS integer START WITH 1",
        "CREATE SEQUENCE \"app\".\"customers_big_seq\" AS bigint START WITH 1",
        "\"id\" integer GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME \"app\".\"orders_id_seq\"",
        "\"total\" numeric GENERATED ALWAYS AS ((amount * (2)::numeric)) STORED",
        "INSERT INTO \"app\".\"orders\" (\"id\", \"customer_id\", \"amount\", \"special\","
          + " \"ratio\", \"price\", \"at\", \"atz\", \"span\", \"tags\", \"doc\", \"docb\","
          + " \"raw\", \"note\", \"mood\", \"qty\", \"room\") OVERRIDING SYSTEM VALUE VALUES",
        "('1', '1', '1.123456789012345678', 'NaN', '0.1', '$1,234.56',"
          + " '2026-10-15 12:34:56.123456', '2026-10-15 12:34:56.654321+00',"
          + " '1 year 2 mons 3 days 04:05:06.789', '{a,\"b c\",NULL}', '{\"k\": [1, 2.50]}',"
          + " '{\"k\": [1, 2.50]}', E'\\\\xdeadbeef', '', 'it''s bad', '5', '1')",
        "('2', '2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,"
          + " 'ok', NULL, '2')",
        "CREATE INDEX orders_note_idx ON app.orders USING btree (note DESC NULLS LAST)"
          + " INCLUDE (room);",
        "ALTER TABLE \"app\".\"orders\" ADD CONSTRAINT \"orders_room_excl\""
          + " EXCLUDE USING btree (room WITH =);",
        "ALTER TABLE \"app\".\"orders\" ADD CONSTRAINT \"orders_customer_id_fkey\""
          + " FOREIGN KEY (customer_id) REFERENCES app.customers(id)"
          + " DEFERRABLE INITIALLY DEFERRED;",
        "ALTER SEQUENCE \"app\".\"customers_id_seq\" OWNED BY \"app\".\"customers\".\"id\";",
        "SELECT pg_catalog.setval('\"app\".\"customers_id_seq\"', 2, true);",
        "SELECT pg_catalog.setval('\"app\".\"customers_big_seq\"', 2, true);",
        "SELECT pg_catalog.setval('\"app\".\"orders_id_seq\"', 2, true);",
        "CREATE VIEW \"app\".\"big_orders\" AS\n",
      ] {
        #expect(text.contains(expected), "\(expected)")
      }
      #expect(!text.contains("INDEX orders_room_excl"))
      // The partition is created PARTITION OF only; the parent's index and constraints cover it
      #expect(
        text.contains(
          "CREATE TABLE \"app\".\"events_2026\" PARTITION OF \"app\".\"events\""
            + " FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');"))
      #expect(text.contains(") PARTITION BY RANGE (logdate);"))
      #expect(
        text.components(
          separatedBy: "CREATE INDEX events_logdate_idx ON app.events USING btree"
            + " (logdate);"
        ).count == 2)
      #expect(!text.contains("events_2026_logdate_idx") && !text.contains("ON ONLY"))
      #expect(!text.contains("ALTER TABLE \"app\".\"events_2026\" ADD"))
      #expect(text.contains("INSERT INTO \"app\".\"events_2026\" (\"id\", \"logdate\") VALUES"))
      #expect(!text.contains("INSERT INTO \"app\".\"events\" "))
      #expect(!text.contains("\"total\") VALUES") && !text.contains(", \"total\""))
      // NOT VALID checks are added after the data, as NOT VALID; the partition gets its copy
      // from the parent's ALTER
      let lines = text.components(separatedBy: "\n")
      let lastInsert = try #require(lines.lastIndex { $0.hasPrefix("INSERT INTO") })
      for notValid in [
        "ALTER TABLE \"app\".\"customers\" ADD CONSTRAINT \"customers_id_check\""
          + " CHECK ((id > 1)) NOT VALID;",
        "ALTER DOMAIN \"app\".\"positive\" ADD CONSTRAINT \"positive_small\""
          + " CHECK ((VALUE < 3)) NOT VALID;",
        "ALTER TABLE \"app\".\"events\" ADD CONSTRAINT \"events_id_big\""
          + " CHECK ((id > 5)) NOT VALID;",
      ] {
        let index = lines.firstIndex(of: notValid)
        #expect(index.map { $0 > lastInsert } == true, "\(notValid)")
      }
      #expect(text.components(separatedBy: "customers_id_check").count == 2)
      #expect(text.components(separatedBy: "positive_small").count == 2)
      #expect(text.components(separatedBy: "events_id_big").count == 2)

      // The dump runs into an empty database and gives back the same rows and counters
      let restoredConfig = Self.postgresConfig(restored)
      try await Self.run(restoredConfig, [text])
      let compare = [
        "SELECT string_agg(o::text, chr(10) ORDER BY o.id) FROM app.orders o",
        "SELECT string_agg(c::text, chr(10) ORDER BY c.id) FROM app.customers c",
        "SELECT string_agg(v::text, chr(10) ORDER BY v.id) FROM app.big_orders v",
        "SELECT string_agg(e::text, chr(10) ORDER BY e.id) FROM app.events e",
        """
        SELECT string_agg(c.relname || ' ' || c.relkind::text, ',' ORDER BY c.relname) FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'app'
        """,
        """
        SELECT string_agg(conname || ' ' || conrelid::regclass::text, ',' ORDER BY conname, conrelid::regclass::text)
        FROM pg_constraint WHERE connamespace = 'app'::regnamespace
        """,
        """
        SELECT string_agg(conname || ' ' || conrelid::regclass::text || ' ' || convalidated::text,
          ',' ORDER BY conname, conrelid::regclass::text)
        FROM pg_constraint WHERE connamespace = 'app'::regnamespace AND contype = 'c'
        """,
      ]
      let restoredValues = try await Self.values(restoredConfig, compare)
      #expect(restoredValues == (try await Self.values(Self.postgresConfig(name), compare)))
      let checks: String = [
        "customers_id_check app.customers false", "events_id_big app.events false",
        "events_id_big app.events_2026 false", "events_id_check app.events true",
        "events_id_check app.events_2026 true", "positive_check - true", "positive_small - false",
      ].joined(separator: ",")
      #expect(restoredValues.last == .string(checks))
      let next = [
        "INSERT INTO app.customers (name) VALUES ('Cy') RETURNING id::text || ' ' || big::text",
        "INSERT INTO app.orders (room) VALUES (3) RETURNING id::text",
      ]
      #expect(try await Self.values(restoredConfig, next) == [.string("3 3"), .string("3")])
    } catch {
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
      (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '')
    """,
  ]

  @Test(
    "MySQL dump keeps every value, turns foreign key checks off around the data and restores",
    .requiresMySQL, .timeLimit(.minutes(2)), arguments: [Server.mysql, .mariadb])
  func mysqlServerDump(server: Server) async throws {
    let name = "dump_\(UUID().uuidString.prefix(8).lowercased())"
    let restored = name + "_restored"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: MySQLManagerTests.rootConfig(server))
    let directory = try Self.temporaryDirectory()
    do {
      // utf8mb4 on both servers, whatever their default character set
      _ = try await admin.executeInternal("CREATE DATABASE \(name) CHARACTER SET utf8mb4")
      _ = try await admin.executeInternal("CREATE DATABASE \(restored) CHARACTER SET utf8mb4")
      let config = Self.mysqlConfig(server, name)
      try await Self.run(config, Self.mysqlSeed)

      let destination = directory.appendingPathComponent("dump.sql")
      let progress = try await SQLDumpWriter(
        config: config, material: nil, sshCredential: nil,
        sshHostKeyPrompt: RejectingSSHHostKeyPrompt()
      ).write(to: destination)
      #expect(progress == SQLDumpProgress(tablesDone: 2, tableCount: 2, rowsWritten: 5))
      let text = try String(contentsOf: destination, encoding: .utf8)

      let lines = text.components(separatedBy: "\n")
      #expect(lines[0].hasPrefix("-- Dblore SQL dump 1 engine=MySQL created="))
      #expect(lines[1] == "SET time_zone = '+00:00';")
      #expect(lines[2] == "SET NAMES utf8mb4;")
      #expect(lines[3].hasPrefix("SET SESSION sql_mode = "))
      let checksOff = try #require(lines.firstIndex(of: "SET FOREIGN_KEY_CHECKS=0;"))
      let checksOn = try #require(lines.firstIndex(of: "SET FOREIGN_KEY_CHECKS=1;"))
      let firstCreate = try #require(lines.firstIndex { $0.hasPrefix("CREATE TABLE") })
      let lastInsert = try #require(lines.lastIndex { $0.hasPrefix("INSERT INTO") })
      #expect(checksOff < firstCreate && lastInsert < checksOn)
      #expect(lines[checksOn + 1].hasPrefix("CREATE ALGORITHM="))

      let json = server == .mysql ? "{\"k\": [1, 2.5]}" : "{\"k\": [1, 2.50]}"
      for expected in [
        "CREATE TABLE `orders` (",
        "AUTO_INCREMENT=3",
        "INSERT INTO `orders` (`id`, `customer_id`, `amount`, `ratio`, `at`, `ts`, `doc`, `raw`,"
          + " `flags`, `note`) VALUES",
        "('1', '1', '1.123456789012345678', '0.1', '2026-10-15 12:34:56.123456',"
          + " '2026-10-15 12:34:56.654321', '\(json)', X'DEADBEEF', X'05', 'a\\\\b''c\u{1F600}')",
        "('2', '2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '')",
        "SQL SECURITY DEFINER VIEW `big_orders` AS select",
      ] {
        #expect(text.contains(expected), "\(server) \(expected)")
      }
      #expect(!text.contains("DEFINER=`"))

      // Restored on a session that has NO_BACKSLASH_ESCAPES on: the dump turns it off
      let restoredConfig = Self.mysqlConfig(server, restored)
      let restoreModes = try await Self.values(
        restoredConfig,
        [
          "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')",
          "SELECT @@SESSION.sql_mode", text, "SELECT @@SESSION.sql_mode",
        ])
      guard case .string(let before) = restoreModes[1], case .string(let after) = restoreModes[3]
      else { throw MySQLSessionError(message: "sql_mode was not read") }
      #expect(before.contains("NO_BACKSLASH_ESCAPES"))
      #expect(!after.contains("NO_BACKSLASH_ESCAPES") && after.contains("NO_AUTO_VALUE_ON_ZERO"))
      let compare = [
        """
        SELECT GROUP_CONCAT(CONCAT_WS(',', id, QUOTE(customer_id), QUOTE(amount), QUOTE(ratio),
          QUOTE(at), QUOTE(ts), QUOTE(doc), QUOTE(HEX(raw)), QUOTE(HEX(flags)), QUOTE(note),
          QUOTE(total)) ORDER BY id SEPARATOR '|') FROM orders
        """,
        "SELECT GROUP_CONCAT(CONCAT_WS(',', id, name) ORDER BY id SEPARATOR '|') FROM customers",
        "SELECT GROUP_CONCAT(id ORDER BY id) FROM big_orders",
      ]
      #expect(try await Self.values(restoredConfig, compare) == Self.values(config, compare))
      let next = try await Self.values(
        restoredConfig,
        [
          "INSERT INTO customers (name) VALUES ('Cy')",
          "SELECT id FROM customers WHERE name = 'Cy'",
        ])
      #expect(next.last == .int(3))
    } catch {
      await Self.dropMySQL(admin, [name, restored], directory)
      throw error
    }
    await Self.dropMySQL(admin, [name, restored], directory)
  }

  private static func mysqlConfig(_ server: Server, _ database: String) -> ConnectionConfig {
    var config = MySQLManagerTests.rootConfig(server)
    config.database = database
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

  /// Runs each script on a new connection to `config`
  private static func run(_ config: ConnectionConfig, _ scripts: [String]) async throws {
    _ = try await values(config, scripts)
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
      .appendingPathComponent("dblore-dump-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
