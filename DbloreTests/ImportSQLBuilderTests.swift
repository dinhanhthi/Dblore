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

  @Test("The MySQL chunk cap is half the packet limit, never above 8 MiB")
  func mysqlChunkByteCap() {
    let mebibyte = 1_024 * 1_024
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: 4 * mebibyte) == 2 * mebibyte)
    // mysql-nio writes one packet (no 16 MiB split), so a 64 MB server limit still caps at 8 MiB.
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: 64 * mebibyte) == 8 * mebibyte)
    #expect(ImportSQLBuilder.mysqlChunkByteCap(maxAllowedPacket: nil) == 8 * mebibyte)
  }
}
