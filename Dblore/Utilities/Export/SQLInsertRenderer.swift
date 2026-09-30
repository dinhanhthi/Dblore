// SQLInsertRenderer.swift
// Multi-row INSERT scripts and IN lists from a query result. The caller supplies the table name.

import Foundation

/// Renders a `QueryResult` as SQL text. Identifiers and literals come from `SQLDialect`.
nonisolated enum SQLInsertRenderer {
  /// One `INSERT` statement per batch. No rows, or rows with no columns, is `""`.
  static func insertScript(
    result: QueryResult, table: String, dialect: SQLDialect, batchSize: Int = 500
  ) -> String {
    guard !result.rows.isEmpty, !result.columns.isEmpty else {
      return ""
    }
    let size = batchSize < 1 ? 1 : batchSize
    let quotedTable = quotedIdentifier(table, dialect: dialect)
    let columnList = result.columns.map { quotedIdentifier($0.name, dialect: dialect) }
      .joined(separator: ", ")
    let header = "INSERT INTO \(quotedTable) (\(columnList)) VALUES"

    var statements: [String] = []
    statements.reserveCapacity((result.rows.count + size - 1) / size)
    var offset = 0
    while offset < result.rows.count {
      let end = min(offset + size, result.rows.count)
      let tuples = result.rows[offset..<end].map { tuple($0, dialect: dialect) }
      statements.append(header + " " + tuples.joined(separator: ", ") + ";")
      offset = end
    }
    return statements.joined(separator: "\n")
  }

  /// `(1, 2, 'a')`. Nulls are omitted; duplicates keep the first occurrence.
  /// When any null was dropped, a comment follows on the next line.
  static func inList(values: [CellValue], dialect: SQLDialect) -> String {
    var kept: [CellValue] = []
    kept.reserveCapacity(values.count)
    var nullCount = 0
    for value in values {
      if value.isNull {
        nullCount += 1
        continue
      }
      if !kept.contains(value) {
        kept.append(value)
      }
    }
    let list = "(" + kept.map { dialect.literal($0) }.joined(separator: ", ") + ")"
    guard nullCount > 0 else { return list }
    return list + "\n-- \(nullCount) NULL values omitted"
  }

  /// `fallback` trimmed, when that is non-empty. Otherwise `table_name`.
  /// `ColumnInfo` has a table OID, not a name.
  static func tableName(for result: QueryResult, fallback: String?) -> String {
    if let fallback {
      let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return "table_name"
  }

  private static func tuple(_ row: [CellValue], dialect: SQLDialect) -> String {
    "(" + row.map { dialect.literal($0) }.joined(separator: ", ") + ")"
  }

  /// `dialect.quoteIdentifier`, or the same doubled-quote text when the name contains a NUL.
  private static func quotedIdentifier(_ name: String, dialect: SQLDialect) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
  }
}
