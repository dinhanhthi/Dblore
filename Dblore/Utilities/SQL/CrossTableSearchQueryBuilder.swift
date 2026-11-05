// CrossTableSearchQueryBuilder.swift
// The SELECT that looks for one value in one table (Find a Value in Every Table). Every column
// whose type has a text form is cast to text (PostgreSQL `text`, MySQL `CHAR`, SQLite `TEXT`,
// DuckDB `VARCHAR`) and compared with the value: a case-insensitive `LIKE` (`ILIKE` on
// PostgreSQL and DuckDB, `LOWER()` on both sides on SQLite and MySQL) with `%`, `_` and the
// escape character escaped and an `ESCAPE` clause (contains), or `=` (equals). Binary and
// spatial columns are skipped. The shown (display) columns are selected as they are, not cast,
// so they decode and show as in the grid (a timestamp as a date in its column's zone). The value
// is always the `:v` bind (the gate rewrites it per dialect), never SQL text, and every
// identifier is quoted. Columns are joined with OR, at most `rowLimit` rows. The result's last
// column is the 1-based index of the first searched column that matched. On PostgreSQL the cast,
// `=` and `ILIKE` are `pg_catalog`'s (`::pg_catalog.text`, `OPERATOR(pg_catalog.=)`,
// `OPERATOR(pg_catalog.~~*)` with `pg_catalog.like_escape`), so no object planted on the user's
// `search_path` runs; they compare the text form, so even a citext column is qualified. A
// statement is returned only once it passed `ReadOnlyQueryGuard`.

import Foundation

nonisolated enum CrossTableSearchQueryBuilder {
  enum Mode: String, CaseIterable, Identifiable, Sendable {
    case contains
    case equals

    var id: String { rawValue }

    var title: String {
      switch self {
      case .contains: "Contains"
      case .equals: "Equals"
      }
    }
  }

  /// A column as the loaded schema lists it
  struct Column: Sendable, Equatable {
    var name: String
    var type: String
    var isPrimaryKey = false
  }

  struct Statement: Sendable, Equatable {
    /// One SELECT with `:v` placeholders
    var sql: String
    var parameters: [String: SQLBindValue]
    /// Columns shown for each matching row (the key columns, else the first searched ones), in
    /// the result's first columns
    var displayColumns: [String]
    /// Columns compared with the value, in the order of the match index
    var searchedColumns: [String]
  }

  static let rowLimit = 50
  static let valueParameter = "v"
  /// Not a backslash (a MySQL string escape) and no comment start in any dialect
  static let escapeCharacter: Unicode.Scalar = "!"
  /// Shown for a table without a key: the first searched columns
  static let fallbackDisplayColumns = 3

  /// Base type names (lowercased, no length, schema or array suffix) that are bytes or shapes
  private static let skippedTypes: Set<String> = [
    "bytea", "blob", "tinyblob", "mediumblob", "longblob", "binary", "varbinary",
    "geometry", "geography", "point", "line", "lseg", "box", "path", "polygon", "circle",
    "linestring", "multipoint", "multilinestring", "multipolygon", "geometrycollection",
    "geomcollection", "raster",
  ]

  /// The SELECT for `table`, nil when no column has a text form. Throws when a name cannot be
  /// quoted (a NUL, or MongoDB) or the statement is refused by `ReadOnlyQueryGuard`.
  static func statement(
    schema: String, table: String, columns: [Column], value: String, mode: Mode,
    dialect: SQLDialect
  ) throws -> Statement? {
    let searched = columns.filter { isTextCastable(type: $0.type) }
    guard !searched.isEmpty else { return nil }
    let keys = searched.filter(\.isPrimaryKey)
    let display = keys.isEmpty ? Array(searched.prefix(fallbackDisplayColumns)) : keys

    let placeholder = ":\(valueParameter)"
    let predicates = try searched.map { column in
      let quoted = try dialect.quoteIdentifier(column.name)
      switch mode {
      case .contains: return try containsPredicate(quoted, placeholder, dialect: dialect)
      case .equals:
        return dialect.comparison(textCast(quoted, dialect: dialect), .equal, placeholder)
      }
    }
    let selected = try display.map { try dialect.quoteIdentifier($0.name) }
    let matchIndex =
      "CASE "
      + predicates.enumerated().map { "WHEN \($1) THEN \($0 + 1)" }.joined(separator: " ")
      + " END"
    let relation =
      schema.isEmpty
      ? try dialect.quoteIdentifier(table)
      : try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(table)
    let sql =
      "SELECT \((selected + [matchIndex]).joined(separator: ", ")) FROM \(relation)"
      + " WHERE \(predicates.joined(separator: " OR ")) LIMIT \(rowLimit)"
    _ = try ReadOnlyQueryGuard.check(sql, dialect: dialect, refuseFileAccess: true)
    let bound = mode == .contains ? "%\(escapedLikeText(value))%" : value
    return Statement(
      sql: sql, parameters: [valueParameter: .text(bound)], displayColumns: display.map(\.name),
      searchedColumns: searched.map(\.name))
  }

  /// False for binary and spatial types. An empty type (SQLite without a declared type) has a
  /// text form.
  static func isTextCastable(type: String) -> Bool {
    var base = type.lowercased().trimmingCharacters(in: .whitespaces)
    if let paren = base.firstIndex(of: "(") { base = String(base[..<paren]) }
    while base.hasSuffix("[]") { base = String(base.dropLast(2)) }
    if let dot = base.lastIndex(of: ".") { base = String(base[base.index(after: dot)...]) }
    base = base.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).trimmingCharacters(
      in: .whitespaces)
    let firstWord = base.split(separator: " ").first.map(String.init) ?? base
    return !skippedTypes.contains(base) && !skippedTypes.contains(firstWord)
  }

  /// `value` with `%`, `_` and `escapeCharacter` each preceded by `escapeCharacter`, by scalar:
  /// a `%` followed by a combining mark is one `Character` but still a wildcard
  static func escapedLikeText(_ value: String) -> String {
    let mark = String(escapeCharacter)
    return SQLDialect.escapingScalars(
      value, ["%": mark + "%", "_": mark + "_", escapeCharacter: mark + mark])
  }

  /// Case-insensitive `LIKE` on the column's text: `ILIKE` where the engine has it (PostgreSQL
  /// as `pg_catalog`'s `~~*` with `like_escape`, DuckDB), else `LOWER()` on both sides (SQLite,
  /// and MySQL/MariaDB, where a `_bin` collation makes `LIKE` case-sensitive; the
  /// `CAST(.. AS CHAR)` subject is a nonbinary string, so `LOWER()` applies).
  private static func containsPredicate(
    _ quotedColumn: String, _ placeholder: String, dialect: SQLDialect
  ) throws -> String {
    let escape = "'\(escapeCharacter)'"
    let subject = textCast(quotedColumn, dialect: dialect)
    switch dialect {
    case .postgresql:
      return dialect.like(
        column: quotedColumn, pattern: placeholder, escape: escape, caseInsensitive: true)
    case .duckdb: return "\(subject) ILIKE \(placeholder) ESCAPE \(escape)"
    case .sqlite, .mysql: return "LOWER(\(subject)) LIKE LOWER(\(placeholder)) ESCAPE \(escape)"
    default: throw SQLDialectError.notSQL
    }
  }

  private static func textCast(_ quotedColumn: String, dialect: SQLDialect) -> String {
    let type: String
    switch dialect {
    case .mysql: type = "CHAR"
    case .sqlite: type = "TEXT"
    case .duckdb: type = "VARCHAR"
    default: type = "text"
    }
    return dialect.cast(quotedColumn, to: type)
  }
}
