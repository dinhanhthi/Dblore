// SQLInsertRendererTests.swift
// INSERT scripts, IN lists, and the caller-chosen table name for a query result.

import Foundation
import Testing

@testable import Dblore

@Suite("SQL INSERT renderer")
struct SQLInsertRendererTests {
  @Test("Five hundred rows are one statement; one more starts a second statement")
  func batchBoundary() {
    let columns = [ColumnInfo(name: "id", type: "int4")]
    let rows500 = (0..<500).map { [CellValue.int($0)] }
    let script500 = SQLInsertRenderer.insertScript(
      result: result(columns: columns, rows: rows500), table: "t", dialect: .postgresql)
    let tuples = (0..<500).map { "(\($0))" }.joined(separator: ", ")
    #expect(script500 == "INSERT INTO \"t\" (\"id\") VALUES \(tuples);")

    let rows501 = rows500 + [[.int(500)]]
    let script501 = SQLInsertRenderer.insertScript(
      result: result(columns: columns, rows: rows501), table: "t", dialect: .postgresql)
    let parts = script501.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(parts.count == 2)
    #expect(parts[0] == script500)
    #expect(parts[1] == "INSERT INTO \"t\" (\"id\") VALUES (500);")

    let two = SQLInsertRenderer.insertScript(
      result: result(columns: columns, rows: [[.int(1)], [.int(2)]]),
      table: "t",
      dialect: .postgresql,
      batchSize: 0)
    #expect(
      two == "INSERT INTO \"t\" (\"id\") VALUES (1);\nINSERT INTO \"t\" (\"id\") VALUES (2);")
  }

  @Test(
    "Identifiers and string literals double embedded quotes; NULL, bool, and JSON stay literals")
  func quotesNullBoolAndJSON() {
    let columns = [
      ColumnInfo(name: "c\"d", type: "text"),
      ColumnInfo(name: "flag", type: "bool"),
      ColumnInfo(name: "doc", type: "json"),
      ColumnInfo(name: "note", type: "text"),
    ]
    let rows: [[CellValue]] = [
      [.string("o'brien"), .bool(true), .json(#"{"a":"o'b"}"#), .null],
      [.string("plain"), .bool(false), .json("{}"), .string("x")],
    ]
    let script = SQLInsertRenderer.insertScript(
      result: result(columns: columns, rows: rows), table: "a\"b", dialect: .postgresql)
    let expected =
      #"INSERT INTO "a""b" ("c""d", "flag", "doc", "note") VALUES "#
      + #"('o''brien', TRUE, '{"a":"o''b"}', NULL), ('plain', FALSE, '{}', 'x');"#
    #expect(script == expected)
  }

  @Test("A NUL in an identifier is still quoted by doubling embedded quotes")
  func nulInIdentifier() {
    let script = SQLInsertRenderer.insertScript(
      result: result(
        columns: [ColumnInfo(name: "c\"d\0", type: "text")],
        rows: [[.int(1)]]),
      table: "a\"\0b",
      dialect: .sqlite)
    #expect(script == "INSERT INTO \"a\"\"\0b\" (\"c\"\"d\0\") VALUES (1);")
  }

  @Test(
    "Bytea uses the dialect literal",
    arguments: [
      (SQLDialect.postgresql, "'\\x000aff'"),
      (SQLDialect.sqlite, "X'000AFF'"),
    ])
  func bytea(dialect: SQLDialect, literal: String) {
    let data = Data([0x00, 0x0A, 0xFF])
    let script = SQLInsertRenderer.insertScript(
      result: result(
        columns: [ColumnInfo(name: "blob", type: "bytea")], rows: [[.data(data)]]),
      table: "files",
      dialect: dialect)
    #expect(script == "INSERT INTO \"files\" (\"blob\") VALUES (\(literal));")
  }

  @Test("No rows, or rows without columns, produce an empty script")
  func emptyResult() {
    let columns = [ColumnInfo(name: "id", type: "int4")]
    #expect(
      SQLInsertRenderer.insertScript(
        result: result(columns: columns, rows: []), table: "t", dialect: .postgresql) == "")
    #expect(
      SQLInsertRenderer.insertScript(
        result: result(columns: [], rows: [[.int(1)]]), table: "t", dialect: .postgresql) == "")
  }

  @Test("Table name is the trimmed fallback, otherwise the placeholder")
  func tableNameFallback() {
    let withOID = result(
      columns: [ColumnInfo(name: "id", type: "int4", tableOID: 42, attributeNumber: 1)],
      rows: [[.int(1)]])
    #expect(SQLInsertRenderer.tableName(for: withOID, fallback: nil) == "table_name")
    #expect(SQLInsertRenderer.tableName(for: withOID, fallback: "") == "table_name")
    #expect(SQLInsertRenderer.tableName(for: withOID, fallback: " \n\t ") == "table_name")
    #expect(SQLInsertRenderer.tableName(for: withOID, fallback: "  orders  ") == "orders")
  }

  @Test("IN lists drop nulls, dedupe in first-seen order, and comment only when nulls were omitted")
  func inListDedupeAndNulls() {
    #expect(
      SQLInsertRenderer.inList(
        values: [.int(1), .string("a"), .int(1), .string("a"), .int(2)],
        dialect: .postgresql) == "(1, 'a', 2)")
    #expect(!SQLInsertRenderer.inList(values: [.int(1), .int(2)], dialect: .sqlite).contains("--"))
    #expect(SQLInsertRenderer.inList(values: [], dialect: .postgresql) == "()")
    #expect(
      SQLInsertRenderer.inList(
        values: [.null, .int(1), .null, .int(1), .string("a")],
        dialect: .postgresql) == "(1, 'a')\n-- 2 NULL values omitted")
    #expect(
      SQLInsertRenderer.inList(values: [.null], dialect: .postgresql)
        == "()\n-- 1 NULL values omitted")
  }

  private func result(columns: [ColumnInfo], rows: [[CellValue]]) -> QueryResult {
    QueryResult(columns: columns, rows: rows, rowCount: rows.count, executionTime: 0)
  }
}
