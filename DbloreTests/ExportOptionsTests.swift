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

  @Test("Each format offers only the options that fit that file")
  func optionsMatchFormat() {
    #expect(ExportFormat.csv.offersLineBreakToSpace)
    #expect(ExportFormat.excel.offersLineBreakToSpace)
    #expect(ExportFormat.markdown.offersLineBreakToSpace)
    #expect(ExportFormat.sqlInsert.offersLineBreakToSpace)
    #expect(!ExportFormat.json.offersLineBreakToSpace)
    #expect(!ExportFormat.pdf.offersLineBreakToSpace)

    #expect(ExportFormat.csv.offersFormulaSanitize)
    #expect(ExportFormat.excel.offersFormulaSanitize)
    #expect(!ExportFormat.markdown.offersFormulaSanitize)
    #expect(!ExportFormat.json.offersFormulaSanitize)
    #expect(!ExportFormat.sqlInsert.offersFormulaSanitize)
    #expect(!ExportFormat.pdf.offersFormulaSanitize)

    #expect(ExportFormat.csv.offersEncoding && ExportFormat.csv.offersLineBreak)
    #expect(ExportFormat.json.offersEncoding && ExportFormat.json.offersLineBreak)
    #expect(ExportFormat.markdown.offersEncoding && ExportFormat.markdown.offersLineBreak)
    #expect(ExportFormat.sqlInsert.offersEncoding && ExportFormat.sqlInsert.offersLineBreak)
    #expect(!ExportFormat.excel.offersEncoding && !ExportFormat.excel.offersLineBreak)
    #expect(!ExportFormat.pdf.offersEncoding && !ExportFormat.pdf.offersLineBreak)

    #expect(ExportFormat.csv.offersQuote)
    #expect(!ExportFormat.excel.offersQuote)
    #expect(!ExportFormat.json.offersQuote)
    #expect(!ExportFormat.markdown.offersQuote)
    #expect(!ExportFormat.sqlInsert.offersQuote)
    #expect(!ExportFormat.pdf.offersQuote)

    #expect(ExportFormat.json.offersJsonPretty)
    #expect(ExportFormat.json.offersJsonIncludeNull)
    #expect(ExportFormat.json.offersJsonValuesAsString)
    #expect(!ExportFormat.csv.offersJsonPretty)

    #expect(ExportFormat.sqlInsert.offersHeaderToggle)
    #expect(ExportFormat.sqlInsert.offersNullAsEmpty)
    #expect(ExportFormat.sqlInsert.headerToggleTitle == "Include column names")
    #expect(ExportFormat.csv.headerToggleTitle == "Put field names in the first row")
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
  }

  @Test("CSV can quote every field, or none, including a field that contains a comma")
  func quoteAlwaysAndNever() {
    let result = grid(columns: ["note"], rows: [[.string("plain")], [.string("a,b")]])
    let always = DataExporter.toCSV(result: result, includeHeader: false, quote: .always)
    #expect(always.contains("\"plain\""))
    let never = DataExporter.toCSV(result: result, includeHeader: false, quote: .never)
    #expect(never.contains("a,b"))
    #expect(!never.contains("\"a,b\""))
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

  @Test("Reset keeps the format and restores the other choices")
  func resetKeepsFormat() {
    let changed = ExportOptions(
      format: .csv,
      redactedColumns: [1],
      convertLineBreaksToSpace: true,
      sanitizeFormulas: false,
      encoding: .windows1252,
      quote: .always,
      lineBreak: .crlf)
    let reset = ExportOptions(format: changed.format)
    #expect(reset.format == .csv)
    #expect(reset.redactedColumns.isEmpty)
    #expect(!reset.convertLineBreaksToSpace)
    #expect(reset.sanitizeFormulas)
    #expect(reset.encoding == .utf8)
    #expect(reset.quote == .ifNeeded)
    #expect(reset.lineBreak == .lf)
  }

  @Test("Row-count emphasis steps up at one thousand and ten thousand rows")
  func rowScaleSteps() {
    #expect(ExportRowScale.level(for: 999) == .modest)
    #expect(ExportRowScale.level(for: 1_000) == .large)
    #expect(ExportRowScale.level(for: 9_999) == .large)
    #expect(ExportRowScale.level(for: 10_000) == .huge)
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
