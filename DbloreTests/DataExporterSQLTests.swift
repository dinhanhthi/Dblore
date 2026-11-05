// DataExporterSQLTests.swift
// INSERT scripts, IN lists, and PDF bytes from a cell result. Download and copy stay untested:
// they open a save panel or write the pasteboard.

import Foundation
import PDFKit
import Testing

@testable import Dblore

@Suite("Data exporter SQL and PDF")
@MainActor
struct DataExporterSQLTests {
  @Test("INSERT quotes the passed schema and name apart, never the pre-quoted result.tableName")
  func insertTableName() {
    // `tableName` holds the server's quoted text; the INSERT must not quote it again
    let result = cellResult(tableName: #""public"."orders""#)
    #expect(
      DataExporter.sqlInsert(result: result, dialect: .postgresql)
        == #"INSERT INTO "table_name" ("id") VALUES (1);"#)
    #expect(
      DataExporter.sqlInsert(result: result, schema: "public", name: "orders", dialect: .postgresql)
        == #"INSERT INTO "public"."orders" ("id") VALUES (1);"#)
    #expect(
      DataExporter.sqlInsert(result: result, name: "", dialect: .postgresql)
        == #"INSERT INTO "table_name" ("id") VALUES (1);"#)
  }

  @Test("A row-index subset exports only in-range rows, in the order given")
  func rowSubset() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")],
      rows: [[.int(1)], [.int(2)], [.int(3)]],
      rowCount: 3)
    #expect(
      DataExporter.sqlInsert(result: result, rows: [2, 0, 9], name: "t", dialect: .postgresql)
        == #"INSERT INTO "t" ("id") VALUES (3), (1);"#)
  }

  @Test("INSERT writes a naive column's wall clock and a zoned column's bind form, per dialect")
  func insertDateLiteralsFollowTheColumn() {
    // 2026-10-15 12:00:00.123 UTC
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123))
    let result = QueryResult(
      columns: [
        ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
        ColumnInfo(name: "zoned", type: "timestamptz"),
      ],
      rows: [[date, date]], rowCount: 1, executionTime: 0)
    #expect(
      SQLInsertRenderer.insertScript(result: result, name: "t", dialect: .postgresql)
        == #"INSERT INTO "t" ("naive", "zoned") VALUES "#
        + "('2026-10-15 12:00:00.123', '2026-10-15T12:00:00.123000Z');")
    #expect(
      SQLInsertRenderer.insertScript(result: result, name: "t", dialect: .mysql)
        == "INSERT INTO `t` (`naive`, `zoned`) VALUES "
        + "('2026-10-15 12:00:00.123', '2026-10-15 12:00:00.123000');")
    // A row longer than its columns writes the extra date zoned
    let short = QueryResult(
      columns: [ColumnInfo(name: "naive", type: "timestamp", wallClock: true)],
      rows: [[date, date]], rowCount: 1, executionTime: 0)
    #expect(
      SQLInsertRenderer.insertScript(
        result: short, name: "t", dialect: .postgresql, includeColumns: false)
        == #"INSERT INTO "t" VALUES ('2026-10-15 12:00:00.123', '2026-10-15T12:00:00.123000Z');"#)
    // The cell-result path (Copy as INSERT, SQL export) keeps the column flag
    let cell = CellResult(columns: result.columns, rows: result.rows, rowCount: 1)
    #expect(
      DataExporter.sqlInsert(result: cell, dialect: .postgresql).contains(
        "('2026-10-15 12:00:00.123', '2026-10-15T12:00:00.123000Z')"))
  }

  @Test("pdfData is non-empty and PDFDocument has at least one page")
  func pdfDataHasAPage() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")],
      rows: [[.int(1)]],
      rowCount: 1,
      sourceQuery: "SELECT 1")
    let data = DataExporter.pdfData(result: result, title: "Result", query: nil)
    #expect(!data.isEmpty)
    #expect((PDFDocument(data: data)?.pageCount ?? 0) >= 1)
  }

  private func cellResult(tableName: String?) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")],
      rows: [[.int(1)]],
      rowCount: 1,
      tableName: tableName)
  }
}
