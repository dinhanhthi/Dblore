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
  @Test("INSERT uses result.tableName when table is nil, and the explicit table when passed")
  func insertTableName() {
    let result = cellResult(tableName: "orders")
    #expect(
      DataExporter.sqlInsert(result: result, dialect: .postgresql)
        == #"INSERT INTO "orders" ("id") VALUES (1);"#)
    #expect(
      DataExporter.sqlInsert(result: result, table: "shipments", dialect: .postgresql)
        == #"INSERT INTO "shipments" ("id") VALUES (1);"#)
  }

  @Test("A nil or empty table name becomes the placeholder table_name")
  func placeholderTableName() {
    let unnamed = cellResult(tableName: nil)
    #expect(
      DataExporter.sqlInsert(result: unnamed, dialect: .postgresql)
        == #"INSERT INTO "table_name" ("id") VALUES (1);"#)
    #expect(
      DataExporter.sqlInsert(result: unnamed, table: "", dialect: .postgresql)
        == #"INSERT INTO "table_name" ("id") VALUES (1);"#)
    #expect(
      DataExporter.sqlInsert(result: unnamed, table: " \n\t ", dialect: .postgresql)
        == #"INSERT INTO "table_name" ("id") VALUES (1);"#)
  }

  @Test("A row-index subset exports only in-range rows, in the order given")
  func rowSubset() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")],
      rows: [[.int(1)], [.int(2)], [.int(3)]],
      rowCount: 3,
      tableName: "t")
    #expect(
      DataExporter.sqlInsert(result: result, rows: [2, 0, 9], dialect: .postgresql)
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
      SQLInsertRenderer.insertScript(result: result, table: "t", dialect: .postgresql)
        == #"INSERT INTO "t" ("naive", "zoned") VALUES "#
        + "('2026-10-15 12:00:00.123', '2026-10-15T12:00:00.123000Z');")
    #expect(
      SQLInsertRenderer.insertScript(result: result, table: "t", dialect: .mysql)
        == "INSERT INTO `t` (`naive`, `zoned`) VALUES "
        + "('2026-10-15 12:00:00.123', '2026-10-15 12:00:00.123000');")
    // A row longer than its columns writes the extra date zoned
    let short = QueryResult(
      columns: [ColumnInfo(name: "naive", type: "timestamp", wallClock: true)],
      rows: [[date, date]], rowCount: 1, executionTime: 0)
    #expect(
      SQLInsertRenderer.insertScript(
        result: short, table: "t", dialect: .postgresql, includeColumns: false)
        == #"INSERT INTO "t" VALUES ('2026-10-15 12:00:00.123', '2026-10-15T12:00:00.123000Z');"#)
    // The cell-result path (Copy as INSERT, SQL export) keeps the column flag
    let cell = CellResult(columns: result.columns, rows: result.rows, rowCount: 1, tableName: "t")
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
