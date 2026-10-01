// ExportOptions.swift
// Choices for the result download sheet. Each format shows only its own toggles.
// Clipboard copy does not use this.

import Foundation

/// Download target. The sheet opens with the format the user picked in the Download menu.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case csv
  case excel
  case json
  case markdown
  case pdf
  case sqlInsert

  var id: String { rawValue }

  var title: String {
    switch self {
    case .csv: "CSV"
    case .excel: "Excel"
    case .json: "JSON"
    case .markdown: "Markdown"
    case .pdf: "PDF"
    case .sqlInsert: "SQL INSERT"
    }
  }

  var blurb: String {
    switch self {
    case .csv:
      "Comma-separated values. Compatible with Excel and most tools."
    case .excel:
      "Excel workbook (.xlsx)."
    case .json:
      "A JSON array of objects, one per row. Null stays null."
    case .markdown:
      "A Markdown table."
    case .pdf:
      "A paginated PDF. Long text can wrap instead of being cut off."
    case .sqlInsert:
      "INSERT statements for the rows in this result."
    }
  }

  /// CSV and Markdown can omit the column-name row. Excel and PDF always show names.
  var offersHeaderToggle: Bool {
    self == .csv || self == .markdown
  }

  /// Text formats that currently write the letters NULL. JSON and SQL keep a real null.
  var offersNullAsEmpty: Bool {
    self == .csv || self == .excel || self == .markdown
  }

  var offersWrap: Bool {
    self == .pdf
  }
}

/// Options for one download. Toggles that the format does not offer stay stored and unused.
nonisolated struct ExportOptions: Equatable, Sendable {
  var format: ExportFormat
  /// Column indexes whose cells are written as `mask`, including nulls.
  var redactedColumns: Set<Int> = []
  /// PDF only. On by default so a long cell is not cut with an ellipsis.
  var wrapText: Bool = true
  /// CSV and Markdown. On matches the previous exporters, which always wrote a header.
  var includeHeader: Bool = true
  /// CSV, Excel, and Markdown. Off keeps the previous "NULL" text.
  var nullAsEmpty: Bool = false

  static let mask = "****"

  var emptiesNulls: Bool {
    nullAsEmpty && format.offersNullAsEmpty
  }
}

extension DataExporter {
  /// Result with sensitive columns replaced, then remaining nulls emptied when that option applies.
  static func applying(_ options: ExportOptions, to result: CellResult) -> CellResult {
    let emptyNulls = options.emptiesNulls
    if options.redactedColumns.isEmpty && !emptyNulls {
      return result
    }
    let rows = result.rows.map { row in
      row.enumerated().map { index, value -> CellValue in
        if options.redactedColumns.contains(index) {
          return .string(ExportOptions.mask)
        }
        if emptyNulls && value.isNull {
          return .string("")
        }
        return value
      }
    }
    return CellResult(
      columns: result.columns,
      rows: rows,
      executionTime: result.executionTime,
      rowCount: rows.count,
      timestamp: result.timestamp,
      error: result.error,
      wasLimited: result.wasLimited,
      sourceQuery: result.sourceQuery,
      tableName: result.tableName,
      primaryKeyColumns: result.primaryKeyColumns,
      affectedRows: result.affectedRows,
      editTarget: result.editTarget)
  }
}
