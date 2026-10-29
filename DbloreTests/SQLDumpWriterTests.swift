// SQLDumpWriterTests.swift
// The SQL dump writer without a server: the snapshot session statements per engine (recording
// fake session), the read-only reader, the dump layout and INSERT batching, value literals, the
// destination refusal, cancel, and that the unremembered certificate and SSH secret reach the
// dump connection. A real SQLite file (WAL, AUTOINCREMENT, FTS5, generated column, REAL, BLOB,
// empty string and NULL) is dumped and the dump is restored into a fresh database.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite("SQLDumpWriterTests")
@MainActor
struct SQLDumpWriterTests {
  private typealias Column = TableStructure.Column

  // MARK: - Snapshot session

  @Test func brakeLiftStatementsArePinnedPerEngineAndFlavor() throws {
    #expect(
      try DatabaseConnectionManager.dumpBrakeLiftStatements(
        databaseType: .postgresql, serverInfo: nil) == [
          "SET LOCAL statement_timeout = 0", "SET LOCAL lock_timeout = 0",
          "SET LOCAL idle_in_transaction_session_timeout = 0",
        ])
    #expect(
      try DatabaseConnectionManager.dumpBrakeLiftStatements(
        databaseType: .mysql, serverInfo: MySQLServerInfo(version: "8.4.3")) == [
          "SET SESSION max_execution_time = 0",
          "SET SESSION innodb_lock_wait_timeout = 31536000",
          "SET SESSION lock_wait_timeout = 31536000",
        ])
    #expect(
      try DatabaseConnectionManager.dumpBrakeLiftStatements(
        databaseType: .mysql, serverInfo: MySQLServerInfo(version: "11.4.3-MariaDB")) == [
          "SET SESSION max_statement_time = 0",
          "SET SESSION innodb_lock_wait_timeout = 31536000",
          "SET SESSION lock_wait_timeout = 31536000",
        ])
    #expect(
      try DatabaseConnectionManager.dumpBrakeLiftStatements(databaseType: .sqlite, serverInfo: nil)
        .isEmpty)
    #expect(throws: SQLDumpError.unknownMySQLServer) {
      try DatabaseConnectionManager.dumpBrakeLiftStatements(databaseType: .mysql, serverInfo: nil)
    }
  }

  @Test func postgresSnapshotBeginsLiftsBrakesPinsFormatsAndRollsBack() async throws {
    let session = Self.recordingSession()
    let rows = try await DatabaseConnectionManager.runDumpSnapshot(
      on: session, databaseType: .postgresql, serverInfo: nil
    ) { reader in
      try await Self.drain(reader, "SELECT 1")
    }
    #expect(rows == 0)
    #expect(
      session.statements == [
        "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
        "SET LOCAL statement_timeout = 0", "SET LOCAL lock_timeout = 0",
        "SET LOCAL idle_in_transaction_session_timeout = 0",
        "SET LOCAL search_path = ''", "SET LOCAL DateStyle = 'ISO'",
        "SET LOCAL IntervalStyle = 'postgres'", "SET LOCAL extra_float_digits = 3",
        "SET LOCAL bytea_output = 'hex'", "SELECT 1", "ROLLBACK",
      ])
  }

  @Test func mysqlSnapshotLiftsBrakesBeforeTheConsistentSnapshot() async throws {
    let session = Self.recordingSession()
    _ = try await DatabaseConnectionManager.runDumpSnapshot(
      on: session, databaseType: .mysql, serverInfo: MySQLServerInfo(version: "11.4.3-MariaDB")
    ) { reader in
      try await Self.drain(reader, "SELECT 1")
    }
    #expect(
      session.statements == [
        "SET SESSION max_statement_time = 0",
        "SET SESSION innodb_lock_wait_timeout = 31536000",
        "SET SESSION lock_wait_timeout = 31536000", "SET time_zone = '+00:00'",
        "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", "SELECT 1", "ROLLBACK",
      ])
  }

  @Test func sqliteSnapshotIsAPlainBegin() async throws {
    let session = Self.recordingSession()
    _ = try await DatabaseConnectionManager.runDumpSnapshot(
      on: session, databaseType: .sqlite, serverInfo: nil
    ) { reader in
      try await Self.drain(reader, "SELECT 1")
    }
    #expect(session.statements == ["BEGIN", "SELECT 1", "ROLLBACK"])
  }

  @Test func duckdbSnapshotIsAReadOnlyTransactionWithoutBrakeStatements() async throws {
    #expect(
      try DatabaseConnectionManager.dumpBrakeLiftStatements(databaseType: .duckdb, serverInfo: nil)
        .isEmpty)
    let session = Self.recordingSession()
    _ = try await DatabaseConnectionManager.runDumpSnapshot(
      on: session, databaseType: .duckdb, serverInfo: nil
    ) { reader in
      try await Self.drain(reader, "SELECT 1")
    }
    #expect(session.statements == ["BEGIN TRANSACTION READ ONLY", "SELECT 1", "ROLLBACK"])
  }

  @Test func duckdbDumpIsRefusedWhileATransactionIsOpenOnTheTab() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.duckdb.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.duckdbConfig)
    _ = try await manager.execute(
      userSQL: "BEGIN TRANSACTION", policy: ProtectionPolicy(protectionLevel: .none))
    let sent = factory.statements.count
    await #expect(throws: SQLDumpError.transactionOpen) {
      _ = try await manager.withDumpSnapshot { _ in 0 }
    }
    #expect(factory.statements.count == sent)
    #expect(
      SQLDumpError.transactionOpen.errorDescription
        == "Commit or roll back the open transaction first, then export the dump.")
  }

  @Test func rollbackIsSentWhenTheBodyFails() async throws {
    let session = Self.recordingSession()
    await #expect(throws: FakeQueryError.self) {
      _ = try await DatabaseConnectionManager.runDumpSnapshot(
        on: session, databaseType: .postgresql, serverInfo: nil
      ) { _ -> Int in
        throw FakeQueryError()
      }
    }
    #expect(session.statements.last == "ROLLBACK")
  }

  @Test func readerRefusesStatementsThatAreNotReads() async throws {
    let session = Self.recordingSession()
    await #expect(throws: SQLDumpError.notRead) {
      _ = try await DatabaseConnectionManager.runDumpSnapshot(
        on: session, databaseType: .sqlite, serverInfo: nil
      ) { reader in
        try await Self.drain(reader, "DELETE FROM t")
      }
    }
    await #expect(throws: SQLDumpError.notRead) {
      _ = try await DatabaseConnectionManager.runDumpSnapshot(
        on: session, databaseType: .postgresql, serverInfo: nil
      ) { reader in
        try await Self.drain(reader, "SELECT 1; SELECT 2")
      }
    }
    #expect(!session.statements.contains { $0.contains("DELETE") || $0.contains("SELECT 2") })
    #expect(session.statements.last == "ROLLBACK")
  }

  // MARK: - Layout and batching

  private static func column(_ ordinal: Int, _ name: String, _ type: String) -> Column {
    Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: true, defaultExpression: nil,
      identity: nil, generated: nil, comment: nil, columnType: nil, extra: nil,
      characterSet: nil, collation: nil)
  }

  private static func insert(
    _ target: String, _ columns: [String], overriding: Bool = false
  ) -> SQLDumpDDL.TableInsert {
    SQLDumpDDL.TableInsert(
      schema: "s", name: target, target: target,
      columns: columns.enumerated().map { column($0.offset + 1, $0.element, "text") },
      overridingSystemValue: overriding, hasData: true)
  }

  private static let created = Date(timeIntervalSince1970: 1_760_000_000)

  /// Writes `script` with `rows` per table, returns the text
  private static func assemble(
    _ engine: DatabaseType, _ script: SQLDumpDDL.Script, rows: [[[String]]],
    maxRows: Int = SQLDumpWriter.maxBatchRows, maxBytes: Int = SQLDumpWriter.maxBatchBytes
  ) throws -> String {
    var assembler = SQLDumpAssembler(engine: engine, maxRows: maxRows, maxBytes: maxBytes)
    var text = assembler.opening(script, created: created)
    for (table, tableRows) in zip(script.tables, rows) {
      try assembler.begin(table)
      for row in tableRows {
        if let flushed = assembler.append(row) { text += flushed }
      }
      if let flushed = assembler.finish() { text += flushed }
    }
    return text + assembler.closing(script)
  }

  @Test func postgresDumpLayout() throws {
    let script = SQLDumpDDL.Script(
      comment: ["-- Not included: functions."], preData: ["CREATE TABLE \"s\".\"t\" (a int);"],
      tables: [Self.insert("\"s\".\"t\"", ["a", "b"], overriding: true)],
      postData: ["CREATE INDEX i ON s.t (a);"])
    let text = try Self.assemble(.postgresql, script, rows: [[["1", "'x'"], ["2", "NULL"]]])
    #expect(
      text == """
        -- Dblore SQL dump 1 engine=PostgreSQL created=2025-10-09T08:53:20Z
        -- Not included: functions.
        CREATE TABLE "s"."t" (a int);
        INSERT INTO "s"."t" ("a", "b") OVERRIDING SYSTEM VALUE VALUES
        (1, 'x'),
        (2, NULL);
        CREATE INDEX i ON s.t (a);

        """)
  }

  @Test func mysqlLayoutTurnsForeignKeyChecksOffAroundTablesAndData() throws {
    let script = SQLDumpDDL.Script(
      comment: ["-- Not included: triggers."],
      preData: ["CREATE TABLE `a` (id int);", "CREATE TABLE `b` (id int);"],
      tables: [Self.insert("`a`", ["id"]), Self.insert("`b`", ["id"])],
      postData: ["CREATE VIEW `v` AS select 1;"])
    let text = try Self.assemble(.mysql, script, rows: [[["1"]], [["2"]]])
    #expect(
      text == """
        -- Dblore SQL dump 1 engine=MySQL created=2025-10-09T08:53:20Z
        SET time_zone = '+00:00';
        SET NAMES utf8mb4;
        SET SESSION sql_mode = TRIM(BOTH ',' FROM CONCAT(REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','), 'NO_AUTO_VALUE_ON_ZERO'));
        -- Not included: triggers.
        SET FOREIGN_KEY_CHECKS=0;
        CREATE TABLE `a` (id int);
        CREATE TABLE `b` (id int);
        INSERT INTO `a` (`id`) VALUES
        (1);
        INSERT INTO `b` (`id`) VALUES
        (2);
        SET FOREIGN_KEY_CHECKS=1;
        CREATE VIEW `v` AS select 1;

        """)
  }

  @Test func sqliteDumpDefersForeignKeysRightAfterTheHeader() throws {
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(
        masterRows: [
          .init(type: "table", name: "t", tableName: "t", sql: "CREATE TABLE t (a)")
        ],
        structures: [
          TableStructure(
            tableID: .sqlite(schema: "main", table: "t"), schema: "main", name: "t",
            columns: [Self.column(1, "a", "")], indexes: [], constraints: [])
        ]))
    let text = try Self.assemble(.sqlite, script, rows: [[["X'00'"]]])
    #expect(
      text == """
        -- Dblore SQL dump 1 engine=SQLite created=2025-10-09T08:53:20Z
        PRAGMA defer_foreign_keys = ON;
        CREATE TABLE t (a);
        INSERT INTO "t" ("a") VALUES
        (X'00');

        """)
  }

  @Test func commentLinesNeverBreakIntoStatements() throws {
    // `sqlite_master.name` is file data: a crafted name with line breaks must stay in its comment
    let payload =
      "x\nATTACH DATABASE '/path/evil' AS e;\rDROP TABLE victim;\u{2028}DELETE FROM t;"
      + "\u{2029}UPDATE t SET a = 1;\u{85}INSERT INTO t VALUES (1);\u{0B}VACUUM;--"
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(
        masterRows: [
          .init(
            type: "table", name: payload, tableName: payload,
            sql: "CREATE VIRTUAL TABLE v USING fts5(a)")
        ],
        structures: []))
    let text = try Self.assemble(.sqlite, script, rows: [[]])
    let lines = text.split(omittingEmptySubsequences: false) {
      $0.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
    for keyword in ["ATTACH", "DROP", "DELETE", "UPDATE", "INSERT", "VACUUM"] {
      for line in lines where line.contains(keyword) {
        #expect(line.hasPrefix("-- "), "\(line)")
      }
    }
    #expect(
      text.hasSuffix("PRAGMA defer_foreign_keys = ON;\nCREATE VIRTUAL TABLE v USING fts5(a);\n"))
  }

  @Test func sqliteDropNeverDropsAVirtualTableAndCreatesItOnlyWhenMissing() throws {
    // Their rows are not dumped: a DROP would empty a filled one
    let rows: [SQLDumpDDL.SQLiteMasterRow] = [
      .init(
        type: "table", name: "docs", tableName: "docs",
        sql: "CREATE VIRTUAL TABLE docs USING fts5(body)"),
      .init(
        type: "table", name: "my docs", tableName: "my docs",
        sql: "CREATE VIRTUAL TABLE \"my docs\" USING fts5(body)"),
      // Text SQLite never stores (it strips IF NOT EXISTS) stays as is
      .init(
        type: "table", name: "r", tableName: "r",
        sql: "CREATE VIRTUAL TABLE IF NOT EXISTS r USING rtree(id, a, b)"),
      // Still dropped: the restore's CREATE VIEW would fail on the source's view
      .init(
        type: "view", name: "dv", tableName: "dv", sql: "CREATE VIEW dv AS SELECT body FROM docs"),
    ]
    let input = SQLDumpDDL.SQLiteInput(masterRows: rows, structures: [])
    let dropping = try SQLDumpDDL.sqlite(
      input, options: SQLDumpOptions(otherTables: SQLDumpOptions.TableOptions(drop: true)))
    #expect(dropping.containsDrop)
    #expect(
      dropping.preData == [
        "PRAGMA defer_foreign_keys = ON;",
        "DROP VIEW IF EXISTS \"dv\";",
        "CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(body);",
        "CREATE VIRTUAL TABLE IF NOT EXISTS \"my docs\" USING fts5(body);",
        "CREATE VIRTUAL TABLE IF NOT EXISTS r USING rtree(id, a, b);",
      ])
    #expect(dropping.postData == ["CREATE VIEW dv AS SELECT body FROM docs;"])
    #expect(dropping.comment.joined().contains("Drop keeps an existing one with its rows"))
    let text = try Self.assemble(.sqlite, dropping, rows: [[], [], []])
    #expect(text.hasPrefix(SQLRestorePlan.dropHeaderPrefix))
    #expect(try SQLRestorePlan(script: text, engine: .sqlite).summary.count(.drop) == 1)
    // Without Drop the catalog text is kept
    let plain = try SQLDumpDDL.sqlite(input)
    #expect(plain.preData[1] == "CREATE VIRTUAL TABLE docs USING fts5(body);")
    #expect(!plain.comment.joined().contains("Drop keeps"))
  }

  @Test func insertBatchesHoldAtMost500Rows() throws {
    let script = SQLDumpDDL.Script(
      comment: [], preData: [], tables: [Self.insert("t", ["a"])], postData: [])
    let rows = (1...1001).map { [String($0)] }
    let text = try Self.assemble(.postgresql, script, rows: [rows])
    let statements = text.components(separatedBy: "INSERT INTO").dropFirst()
    #expect(statements.map { $0.components(separatedBy: "\n(").count - 1 } == [500, 500, 1])
  }

  @Test func insertBatchesStayUnderTheByteLimitAndAnOversizedRowGoesAlone() throws {
    let script = SQLDumpDDL.Script(
      comment: [], preData: [], tables: [Self.insert("t", ["a"])], postData: [])
    let row = "'" + String(repeating: "x", count: 1_500_000) + "'"
    let huge = "'" + String(repeating: "y", count: 5_000_000) + "'"
    let text = try Self.assemble(.postgresql, script, rows: [[[row], [row], [row], [huge], [row]]])
    let statements = text.components(separatedBy: "INSERT INTO").dropFirst()
    #expect(statements.map { $0.components(separatedBy: "\n(").count - 1 } == [2, 1, 1, 1])
    for statement in statements where !statement.contains("y") {
      #expect(statement.utf8.count <= SQLDumpWriter.maxBatchBytes)
    }
  }

  @Test func zeroColumnRowsUseDefaultValues() throws {
    let script = SQLDumpDDL.Script(
      comment: [], preData: [], tables: [Self.insert("t", [])], postData: [])
    let text = try Self.assemble(.postgresql, script, rows: [[[], []]])
    #expect(text.hasSuffix("\nINSERT INTO t DEFAULT VALUES;\nINSERT INTO t DEFAULT VALUES;\n"))
  }

  // MARK: - Values

  @Test func dataReadsUseTextFormsPerEngine() throws {
    var bin = Self.column(2, "bin", "varbinary")
    bin.columnType = "varbinary(4)"
    let mysql = SQLDumpDDL.TableInsert(
      schema: "db", name: "t", target: "`t`",
      columns: [Self.column(1, "a`b", "decimal"), bin, Self.column(3, "flag", "bit")],
      overridingSystemValue: false, hasData: true)
    #expect(
      try SQLDumpDataRenderer.selectStatement(mysql, engine: .mysql)
        == "SELECT CAST(`a``b` AS CHAR), HEX(`bin`), HEX(`flag`) FROM `t`")
    let postgres = SQLDumpDDL.TableInsert(
      schema: "s", name: "t", target: "\"s\".\"t\"",
      columns: [Self.column(1, "n", "numeric"), Self.column(2, "b", "bytea")],
      overridingSystemValue: false, hasData: true)
    #expect(
      try SQLDumpDataRenderer.selectStatement(postgres, engine: .postgresql)
        == "SELECT 'v' || \"n\"::text, 'v' || \"b\"::text FROM ONLY \"s\".\"t\"")
    let sqlite = SQLDumpDDL.TableInsert(
      schema: "main", name: "t", target: "\"t\"", columns: [Self.column(1, "a", "")],
      overridingSystemValue: false, hasData: true)
    #expect(
      try SQLDumpDataRenderer.selectStatement(sqlite, engine: .sqlite)
        == "SELECT quote(\"a\") FROM \"t\"")
    let empty = SQLDumpDDL.TableInsert(
      schema: "s", name: "e", target: "\"s\".\"e\"", columns: [], overridingSystemValue: false,
      hasData: true)
    #expect(
      try SQLDumpDataRenderer.selectStatement(empty, engine: .postgresql)
        == "SELECT FROM ONLY \"s\".\"e\"")
  }

  @Test func literalsKeepEveryValueExact() throws {
    let text = Self.column(1, "t", "text")
    func pg(_ value: CellValue) throws -> String {
      try SQLDumpDataRenderer.literal(value, column: text, table: "t", engine: .postgresql)
    }
    #expect(try pg(.null) == "NULL")
    #expect(try pg(.string("v")) == "''")
    #expect(try pg(.string("v1.123456789012345678")) == "'1.123456789012345678'")
    #expect(try pg(.string("vit's")) == "'it''s'")
    #expect(try pg(.string("v\\xdeadbeef")) == "E'\\\\xdeadbeef'")
    // A leading combining mark joins the "v" prefix in one character
    #expect(try pg(.string("v\u{301}x")) == "'\u{301}x'")
    #expect(throws: SQLDumpError.unexpectedValue(table: "t", column: "t")) {
      try pg(.int(1))
    }

    func mysql(_ value: CellValue, _ type: String) throws -> String {
      try SQLDumpDataRenderer.literal(
        value, column: Self.column(1, "c", type), table: "t", engine: .mysql)
    }
    #expect(try mysql(.string("DEADBEEF"), "blob") == "X'DEADBEEF'")
    #expect(try mysql(.string("5"), "bit") == "X'05'")
    #expect(try mysql(.string(""), "varbinary") == "X''")
    #expect(try mysql(.string(""), "varchar") == "''")
    #expect(try mysql(.string("a\\b'c"), "varchar") == "'a\\\\b''c'")
    #expect(try mysql(.null, "blob") == "NULL")
    #expect(try mysql(.data(Data([0x01, 0xAB])), "varchar") == "X'01AB'")

    func sqlite(_ value: CellValue) throws -> String {
      try SQLDumpDataRenderer.literal(value, column: text, table: "t", engine: .sqlite)
    }
    #expect(try sqlite(.string("X'00FF'")) == "X'00FF'")
    #expect(try sqlite(.string("NULL")) == "NULL")
    #expect(try sqlite(.string("3.0000000000000004441e-01")) == "3.0000000000000004441e-01")
    for literal in [
      "''", "'a'''", "'it''s'", "'\u{0301}a'", "X''", "-2", "1.5", "9.0e+999", "-9.0e+999",
    ] {
      #expect(try sqlite(.string(literal)) == literal)
    }
  }

  @Test func duckdbReadsTextAndBlobsAsHex() throws {
    let table = SQLDumpDDL.TableInsert(
      schema: "main", name: "t", target: "\"main\".\"t\"",
      columns: [Self.column(1, "a\"b", "DECIMAL(18,4)"), Self.column(2, "bin", "BLOB")],
      overridingSystemValue: false, hasData: true)
    #expect(
      try SQLDumpDataRenderer.selectStatement(table, engine: .duckdb)
        == "SELECT CAST(\"a\"\"b\" AS VARCHAR), hex(\"bin\") FROM \"main\".\"t\"")
    func duckdb(_ value: CellValue, _ type: String) throws -> String {
      try SQLDumpDataRenderer.literal(
        value, column: Self.column(1, "c", type), table: "t", engine: .duckdb)
    }
    #expect(try duckdb(.null, "BLOB") == "NULL")
    #expect(try duckdb(.string(""), "VARCHAR") == "''")
    #expect(try duckdb(.string("it's a \\ path"), "VARCHAR") == "'it''s a \\ path'")
    #expect(
      try duckdb(.string("2024-01-02 02:04:05.123456+01"), "TIMESTAMP WITH TIME ZONE")
        == "'2024-01-02 02:04:05.123456+01'")
    #expect(try duckdb(.string("AB005CFF"), "BLOB") == "'\\xAB\\x00\\x5C\\xFF'")
    #expect(try duckdb(.string(""), "BLOB") == "''")
    let refused = SQLDumpError.unexpectedValue(table: "t", column: "c")
    for hex in ["ABC", "GG", "AB'", "\u{FF11}\u{FF11}"] {
      #expect(throws: refused) { try duckdb(.string(hex), "BLOB") }
    }
    #expect(throws: refused) { try duckdb(.int(1), "INTEGER") }
    // A restore refuses any DuckDB script with a NUL: the dump stops instead of writing one
    #expect(throws: refused) { try duckdb(.string("a\u{0}b"), "VARCHAR") }
  }

  @Test func literalsRefuseValuesNotInTheFormRead() throws {
    let refused = SQLDumpError.unexpectedValue(table: "t", column: "c")
    for hex in ["GG", "DE;AD", "DE AD", "\u{FF11}"] {
      #expect(throws: refused) {
        try SQLDumpDataRenderer.literal(
          .string(hex), column: Self.column(1, "c", "blob"), table: "t", engine: .mysql)
      }
    }
    let invalid = [
      "1; DROP TABLE t", "'a' || 'b'", "'ab'cd'", "X'GG'", "'unterminated", "'", "X'", "--",
      "1 OR 1", "", "Inf", "1e", "-", ".5", "\u{FF11}", "'a'\u{0301}; DROP TABLE t --'",
    ]
    for text in invalid {
      #expect(throws: refused) {
        try SQLDumpDataRenderer.literal(
          .string(text), column: Self.column(1, "c", "text"), table: "t", engine: .sqlite)
      }
    }
  }

  // MARK: - Destination

  @Test func destinationRefusesTheConnectedSQLiteFileAndItsSiblings() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("app.sqlite")
    FileManager.default.createFile(atPath: database.path, contents: Data())
    let link = directory.appendingPathComponent("link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: database)
    let config = Self.sqliteConfig(database.path)
    for path in [
      database.path, database.path + "-wal", database.path + "-journal", database.path + "-shm",
      link.path, directory.path + "/./sub/../app.sqlite",
    ] {
      #expect(
        SQLDumpWriter.isConnectedDatabaseFile(URL(fileURLWithPath: path), config: config),
        "\(path)")
    }
    #expect(
      !SQLDumpWriter.isConnectedDatabaseFile(
        directory.appendingPathComponent("app.sql"), config: config))
    var postgres = config
    postgres.databaseType = .postgresql
    #expect(!SQLDumpWriter.isConnectedDatabaseFile(database, config: postgres))
  }

  @Test func destinationRefusesTheConnectedDuckDBFileAndItsWAL() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("app.duckdb")
    FileManager.default.createFile(atPath: database.path, contents: Data())
    let config = ConnectionConfig(databaseType: .duckdb, database: database.path)
    for path in [database.path, database.path + ".wal"] {
      #expect(
        SQLDumpWriter.isConnectedDatabaseFile(URL(fileURLWithPath: path), config: config),
        "\(path)")
    }
    #expect(
      !SQLDumpWriter.isConnectedDatabaseFile(
        directory.appendingPathComponent("app.sql"), config: config))
    #expect(
      !SQLDumpWriter.isConnectedDatabaseFile(
        directory.appendingPathComponent(":memory:"),
        config: ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath)))
  }

  @Test func duckdbIsNeverDumpedThroughASecondConnection() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.duckdb.capabilities)
    let writer = SQLDumpWriter(
      config: Self.duckdbConfig, material: nil, sshCredential: nil, sessionFactory: factory,
      temporaryDirectory: directory)
    await #expect(throws: SQLDumpError.unsupportedEngine(.duckdb)) {
      _ = try await writer.write(to: directory.appendingPathComponent("out.sql"))
    }
    #expect(factory.sessions.isEmpty)
    #expect(try Self.leftovers(in: directory).isEmpty)
  }

  @Test func refusedDestinationNeverConnects() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("app.sqlite")
    FileManager.default.createFile(atPath: database.path, contents: Data())
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let writer = SQLDumpWriter(
      config: Self.sqliteConfig(database.path), material: nil, sshCredential: nil,
      sessionFactory: factory, temporaryDirectory: directory)
    await #expect(throws: SQLDumpError.destinationIsDatabase) {
      _ = try await writer.write(to: URL(fileURLWithPath: database.path + "-wal"))
    }
    #expect(factory.sessions.isEmpty)
  }

  // MARK: - Connection

  @Test func unrememberedCertificateAndSSHSecretReachTheDumpConnection() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = ConnectionConfig(
      host: "fake", port: 1, database: "db", username: "u", password: "p")
    config.rememberConnection = false
    config.clientCertificate = ClientCertificateInfo(subject: "CN=u", expiry: nil, hasCA: false)
    config.sshTunnel = SSHTunnelConfig(
      host: "bastion-\(UUID().uuidString).example", username: "jump")
    let certificate = ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key")
    let secret = SSHStoredCredential.password("held-only-in-memory")
    let factory = MaterialRecordingFactory(FakeDatabaseSessionFactory(capabilities: .contract()))
    let writer = SQLDumpWriter(
      config: config,
      material: .init(
        account: ClientCertificateStoreFactory.account(for: config), material: certificate),
      sshCredential: .init(
        account: try #require(SSHCredentialStoreFactory.account(for: config)), credential: secret),
      sessionFactory: factory, temporaryDirectory: directory)
    let destination = directory.appendingPathComponent("out.sql")
    let progress = try await writer.write(to: destination)

    #expect(factory.certificates == [certificate])
    #expect(factory.credentials == [secret])
    #expect(progress == SQLDumpProgress(tablesDone: 0, tableCount: 0, rowsWritten: 0))
    let statements = factory.inner.statements
    #expect(statements.first == "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
    #expect(statements.last == "ROLLBACK")
    let text = try String(contentsOf: destination, encoding: .utf8)
    #expect(text.hasPrefix("-- Dblore SQL dump 1 engine=PostgreSQL created="))
    let sessions = factory.inner.sessions
    #expect(sessions.allSatisfy { $0.didClose })
    #expect(try Self.leftovers(in: directory) == ["out.sql"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelRollsBackAndDeletesTheTemporaryFile() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = SessionAnnouncingFactory(
      FakeDatabaseSessionFactory(capabilities: .contract(), slowQueries: true))
    let writer = SQLDumpWriter(
      config: ConnectionConfig(host: "fake", port: 1, database: "db", username: "u", password: "p"),
      material: nil, sshCredential: nil, sessionFactory: factory, temporaryDirectory: directory)
    let destination = directory.appendingPathComponent("out.sql")
    let task = Task { try await writer.write(to: destination) }
    // The dump's session, once the writer has made it (no deadline: the suite's limit applies)
    var made = factory.sessions.makeAsyncIterator()
    let session = try #require(await made.next())
    await session.waitUntilQueryStarted()
    // Mid-dump, the temporary file is private to the user
    let temporary = try #require(try Self.leftovers(in: directory).first)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(temporary).path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(session.statements.last == "ROLLBACK")
    #expect(session.didClose)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Self.leftovers(in: directory).isEmpty)
  }

  @Test func relockDuringTheDumpStopsItBeforeTheNextBatch() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    // 1200 rows: three INSERT batches of at most 500
    try Self.exec(
      source.path,
      """
      CREATE TABLE t (id INTEGER PRIMARY KEY);
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1200)
      INSERT INTO t SELECT i FROM n;
      """)
    let config = Self.sqliteConfig(source.path)
    let registry = LockRegistry()
    registry.setLockedConnections(LockIdentity.all(config))
    registry.grant(LockIdentity(config))
    let dumps = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
    let writer = SQLDumpWriter(
      config: config, material: nil, sshCredential: nil,
      sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
      temporaryDirectory: dumps, lockSource: registry)
    let destination = directory.appendingPathComponent("dump.sql")
    let reports = ProgressRecorder()

    // The lock comes back once the first batch is written
    do {
      _ = try await writer.write(to: destination) { progress in
        reports.append(progress)
        registry.relockAll()
      }
      Issue.record("Expected the relocked dump to be refused")
    } catch DatabaseError.connectionLocked {}
    #expect(reports.values.map(\.rowsWritten) == [500])
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Self.leftovers(in: dumps).isEmpty)
  }

  // MARK: - SQLite end to end

  @Test func sqliteDumpRestoresIntoAFreshDatabase() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    let live = SQLiteSession(config: Self.sqliteConfig(source.path))
    try await live.open()
    for statement in [
      "PRAGMA journal_mode = WAL", "PRAGMA wal_autocheckpoint = 0",
      """
      CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT, data BLOB,
        ratio REAL, note TEXT, lower_body TEXT GENERATED ALWAYS AS (lower(body)) VIRTUAL)
      """,
      """
      INSERT INTO notes (id, body, data, ratio, note) VALUES
        (1, 'Hello', X'00FF10', 0.1 + 0.2, ''), (2, 'it''s', NULL, 1e300, NULL),
        (7, 'gone', NULL, NULL, NULL)
      """,
      "DELETE FROM notes WHERE id = 7",
      "CREATE TABLE empty_auto (id INTEGER PRIMARY KEY AUTOINCREMENT)",
      "INSERT INTO empty_auto DEFAULT VALUES", "DELETE FROM empty_auto",
      "CREATE TABLE child (id INTEGER PRIMARY KEY, note_id INTEGER REFERENCES notes(id))",
      "INSERT INTO child VALUES (1, 2)",
      "CREATE VIRTUAL TABLE notes_fts USING fts5(body)",
      "INSERT INTO notes_fts (body) VALUES ('searchable')",
      "CREATE INDEX idx_notes_body ON notes (body)",
      "CREATE VIEW v_notes AS SELECT body FROM notes",
    ] {
      _ = try await live.command(statement, binds: [])
    }
    let destination = directory.appendingPathComponent("dump.sql")
    try "old dump".write(to: destination, atomically: true, encoding: .utf8)

    let dumps = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
    let writer = SQLDumpWriter(
      config: Self.sqliteConfig(source.path), material: nil, sshCredential: nil,
      sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
      temporaryDirectory: dumps)
    let reports = ProgressRecorder()
    let progress = try await writer.write(to: destination) { reports.append($0) }
    await live.close()

    #expect(progress == SQLDumpProgress(tablesDone: 3, tableCount: 3, rowsWritten: 3))
    #expect(reports.values.last == progress)
    #expect(try Self.leftovers(in: dumps).isEmpty)
    let text = try String(contentsOf: destination, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    #expect(lines[0].hasPrefix("-- Dblore SQL dump 1 engine=SQLite created="))
    #expect(lines.dropFirst().first { !$0.hasPrefix("--") } == "PRAGMA defer_foreign_keys = ON;")
    #expect(text.contains("CREATE VIRTUAL TABLE notes_fts USING fts5(body);"))
    for shadow in ["_data", "_idx", "_content", "_docsize", "_config"] {
      #expect(!text.contains("notes_fts\(shadow)"), "\(shadow)")
    }
    #expect(
      text.contains(
        "INSERT INTO \"notes\" (\"id\", \"body\", \"data\", \"ratio\", \"note\") VALUES\n"
          + "(1, 'Hello', X'00FF10', "))
    #expect(text.contains("(2, 'it''s', NULL, 1.0e+300, NULL)"))
    #expect(text.contains("INSERT INTO sqlite_sequence (name, seq) VALUES ('notes', 7);"))
    #expect(text.contains("INSERT INTO sqlite_sequence (name, seq) VALUES ('empty_auto', 1);"))

    let restored = directory.appendingPathComponent("restored.db")
    try Self.exec(restored.path, "BEGIN;\n" + text + "\nCOMMIT;")
    let compare = [
      "SELECT quote(id), quote(body), quote(data), quote(ratio), quote(note), lower_body"
        + " FROM notes ORDER BY id",
      "SELECT name, seq FROM sqlite_sequence ORDER BY name",
      "SELECT * FROM child", "SELECT * FROM v_notes ORDER BY body",
      "SELECT ratio = 0.1 + 0.2 FROM notes WHERE id = 1",
      "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL",
    ]
    for sql in compare {
      #expect(try Self.query(restored.path, sql) == Self.query(source.path, sql), "\(sql)")
    }
    #expect(try Self.query(restored.path, "SELECT count(*) FROM notes_fts") == [["0"]])
  }

  // MARK: - Table subset and schema only

  private typealias Name = SQLDumpDDL.ObjectName

  private static func table(
    _ schema: String, _ name: String, references: Name? = nil
  ) -> TableStructure {
    TableStructure(
      tableID: .postgresql(oid: 1), schema: schema, name: name,
      columns: [column(1, "id", "integer")], indexes: [],
      constraints: references.map {
        [
          TableStructure.Constraint(
            name: "\(name)_fk",
            kind: .foreignKey(
              TableStructure.ForeignKeyReference(
                schema: $0.schema, table: $0.name, columns: ["id"], onUpdate: .noAction,
                onDelete: .noAction)), columns: ["id"])
        ]
      } ?? [])
  }

  private static func sequence(
    _ name: String, owner: Name?, identity: Bool = false
  ) -> SQLDumpDDL.PostgresSequence {
    SQLDumpDDL.PostgresSequence(
      schema: "app", name: name, dataType: "integer", start: 1, increment: 1, minValue: 1,
      maxValue: 100, cycle: false,
      ownedBy: owner.map { SQLDumpDDL.ColumnRef(table: $0, column: "id") }, lastValue: 3,
      isIdentity: identity)
  }

  @Test func postgresSelectionKeepsPartitionsSequencesAndViewsThatStillResolve() {
    let events = Name(schema: "app", name: "events")
    let partition = Name(schema: "app", name: "events_2026")
    let orders = Name(schema: "app", name: "orders")
    let customers = Name(schema: "app", name: "customers")
    let input = SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(structure: Self.table("app", "customers")),
        SQLDumpDDL.PostgresTable(
          structure: Self.table("app", "events"), partitionKey: "RANGE (id)"),
        SQLDumpDDL.PostgresTable(
          structure: Self.table("app", "events_2026"),
          partitionOf: SQLDumpDDL.Partition(parent: events, bound: "DEFAULT")),
        SQLDumpDDL.PostgresTable(structure: Self.table("app", "orders", references: customers)),
      ],
      sequences: [
        Self.sequence("customers_id_seq", owner: customers),
        Self.sequence("orders_id_seq", owner: orders, identity: true),
        Self.sequence("events_id_seq", owner: events),
        Self.sequence("shared_seq", owner: nil),
      ],
      enums: [SQLDumpDDL.PostgresEnum(schema: "app", name: "mood", labels: ["ok"])], domains: [],
      views: [
        SQLDumpDDL.View(schema: "app", name: "v_events", sql: "SELECT 1", dependsOn: [events]),
        SQLDumpDDL.View(schema: "app", name: "v_orders", sql: "SELECT 1", dependsOn: [orders]),
        SQLDumpDDL.View(
          schema: "app", name: "v_on_v_orders", sql: "SELECT 1",
          dependsOn: [Name(schema: "app", name: "v_orders")]),
        SQLDumpDDL.View(
          schema: "app", name: "v_catalog", sql: "SELECT 1",
          dependsOn: [Name(schema: "pg_catalog", name: "pg_class")]),
      ])

    // The partition follows its parent; the parent comes with a chosen partition
    for chosen in [Set([events]), Set([partition])] {
      let kept = SQLDumpSelection.postgres(input, keeping: chosen)
      #expect(kept.tables.map(\.structure.name) == ["events", "events_2026"])
      // An identity sequence of a table left out goes; another one stays without OWNED BY
      #expect(kept.sequences.map(\.name) == ["customers_id_seq", "events_id_seq", "shared_seq"])
      #expect(kept.sequences.map(\.ownedBy?.table) == [nil, events, nil])
      #expect(kept.views.map(\.name) == ["v_events", "v_catalog"])
      #expect(kept.enums == input.enums)
    }
    let ordersOnly = SQLDumpSelection.postgres(input, keeping: [orders, customers])
    #expect(ordersOnly.tables.map(\.structure.name) == ["customers", "orders"])
    #expect(ordersOnly.views.map(\.name) == ["v_orders", "v_on_v_orders", "v_catalog"])
    #expect(
      ordersOnly.sequences.map(\.name) == [
        "customers_id_seq", "orders_id_seq", "events_id_seq", "shared_seq",
      ])
  }

  @Test func mysqlSelectionDropsTablesAndTheViewsOnThem() {
    let orders = Name(schema: "shop", name: "orders")
    let input = SQLDumpDDL.MySQLInput(
      tables: [
        SQLDumpDDL.MySQLTable(
          structure: Self.table("shop", "customers"), createStatement: "CREATE TABLE c"),
        SQLDumpDDL.MySQLTable(
          structure: Self.table("shop", "orders"), createStatement: "CREATE TABLE o"),
      ],
      views: [
        SQLDumpDDL.View(schema: "shop", name: "v_orders", sql: "CREATE VIEW", dependsOn: [orders]),
        SQLDumpDDL.View(schema: "shop", name: "v_plain", sql: "CREATE VIEW", dependsOn: []),
      ])
    let kept = SQLDumpSelection.mysql(input, keeping: [Name(schema: "shop", name: "customers")])
    #expect(kept.tables.map(\.structure.name) == ["customers"])
    #expect(kept.views.map(\.name) == ["v_plain"])
    #expect(SQLDumpSelection.mysql(input, keeping: [orders]).views.count == 2)
  }

  @Test func sqliteSelectionDropsTablesWithTheirIndexesAndTriggers() {
    func row(
      _ type: String, _ name: String, _ table: String, _ sql: String?
    )
      -> SQLDumpDDL.SQLiteMasterRow
    {
      SQLDumpDDL.SQLiteMasterRow(type: type, name: name, tableName: table, sql: sql)
    }
    let input = SQLDumpDDL.SQLiteInput(
      masterRows: [
        row("table", "notes", "notes", "CREATE TABLE notes (id)"),
        row("table", "tags", "tags", "CREATE TABLE tags (id)"),
        row("table", "sqlite_sequence", "sqlite_sequence", "CREATE TABLE sqlite_sequence(n,s)"),
        row("table", "fts", "fts", "CREATE VIRTUAL TABLE fts USING fts5(body)"),
        row("table", "fts_data", "fts_data", "CREATE TABLE 'fts_data'(id)"),
        row("index", "idx_tags", "tags", "CREATE INDEX idx_tags ON tags (id)"),
        row("index", "sqlite_autoindex_notes_1", "notes", nil),
        row("trigger", "tags_trigger", "tags", "CREATE TRIGGER tags_trigger ..."),
        row("view", "v_tags", "v_tags", "CREATE VIEW v_tags AS SELECT id FROM tags"),
      ],
      structures: [Self.table("main", "notes"), Self.table("main", "tags")],
      shadowTableNames: ["fts_data"],
      sequences: [SQLDumpDDL.SQLiteSequence(name: "notes", seq: 3)])
    let kept = SQLDumpSelection.sqlite(input, keeping: [Name(schema: "main", name: "notes")])
    #expect(
      kept.masterRows.map(\.name) == [
        "notes", "sqlite_sequence", "fts_data", "sqlite_autoindex_notes_1", "v_tags",
      ])
    #expect(kept.structures.map(\.name) == ["notes"])
    #expect(kept.sequences == input.sequences)
    // Without the pragma, a shadow table goes with its virtual table (the name prefix rule)
    var old = input
    old.shadowTableNames = nil
    #expect(
      !SQLDumpSelection.sqlite(old, keeping: [Name(schema: "main", name: "notes")]).masterRows
        .contains { $0.name == "fts_data" })
    #expect(
      SQLDumpSelection.sqlite(input, keeping: [Name(schema: "main", name: "fts")]).masterRows
        .map(\.name) == ["sqlite_sequence", "fts", "fts_data", "v_tags"])
  }

  @Test func sqliteTableSubsetAndSchemaOnlyDumps() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    try Self.exec(
      source.path,
      """
      CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
      CREATE TABLE tags (id INTEGER PRIMARY KEY, label TEXT);
      CREATE INDEX idx_tags ON tags (label);
      INSERT INTO notes VALUES (1, 'a'), (2, 'b');
      INSERT INTO tags VALUES (1, 'x');
      """)
    func dump(_ options: SQLDumpOptions) async throws -> (SQLDumpProgress, String) {
      let destination = directory.appendingPathComponent("dump-\(UUID().uuidString).sql")
      let writer = SQLDumpWriter(
        config: Self.sqliteConfig(source.path), material: nil, sshCredential: nil,
        sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
        temporaryDirectory: directory)
      let progress = try await writer.write(to: destination, options: options)
      return (progress, try String(contentsOf: destination, encoding: .utf8))
    }
    let notes = Name(schema: "main", name: "notes")

    let (subset, subsetText) = try await dump(SQLDumpOptions(tables: [notes]))
    #expect(subset == SQLDumpProgress(tablesDone: 1, tableCount: 1, rowsWritten: 2))
    #expect(subsetText.contains("CREATE TABLE notes"))
    #expect(subsetText.contains("INSERT INTO \"notes\""))
    #expect(!subsetText.contains("tags"))

    let (schemaOnly, schemaText) = try await dump(SQLDumpOptions(includeData: false))
    // Both tables are written (without rows), so the result says "2 tables, 0 rows"
    #expect(schemaOnly == SQLDumpProgress(tablesDone: 2, tableCount: 2, rowsWritten: 0))
    #expect(schemaText.contains("CREATE TABLE notes") && schemaText.contains("CREATE TABLE tags"))
    #expect(schemaText.contains("CREATE INDEX idx_tags ON tags (label);"))
    #expect(!schemaText.contains("INSERT INTO"))

    // The default options dump the same text as before (the header's time aside)
    let (all, allText) = try await dump(SQLDumpOptions())
    let destination = directory.appendingPathComponent("plain.sql")
    let plain = try await SQLDumpWriter(
      config: Self.sqliteConfig(source.path), material: nil, sshCredential: nil,
      sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
      temporaryDirectory: directory
    ).write(to: destination)
    #expect(all == plain)
    let plainText = try String(contentsOf: destination, encoding: .utf8)
    #expect(
      allText.components(separatedBy: "\n").dropFirst()
        == plainText.components(separatedBy: "\n").dropFirst())
  }

  // MARK: - Structure, Data and Drop per table

  private typealias Flags = SQLDumpOptions.TableOptions

  /// app.items -> app.orders -> app.customers (catalog order: children first), a serial-style
  /// sequence of customers, an identity sequence of orders, a free sequence, an enum, two
  /// domains (one over the other) and two views
  private static let postgresInput = SQLDumpDDL.PostgresInput(
    tables: [
      SQLDumpDDL.PostgresTable(
        structure: table("app", "items", references: Name(schema: "app", name: "orders"))),
      SQLDumpDDL.PostgresTable(
        structure: table("app", "orders", references: Name(schema: "app", name: "customers"))),
      SQLDumpDDL.PostgresTable(structure: table("app", "customers")),
    ],
    sequences: [
      sequence("customers_id_seq", owner: Name(schema: "app", name: "customers")),
      sequence("orders_id_seq", owner: Name(schema: "app", name: "orders"), identity: true),
      sequence("free_seq", owner: nil),
    ],
    enums: [SQLDumpDDL.PostgresEnum(schema: "app", name: "mood", labels: ["ok"])],
    domains: [
      SQLDumpDDL.PostgresDomain(
        schema: "app", name: "positive", baseType: "integer", defaultExpression: nil,
        notNull: false, constraints: []),
      SQLDumpDDL.PostgresDomain(
        schema: "app", name: "small", baseType: "app.positive", defaultExpression: nil,
        notNull: false, constraints: []),
    ],
    views: [
      SQLDumpDDL.View(
        schema: "app", name: "v_on_v_orders", sql: "SELECT 1",
        dependsOn: [Name(schema: "app", name: "v_orders")]),
      SQLDumpDDL.View(
        schema: "app", name: "v_orders", sql: "SELECT 1",
        dependsOn: [Name(schema: "app", name: "orders")]),
    ])

  private static let orders = Name(schema: "app", name: "orders")
  private static let items = Name(schema: "app", name: "items")
  private static let customers = Name(schema: "app", name: "customers")

  @Test func postgresWithoutDropIsUnchangedAndHeaderStaysOne() throws {
    let plain = try SQLDumpDDL.postgres(Self.postgresInput)
    let flagged = try SQLDumpDDL.postgres(
      Self.postgresInput,
      options: SQLDumpOptions(perTable: [Self.orders: Flags(), Self.items: Flags(data: false)]))
    #expect(flagged == plain)
    #expect(!plain.containsDrop && !plain.foreignKeyCycle)
    #expect(!(plain.preData + plain.postData).contains { $0.hasPrefix("DROP") })
    let text = try Self.assemble(.postgresql, plain, rows: [[], [], []])
    #expect(text.hasPrefix("-- Dblore SQL dump 1 engine=PostgreSQL created="))
  }

  @Test func postgresDropsOnlyWhatTheDumpCreatesRightAfterTheSchemas() throws {
    let script = try SQLDumpDDL.postgres(
      Self.postgresInput, options: SQLDumpOptions(perTable: [Self.orders: Flags(drop: true)]))
    #expect(script.containsDrop)
    #expect(
      Array(script.preData.prefix(9)) == [
        "CREATE SCHEMA IF NOT EXISTS \"app\";",
        "DROP VIEW IF EXISTS \"app\".\"v_on_v_orders\";",
        "DROP VIEW IF EXISTS \"app\".\"v_orders\";",
        "DROP TABLE IF EXISTS \"app\".\"orders\";",
        // The identity sequence goes with its table
        "DROP SEQUENCE IF EXISTS \"app\".\"customers_id_seq\";",
        "DROP SEQUENCE IF EXISTS \"app\".\"free_seq\";",
        "DROP DOMAIN IF EXISTS \"app\".\"small\";",
        "DROP DOMAIN IF EXISTS \"app\".\"positive\";",
        "DROP TYPE IF EXISTS \"app\".\"mood\";",
      ])
    #expect(script.preData[9].hasPrefix("CREATE TYPE"))
    #expect(script.preData.filter { $0.hasPrefix("DROP") }.count == 8)
    #expect(!(script.preData + script.postData).contains { $0.contains("CASCADE") })
    let text = try Self.assemble(.postgresql, script, rows: [[], [], []])
    #expect(text.hasPrefix("-- Dblore SQL dump 2 engine=PostgreSQL created="))
    // The restore gate accepts every DROP: each names an object the dump creates after it
    #expect(try SQLRestorePlan(script: text, engine: .postgresql).summary.count(.drop) == 8)

    // Every table: one DROP TABLE statement; a table without Structure is never dropped
    let all = try SQLDumpDDL.postgres(
      Self.postgresInput,
      options: SQLDumpOptions(
        perTable: [Self.items: Flags(structure: false, drop: true)],
        otherTables: Flags(drop: true)))
    #expect(all.preData.contains("DROP TABLE IF EXISTS \"app\".\"orders\", \"app\".\"customers\";"))
    #expect(!all.preData.contains { $0.contains("DROP") && $0.contains("\"items\"") })
  }

  @Test func postgresStructureOffWritesNoDDLAndInsertsParentsFirst() throws {
    let mixed = try SQLDumpDDL.postgres(
      Self.postgresInput,
      options: SQLDumpOptions(perTable: [Self.customers: Flags(structure: false)]))
    let statements = mixed.preData + mixed.postData
    #expect(
      !statements.contains {
        $0.hasPrefix("CREATE TABLE \"app\".\"customers\"")
          || $0.hasPrefix("ALTER TABLE \"app\".\"customers\"") || $0.contains("OWNED BY")
      })
    // Types, views and other sequences stay while one dumped table keeps its structure; the
    // sequence customers owns stays in the target with it (its setval is kept)
    #expect(!statements.contains { $0.contains("SEQUENCE \"app\".\"customers_id_seq\"") })
    #expect(
      statements.contains("SELECT pg_catalog.setval('\"app\".\"customers_id_seq\"', 3, true);"))
    #expect(statements.contains { $0.hasPrefix("CREATE SEQUENCE \"app\".\"free_seq\"") })
    #expect(statements.contains { $0.hasPrefix("CREATE TYPE \"app\".\"mood\"") })
    #expect(statements.contains { $0.hasPrefix("CREATE VIEW") })
    #expect(statements.contains { $0.hasPrefix("ALTER TABLE \"app\".\"orders\" ADD") })
    #expect(mixed.tables.map(\.name) == ["customers", "orders", "items"])
    #expect(!mixed.foreignKeyCycle && !mixed.containsDrop)

    let dataOnly = try SQLDumpDDL.postgres(
      Self.postgresInput, options: SQLDumpOptions(otherTables: Flags(structure: false)))
    #expect(dataOnly.preData == ["CREATE SCHEMA IF NOT EXISTS \"app\";"])
    #expect(
      dataOnly.postData == [
        "SELECT pg_catalog.setval('\"app\".\"customers_id_seq\"', 3, true);",
        "SELECT pg_catalog.setval('\"app\".\"orders_id_seq\"', 3, true);",
        "SELECT pg_catalog.setval('\"app\".\"free_seq\"', 3, true);",
      ])
    #expect(dataOnly.tables.map(\.name) == ["customers", "orders", "items"])

    // A cycle keeps catalog order and says so
    var cyclic = Self.postgresInput
    cyclic.tables[2] = SQLDumpDDL.PostgresTable(
      structure: Self.table("app", "customers", references: Self.items))
    let cycle = try SQLDumpDDL.postgres(
      cyclic, options: SQLDumpOptions(otherTables: Flags(structure: false)))
    #expect(cycle.foreignKeyCycle)
    #expect(cycle.tables.map(\.name) == ["items", "orders", "customers"])
  }

  @Test func postgresStructureOffTableKeepsItsSequencesAndTypesOutOfCreateAndDrop() throws {
    func column(_ name: String, _ type: String, default value: String? = nil) -> Column {
      var column = Self.column(1, name, type)
      column.defaultExpression = value
      return column
    }
    let off = Name(schema: "app", name: "off")
    let kept = Name(schema: "app", name: "kept")
    var offTable = Self.table("app", "off")
    offTable.columns = [
      column("id", "integer", default: "nextval('app.off_id_seq'::regclass)"),
      column("other", "bigint", default: "nextval('\"app\".\"Shared\"'::regclass)"),
      column("m", "app.mood[]"), column("d", "app.small"),
    ]
    var keptTable = Self.table("app", "kept")
    keptTable.columns = [
      column("id", "integer", default: "nextval('app.kept_id_seq'::regclass)"),
      column("m", "app.mood"), column("c", "app.color"),
    ]
    let input = SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(structure: offTable),
        SQLDumpDDL.PostgresTable(structure: keptTable),
      ],
      sequences: [
        Self.sequence("off_id_seq", owner: off), Self.sequence("Shared", owner: nil),
        Self.sequence("kept_id_seq", owner: kept),
      ],
      enums: [
        SQLDumpDDL.PostgresEnum(schema: "app", name: "mood", labels: ["ok"]),
        SQLDumpDDL.PostgresEnum(schema: "app", name: "color", labels: ["red"]),
      ],
      domains: [
        SQLDumpDDL.PostgresDomain(
          schema: "app", name: "positive", baseType: "integer", defaultExpression: nil,
          notNull: false, constraints: []),
        SQLDumpDDL.PostgresDomain(
          schema: "app", name: "small", baseType: "app.positive", defaultExpression: nil,
          notNull: false, constraints: []),
      ],
      views: [])
    let script = try SQLDumpDDL.postgres(
      input,
      options: SQLDumpOptions(
        perTable: [off: Flags(structure: false), kept: Flags(structure: true, drop: true)]))
    let statements = script.preData + script.postData
    // Only what the Structure-off table does not use is dropped and created
    #expect(
      script.preData.filter { $0.hasPrefix("DROP") } == [
        "DROP TABLE IF EXISTS \"app\".\"kept\";",
        "DROP SEQUENCE IF EXISTS \"app\".\"kept_id_seq\";",
        "DROP TYPE IF EXISTS \"app\".\"color\";",
      ])
    #expect(
      script.preData.filter { $0.hasPrefix("CREATE") && !$0.hasPrefix("CREATE TABLE") } == [
        "CREATE SCHEMA IF NOT EXISTS \"app\";",
        "CREATE TYPE \"app\".\"color\" AS ENUM ('red');",
        "CREATE SEQUENCE \"app\".\"kept_id_seq\" AS integer START WITH 1 INCREMENT BY 1"
          + " MINVALUE 1 MAXVALUE 100 NO CYCLE;",
      ])
    for name in ["off_id_seq", "Shared", "mood", "small", "positive"] {
      #expect(
        !statements.contains {
          ($0.hasPrefix("CREATE") || $0.hasPrefix("DROP")) && $0.contains("\"\(name)\"")
        }, "\(name)")
    }
    // Every sequence keeps its value
    #expect(statements.filter { $0.hasPrefix("SELECT pg_catalog.setval") }.count == 3)
    // The default options stay as they were
    #expect(
      try SQLDumpDDL.postgres(input, options: SQLDumpOptions()) == SQLDumpDDL.postgres(input))
    #expect(try SQLDumpDDL.postgres(input).preData.contains { $0.contains("\"off_id_seq\"") })
    // The restore gate reads the dump as written
    let text = try Self.assemble(.postgresql, script, rows: [[], []])
    #expect(try SQLRestorePlan(script: text, engine: .postgresql).summary.count(.drop) == 3)
  }

  @Test func duckdbStructureOffTableKeepsItsNextvalSequencesOutOfCreateAndDrop() throws {
    func table(_ name: String, default value: String) -> SQLDumpDDL.DuckDBTable {
      var structure = Self.table("s", name)
      structure.columns[0].defaultExpression = value
      return SQLDumpDDL.DuckDBTable(
        structure: structure,
        sql: "CREATE TABLE s.\(name)(id INTEGER DEFAULT(\(value)));")
    }
    func sequence(_ schema: String, _ name: String) -> SQLDumpDDL.DuckDBSequence {
      SQLDumpDDL.DuckDBSequence(
        schema: schema, name: name, start: 1, increment: 1, minValue: 1, maxValue: 9,
        cycle: false, lastValue: nil)
    }
    let input = SQLDumpDDL.DuckDBInput(
      schemas: ["s"], enums: [],
      sequences: [
        sequence("s", "off_seq"), sequence("main", "off_seq"), sequence("s", "other"),
        sequence("s", "kept_seq"),
      ],
      tables: [
        table("off", default: "nextval('off_seq')"),
        table("off2", default: "nextval('S.\"Other\"')"),
        table("kept", default: "nextval('s.kept_seq')"),
      ],
      indexes: [], views: [])
    let script = try SQLDumpDDL.duckdb(
      input,
      options: SQLDumpOptions(
        perTable: [
          Name(schema: "s", name: "off"): Flags(structure: false),
          Name(schema: "s", name: "off2"): Flags(structure: false),
        ],
        otherTables: Flags(drop: true)))
    #expect(
      script.preData == [
        "CREATE SCHEMA IF NOT EXISTS \"s\";",
        "DROP TABLE IF EXISTS \"s\".\"kept\";",
        "DROP SEQUENCE IF EXISTS \"s\".\"kept_seq\";",
        "CREATE SEQUENCE \"s\".\"kept_seq\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9"
          + " NO CYCLE;",
        "CREATE TABLE s.kept(id INTEGER DEFAULT(nextval('s.kept_seq')));",
      ])
    #expect(try SQLDumpDDL.duckdb(input, options: SQLDumpOptions()) == SQLDumpDDL.duckdb(input))
    let text = try Self.assemble(.duckdb, script, rows: [[], [], []])
    #expect(try SQLRestorePlan(script: text, engine: .duckdb).summary.count(.drop) == 2)
  }

  @Test func mysqlDropsGoInsideForeignKeyChecksOff() throws {
    let input = SQLDumpDDL.MySQLInput(
      tables: [
        SQLDumpDDL.MySQLTable(
          structure: Self.table("shop", "customers"),
          createStatement: "CREATE TABLE `customers` (id int)"),
        SQLDumpDDL.MySQLTable(
          structure: Self.table("shop", "orders"), createStatement: "CREATE TABLE `orders` (id int)"
        ),
      ],
      views: [
        SQLDumpDDL.View(
          schema: "shop", name: "v_plain", sql: "CREATE VIEW `v_plain` AS select 1", dependsOn: [])
      ])
    let script = try SQLDumpDDL.mysql(
      input,
      options: SQLDumpOptions(perTable: [Name(schema: "shop", name: "orders"): Flags(drop: true)]))
    let text = try Self.assemble(.mysql, script, rows: [[["1"]], [["2"]]])
    #expect(
      text == """
        -- Dblore SQL dump 2 engine=MySQL created=2025-10-09T08:53:20Z
        SET time_zone = '+00:00';
        SET NAMES utf8mb4;
        SET SESSION sql_mode = TRIM(BOTH ',' FROM CONCAT(REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ','), 'NO_AUTO_VALUE_ON_ZERO'));
        -- Not included: stored procedures, functions, triggers, events, users and grants.
        SET FOREIGN_KEY_CHECKS=0;
        DROP VIEW IF EXISTS `v_plain`;
        DROP TABLE IF EXISTS `orders`;
        CREATE TABLE `customers` (id int);
        CREATE TABLE `orders` (id int);
        INSERT INTO `customers` (`id`) VALUES
        (1);
        INSERT INTO `orders` (`id`) VALUES
        (2);
        SET FOREIGN_KEY_CHECKS=1;
        CREATE VIEW `v_plain` AS select 1;

        """)
    // The restore gate accepts both DROPs (the rows here are unquoted fixtures, so none)
    let schema = try Self.assemble(.mysql, script, rows: [[], []])
    #expect(try SQLRestorePlan(script: schema, engine: .mysql).summary.count(.drop) == 2)
    #expect(try SQLDumpDDL.mysql(input, options: SQLDumpOptions()) == SQLDumpDDL.mysql(input))
    let dataOnly = try SQLDumpDDL.mysql(
      input, options: SQLDumpOptions(otherTables: Flags(structure: false, drop: true)))
    #expect(dataOnly.preData.isEmpty && dataOnly.postData.isEmpty && !dataOnly.containsDrop)
    #expect(dataOnly.tables.count == 2)
  }

  @Test func duckdbDropsInReverseCreationOrder() throws {
    func duckTable(_ name: String) -> SQLDumpDDL.DuckDBTable {
      SQLDumpDDL.DuckDBTable(
        structure: Self.table("s", name), sql: "CREATE TABLE s.\(name)(id INTEGER);")
    }
    func sequence(_ name: String) -> SQLDumpDDL.DuckDBSequence {
      SQLDumpDDL.DuckDBSequence(
        schema: "s", name: name, start: 1, increment: 1, minValue: 1, maxValue: 9, cycle: false,
        lastValue: nil)
    }
    let input = SQLDumpDDL.DuckDBInput(
      schemas: ["s"], enums: [SQLDumpDDL.DuckDBEnum(schema: "s", name: "mood", labels: ["ok"])],
      sequences: [sequence("seq1"), sequence("seq2")], tables: [duckTable("a"), duckTable("b")],
      indexes: [
        SQLDumpDDL.DuckDBIndex(
          schema: "s", table: "b", name: "b_idx", sql: "CREATE INDEX b_idx ON s.b(id);")
      ],
      views: [
        SQLDumpDDL.View(
          schema: "main", name: "v1", sql: "CREATE VIEW v1 AS SELECT 1;", dependsOn: [])
      ])
    let script = try SQLDumpDDL.duckdb(
      input, options: SQLDumpOptions(otherTables: Flags(drop: true)))
    #expect(script.containsDrop)
    #expect(
      Array(script.preData.prefix(7)) == [
        "CREATE SCHEMA IF NOT EXISTS \"s\";",
        "DROP VIEW IF EXISTS \"main\".\"v1\";",
        "DROP TABLE IF EXISTS \"s\".\"b\";",
        "DROP TABLE IF EXISTS \"s\".\"a\";",
        "DROP SEQUENCE IF EXISTS \"s\".\"seq2\";",
        "DROP SEQUENCE IF EXISTS \"s\".\"seq1\";",
        "DROP TYPE IF EXISTS \"s\".\"mood\";",
      ])
    #expect(script.preData[7].hasPrefix("CREATE TYPE"))
    let text = try Self.assemble(.duckdb, script, rows: [[], []])
    #expect(try SQLRestorePlan(script: text, engine: .duckdb).summary.count(.drop) == 6)
    #expect(try SQLDumpDDL.duckdb(input, options: SQLDumpOptions()) == SQLDumpDDL.duckdb(input))

    // Structure off on b: no CREATE TABLE and no index for it, and no DROP
    let mixed = try SQLDumpDDL.duckdb(
      input,
      options: SQLDumpOptions(perTable: [
        Name(schema: "s", name: "b"): Flags(structure: false, drop: true)
      ]))
    #expect(!mixed.containsDrop)
    #expect(!(mixed.preData + mixed.postData).contains { $0.contains("s.b") })
    #expect(mixed.preData.contains("CREATE TABLE s.a(id INTEGER);"))
  }

  @Test func sqliteDropAndDataOnlyDumpsRestoreOverTheirTables() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    try Self.exec(
      source.path,
      """
      CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
      CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id));
      CREATE TABLE keep (id INTEGER PRIMARY KEY);
      CREATE INDEX idx_child ON child (parent_id);
      CREATE TRIGGER child_touch AFTER INSERT ON child BEGIN SELECT 1; END;
      CREATE VIEW v_child AS SELECT * FROM child;
      INSERT INTO parent VALUES (1, 'a'), (5, 'b');
      INSERT INTO child VALUES (1, 1), (2, 5);
      INSERT INTO keep VALUES (1);
      """)
    func dump(_ options: SQLDumpOptions) async throws -> (SQLDumpProgress, String) {
      let destination = directory.appendingPathComponent("dump-\(UUID().uuidString).sql")
      let writer = SQLDumpWriter(
        config: Self.sqliteConfig(source.path), material: nil, sshCredential: nil,
        sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
        temporaryDirectory: directory)
      let progress = try await writer.write(to: destination, options: options)
      return (progress, try String(contentsOf: destination, encoding: .utf8))
    }
    func statements(_ text: String) -> [String] {
      text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("--") }
    }
    let parent = Name(schema: "main", name: "parent")
    let child = Name(schema: "main", name: "child")
    let compare = [
      "SELECT * FROM parent ORDER BY id", "SELECT * FROM child ORDER BY id",
      "SELECT * FROM keep", "SELECT name, seq FROM sqlite_sequence",
      "SELECT type, name FROM sqlite_master ORDER BY name",
    ]
    let before = try compare.map { try Self.query(source.path, $0) }

    // Per-table flags without Drop: today's dump, header 1
    let (_, plainText) = try await dump(SQLDumpOptions())
    let (_, flaggedText) = try await dump(SQLDumpOptions(perTable: [parent: Flags()]))
    #expect(flaggedText.hasPrefix("-- Dblore SQL dump 1 engine=SQLite created="))
    #expect(
      flaggedText.components(separatedBy: "\n").dropFirst()
        == plainText.components(separatedBy: "\n").dropFirst())

    // Drop on parent and child (child without data); keep is written but not dropped
    let (dropProgress, dropText) = try await dump(
      SQLDumpOptions(
        perTable: [parent: Flags(drop: true), child: Flags(data: false, drop: true)]))
    #expect(dropText.hasPrefix("-- Dblore SQL dump 2 engine=SQLite created="))
    #expect(
      Array(statements(dropText).prefix(5)) == [
        "PRAGMA defer_foreign_keys = ON;", "DROP VIEW IF EXISTS \"v_child\";",
        "DROP TABLE IF EXISTS \"parent\";", "DROP TABLE IF EXISTS \"child\";",
        "CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);",
      ])
    #expect(statements(dropText).filter { $0.hasPrefix("DROP") }.count == 3)
    #expect(!dropText.contains("INSERT INTO \"child\""))
    #expect(dropProgress == SQLDumpProgress(tablesDone: 2, tableCount: 2, rowsWritten: 3))
    // Restored over a database that already has those objects: they are replaced
    let target = directory.appendingPathComponent("target.db")
    try Self.exec(
      target.path,
      """
      CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, old TEXT);
      CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER);
      CREATE VIEW v_child AS SELECT id FROM child;
      INSERT INTO parent VALUES (9, 'old'); INSERT INTO child VALUES (9, 9);
      """)
    try Self.exec(target.path, "BEGIN;\n" + dropText + "\nCOMMIT;")
    #expect(try Self.query(target.path, compare[0]) == before[0])
    #expect(try Self.query(target.path, compare[1]).isEmpty)
    #expect(try Self.query(target.path, compare[4]) == before[4])

    // Structure off everywhere: rows and counters only, back into the emptied source
    let (dataProgress, dataText) = try await dump(
      SQLDumpOptions(otherTables: Flags(structure: false, drop: true)))
    #expect(dataText.hasPrefix("-- Dblore SQL dump 1 engine=SQLite created="))
    #expect(dataProgress == SQLDumpProgress(tablesDone: 3, tableCount: 3, rowsWritten: 5))
    #expect(
      statements(dataText).allSatisfy {
        $0 == "PRAGMA defer_foreign_keys = ON;" || $0.hasPrefix("INSERT INTO ")
          || $0.hasPrefix("(") || $0.hasPrefix("DELETE FROM sqlite_sequence ")
      })
    try Self.exec(source.path, "DELETE FROM child; DELETE FROM parent; DELETE FROM keep;")
    try Self.exec(source.path, "BEGIN;\n" + dataText + "\nCOMMIT;")
    #expect(try compare.map { try Self.query(source.path, $0) } == before)
  }

  // MARK: - Helpers

  private static func recordingSession() -> FakeDatabaseSession {
    FakeDatabaseSession(capabilities: .contract(), columns: [], rows: [], slowQueries: false)
  }

  @discardableResult
  private static func drain(_ reader: DumpSnapshotReader, _ sql: String) async throws -> Int {
    var count = 0
    for try await _ in try await reader.query(sql, binds: []).rows { count += 1 }
    return count
  }

  private static let duckdbConfig = ConnectionConfig(
    databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
    protectionLevel: .none, safeMode: .silent, protectedMode: false)

  private static func sqliteConfig(_ path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, database: path, username: "", password: "", sslMode: .disable)
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-dump-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func leftovers(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  /// Runs `sql` on a new connection to `path`
  private static func exec(_ path: String, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
      throw SQLiteSessionError(extendedCode: SQLITE_CANTOPEN, message: "open failed")
    }
    defer { sqlite3_close_v2(db) }
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(db, sql, nil, nil, &message)
    let text = message.map { String(cString: $0) } ?? ""
    sqlite3_free(message)
    guard code == SQLITE_OK else { throw SQLiteSessionError(extendedCode: code, message: text) }
  }

  /// Rows of `sql` as text, read on a new connection to `path`
  private static func query(_ path: String, _ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
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
    var rows: [[String]] = []
    while sqlite3_step(prepared) == SQLITE_ROW {
      rows.append(
        (0..<sqlite3_column_count(prepared)).map { index in
          sqlite3_column_text(prepared, index).map { String(cString: $0) } ?? "<null>"
        })
    }
    return rows
  }
}

/// Records the certificate and SSH secret a real session would read when it is built
private final class MaterialRecordingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let inner: FakeDatabaseSessionFactory
  private let lock = NSLock()
  private var loadedCertificates: [ClientCertificateMaterial?] = []
  private var loadedCredentials: [SSHStoredCredential?] = []

  init(_ inner: FakeDatabaseSessionFactory) {
    self.inner = inner
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let certificate = ClientCertificateStoreFactory.load(for: config)
    let credential = SSHCredentialStoreFactory.load(for: config)
    lock.withLock {
      loadedCertificates.append(certificate)
      loadedCredentials.append(credential)
    }
    return inner.makeSession(config: config)
  }

  var certificates: [ClientCertificateMaterial?] { lock.withLock { loadedCertificates } }
  var credentials: [SSHStoredCredential?] { lock.withLock { loadedCredentials } }
}

/// Yields each session it makes, so a test can wait for the writer's session without polling
private final class SessionAnnouncingFactory: DatabaseSessionFactory, @unchecked Sendable {
  let inner: FakeDatabaseSessionFactory
  let sessions: AsyncStream<FakeDatabaseSession>
  private let continuation: AsyncStream<FakeDatabaseSession>.Continuation

  init(_ inner: FakeDatabaseSessionFactory) {
    self.inner = inner
    (sessions, continuation) = AsyncStream.makeStream()
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let session = inner.makeSession(config: config)
    if let fake = session as? FakeDatabaseSession { continuation.yield(fake) }
    return session
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [SQLDumpProgress] = []

  func append(_ progress: SQLDumpProgress) { lock.withLock { recorded.append(progress) } }
  var values: [SQLDumpProgress] { lock.withLock { recorded } }
}
