//
//  CellResult+Grid.swift
//  Dblore
//
//  Result grid helpers: display order of the rows and the row data of a tapped row.
//

import Foundation

extension CellResult {
  /// Rows in display order: sorted by `column` (stable for equal values is not guaranteed),
  /// or `rows` unchanged when there is no sort column or it is not in the result.
  func sortedRows(byColumn column: String?, ascending: Bool) -> [[CellValue]] {
    sortedRowIndices(byColumn: column, ascending: ascending).map { rows[$0] }
  }

  /// Indices into `rows` in display order (the order of `sortedRows`), so duplicate rows keep
  /// their own original index
  func sortedRowIndices(byColumn column: String?, ascending: Bool) -> [Int] {
    guard let column, let columnIndex = columns.firstIndex(where: { $0.name == column }) else {
      return Array(rows.indices)
    }
    return rows.indices.sorted { index1, index2 in
      let row1 = rows[index1]
      let row2 = rows[index2]
      guard columnIndex < row1.count, columnIndex < row2.count else { return false }
      let value1 = row1[columnIndex]
      let value2 = row2[columnIndex]
      return ascending ? value1 < value2 : value2 < value1
    }
  }

  /// Column name to value for one displayed `row` (the row itself, never re-indexed into
  /// `rows`, whose order differs once the grid is sorted). A later duplicate column name wins.
  nonisolated static func rowData(columns: [ColumnInfo], row: [CellValue]) -> [String: CellValue] {
    var rowData: [String: CellValue] = [:]
    for (column, value) in zip(columns, row) {
      rowData[column.name] = value
    }
    return rowData
  }
}
