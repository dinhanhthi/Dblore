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
      DataExporter.toTSV(result: result)
        == "id\tvalue\n1\t\"a\tb\"\n2\t\"l1\nl2\"\n3\t\"r\rs\"\n4\t\"say \"\"hi\"\"\"\n5\tplain\n")
  }

  @Test("A CRLF value is quoted (checked per unicode scalar, not per character)")
  func escapesCRLF() {
    #expect(DataExporter.escapeTSV("a\r\nb") == "\"a\r\nb\"")
  }
}
