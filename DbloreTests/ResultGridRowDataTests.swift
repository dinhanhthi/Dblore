// ResultGridRowDataTests.swift
// The sidebar row data of a tapped grid cell comes from the displayed (possibly sorted) row,
// never from `result.rows` re-indexed by the display position.

import Foundation
import Testing

@testable import Dblore

@Suite("Result grid - row data of the tapped row")
@MainActor
struct ResultGridRowDataTests {
  private let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text"),
  ]
  private let rows: [[CellValue]] = [
    [.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .string("b")],
  ]

  @Test("Sorted grid: the tapped displayed row's data carries that row's primary key")
  func sortedRowData() {
    let result = CellResult(columns: columns, rows: rows, rowCount: 3)
    let displayed = result.sortedRows(byColumn: "id", ascending: true)
    #expect(displayed.map { $0[0] } == [.int(1), .int(2), .int(3)])

    // Tap on the first displayed row (id 1), which is result.rows[1], not result.rows[0]
    let rowData = CellResult.rowData(columns: result.columns, row: displayed[0])
    #expect(rowData["id"] == .int(1))
    #expect(rowData["name"] == .string("a"))
    #expect(rowData["id"] != result.rows[0][0])
  }

  @Test("Descending sort and no sort column keep row data aligned with the displayed row")
  func descendingAndUnsorted() {
    let result = CellResult(columns: columns, rows: rows, rowCount: 3)
    let descending = result.sortedRows(byColumn: "name", ascending: false)
    #expect(CellResult.rowData(columns: columns, row: descending[0])["id"] == .int(3))
    #expect(CellResult.rowData(columns: columns, row: descending[2])["id"] == .int(1))
    #expect(result.sortedRows(byColumn: nil, ascending: true) == rows)
    #expect(result.sortedRows(byColumn: "missing", ascending: true) == rows)
  }

  @Test("Duplicate column names keep the last value and a short row maps only its values")
  func duplicateAndShortRows() {
    let duplicated = [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "id", type: "int4")]
    #expect(CellResult.rowData(columns: duplicated, row: [.int(1), .int(2)]) == ["id": .int(2)])
    #expect(CellResult.rowData(columns: columns, row: [.int(5)]) == ["id": .int(5)])
  }
}
