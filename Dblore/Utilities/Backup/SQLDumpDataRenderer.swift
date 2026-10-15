// SQLDumpDataRenderer.swift
// Data reads and value literals of a SQL dump. Every value is read as text per column and never
// decoded into a `CellValue` number or date (which loses NUMERIC precision and fractional
// seconds):
// - PostgreSQL selects `'v' || "col"::text`. The session reads an empty text cell as NULL, so
//   each value carries a one-character prefix that `literal` removes; NULL stays NULL (text
//   concatenated with NULL is NULL). The text becomes a quoted string literal (`bytea` is its
//   `\x...` form, which `SET LOCAL bytea_output = 'hex'` pins).
// - MySQL selects `HEX(col)` for binary, blob, bit and spatial columns (written `X'...'`) and
//   `CAST(col AS CHAR)` for the rest (written as a quoted string, backslash-escaped). The
//   `HEX()` text is checked to be hex digits.
// - SQLite selects `quote(col)`, which already returns an SQL literal, written as returned once
//   checked to be `NULL`, a number, a quoted string or a blob.

import Foundation

nonisolated enum SQLDumpDataRenderer {
  /// MySQL `DATA_TYPE`s read with `HEX()`: byte strings, BIT and spatial values (SRID + WKB)
  static let mysqlHexTypes: Set<String> = [
    "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry",
    "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
    "geometrycollection", "geomcollection",
  ]

  /// The read of `table`'s rows, one text value per insert column, in column order.
  /// PostgreSQL reads `FROM ONLY`, so inherited and partitioned rows are not read twice.
  static func selectStatement(
    _ table: SQLDumpDDL.TableInsert, engine: DatabaseType
  ) throws -> String {
    let dialect = engine.dialect
    let values = try table.columns.map { column -> String in
      let name = try dialect.quoteIdentifier(column.name)
      switch engine {
      case .postgresql: return "'v' || \(name)::text"
      case .mysql: return isMySQLHex(column) ? "HEX(\(name))" : "CAST(\(name) AS CHAR)"
      default: return "quote(\(name))"
      }
    }
    let from = engine == .postgresql ? "FROM ONLY \(table.target)" : "FROM \(table.target)"
    return values.isEmpty
      ? "SELECT \(from)" : "SELECT \(values.joined(separator: ", ")) \(from)"
  }

  /// The SQL literal of one value read by `selectStatement`.
  /// - Throws: `SQLDumpError.unexpectedValue` when the value is not in the form read.
  static func literal(
    _ value: CellValue, column: TableStructure.Column, table: String, engine: DatabaseType
  ) throws -> String {
    if case .null = value { return "NULL" }
    switch (engine, value) {
    case (.postgresql, .string(let text)) where text.hasPrefix("v"):
      return SQLDialect.postgresql.literal(.string(String(text.dropFirst())))
    case (.mysql, .string(let text)) where isMySQLHex(column):
      guard isHex(text[...]) else {
        throw SQLDumpError.unexpectedValue(table: table, column: column.name)
      }
      return "X'" + (text.count % 2 == 0 ? text : "0" + text) + "'"
    case (.mysql, .string(let text)):
      return SQLDialect.mysql.literal(.string(text))
    case (.mysql, .data(let data)):
      return SQLDialect.mysql.literal(.data(data))
    case (.sqlite, .string(let text)) where isSQLiteLiteral(text):
      return text
    default:
      throw SQLDumpError.unexpectedValue(table: table, column: column.name)
    }
  }

  private static func isMySQLHex(_ column: TableStructure.Column) -> Bool {
    mysqlHexTypes.contains(column.dataType.lowercased())
  }

  /// `quote()` output: `NULL`, a number (`9.0e+999` for infinity), `'text'` with every inner
  /// quote doubled, or `X'hex'`.
  private static func isSQLiteLiteral(_ text: String) -> Bool {
    if text == "NULL" || isNumber(text) { return true }
    if text.count >= 3, text.hasPrefix("X'"), text.hasSuffix("'") {
      return isHex(text.dropFirst(2).dropLast())
    }
    return isQuotedString(Array(text.utf8))
  }

  /// `'...'` with every inner quote doubled, checked on bytes: a combining mark after a quote
  /// forms one `Character` that would hide the quote.
  private static func isQuotedString(_ bytes: [UInt8]) -> Bool {
    let quote = UInt8(ascii: "'")
    guard bytes.count >= 2, bytes.first == quote, bytes.last == quote else { return false }
    var index = 1
    while index < bytes.count - 1 {
      if bytes[index] == quote {
        guard index + 1 < bytes.count - 1, bytes[index + 1] == quote else { return false }
        index += 1
      }
      index += 1
    }
    return true
  }

  /// `-`, digits, an optional `.digits` fraction and an optional `e[+-]digits` exponent.
  private static func isNumber(_ text: String) -> Bool {
    let unsigned = text.hasPrefix("-") ? text.dropFirst() : text[...]
    let parts = unsigned.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
    let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard mantissa.allSatisfy(isDigits) else { return false }
    guard parts.count == 2 else { return true }
    let exponent = parts[1]
    return isDigits(
      exponent.hasPrefix("+") || exponent.hasPrefix("-") ? exponent.dropFirst() : exponent)
  }

  private static func isDigits(_ text: Substring) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
  }

  /// ASCII hex digits only (empty allowed): `Character.isHexDigit` also accepts fullwidth forms.
  private static func isHex(_ text: Substring) -> Bool {
    text.utf8.allSatisfy { byte in
      (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
  }
}
