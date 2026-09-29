//
//  ResultGridModel.swift
//  Dblore
//
//  Pure model behind the result grid: the displayed (sorted) rows, cell display text and
//  TSV of a selection. It holds only the displayed rows, so every row index it takes is a
//  table (displayed) row and can never be confused with an index into `CellResult.rows`;
//  only `displayedRow(forOriginalRow:)` takes, and `originalRow(forDisplayedRow:)` returns,
//  an index into `CellResult.rows`.
//

import Foundation

struct ResultGridModel {
  let columns: [ColumnInfo]
  private let displayedRows: [[CellValue]]
  /// Index into `CellResult.rows` of each displayed row
  private let originalRows: [Int]
  /// Displayed row of each index into `CellResult.rows`
  private let displayedRowByOriginalRow: [Int]
  /// Lazily filled display text, shared by copies of this model (the rows are immutable, and
  /// a new model, hence an empty cache, is built whenever the result or sort changes)
  private let textCache: DisplayTextCache

  init(result: CellResult, sortColumn: String?, ascending: Bool) {
    columns = result.columns
    let originalRows = result.sortedRowIndices(byColumn: sortColumn, ascending: ascending)
    displayedRows = originalRows.map { result.rows[$0] }
    self.originalRows = originalRows
    var displayedRowByOriginalRow = Array(repeating: 0, count: originalRows.count)
    for (displayedRow, originalRow) in originalRows.enumerated() {
      displayedRowByOriginalRow[originalRow] = displayedRow
    }
    self.displayedRowByOriginalRow = displayedRowByOriginalRow
    textCache = DisplayTextCache(rowCount: originalRows.count)
  }

  var rowCount: Int { displayedRows.count }

  /// The displayed row at table row `row`
  func row(at row: Int) -> [CellValue] {
    displayedRows[row]
  }

  /// Table (displayed) row of `originalRow`, an index into `CellResult.rows` such as a search
  /// match's row; nil when out of range
  func displayedRow(forOriginalRow originalRow: Int) -> Int? {
    displayedRowByOriginalRow.indices.contains(originalRow)
      ? displayedRowByOriginalRow[originalRow] : nil
  }

  /// Index into `CellResult.rows` of table (displayed) row `displayedRow`; nil when out of
  /// range
  func originalRow(forDisplayedRow displayedRow: Int) -> Int? {
    originalRows.indices.contains(displayedRow) ? originalRows[displayedRow] : nil
  }

  /// Value at a table row and column; NULL when the row is shorter than the columns
  func value(row: Int, column: Int) -> CellValue {
    let values = displayedRows[row]
    return column < values.count ? values[column] : .null
  }

  /// Longest text shown in a cell; longer text ends with "…"
  static let maxDisplayLength = 1000

  /// Text shown in a cell, the same as the result table (NULL shows as "NULL"), on one line
  /// (line breaks become spaces) and at most `maxDisplayLength` characters: the single-line
  /// text field still lays out every line of a long multi-line value, which made scrolling lag
  func displayText(row: Int, column: Int) -> String {
    if let cached = textCache.text(row: row, column: column) { return cached }
    let text = computeDisplayText(row: row, column: column)
    textCache.store(text, row: row, column: column, columnCount: columns.count)
    return text
  }

  private func computeDisplayText(row: Int, column: Int) -> String {
    let text = value(row: row, column: column).displayString
    let prefix = text.prefix(Self.maxDisplayLength)
    let flat = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
    return prefix.endIndex < text.endIndex ? flat + "…" : flat
  }

  /// Tab-separated selected cells (no header, no trailing newline), full values like the
  /// TSV copy, `columns` (model column indices) in the given order. A value with a tab,
  /// newline or quote is quoted with quotes doubled, as in CSV.
  func tsv(rows: IndexSet, columns: [Int]) -> String {
    rows.map { row in
      columns.map { DataExporter.escapeTSV(value(row: row, column: $0).fullString) }
        .joined(separator: "\t")
    }
    .joined(separator: "\n")
  }
}

/// Per-cell display text of one `ResultGridModel`, filled on first request. A row's array is
/// allocated on first store, so memory stays proportional to the cells actually shown. Main
/// actor only, like the model (the project's default isolation), so no locking is needed.
private final class DisplayTextCache {
  private var rows: [[String?]?]

  init(rowCount: Int) {
    rows = Array(repeating: nil, count: rowCount)
  }

  func text(row: Int, column: Int) -> String? {
    guard let cells = rows[row], column < cells.count else { return nil }
    return cells[column]
  }

  func store(_ text: String, row: Int, column: Int, columnCount: Int) {
    // A column past the model's columns (a short row shows NULL) is not cached
    guard column < columnCount else { return }
    if rows[row] == nil { rows[row] = Array(repeating: nil, count: columnCount) }
    rows[row]?[column] = text
  }
}
