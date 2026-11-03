// DataExporterXLSXTests.swift
// The XLSX file format: values a spreadsheet app would change as numbers are written as text
// cells, and NULL is an empty cell. Reads the worksheet XML back out of the generated file.

import Foundation
import Testing

@testable import Dblore

@Suite("Data exporter XLSX")
@MainActor
struct DataExporterXLSXTests {
  @Test("A 19-digit integer and NaN are text cells, and NULL is an empty cell")
  func writesExactTextAndEmptyNull() throws {
    let result = CellResult(
      columns: [
        ColumnInfo(name: "big", type: "int8"), ColumnInfo(name: "small", type: "int8"),
        ColumnInfo(name: "ratio", type: "float8"), ColumnInfo(name: "note", type: "text"),
      ],
      rows: [[.int(9_223_372_036_854_775_807), .int(999_999_999_999_999), .double(.nan), .null]],
      rowCount: 1)
    let sheet = try worksheet(of: try #require(DataExporter.toXLSX(result: result)))

    let big = try cell("A2", in: sheet)
    #expect(big.attribute(forName: "t")?.stringValue == "inlineStr")
    #expect(text(of: big) == "9223372036854775807")
    // 15 digits still fit a spreadsheet number exactly
    let small = try cell("B2", in: sheet)
    #expect(small.attribute(forName: "t")?.stringValue == "n")
    #expect(value(of: small) == "999999999999999")
    let ratio = try cell("C2", in: sheet)
    #expect(ratio.attribute(forName: "t")?.stringValue == "inlineStr")
    #expect(text(of: ratio) == "NaN")
    let note = try cell("D2", in: sheet)
    #expect(note.attribute(forName: "t") == nil)
    #expect(note.childCount == 0)
  }

  @Test("Dates are text cells: a naive column's wall clock, a zoned column as ISO 8601 UTC")
  func writesDatesPerColumn() throws {
    // 2026-10-15 12:00:00.123 UTC
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123))
    let result = CellResult(
      columns: [
        ColumnInfo(name: "naive", type: "timestamp", wallClock: true),
        ColumnInfo(name: "zoned", type: "timestamptz"),
      ],
      rows: [[date, date]],
      rowCount: 1)
    let sheet = try worksheet(of: try #require(DataExporter.toXLSX(result: result)))

    let naive = try cell("A2", in: sheet)
    #expect(naive.attribute(forName: "t")?.stringValue == "inlineStr")
    #expect(text(of: naive) == "2026-10-15 12:00:00.123")
    let zoned = try cell("B2", in: sheet)
    #expect(zoned.attribute(forName: "t")?.stringValue == "inlineStr")
    #expect(text(of: zoned) == "2026-10-15T12:00:00.123Z")
  }

  /// Unzips `xl/worksheets/sheet1.xml` from the XLSX bytes
  private func worksheet(of xlsx: Data) throws -> XMLDocument {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".xlsx")
    try xlsx.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", file.path, "xl/worksheets/sheet1.xml"]
    let output = Pipe()
    unzip.standardOutput = output
    try unzip.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    unzip.waitUntilExit()
    #expect(unzip.terminationStatus == 0)
    return try XMLDocument(data: data)
  }

  private func cell(_ reference: String, in sheet: XMLDocument) throws -> XMLElement {
    let nodes = try sheet.nodes(forXPath: "//*[local-name()='c'][@r='\(reference)']")
    return try #require(nodes.first as? XMLElement)
  }

  private func text(of cell: XMLElement) -> String? {
    try? cell.nodes(forXPath: "*[local-name()='is']/*[local-name()='t']").first?.stringValue
  }

  private func value(of cell: XMLElement) -> String? {
    try? cell.nodes(forXPath: "*[local-name()='v']").first?.stringValue
  }
}
