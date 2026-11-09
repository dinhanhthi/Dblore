// StreamedResultWriterTests.swift
// The streamed export writes the same bytes as the whole-result download for the same rows and
// options, whatever the batches it is given and however often its buffer flushes.

import Foundation
import Testing

@testable import Dblore

@Suite("Streamed result writer")
@MainActor
struct StreamedResultWriterTests {
  /// One file format with the table an INSERT names
  struct Case: Sendable, CustomTestStringConvertible {
    let label: String
    let format: StreamedResultWriter.Format
    var dialect: SQLDialect = .postgresql
    var schema: String? = nil
    var name: String? = nil

    var testDescription: String { label }
  }

  nonisolated static let cases: [Case] = [
    Case(label: "CSV defaults", format: .download(ExportOptions(format: .csv))),
    Case(
      label: "CSV always quoted, no header, empty NULL, flat lines, CRLF, UTF-16 LE",
      format: .download(
        ExportOptions(
          format: .csv, includeHeader: false, nullAsEmpty: true, convertLineBreaksToSpace: true,
          encoding: .utf16LE, quote: .always, lineBreak: .crlf))),
    Case(
      label: "CSV never quoted, Windows-1252, CR",
      format: .download(
        ExportOptions(format: .csv, encoding: .windows1252, quote: .never, lineBreak: .cr))),
    Case(label: "TSV", format: .tsv(neutralizesFormulas: true)),
    Case(label: "JSON pretty", format: .download(ExportOptions(format: .json))),
    Case(
      label: "JSON compact, no NULL keys, values as text",
      format: .download(
        ExportOptions(
          format: .json, jsonPretty: false, jsonIncludeNull: false, jsonValuesAsString: true))),
    Case(
      label: "SQL INSERT PostgreSQL", format: .download(ExportOptions(format: .sqlInsert)),
      schema: "public", name: "orders"),
    Case(
      label: "SQL INSERT MySQL without columns, empty NULL, CRLF",
      format: .download(
        ExportOptions(format: .sqlInsert, includeHeader: false, nullAsEmpty: true, lineBreak: .crlf)
      ),
      dialect: .mysql, name: "orders"),
  ]

  @Test("Streamed bytes equal the whole-result export", arguments: cases)
  func matchesWholeResult(_ testCase: Case) throws {
    let result = Self.sample()
    let rows = result.rows
    let batches = [Array(rows[0..<1]), [], Array(rows[1..<3]), Array(rows[3...])]
    #expect(
      try streamed(testCase, columns: result.columns, batches: batches)
        == expected(testCase, result))
  }

  @Test("An empty result writes what the whole-result export writes", arguments: cases)
  func emptyResult(_ testCase: Case) throws {
    let result = CellResult(columns: Self.sample().columns, rows: [], rowCount: 0)
    #expect(
      try streamed(testCase, columns: result.columns, batches: []) == expected(testCase, result))
  }

  @Test("INSERT keeps the whole-result chunks when the batches do not line up with them")
  func insertChunks() throws {
    let columns = [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "note", type: "text")]
    let rows: [[CellValue]] = (0..<1001).map { [.int($0), .string("row \($0)")] }
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let testCase = Case(
      label: "INSERT", format: .download(ExportOptions(format: .sqlInsert)), name: "t")
    let batches = [Array(rows[0..<300]), Array(rows[300..<600]), Array(rows[600...])]
    let bytes = try streamed(testCase, columns: columns, batches: batches)
    #expect(bytes == expected(testCase, result))
    #expect(
      String(decoding: bytes, as: UTF8.self).components(separatedBy: "INSERT INTO").count == 4)
  }

  @Test("A small buffer flushes during the writes and keeps the bytes, one byte order mark")
  func smallBufferFlushes() throws {
    let result = Self.sample()
    let testCase = Case(
      label: "CSV UTF-16 LE", format: .download(ExportOptions(format: .csv, encoding: .utf16LE)))
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    let writer = StreamedResultWriter(
      format: testCase.format, columns: result.columns, fileHandle: handle, bufferSize: 16)
    for row in result.rows { try writer.write(rows: [row]) }
    #expect(try handle.offset() > 0)
    try writer.finish()
    try handle.close()
    #expect(try Data(contentsOf: url) == expected(testCase, result))
  }

  // MARK: - Helpers

  /// What the download writes for `result`: options applied, then the format's text, then the
  /// line ending and encoding (`DataExporter.download`); TSV is `toTSV` as UTF-8
  private func expected(_ testCase: Case, _ result: CellResult) -> Data {
    switch testCase.format {
    case .tsv(let neutralizesFormulas):
      return Data(
        DataExporter.toTSV(result: result, neutralizesFormulas: neutralizesFormulas).utf8)
    case .download(let options):
      let prepared = DataExporter.applying(options, to: result)
      let text: String
      switch options.format {
      case .csv:
        text = DataExporter.toCSV(
          result: prepared, includeHeader: options.includeHeader, quote: options.quote)
      case .json:
        text = DataExporter.toJSON(
          result: prepared, pretty: options.jsonPretty, includeNull: options.jsonIncludeNull,
          valuesAsString: options.jsonValuesAsString)
      case .sqlInsert:
        text = DataExporter.sqlInsert(
          result: prepared, schema: testCase.schema, name: testCase.name,
          dialect: testCase.dialect, includeColumns: options.includeHeader)
      default:
        Issue.record("not a streamed format")
        text = ""
      }
      return DataExporter.fileData(text: text, options: options)
    }
  }

  private func streamed(
    _ testCase: Case, columns: [ColumnInfo], batches: [[[CellValue]]]
  ) throws -> Data {
    let url = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    let writer = StreamedResultWriter(
      format: testCase.format, columns: columns, dialect: testCase.dialect,
      schema: testCase.schema, name: testCase.name, fileHandle: handle)
    for batch in batches { try writer.write(rows: batch) }
    try writer.finish()
    try handle.close()
    return try Data(contentsOf: url)
  }

  private func temporaryFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("streamed-\(UUID().uuidString)")
    try Data().write(to: url)
    return url
  }

  /// Every value kind, with NULLs, quotes, delimiters, line breaks, unicode, a formula-like
  /// text, a naive and a zoned date and a masked column
  private static func sample() -> CellResult {
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123))
    let columns = [
      ColumnInfo(name: "id", type: "int4"),
      ColumnInfo(name: "name, \"quoted\"", type: "text"),
      ColumnInfo(name: "amount", type: "numeric"),
      ColumnInfo(name: "ratio", type: "float8"),
      ColumnInfo(name: "active", type: "bool"),
      ColumnInfo(name: "payload", type: "jsonb"),
      ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
      ColumnInfo(name: "zoned", type: "timestamptz"),
      ColumnInfo(name: "blob", type: "bytea"),
      ColumnInfo(name: "email", type: "text", masked: true),
      ColumnInfo(name: "id", type: "int4"),
    ]
    let rows: [[CellValue]] = [
      [
        .int(1), .string("plain"), .decimal("-007.50"), .double(1.5), .bool(true),
        .json(#"{"a": [1, 2], "b": "x/y"}"#), date, date, .data(Data([0, 1, 0xFF])),
        .string("xx@xx"), .int(10),
      ],
      [
        .int(2), .string("a,b \"c\"\nline\r\nnext\ttab"), .decimal("12345678901234567890.1"),
        .double(.nan), .bool(false), .json("-5"), .null, .null, .null, .null, .null,
      ],
      [
        .int(3), .string("=SUM(A1)"), .null, .double(-0.25), .null, .json("not json"),
        date, date, .data(Data()), .string("****"), .int(30),
      ],
      [
        .int(4), .string("Ünïcødé 😀 e\u{0301} 日本"), .decimal("0"), .null, .bool(true),
        .json(#"[{"k": null}]"#), date, .null, .data(Data("héllo".utf8)), .string("m"),
        .int(40),
      ],
    ]
    return CellResult(columns: columns, rows: rows, rowCount: rows.count)
  }
}
