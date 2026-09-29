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

  @Test("Display text is on one line and capped at maxDisplayLength characters")
  func flatCappedDisplayText() {
    let max = ResultGridModel.maxDisplayLength
    let exact = String(repeating: "x", count: max)
    let values: [CellValue] = [
      .string("a\nb"), .string("a\r\nb"), .string(exact), .string(exact + "y"),
    ]
    let model = ResultGridModel(
      result: CellResult(
        columns: [ColumnInfo(name: "t", type: "text")], rows: values.map { [$0] },
        rowCount: values.count),
      sortColumn: nil, ascending: true)
    #expect(
      (0..<4).map { model.displayText(row: $0, column: 0) } == [
        "a b", "a b", exact, exact + "…",
      ])
    // Edit and copy keep the full value
    #expect(model.value(row: 1, column: 0).fullString == "a\r\nb")
  }

  @Test("TSV columns follow the given order")
  func tsvColumnOrder() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(model.tsv(rows: IndexSet([0, 1]), columns: [1, 0]) == "a\t1\nNULL\t2")
  }

  @Test("A displayed row maps back to its index in result.rows")
  func originalRowLookup() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    #expect((0..<3).map { model.originalRow(forDisplayedRow: $0) } == [0, 2, 1])
    #expect(model.originalRow(forDisplayedRow: 3) == nil)
    #expect(model.originalRow(forDisplayedRow: -1) == nil)
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
    let tsv = model.tsv(rows: IndexSet([0, 1]), columns: [0, 1])
    #expect(tsv == "1\t\"a\tb\"\n2\t\"line1\nline2\"")
  }

  @Test(
    "An original row index maps to its displayed row, by index even for duplicate rows",
    arguments: [true, false])
  func originalToDisplayedRow(ascending: Bool) {
    let result = CellResult(
      columns: columns,
      rows: [
        [.int(2), .string("x")], [.int(1), .string("y")], [.int(2), .string("x")],
        [.int(1), .null],
      ],
      rowCount: 4)
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: ascending)
    let displayed = result.rows.indices.compactMap { model.displayedRow(forOriginalRow: $0) }
    #expect(displayed.count == 4)
    #expect(Set(displayed).count == 4)  // duplicates map to distinct displayed rows
    for (original, row) in zip(result.rows.indices, displayed) {
      #expect(model.row(at: row) == result.rows[original])
    }
    #expect(model.displayedRow(forOriginalRow: 4) == nil)
    #expect(model.displayedRow(forOriginalRow: -1) == nil)

    let unsorted = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(result.rows.indices.map { unsorted.displayedRow(forOriginalRow: $0) } == [0, 1, 2, 3])
  }

  // MARK: - Display text cache

  /// The uncached algorithm: display string, first 1000 characters, line breaks as spaces
  private func referenceText(_ value: CellValue) -> String {
    let text = value.displayString
    let prefix = text.prefix(1000)
    let flat = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
    return prefix.endIndex < text.endIndex ? flat + "…" : flat
  }

  @Test("Cached text equals the uncached computation, on the first and the second call")
  func cachedTextEqualsUncached() {
    let values: [CellValue] = [
      .string("line1\nline2\r\nline3"), .string(String(repeating: "ab\n", count: 600)),
      .string(String(repeating: "x", count: 1000)), .string(String(repeating: "x", count: 1001)),
      .null, .int(-42), .double(3.14159), .bool(true),
      .date(Date(timeIntervalSince1970: 1_700_000_000)), .json("{\"a\":\n[1,2]}"),
      .data(Data([0xDE, 0xAD, 0xBE, 0xEF])),
    ]
    let result = CellResult(
      columns: [ColumnInfo(name: "v", type: "text")], rows: values.map { [$0] },
      rowCount: values.count)
    let model = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    for pass in 1...2 {
      for (row, value) in values.enumerated() {
        #expect(
          model.displayText(row: row, column: 0) == referenceText(value), "pass \(pass) row \(row)")
      }
    }
    // Column beyond a short row shows NULL
    #expect(model.displayText(row: 0, column: 5) == "NULL")
  }

  @Test("A model rebuilt after an inline edit shows the new value, the old model keeps the old")
  func rebuiltModelShowsEdit() {
    let before = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(before.displayText(row: 0, column: 1) == "c")  // fills the cache

    var editedRows = rows
    editedRows[0][1] = .string("edited")
    let edited = CellResult(columns: columns, rows: editedRows, rowCount: 3)
    let after = ResultGridModel(result: edited, sortColumn: nil, ascending: true)

    #expect(after.displayText(row: 0, column: 1) == "edited")
    #expect(before.displayText(row: 0, column: 1) == "c")
  }

  @Test("The cache is per model: models over different results do not share entries")
  func cacheIsPerModel() {
    let other = CellResult(
      columns: columns, rows: [[.int(9), .string("z")]], rowCount: 1)
    let modelA = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    let modelB = ResultGridModel(result: other, sortColumn: nil, ascending: true)
    #expect(modelA.displayText(row: 0, column: 0) == "3")
    #expect(modelB.displayText(row: 0, column: 0) == "9")
    #expect(modelA.displayText(row: 0, column: 1) == "c")
    #expect(modelB.displayText(row: 0, column: 1) == "z")
  }

  @Test("A sorted model caches by displayed row")
  func sortedModelCachesByDisplayedRow() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    for _ in 1...2 {
      #expect(model.displayText(row: 0, column: 0) == "3")
      #expect(model.displayText(row: 0, column: 1) == "c")
      #expect(model.displayText(row: 2, column: 0) == "1")
      #expect(model.displayText(row: 1, column: 1) == "NULL")
    }
  }
}
