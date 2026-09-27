//
//  ResultGridModel.swift
//  SQLNotebook
//
//  Pure model behind the result grid: the displayed (sorted) rows, cell display text and
//  TSV of a selection. It holds only the displayed rows, so every row index it takes is a
//  table (displayed) row and can never be confused with an index into `CellResult.rows`.
//

import Foundation

struct ResultGridModel {
  let columns: [ColumnInfo]
  private let displayedRows: [[CellValue]]

  init(result: CellResult, sortColumn: String?, ascending: Bool) {
    columns = result.columns
    displayedRows = result.sortedRows(byColumn: sortColumn, ascending: ascending)
  }

  var rowCount: Int { displayedRows.count }

  /// The displayed row at table row `row`
  func row(at row: Int) -> [CellValue] {
    displayedRows[row]
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
      columns.map { Self.escapeTSV(value(row: row, column: $0).fullString) }
        .joined(separator: "\t")
    }
    .joined(separator: "\n")
  }

  private static func escapeTSV(_ value: String) -> String {
    guard value.unicodeScalars.contains(where: { "\t\n\r\"".unicodeScalars.contains($0) }) else {
      return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
