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

  @Test("IN list matches SQLInsertRenderer.inList")
  func inListMatchesRenderer() {
    let values: [CellValue] = [.int(1), .string("a"), .null]
    #expect(
      DataExporter.sqlINList(values: values, dialect: .postgresql)
        == SQLInsertRenderer.inList(values: values, dialect: .postgresql))
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
