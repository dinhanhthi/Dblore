// DataExporterTSVTests.swift
// The TSV export (copy as TSV) escapes values with the same rule as the grid selection copy:
// a value with a tab, LF, CR or quote is wrapped in quotes with inner quotes doubled.

import Foundation
import Testing

@testable import Dblore

@Suite("Data exporter TSV")
@MainActor
struct DataExporterTSVTests {
  @Test("toTSV keeps the header row and quotes values with a tab, LF, CR or quote")
  func escapesSpecialValues() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "value", type: "text")],
      rows: [
        [.int(1), .string("a\tb")], [.int(2), .string("l1\nl2")], [.int(3), .string("r\rs")],
        [.int(4), .string("say \"hi\"")], [.int(5), .string("plain")],
      ],
      rowCount: 5)
    #expect(
      DataExporter.toTSV(result: result, neutralizesFormulas: false)
        == "id\tvalue\n1\t\"a\tb\"\n2\t\"l1\nl2\"\n3\t\"r\rs\"\n4\t\"say \"\"hi\"\"\"\n5\tplain\n")
  }

  @Test("A CRLF value is quoted (checked per unicode scalar, not per character)")
  func escapesCRLF() {
    #expect(DataExporter.escapeTSV("a\r\nb") == "\"a\r\nb\"")
  }

  @Test("Copied TSV prefixes formula-like text and headers when on, never numbers or dates")
  func neutralizesFormulaText() {
    let date = Date(timeIntervalSince1970: 0)
    let result = CellResult(
      columns: [
        ColumnInfo(name: "=sum", type: "text"), ColumnInfo(name: "n", type: "int4"),
        ColumnInfo(name: "d", type: "date"),
      ],
      rows: [[.string("=1+1"), .int(-5), .date(date)]],
      rowCount: 1)
    let iso = CellValue.date(date).fullString
    #expect(
      DataExporter.toTSV(result: result, neutralizesFormulas: true)
        == "'=sum\tn\td\n'=1+1\t-5\t\(iso)\n")
    #expect(
      DataExporter.toTSV(result: result, neutralizesFormulas: false)
        == "=sum\tn\td\n=1+1\t-5\t\(iso)\n")
  }

  @Test("Copied TSV escapes headers like cells, and leaves JSON cells raw")
  func escapesHeadersAndKeepsJSON() {
    let result = CellResult(
      columns: [
        ColumnInfo(name: "x\t=HYPERLINK(\"y\")", type: "text"),
        ColumnInfo(name: "x\n=1", type: "text"),
      ],
      rows: [[.json("-5"), .string("-5")]],
      rowCount: 1)
    #expect(
      DataExporter.toTSV(result: result, neutralizesFormulas: true)
        == "\"x\t=HYPERLINK(\"\"y\"\")\"\t\"x\n=1\"\n-5\t'-5\n")
    #expect(
      DataExporter.toTSV(result: result, neutralizesFormulas: false)
        == "\"x\t=HYPERLINK(\"\"y\"\")\"\t\"x\n=1\"\n-5\t-5\n")
  }
}
