// ResultGridModelTests.swift
// The grid model only knows displayed (sorted) rows: every table row index maps to the
// displayed row, never to `result.rows` re-indexed by the display position.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Result grid model")
@MainActor
struct ResultGridModelTests {
  private let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text"),
  ]
  private let rows: [[CellValue]] = [
    [.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .null],
  ]

  private var result: CellResult { CellResult(columns: columns, rows: rows, rowCount: 3) }

  @Test("Ascending and descending sort map table rows and columns to the sorted values")
  func sortMapping() {
    let ascending = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(ascending.rowCount == 3)
    #expect((0..<3).map { ascending.value(row: $0, column: 0) } == [.int(1), .int(2), .int(3)])
    #expect(ascending.value(row: 0, column: 1) == .string("a"))

    let descending = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    #expect((0..<3).map { descending.value(row: $0, column: 0) } == [.int(3), .int(2), .int(1)])

    let unsorted = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect((0..<3).map { unsorted.row(at: $0) } == rows)
  }

  @Test("Displayed-row lookup returns the sorted row, not result.rows at that index")
  func displayedRowLookup() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(model.row(at: 0) == [.int(1), .string("a")])
    #expect(model.row(at: 0) != result.rows[0])
  }

  @Test("NULL is displayed as NULL, like the current result table")
  func nullDisplayText() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(model.displayText(row: 1, column: 1) == "NULL")
    #expect(model.displayText(row: 0, column: 1) == "a")
  }

  @Test("TSV of a 2x2 selection quotes values containing a tab or a newline")
  func tsvSelection() {
    let result = CellResult(
      columns: columns,
      rows: [
        [.int(2), .string("line1\nline2")], [.int(1), .string("a\tb")], [.int(3), .string("x")],
      ],
      rowCount: 3)
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    let tsv = model.tsv(rows: IndexSet([0, 1]), columns: IndexSet([0, 1]))
    #expect(tsv == "1\t\"a\tb\"\n2\t\"line1\nline2\"")
  }
}
