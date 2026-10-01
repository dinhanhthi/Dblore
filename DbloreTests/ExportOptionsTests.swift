// ExportOptionsTests.swift
// Sensitive-column masking and the format-specific download toggles.

import Foundation
import Testing

@testable import Dblore

@Suite("Export options")
@MainActor
struct ExportOptionsTests {
  @Test("Several checked columns become ****, including null, and other columns stay")
  func redactsSelectedColumns() {
    let result = sample()
    let options = ExportOptions(format: .csv, redactedColumns: [0, 2])
    let prepared = DataExporter.applying(options, to: result)
    #expect(prepared.rows[0][0] == .string("****"))
    #expect(prepared.rows[0][1] == .string("visible"))
    #expect(prepared.rows[0][2] == .string("****"))
    let csv = DataExporter.toCSV(result: prepared)
    #expect(csv.contains("****"))
    #expect(!csv.contains("hunter2"))
    #expect(csv.contains("visible"))
  }

  @Test("An index past the row is ignored")
  func ignoresOutOfRangeColumn() {
    let prepared = DataExporter.applying(
      ExportOptions(format: .json, redactedColumns: [9]), to: sample())
    #expect(prepared.rows[0][0] == .string("hunter2"))
  }

  @Test("NULL becomes an empty field only for formats that offer that toggle")
  func nullAsEmptyRespectsFormat() {
    let csv = DataExporter.applying(
      ExportOptions(format: .csv, nullAsEmpty: true), to: sample())
    #expect(csv.rows[0][2] == .string(""))
    let json = DataExporter.applying(
      ExportOptions(format: .json, nullAsEmpty: true), to: sample())
    #expect(json.rows[0][2] == .null)
  }

  @Test("A redacted null stays **** even when NULL is converted to empty")
  func redactionWinsOverNullAsEmpty() {
    let prepared = DataExporter.applying(
      ExportOptions(format: .csv, redactedColumns: [2], nullAsEmpty: true), to: sample())
    #expect(prepared.rows[0][2] == .string("****"))
  }

  @Test("CSV and Markdown can omit the column-name row")
  func headerToggle() {
    let result = sample()
    let csv = DataExporter.toCSV(result: result, includeHeader: false)
    #expect(!csv.contains("note"))
    #expect(!csv.contains("token"))
    #expect(csv.contains("hunter2"))
    let markdown = DataExporter.toMarkdown(result: result, includeHeader: false)
    #expect(!markdown.contains("| note "))
    #expect(!markdown.contains("| --- "))
    #expect(markdown.contains("visible"))
  }

  @Test("A redacted SQL value is the quoted mask, not the original text")
  func sqlRedactsLiteral() {
    let prepared = DataExporter.applying(
      ExportOptions(format: .sqlInsert, redactedColumns: [0]), to: sample())
    let sql = DataExporter.sqlInsert(result: prepared, dialect: .postgresql)
    #expect(sql.contains("'****'"))
    #expect(!sql.contains("hunter2"))
  }

  private func sample() -> CellResult {
    CellResult(
      columns: [
        ColumnInfo(name: "pwd", type: "text"),
        ColumnInfo(name: "note", type: "text"),
        ColumnInfo(name: "token", type: "text"),
      ],
      rows: [[.string("hunter2"), .string("visible"), .null]],
      rowCount: 1,
      tableName: "accounts")
  }
}
