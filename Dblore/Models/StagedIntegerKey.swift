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

  /// `int4`, `INTEGER`, `bigint`, the serial aliases, and MySQL `tinyint`/`mediumint`
  /// (display widths and `UNSIGNED` ignored). `numeric` and floats are not.
  static func isIntegerType(_ type: String) -> Bool {
    let base =
      type.lowercased()
      .split(whereSeparator: { $0 == "(" || $0 == " " || $0 == "," })
      .first
      .map(String.init) ?? ""
    switch base {
    case "int", "int2", "int4", "int8", "int32", "int64", "integer", "bigint", "smallint",
      "serial", "bigserial", "smallserial", "tinyint", "mediumint":
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
    // An integer key column never holds NUMERIC: a decimal is no integer key
    case .decimal:
      nil
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
  /// MySQL `AUTO_INCREMENT` has no COLUMN_DEFAULT; it is read from COLUMNS.EXTRA.
  /// Nil when a name cannot be quoted, and on ClickHouse and SQL Server (a SQL Server IDENTITY
  /// column has no default either): no key is ever assigned there.
  static func lookupSQL(
    schema: String, table: String, column: String, dialect: SQLDialect
  ) -> String? {
    guard dialect != .clickhouse, dialect != .sqlserver else { return nil }
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
    if dialect == .mysql {
      return """
        SELECT (c.COLUMN_DEFAULT IS NOT NULL OR c.EXTRA LIKE '%auto_increment%') AS has_default, \
        \(maxSQL) AS max_id FROM information_schema.COLUMNS AS c \
        WHERE c.TABLE_SCHEMA = \(schemaLiteral) AND c.TABLE_NAME = \(tableLiteral) \
        AND c.COLUMN_NAME = \(columnLiteral)
        """
    }
    if dialect == .postgresql {
      return postgresLookupSQL(
        literals: (schemaLiteral, tableLiteral, columnLiteral),
        maxOf: (quotedColumn, quotedRelation))
    }
    return """
      SELECT (c.column_default IS NOT NULL) AS has_default, \(maxSQL) AS max_id \
      FROM information_schema.columns AS c \
      WHERE c.table_schema = \(schemaLiteral) AND c.table_name = \(tableLiteral) \
      AND c.column_name = \(columnLiteral)
      """
  }

  /// The PostgreSQL lookup runs on the user's session with the user's search_path, so it reads
  /// pg_catalog directly and names pg_catalog for every catalog name, function, operator and cast
  /// type: `information_schema.columns` is SQL whose helpers are parsed with the caller's
  /// search_path on PostgreSQL 13 and older. `has_default` is `column_default IS NOT NULL` as
  /// information_schema reports it: a pg_attrdef row, except for a generated column
  /// (`attgenerated` is PostgreSQL 12+, read through to_jsonb so older servers see no key). The
  /// row covers the relation kinds information_schema.columns lists. The MAX'd relation is the
  /// user's table, as the user named it (quoted literals and identifiers from the caller).
  private static func postgresLookupSQL(
    literals: (schema: String, table: String, column: String),
    maxOf: (column: String, relation: String)
  ) -> String {
    """
    SELECT (d.adbin IS NOT NULL \
    AND COALESCE(pg_catalog.to_jsonb(a) OPERATOR(pg_catalog.->>) 'attgenerated', '') \
    OPERATOR(pg_catalog.=) '') AS has_default, \
    (SELECT pg_catalog.max(\(maxOf.column)) FROM \(maxOf.relation)) AS max_id \
    FROM pg_catalog.pg_attribute a \
    JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) a.attrelid \
    JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace \
    LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid OPERATOR(pg_catalog.=) a.attrelid \
    AND d.adnum OPERATOR(pg_catalog.=) a.attnum \
    WHERE n.nspname OPERATOR(pg_catalog.=) \(literals.schema) \
    AND c.relname OPERATOR(pg_catalog.=) \(literals.table) \
    AND a.attname OPERATOR(pg_catalog.=) \(literals.column) \
    AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped \
    AND c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'v', 'f', 'p']::pg_catalog."char"[]) \
    AND NOT pg_catalog.pg_is_other_temp_schema(n.oid)
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
