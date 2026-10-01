// ChartSpec.swift
// Suggested mark and columns for charting a query result.

import Foundation

/// Mark used to draw a query result. Suggestion only picks line or bar.
nonisolated enum ChartKind: String, Codable, Equatable, Sendable {
  case bar
  case line
  case area
  case point
}

/// Columns and mark for one chart. `xColumn == nil` means the row index.
nonisolated struct ChartSpec: Codable, Equatable, Sendable {
  var kind: ChartKind
  var xColumn: String?
  /// At most five names when the spec comes from `suggested(for:)`.
  var yColumns: [String]
  var seriesColumn: String?

  /// A chart for `result`, or nil when no column can be plotted as y.
  /// Y is an int/double column, or a numeric SQL type (including numeric strings).
  /// X is the first temporal column, else the first text column with at most 50
  /// distinct non-null values, else the row index. Temporal x uses a line mark.
  static func suggested(for result: QueryResult) -> ChartSpec? {
    let columns = result.columns
    guard !columns.isEmpty else { return nil }
    let values = columns.indices.map { columnValues(result, at: $0) }

    var yColumns: [String] = []
    for index in columns.indices where isNumericY(columns[index], values: values[index]) {
      yColumns.append(columns[index].name)
    }

    let axis = xAxis(columns: columns, values: values)
    if let name = axis.name {
      yColumns.removeAll { $0 == name }
    }
    guard !yColumns.isEmpty else { return nil }
    if yColumns.count > maxYColumns {
      yColumns.removeSubrange(maxYColumns...)
    }

    return ChartSpec(
      kind: axis.temporal ? .line : .bar,
      xColumn: axis.name,
      yColumns: yColumns,
      seriesColumn: nil
    )
  }

  private static let maxYColumns = 5

  private static let numericSQLTypes: Set<String> = [
    "int2", "int4", "int8", "float4", "float8", "numeric", "decimal",
    "int", "smallint", "integer", "bigint", "real", "float", "double", "double precision",
  ]

  static func columnValues(_ result: QueryResult, at index: Int) -> [CellValue] {
    result.rows.map { row in
      index < row.count ? row[index] : .null
    }
  }

  /// Date/time type, or a column whose non-null values are all `CellValue.date`.
  static func isTemporal(_ column: ColumnInfo, values: [CellValue]) -> Bool {
    if temporalType(column.type) { return true }
    var sawDate = false
    for value in values {
      switch value {
      case .null:
        continue
      case .date:
        sawDate = true
      default:
        return false
      }
    }
    return sawDate
  }

  private struct AxisChoice {
    var name: String?
    var temporal: Bool
  }

  private static func xAxis(columns: [ColumnInfo], values: [[CellValue]]) -> AxisChoice {
    for index in columns.indices where isTemporal(columns[index], values: values[index]) {
      return AxisChoice(name: columns[index].name, temporal: true)
    }
    for index in columns.indices {
      let column = columns[index]
      if isNumericY(column, values: values[index]) { continue }
      if isLowCardinalityText(column, values: values[index]) {
        return AxisChoice(name: column.name, temporal: false)
      }
    }
    return AxisChoice(name: nil, temporal: false)
  }

  private static func isNumericY(_ column: ColumnInfo, values: [CellValue]) -> Bool {
    if numericSQLType(column.type) { return true }
    var sawNumber = false
    for value in values {
      switch value {
      case .null:
        continue
      case .int, .double:
        sawNumber = true
      default:
        return false
      }
    }
    return sawNumber
  }

  private static func isLowCardinalityText(_ column: ColumnInfo, values: [CellValue]) -> Bool {
    var distinct: Set<String> = []
    for value in values {
      switch value {
      case .null:
        continue
      case .string(let text):
        distinct.insert(text)
        if distinct.count > 50 { return false }
      default:
        return false
      }
    }
    if !distinct.isEmpty { return true }
    return textType(column.type) && values.allSatisfy(\.isNull)
  }

  private static func numericSQLType(_ type: String) -> Bool {
    numericSQLTypes.contains(typeHead(type))
  }

  private static func temporalType(_ type: String) -> Bool {
    let head = type.lowercased()
    return head.contains("date") || head.contains("time") || head.contains("timestamp")
  }

  private static func textType(_ type: String) -> Bool {
    let head = typeHead(type)
    return head == "text" || head == "varchar" || head == "char" || head == "character"
      || head == "character varying" || head == "name" || head == "string"
  }

  private static func typeHead(_ type: String) -> String {
    var head = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let paren = head.firstIndex(of: "(") {
      head = String(head[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return head
  }
}
