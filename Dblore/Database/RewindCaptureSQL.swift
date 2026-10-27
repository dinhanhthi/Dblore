// RewindCaptureSQL.swift
// The Data Rewind row read: one row by primary key, every column in text form, and the way
// back from that stored text to binds for the inverse statements.
// - PostgreSQL reads `'v' || col::text` (the session reads an empty text cell as NULL, so the
//   one-character prefix keeps '' apart from NULL) and binds the text as an untyped `$n`.
// - MySQL reads `HEX(col)` for byte, BIT and spatial columns, bound back as `UNHEX(?)`, and
//   `CAST(col AS CHAR)` for the rest, bound back as text.
// - SQLite reads `quote(col)` and keeps the literal, so the storage class survives: `NULL`,
//   integers through `CAST(? AS INTEGER)`, reals through `CAST(? AS REAL)`, blobs through
//   `UNHEX(?)` (SQLite 3.41+), text as text.
// PostgreSQL and MySQL lock the row (`FOR UPDATE`): under READ COMMITTED a plain read can go
// stale between the read and the write. DuckDB and MongoDB have no Data Rewind.

import Foundation

nonisolated enum RewindCaptureError: Error, Equatable, LocalizedError {
  /// The engine has no Data Rewind (DuckDB, MongoDB)
  case unsupportedEngine(DatabaseType)
  /// The target has no primary key, or the key values do not match its key columns
  case noPrimaryKey
  /// The read returned another number of values than columns asked for
  case columnCount(expected: Int, actual: Int)
  /// A value is not text in the form the capture reads
  case unexpectedValue(column: String)

  var errorDescription: String? {
    switch self {
    case .unsupportedEngine(let type):
      "Data Rewind is not available for \(type.rawValue)."
    case .noPrimaryKey:
      "Data Rewind needs the table's primary key."
    case .columnCount(let expected, let actual):
      "The row read returned \(actual) values for \(expected) columns."
    case .unexpectedValue(let column):
      "The value of \(column) was not read in the expected form."
    }
  }
}

/// A stored value as a bind: the SQL around its placeholder and the text sent.
nonisolated struct RewindBind: Equatable, Sendable {
  nonisolated enum Form: Equatable, Sendable {
    case plain
    case integer
    case real
    case hex
  }

  var form: Form
  var value: SQLBindValue

  /// `placeholder` (`$1`, `?`, `?1`) wrapped as the form needs
  func sql(placeholder: String) -> String {
    switch form {
    case .plain: placeholder
    case .integer: "CAST(\(placeholder) AS INTEGER)"
    case .real: "CAST(\(placeholder) AS REAL)"
    case .hex: "UNHEX(\(placeholder))"
    }
  }
}

nonisolated enum RewindCaptureSQL {
  /// The read of the row of `target` whose key columns equal `keyValues` (in key order),
  /// bound the way the edit's own WHERE binds them. `ONLY` follows `target.updateOnly`.
  static func selectStatement(
    target: EditTarget, columns: [RewindColumn], keyValues: [CellValue], engine: DatabaseType
  ) throws -> BoundStatement {
    let (dialect, locksRow) = try route(engine)
    let keys = target.primaryKeyColumns
    guard !keys.isEmpty, keys.count == keyValues.count else {
      throw RewindCaptureError.noPrimaryKey
    }
    let reads = try columns.map { column in
      SQLDumpDataRenderer.textExpression(
        try dialect.quoteIdentifier(column.name), typeName: column.typeName, engine: engine)
    }
    var sql = "SELECT \(reads.joined(separator: ", ")) FROM "
    if target.updateOnly && dialect.supportsUpdateOnly {
      sql += "ONLY "
    }
    sql += target.qualifiedName
    let condition = try keyCondition(
      keys: keys, keyValues: keyValues, dialect: dialect, placeholder: dialect.placeholder)
    sql += " WHERE " + condition.sql
    if locksRow {
      sql += " FOR UPDATE"
    }
    return BoundStatement(sql: sql, values: condition.values, expectedRows: nil)
  }

  /// `k1 = <p1> AND k2 = <p2> ...` for the key columns `keys` equal to `keyValues` (in key
  /// order), each value bound the way an edit's own WHERE binds it (`inputText`, MySQL bytes
  /// through `UNHEX`), and the bind text of each placeholder in order (nil is NULL).
  /// `placeholder` gives the placeholder of the n-th bind (1-based). Shared with the full
  /// value read of a lazy binary cell (`LazyCellLoader`).
  static func keyCondition(
    keys: [String], keyValues: [CellValue], dialect: SQLDialect,
    placeholder: (Int) -> String
  ) throws -> (sql: String, values: [String?]) {
    guard !keys.isEmpty, keys.count == keyValues.count else {
      throw RewindCaptureError.noPrimaryKey
    }
    var conditions: [String] = []
    var values: [String?] = []
    for (index, (key, value)) in zip(keys, keyValues).enumerated() {
      let bound = CellUpdateStatement.bindPlaceholder(
        placeholder(index + 1), value, dialect: dialect)
      conditions.append("\(try dialect.quoteIdentifier(key)) = \(bound)")
      values.append(CellUpdateStatement.inputText(value, dialect: dialect))
    }
    return (conditions.joined(separator: " AND "), values)
  }

  /// One row returned by `selectStatement` as stored text per column (nil is NULL).
  static func image(
    _ row: [CellValue], columns: [RewindColumn], engine: DatabaseType
  ) throws -> RewindImage {
    _ = try route(engine)
    guard row.count == columns.count else {
      throw RewindCaptureError.columnCount(expected: columns.count, actual: row.count)
    }
    var image = RewindImage()
    for (value, column) in zip(row, columns) {
      // `updateValue` keeps a nil (NULL) entry; assigning nil through the subscript removes it
      image.updateValue(try text(value, column: column, engine: engine), forKey: column.name)
    }
    return image
  }

  /// The bind for a stored value of `column`. Stored text is checked again, since the store
  /// file is outside the database.
  static func bind(
    _ text: String?, column: RewindColumn, engine: DatabaseType
  ) throws -> RewindBind {
    switch engine {
    case .postgresql:
      return RewindBind(form: .plain, value: SQLBindValue(optionalText: text))
    case .mysql:
      guard let text else { return RewindBind(form: .plain, value: .null) }
      guard SQLDumpDataRenderer.isMySQLHexType(column.typeName) else {
        return RewindBind(form: .plain, value: .text(text))
      }
      guard SQLDumpDataRenderer.isHex(text[...]) else {
        throw RewindCaptureError.unexpectedValue(column: column.name)
      }
      // BIT reads back with an odd digit count
      return RewindBind(form: .hex, value: .text(text.utf8.count % 2 == 0 ? text : "0" + text))
    case .sqlite:
      guard let text else { return RewindBind(form: .plain, value: .null) }
      return try sqliteBind(text, column: column.name)
    case .duckdb, .mongodb:
      throw RewindCaptureError.unsupportedEngine(engine)
    }
  }

  /// The dialect of an engine with Data Rewind, and whether its read locks the row.
  private static func route(_ engine: DatabaseType) throws -> (SQLDialect, Bool) {
    switch engine {
    case .postgresql: (.postgresql, true)
    case .mysql: (.mysql, true)
    case .sqlite: (.sqlite, false)
    case .duckdb, .mongodb: throw RewindCaptureError.unsupportedEngine(engine)
    }
  }

  private static func text(
    _ value: CellValue, column: RewindColumn, engine: DatabaseType
  ) throws -> String? {
    switch (engine, value) {
    case (.postgresql, .null), (.mysql, .null):
      return nil
    case (.postgresql, .string(let text)) where text.unicodeScalars.first == "v":
      // Scalars, not characters: a combining mark after the prefix joins it in one character
      return String(text.unicodeScalars.dropFirst())
    case (.mysql, .string(let text)):
      guard
        !SQLDumpDataRenderer.isMySQLHexType(column.typeName)
          || SQLDumpDataRenderer.isHex(text[...])
      else { throw RewindCaptureError.unexpectedValue(column: column.name) }
      return text
    case (.sqlite, .string(let text)) where SQLDumpDataRenderer.isSQLiteLiteral(text):
      return text
    default:
      throw RewindCaptureError.unexpectedValue(column: column.name)
    }
  }

  /// A `quote()` literal as a bind that stores the same value and storage class.
  private static func sqliteBind(_ text: String, column: String) throws -> RewindBind {
    guard SQLDumpDataRenderer.isSQLiteLiteral(text) else {
      throw RewindCaptureError.unexpectedValue(column: column)
    }
    if text == "NULL" {
      return RewindBind(form: .plain, value: .null)
    }
    if SQLDumpDataRenderer.isNumber(text) {
      let isReal = text.contains(".") || text.contains("e")
      return RewindBind(form: isReal ? .real : .integer, value: .text(text))
    }
    let bytes = Array(text.utf8)
    if bytes.first == UInt8(ascii: "X") {
      let hex = bytes.dropFirst(2).dropLast()
      // `unhex` returns NULL for an odd digit count
      guard hex.count % 2 == 0 else { throw RewindCaptureError.unexpectedValue(column: column) }
      return RewindBind(form: .hex, value: .text(String(decoding: hex, as: UTF8.self)))
    }
    return RewindBind(form: .plain, value: .text(unquoted(bytes)))
  }

  /// `'...'` with every doubled quote made single, on bytes (the literal was checked).
  private static func unquoted(_ bytes: [UInt8]) -> String {
    let quote = UInt8(ascii: "'")
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var index = 1
    while index < bytes.count - 1 {
      result.append(bytes[index])
      index += bytes[index] == quote ? 2 : 1
    }
    return String(decoding: result, as: UTF8.self)
  }
}
