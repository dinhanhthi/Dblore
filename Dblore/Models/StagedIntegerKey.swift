// StagedIntegerKey.swift
// Next integer for a staged insert when the primary key is one integer column
// and the database does not fill it (no identity, serial, or other default).

import Foundation

/// Picks the next integer primary-key value for a data-viewer insert.
nonisolated enum StagedIntegerKey {
  /// One integer primary-key column, or nil when the key is composite or not an integer.
  static func integerColumn(primaryKey: [String], columns: [ColumnInfo]) -> String? {
    guard primaryKey.count == 1, let name = primaryKey.first,
      let column = columns.first(where: { $0.name == name }), isIntegerType(column.type)
    else { return nil }
    return name
  }

  /// `int4`, `INTEGER`, `bigint`, and the serial aliases. `numeric` and floats are not.
  static func isIntegerType(_ type: String) -> Bool {
    let base =
      type.lowercased()
      .split(whereSeparator: { $0 == "(" || $0 == " " || $0 == "," })
      .first
      .map(String.init) ?? ""
    switch base {
    case "int", "int2", "int4", "int8", "int32", "int64", "integer", "bigint", "smallint",
      "serial", "bigserial", "smallserial":
      return true
    default:
      return false
    }
  }

  static func integer(from value: CellValue) -> Int? {
    switch value {
    case .int(let number):
      number
    case .string(let text), .json(let text):
      Int(text)
    default:
      nil
    }
  }

  /// One past the highest known key. No known key means the first row, `1`.
  static func nextValue(known: [Int]) -> Int? {
    guard let floor = known.max() else { return 1 }
    let (next, overflow) = floor.addingReportingOverflow(1)
    return overflow ? nil : next
  }

  /// `value + 1`, or nil at `Int.max`.
  static func increment(_ value: Int) -> Int? {
    let (next, overflow) = value.addingReportingOverflow(1)
    return overflow ? nil : next
  }

  /// Catalog lookup: whether the column has a default, and `MAX(column)` of the table.
  /// Nil when a name cannot be quoted.
  static func lookupSQL(
    schema: String, table: String, column: String, dialect: SQLDialect
  ) -> String? {
    let quotedColumn: String
    let quotedRelation: String
    do {
      quotedColumn = try dialect.quoteIdentifier(column)
      let quotedTable = try dialect.quoteIdentifier(table)
      if schema.isEmpty {
        quotedRelation = quotedTable
      } else {
        quotedRelation = try dialect.quoteIdentifier(schema) + "." + quotedTable
      }
    } catch {
      return nil
    }
    let schemaLiteral = dialect.literal(.string(schema))
    let tableLiteral = dialect.literal(.string(table))
    let columnLiteral = dialect.literal(.string(column))
    let maxSQL = "(SELECT MAX(\(quotedColumn)) FROM \(quotedRelation))"
    if dialect == .sqlite {
      let pragma =
        schema.isEmpty
        ? "pragma_table_info(\(tableLiteral))"
        : "pragma_table_info(\(tableLiteral), \(schemaLiteral))"
      return """
        SELECT (dflt_value IS NOT NULL) AS has_default, \(maxSQL) AS max_id \
        FROM \(pragma) WHERE name = \(columnLiteral)
        """
    }
    return """
      SELECT (c.column_default IS NOT NULL) AS has_default, \(maxSQL) AS max_id \
      FROM information_schema.columns AS c \
      WHERE c.table_schema = \(schemaLiteral) AND c.table_name = \(tableLiteral) \
      AND c.column_name = \(columnLiteral)
      """
  }

  /// A lookup row `(has_default, max_id)`. Nil when the row is missing or not those types.
  static func parseLookup(_ row: [CellValue]?) -> (hasDefault: Bool, serverMax: Int?)? {
    guard let row, row.count >= 2, let hasDefault = bool(from: row[0]) else { return nil }
    if case .null = row[1] { return (hasDefault, nil) }
    guard let serverMax = integer(from: row[1]) else { return nil }
    return (hasDefault, serverMax)
  }

  private static func bool(from value: CellValue) -> Bool? {
    switch value {
    case .bool(let flag):
      flag
    case .int(let number):
      number != 0
    case .string(let text), .json(let text):
      switch text.lowercased() {
      case "t", "true", "1": true
      case "f", "false", "0": false
      default: nil
      }
    default:
      nil
    }
  }
}
