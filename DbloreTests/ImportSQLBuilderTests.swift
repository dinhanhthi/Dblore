import Foundation
import Testing

@testable import Dblore

@Suite("Import SQL builder")
struct ImportSQLBuilderTests {
  @Test("CREATE TABLE quotes names and has no affected-row expectation")
  func createTable() throws {
    let columns = [
      ImportSQLBuilder.Column(name: "id", kind: .integer),
      ImportSQLBuilder.Column(name: "na\"me", kind: .text),
    ]
    let statement = try ImportSQLBuilder.createTable(
      schema: "other", table: "new table", columns: columns, dialect: .postgresql)
    #expect(statement.sql == #"CREATE TABLE "other"."new table" ("id" bigint, "na""me" text)"#)
    #expect(statement.values.isEmpty)
    #expect(statement.expectedRows == nil)
  }

  @Test("INSERT chunks respect both row and bind limits and bind every cell")
  func insertChunks() throws {
    let rows: [[String?]] = [["1", "o'brien"], ["2", nil], ["3", "secret"]]
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["id", "name"], rows: rows,
      dialect: .postgresql, bindLimit: 4)
    #expect(statements.count == 2)
    #expect(statements[0].sql == #"INSERT INTO "t" ("id", "name") VALUES ($1, $2), ($3, $4)"#)
    #expect(statements[0].values == ["1", "o'brien", "2", nil])
    #expect(statements[0].expectedRows == 2)
    #expect(statements[1].sql == #"INSERT INTO "t" ("id", "name") VALUES ($1, $2)"#)
    #expect(statements[1].values == ["3", "secret"])
    #expect(statements[1].expectedRows == 1)
    #expect(
      statements.flatMap(\.binds) == [
        .text("1"), .text("o'brien"), .text("2"), .null,
        .text("3"), .text("secret"),
      ])
  }

  @Test("Summary contains CREATE SQL and row count, never file values")
  func summary() throws {
    let create = try ImportSQLBuilder.createTable(
      schema: nil, table: "t", columns: [.init(name: "name", kind: .text)],
      dialect: .sqlite)
    let summary = try ImportSQLBuilder.summaryText(
      createTable: create, schema: nil, table: "t", columns: ["name"],
      rowCount: 3, dialect: .sqlite)
    #expect(
      summary == """
        CREATE TABLE "t" ("name" TEXT);
        INSERT INTO "t" ("name") -- 3 rows from file
        """)
    #expect(!summary.contains("secret"))
  }

  @Test("A row wider than the bind limit is rejected")
  func tooManyColumns() {
    #expect(throws: ImportSQLBuilder.Error.bindLimitExceeded) {
      try ImportSQLBuilder.insertStatements(
        schema: nil, table: "t", columns: ["a", "b"], rows: [["1", "2"]],
        dialect: .sqlite, bindLimit: 1)
    }
  }

  @Test("A statement never exceeds the 1000-row cap")
  func thousandRowCap() throws {
    let rows = (0..<1_001).map { [String($0)] as [String?] }
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["n"], rows: rows, dialect: .sqlite)
    #expect(statements.map(\.expectedRows) == [999, 2])
    let generous = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["n"], rows: rows,
      dialect: .sqlite, bindLimit: 10_000)
    #expect(generous.map(\.expectedRows) == [1_000, 1])
  }

  @Test("Blank imported cells bind NULL without changing nonblank text")
  func blankCells() throws {
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["a", "b", "c"],
      rows: [["", " \t ", " keep "]], dialect: .postgresql)
    #expect(statements[0].values == [nil, nil, " keep "])
    #expect(statements[0].binds == [.null, .null, .text(" keep ")])
  }

  @Test("Typed SQLite boolean columns cast bound 1 and 0 to INTEGER")
  func sqliteBoolean() throws {
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: [.init(name: "flag", kind: .boolean)],
      rows: [["true"], ["FALSE"], [nil]], dialect: .sqlite)
    #expect(
      statements[0].sql
        == #"INSERT INTO "t" ("flag") VALUES (CAST(?1 AS INTEGER)), (CAST(?2 AS INTEGER)), (CAST(?3 AS INTEGER))"#
    )
    #expect(statements[0].values == ["1", "0", nil])
  }

  @Test("MySQL binds ? markers, booleans as 1 and 0, under a 65535 bind limit")
  func mysqlInsert() throws {
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t",
      columns: [.init(name: "id", kind: .integer), .init(name: "flag", kind: .boolean)],
      rows: [["1", "true"], ["2", "FALSE"], ["3", nil]], dialect: .mysql)
    #expect(statements[0].sql == "INSERT INTO `t` (`id`, `flag`) VALUES (?, ?), (?, ?), (?, ?)")
    #expect(statements[0].values == ["1", "1", "2", "0", "3", nil])

    let columns = (0..<1_000).map { "c\($0)" }
    let rows = (0..<100).map { _ in columns.map { _ in "x" } as [String?] }
    let wide = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: columns, rows: rows, dialect: .mysql)
    #expect(wide.map(\.expectedRows) == [65, 35])
  }

  @Test("MySQL timestamps bind as UTC DATETIME text; other engines and unparsed text keep it")
  func mysqlTimestamps() throws {
    let columns: [ImportSQLBuilder.Column] = [.init(name: "seen", kind: .timestamp)]
    let rows: [[String?]] = [
      ["2024-01-02T03:04:05Z"], ["2024-01-02T05:04:05.5+02:00"], ["2024-01-02"], ["soon"],
    ]
    let mysql = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: columns, rows: rows, dialect: .mysql)
    #expect(
      mysql[0].values == [
        "2024-01-02 03:04:05.000000", "2024-01-02 03:04:05.500000", "2024-01-02 00:00:00.000000",
        "soon",
      ])
    let postgres = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: columns, rows: rows, dialect: .postgresql)
    #expect(postgres[0].values == rows.map { $0[0] })
  }

  @Test("A byte cap closes a chunk before the next row would pass it; a big row goes alone")
  func byteCapSplitsChunks() throws {
    let kilobyte = String(repeating: "a", count: 1_000)
    let rows: [[String?]] = [[kilobyte], [kilobyte], [kilobyte], ["b"], ["c"]]
    // Each row is 1,000 bytes plus the per-bind overhead: two fit under 2,100, three do not.
    let statements = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["v"], rows: rows, dialect: .mysql,
      maxChunkBytes: 2_100)
    #expect(statements.map(\.expectedRows) == [2, 3])
    #expect(statements.flatMap(\.values) == rows.map { $0[0] })

    let alone = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["v"], rows: rows, dialect: .mysql, maxChunkBytes: 10)
    #expect(alone.map(\.expectedRows) == [1, 1, 1, 1, 1])
    let uncapped = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "t", columns: ["v"], rows: rows, dialect: .mysql)
    #expect(uncapped.map(\.expectedRows) == [5])
  }

  @Test("UPDATE sets the mapped non-key columns and matches the key as the match read does")
  func updateStatements() throws {
    let postgres = try ImportSQLBuilder.updateStatement(
      schema: "s", table: "t",
      columns: [.init(name: "id", kind: .integer), .init(name: "name", kind: .text)],
      row: [" 7", "Ada"],
      keys: [try key(column("id", "integer(4)"), .postgresql)], dialect: .postgresql)
    #expect(postgres.sql == #"UPDATE "s"."t" SET "name" = $1 WHERE "id" = CAST($2 AS integer)"#)
    #expect(postgres.values == ["Ada", " 7"])
    #expect(postgres.expectedRows == 1)
    #expect(postgres.rowCheck == nil)

    let sqlite = try ImportSQLBuilder.updateStatement(
      schema: nil, table: "t",
      columns: [.init(name: "flag", kind: .boolean), .init(name: "id", kind: .integer)],
      row: ["TRUE", "5"], keys: [try key(column("id", "INTEGER"), .sqlite)], dialect: .sqlite)
    #expect(sqlite.sql == #"UPDATE "t" SET "flag" = CAST(?1 AS INTEGER) WHERE "id" = ?2"#)
    #expect(sqlite.values == ["1", "5"])

    // MySQL: the read's COLLATE / CONVERT / CAST, and the row check, so a same-value write
    // (0 changed rows) still counts as the one expected row
    let keys = try [
      key(
        column("name", "varchar", characterSet: "utf8mb4", collation: "utf8mb4_unicode_ci"),
        .mysql),
      key(
        column("code", "varchar", characterSet: "latin1", collation: "latin1_swedish_ci"), .mysql),
      key(column("id", "bigint"), .mysql),
    ]
    let mysql = try ImportSQLBuilder.updateStatement(
      schema: "shop", table: "items",
      columns: [
        .init(name: "name", kind: .text), .init(name: "note", kind: .text),
        .init(name: "code", kind: .text), .init(name: "id", kind: .integer),
        .init(name: "seen", kind: .timestamp),
      ],
      row: ["Café", "hi", "é", " 42 ", "2024-01-02T03:04:05Z"], keys: keys, dialect: .mysql)
    let condition =
      "`name` = ? COLLATE utf8mb4_unicode_ci "
      + "AND `code` = CONVERT(? USING latin1) COLLATE latin1_swedish_ci "
      + "AND `id` = CAST(? AS SIGNED)"
    #expect(mysql.sql == "UPDATE `shop`.`items` SET `note` = ?, `seen` = ? WHERE \(condition)")
    #expect(mysql.values == ["hi", "2024-01-02 03:04:05.000000", "Café", "é", "42"])
    #expect(mysql.expectedRows == 1)
    #expect(
      mysql.rowCheck
        == RowExistenceCheck(
          sql: "SELECT 1 FROM `shop`.`items` WHERE \(condition) FOR UPDATE",
          values: ["Café", "é", "42"]))

    // A NULL key part names no row
    #expect(throws: ImportSQLBuilder.Error.invalidKey) {
      try ImportSQLBuilder.updateStatement(
        schema: nil, table: "t",
        columns: [.init(name: "id", kind: .integer), .init(name: "v", kind: .text)],
        row: [" ", "x"], keys: [try key(column("id", "INTEGER"), .sqlite)], dialect: .sqlite)
    }
  }

  @Test("A keyed import summary names each statement kind and the per-mode counts, no values")
  func matchSummary() throws {
    let update = try ImportSQLBuilder.updateStatement(
      schema: nil, table: "t",
      columns: [.init(name: "id", kind: .integer), .init(name: "name", kind: .text)],
      row: ["1", "secret"], keys: [try key(column("id", "INTEGER"), .sqlite)], dialect: .sqlite)
    let summary = try ImportSQLBuilder.matchSummaryText(
      schema: nil, table: "t", columns: ["id", "name"], update: update,
      counts: .init(inserts: 3, updates: 2, skips: 1, refused: 4), dialect: .sqlite)
    #expect(
      summary == """
        -- From file: 3 to insert, 2 to update, 1 skipped, 4 refused
        INSERT INTO "t" ("id", "name");
        UPDATE "t" SET "name" = ?1 WHERE "id" = ?2
        """)
    #expect(!summary.contains("secret"))
    // Safe Mode confirms this text: no all-rows warning and no `:name` parameter to ask for
    let classified = SQLStatementClassifier.classify(summary, dialect: .sqlite)
    #expect(classified.map(\.kind) == [.dml, .dml])
    #expect(!SQLStatementClassifier.summary(classified).affectsAllRows)
    #expect(SQLParameterRewriter.parameterNames(in: summary, dialect: .sqlite).isEmpty)
  }

  @Test("The MySQL chunk cap is half the packet limit, never above 8 MiB")
  func mysqlChunkByteCap() {
    let mebibyte = 1_024 * 1_024
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: 4 * mebibyte) == 2 * mebibyte)
    // mysql-nio writes one packet (no 16 MiB split), so a 64 MB server limit still caps at 8 MiB.
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: 64 * mebibyte) == 8 * mebibyte)
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: nil) == 8 * mebibyte)
  }

  private func key(
    _ column: TableStructure.Column, _ dialect: SQLDialect
  ) throws -> ImportMatchPlanner.KeyColumn {
    try ImportMatchPlanner.KeyColumn(column, dialect: dialect)
  }

  private func column(
    _ name: String, _ dataType: String, characterSet: String? = nil, collation: String? = nil
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: 1, name: name, dataType: dataType, isNullable: true, columnType: dataType,
      characterSet: characterSet, collation: collation)
  }
}
