// RewindCaptureSQLTests.swift
// The Data Rewind capture reads one row by key in text form per engine, keeps '' apart from
// NULL, and turns stored text back into binds that restore the exact value.

import Foundation
import Testing

@testable import Dblore

@Suite("Rewind capture SQL")
struct RewindCaptureSQLTests {
  @Test("The full-row read per engine: text forms, bound key, FOR UPDATE on servers")
  func selectPerEngine() throws {
    let postgres = try RewindCaptureSQL.selectStatement(
      target: Self.target("public.people", keys: ["id"], updateOnly: true),
      columns: [Self.column("id", "int4"), Self.column("name", "text")],
      keyValues: [.int(7)], engine: .postgresql)
    #expect(
      postgres.sql
        == "SELECT 'v' || \"id\"::text, 'v' || \"name\"::text FROM ONLY public.people"
        + " WHERE \"id\" = $1 FOR UPDATE")
    #expect(postgres.values == ["7"])

    let partitioned = try RewindCaptureSQL.selectStatement(
      target: Self.target("public.events", keys: ["id"], updateOnly: false),
      columns: [Self.column("id", "int8")], keyValues: [.int(1)], engine: .postgresql)
    #expect(
      partitioned.sql
        == "SELECT 'v' || \"id\"::text FROM public.events WHERE \"id\" = $1 FOR UPDATE")

    // ColumnInfo spells MySQL types in upper case; byte keys go through UNHEX like the edit
    let mysql = try RewindCaptureSQL.selectStatement(
      target: Self.target("`db`.`t`", keys: ["k", "a`b"]),
      columns: [
        Self.column("k", "VARBINARY"), Self.column("a`b", "DECIMAL"), Self.column("f", "BIT"),
      ],
      keyValues: [.data(Data([0x01, 0xAB])), .string("x")], engine: .mysql)
    #expect(
      mysql.sql
        == "SELECT HEX(`k`), CAST(`a``b` AS CHAR), HEX(`f`) FROM `db`.`t`"
        + " WHERE `k` = UNHEX(?) AND `a``b` = ? FOR UPDATE")
    #expect(mysql.values == ["01ab", "x"])

    let sqlite = try RewindCaptureSQL.selectStatement(
      target: Self.target("\"t\"", keys: ["id"]), columns: [Self.column("id", "INTEGER")],
      keyValues: [.int(3)], engine: .sqlite)
    #expect(sqlite.sql == "SELECT quote(\"id\") FROM \"t\" WHERE \"id\" = ?1")
    #expect(sqlite.values == ["3"])
  }

  @Test("PostgreSQL keeps an empty string apart from NULL through capture and bind")
  func postgresEmptyStringIsNotNull() throws {
    let columns = [Self.column("a", "text"), Self.column("b", "text"), Self.column("c", "text")]
    let image = try RewindCaptureSQL.image(
      [.string("v"), .null, .string("vNULL")], columns: columns, engine: .postgresql)
    let expected: RewindImage = ["a": "", "b": nil, "c": "NULL"]
    #expect(image == expected)
    #expect(
      try RewindCaptureSQL.bind(image["a"] ?? nil, column: columns[0], engine: .postgresql)
        == RewindBind(form: .plain, value: .text("")))
    #expect(
      try RewindCaptureSQL.bind(image["b"] ?? nil, column: columns[1], engine: .postgresql)
        == RewindBind(form: .plain, value: .null))
    #expect(throws: RewindCaptureError.unexpectedValue(column: "a")) {
      try RewindCaptureSQL.image([.string("x")], columns: [columns[0]], engine: .postgresql)
    }
  }

  @Test("MySQL binds hex columns through UNHEX and keeps the text NULL as text")
  func mysqlBinds() throws {
    let bits = Self.column("f", "BIT")
    #expect(
      try RewindCaptureSQL.bind("5", column: bits, engine: .mysql)
        == RewindBind(form: .hex, value: .text("05")))
    #expect(RewindBind(form: .hex, value: .text("05")).sql(placeholder: "?") == "UNHEX(?)")
    #expect(
      try RewindCaptureSQL.bind("NULL", column: Self.column("s", "VARCHAR"), engine: .mysql)
        == RewindBind(form: .plain, value: .text("NULL")))
    #expect(
      try RewindCaptureSQL.bind(nil, column: bits, engine: .mysql)
        == RewindBind(form: .plain, value: .null))
    #expect(throws: RewindCaptureError.unexpectedValue(column: "f")) {
      try RewindCaptureSQL.bind("DE;AD", column: bits, engine: .mysql)
    }
  }

  @Test("SQLite: capture, bind back and rewrite restore every value and its storage class")
  func sqliteRoundTripIsExact() throws {
    let handle = try SQLiteHandle.inMemory()
    try handle.execute(
      "CREATE TABLE t (id INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT, e TEXT, n TEXT,"
        + " q TEXT, b BLOB, x)")
    try handle.execute(
      "INSERT INTO t VALUES (1, -9223372036854775808, 0.1 + 0.2, 'it''s', '', NULL, 'NULL',"
        + " X'00FF10', 1e999)")
    let columns = ["id", "i", "r", "s", "e", "n", "q", "b", "x"].map { Self.column($0, "") }
    let read = try RewindCaptureSQL.selectStatement(
      target: Self.target("\"t\"", keys: ["id"]), columns: columns, keyValues: [.int(1)],
      engine: .sqlite)
    let statement = try handle.prepare(read.sql)
    for (offset, value) in read.values.enumerated() {
      try statement.bind(text: try #require(value), index: Int32(offset + 1))
    }
    #expect(try statement.step())
    let row = (0..<Int32(columns.count)).map { CellValue.string(statement.columnText($0) ?? "") }
    let image = try RewindCaptureSQL.image(row, columns: columns, engine: .sqlite)
    #expect(image["n"] == .some("NULL"))
    #expect(image["q"] == .some("'NULL'"))

    // Re-insert under id 2 with the bound values, then compare value and storage class
    var restored = image
    restored["id"] = "2"
    let binds = try columns.map { column in
      try RewindCaptureSQL.bind(restored[column.name] ?? nil, column: column, engine: .sqlite)
    }
    let placeholders = binds.enumerated().map { $1.sql(placeholder: "?\($0 + 1)") }
    let insert = try handle.prepare(
      "INSERT INTO t VALUES (\(placeholders.joined(separator: ", ")))")
    for (offset, bind) in binds.enumerated() {
      switch bind.value {
      case .null: try insert.bind(Int32(offset + 1), .null)
      case .text(let text): try insert.bind(text: text, index: Int32(offset + 1))
      }
    }
    while try insert.step() {}

    let compare = columns.dropFirst().map { "quote(\"\($0.name)\") || typeof(\"\($0.name)\")" }
    let check = try handle.prepare(
      "SELECT \(compare.joined(separator: ", ")) FROM t ORDER BY id")
    var pairs: [[String?]] = []
    while try check.step() {
      pairs.append((0..<Int32(compare.count)).map { check.columnText($0) })
    }
    #expect(pairs.count == 2)
    #expect(pairs[0] == pairs[1])
  }

  @Test("SQLite refuses stored text that is not a quote() literal")
  func sqliteRefusesNonLiterals() throws {
    for text in ["1; DROP TABLE t", "'a' || 'b'", "X'GG'", ""] {
      #expect(throws: RewindCaptureError.unexpectedValue(column: "c")) {
        try RewindCaptureSQL.bind(text, column: Self.column("c", ""), engine: .sqlite)
      }
    }
  }

  @Test("DuckDB and MongoDB have no rewind capture", arguments: [DatabaseType.duckdb, .mongodb])
  func unsupportedEngines(engine: DatabaseType) throws {
    #expect(throws: RewindCaptureError.unsupportedEngine(engine)) {
      try RewindCaptureSQL.selectStatement(
        target: Self.target("\"t\"", keys: ["id"]), columns: [Self.column("id", "INTEGER")],
        keyValues: [.int(1)], engine: engine)
    }
    #expect(throws: RewindCaptureError.unsupportedEngine(engine)) {
      try RewindCaptureSQL.bind("1", column: Self.column("id", "INTEGER"), engine: engine)
    }
  }

  // MARK: - Fixtures

  private static func column(_ name: String, _ type: String) -> RewindColumn {
    RewindColumn(name: name, typeName: type)
  }

  private static func target(
    _ qualifiedName: String, keys: [String], updateOnly: Bool = false
  ) -> EditTarget {
    EditTarget(
      qualifiedName: qualifiedName, tableID: TableRef("t"), primaryKeyColumns: keys,
      updateOnly: updateOnly)
  }
}
