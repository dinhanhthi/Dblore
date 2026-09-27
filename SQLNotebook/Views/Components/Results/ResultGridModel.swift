//
//  ResultGridModel.swift
//  SQLNotebook
//
//  Pure model behind the result grid: the displayed (sorted) rows, cell display text and
//  TSV of a selection. It holds only the displayed rows, so every row index it takes is a
//  table (displayed) row and can never be confused with an index into `CellResult.rows`;
//  only `displayedRow(forOriginalRow:)` takes an index into `CellResult.rows`.
//

import Foundation

struct ResultGridModel {
  let columns: [ColumnInfo]
  private let displayedRows: [[CellValue]]
  /// Displayed row of each index into `CellResult.rows`
  private let displayedRowByOriginalRow: [Int]

  init(result: CellResult, sortColumn: String?, ascending: Bool) {
    columns = result.columns
    let originalRows = result.sortedRowIndices(byColumn: sortColumn, ascending: ascending)
    displayedRows = originalRows.map { result.rows[$0] }
    var displayedRowByOriginalRow = Array(repeating: 0, count: originalRows.count)
    for (displayedRow, originalRow) in originalRows.enumerated() {
      displayedRowByOriginalRow[originalRow] = displayedRow
    }
    self.displayedRowByOriginalRow = displayedRowByOriginalRow
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

  /// Value at a table row and column; NULL when the row is shorter than the columns
  func value(row: Int, column: Int) -> CellValue {
    let values = displayedRows[row]
    return column < values.count ? values[column] : .null
  }

  /// Text shown in a cell, the same as the result table (NULL shows as "NULL")
  func displayText(row: Int, column: Int) -> String {
    value(row: row, column: column).displayString
  }

  /// Tab-separated selected cells (no header, no trailing newline), full values like the
  /// TSV copy. A value with a tab, newline or quote is quoted with quotes doubled, as in CSV.
  func tsv(rows: IndexSet, columns: IndexSet) -> String {
    rows.map { row in
      columns.map { DataExporter.escapeTSV(value(row: row, column: $0).fullString) }
        .joined(separator: "\t")
    }
    .joined(separator: "\n")
  }
}
