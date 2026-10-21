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

  @Test("Line breaks inside a cell become spaces only for formats that offer it")
  func lineBreakBecomesSpace() {
    let result = grid(columns: ["note"], rows: [[.string("a\nb")]])
    let csv = DataExporter.applying(
      ExportOptions(format: .csv, convertLineBreaksToSpace: true), to: result)
    #expect(csv.rows[0][0] == .string("a b"))
    let json = DataExporter.applying(
      ExportOptions(format: .json, convertLineBreaksToSpace: true), to: result)
    #expect(json.rows[0][0] == .string("a\nb"))
  }

  @Test("Formula-like text is prefixed, and a real number is left alone")
  func sanitizesFormulaTextNotNumbers() {
    let result = grid(columns: ["expr", "n"], rows: [[.string("=1+1"), .int(-1)]])
    let excel = DataExporter.applying(ExportOptions(format: .excel), to: result)
    #expect(excel.rows[0][0] == .string("'=1+1"))
    #expect(excel.rows[0][1] == .int(-1))
    let xml = DataExporter.toExcelXML(result: excel)
    #expect(xml.contains("&apos;=1+1"))
    #expect(xml.contains(">-1</Data>"))
    let json = DataExporter.applying(
      ExportOptions(format: .json, sanitizeFormulas: true), to: result)
    #expect(json.rows[0][0] == .string("=1+1"))
    let hidden = grid(
      columns: ["crlf", "lf", "mark"],
      rows: [[.string("\r\n=1+1"), .string("\n=1+1"), .string("=\u{0301}1+1")]])
    let csv = DataExporter.applying(ExportOptions(format: .csv), to: hidden)
    #expect(csv.rows[0][0] == .string("'\r\n=1+1"))
    #expect(csv.rows[0][1] == .string("'\n=1+1"))
    #expect(csv.rows[0][2] == .string("'=\u{0301}1+1"))
  }

  @Test("Without quotes, a formula cannot start the next physical line of a field")
  func neverQuoteNeutralizesEveryLine() {
    let result = grid(columns: ["note"], rows: [[.string("abc\r\n=HYPERLINK(\"x\")\n@y")]])
    let never = DataExporter.applying(ExportOptions(format: .csv, quote: .never), to: result)
    #expect(never.rows[0][0] == .string("abc\r\n'=HYPERLINK(\"x\")\n'@y"))
    let text = DataExporter.toCSV(result: never, includeHeader: false, quote: .never)
    let lines = text.unicodeScalars.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
    #expect(!lines.contains { ["=", "+", "-", "@"].contains($0.first) })
    let quoted = DataExporter.applying(ExportOptions(format: .csv), to: result)
    #expect(quoted.rows[0][0] == result.rows[0][0])
    let smuggled = grid(columns: ["a,=1", "b"], rows: [[.string("x,=1+1"), .string("\"=1+1\"")]])
    let split = DataExporter.applying(ExportOptions(format: .csv, quote: .never), to: smuggled)
    #expect(split.rows[0] == [.string("x,'=1+1"), .string("'\"=1+1\"")])
    let csv = DataExporter.toCSV(result: split, quote: .never)
    let fields = csv.unicodeScalars.split(whereSeparator: { "\r\n,".unicodeScalars.contains($0) })
    #expect(!fields.contains { ["=", "+", "-", "@", "\""].contains($0.first) })
  }

  @Test("Column names are sanitized like text cells, and stay raw when sanitizing is off")
  func sanitizesHeaders() {
    let result = grid(columns: ["=HYPERLINK(\"x\")", "a\n=1"], rows: [[.int(1), .int(2)]])
    let never = DataExporter.applying(ExportOptions(format: .csv, quote: .never), to: result)
    #expect(never.columns.map(\.name) == ["'=HYPERLINK(\"x\")", "a\n'=1"])
    let excel = DataExporter.applying(ExportOptions(format: .excel), to: result)
    #expect(DataExporter.toExcelXML(result: excel).contains("&apos;=HYPERLINK"))
    let raw = DataExporter.applying(
      ExportOptions(format: .csv, sanitizeFormulas: false, quote: .never), to: result)
    #expect(raw.columns.map(\.name) == ["=HYPERLINK(\"x\")", "a\n=1"])
  }

  @Test("CSV can quote every field, or none, including a field that contains a comma")
  func quoteAlwaysAndNever() {
    let result = grid(columns: ["note"], rows: [[.string("plain")], [.string("a,b")]])
    let always = DataExporter.toCSV(result: result, includeHeader: false, quote: .always)
    #expect(always.contains("\"plain\""))
    let never = DataExporter.toCSV(result: result, includeHeader: false, quote: .never)
    #expect(never.contains("a,b"))
    #expect(!never.contains("\"a,b\""))
    #expect(DataExporter.escapeCSV("\r\n", quote: .ifNeeded) == "\"\r\n\"")
  }

  @Test("The finished text file uses the chosen line ending and encoding")
  func lineEndingAndEncoding() {
    let crlf = DataExporter.fileData(
      text: "A\n", options: ExportOptions(format: .csv, encoding: .utf16LE, lineBreak: .crlf))
    #expect(
      crlf == Data([0xFF, 0xFE, 0x41, 0x00, 0x0D, 0x00, 0x0A, 0x00]))
    let latin = DataExporter.fileData(
      text: "é", options: ExportOptions(format: .markdown, encoding: .windows1252))
    #expect(latin == Data([0xE9]))
  }

  @Test("JSON can be compact, omit nulls, or write every value as text")
  func jsonShape() {
    let result = grid(columns: ["n", "token"], rows: [[.int(2), .null]])
    let compact = DataExporter.toJSON(result: result, pretty: false)
    #expect(!compact.contains("\n"))
    #expect(compact.contains("\"token\""))
    let omitted = DataExporter.toJSON(result: result, pretty: false, includeNull: false)
    #expect(!omitted.contains("token"))
    #expect(omitted.contains("2"))
    let text = DataExporter.toJSON(
      result: result, pretty: false, includeNull: true, valuesAsString: true)
    #expect(text.contains("\"2\""))
    #expect(text.contains("\"NULL\""))
  }

  @Test("SQL can omit column names, write an empty string for NULL, and flatten line breaks")
  func sqlShape() {
    let named = DataExporter.sqlInsert(
      result: sample(), dialect: .postgresql, includeColumns: false)
    #expect(named.contains("INSERT INTO \"accounts\" VALUES"))
    #expect(!named.contains("pwd"))
    let emptied = DataExporter.applying(
      ExportOptions(format: .sqlInsert, nullAsEmpty: true), to: sample())
    let sql = DataExporter.sqlInsert(result: emptied, dialect: .postgresql)
    #expect(sql.contains("''"))
    #expect(!sql.contains("NULL"))
    let broken = grid(columns: ["note"], rows: [[.string("a\nb")]])
    let flat = DataExporter.applying(
      ExportOptions(format: .sqlInsert, convertLineBreaksToSpace: true), to: broken)
    let script = DataExporter.sqlInsert(result: flat, table: "t", dialect: .postgresql)
    #expect(script.contains("'a b'"))
    #expect(!script.contains("a\nb"))
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

  private func grid(columns: [String], rows: [[CellValue]]) -> CellResult {
    CellResult(
      columns: columns.map { ColumnInfo(name: $0, type: "text") },
      rows: rows,
      rowCount: rows.count,
      tableName: "accounts")
  }
}
