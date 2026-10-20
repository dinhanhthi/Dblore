// SQLDialect.swift
// Quote, literal, and statement-fragment rules for PostgreSQL, SQLite, DuckDB, and MySQL,
// plus the MongoDB marker: no SQL identifiers, every other member PostgreSQL-shaped.

import Foundation

/// Identifier quoting failed.
nonisolated enum SQLDialectError: Error, Equatable, Sendable {
  /// `name` contains a NUL (`U+0000`) and cannot be placed in SQL text.
  case nulInIdentifier
  /// The dialect is `SQLDialect.mongodb`, which has no SQL identifiers.
  case notSQL
}

/// How one database spells identifiers, literals, and a few statement fragments.
/// `mongodb` is a marker, not a SQL dialect: the text entry points (classifier, splitter,
/// tokenizer, parameter rewriter) delegate to the mongosh code, `quoteIdentifier` and
/// `qualified` throw `notSQL`, and the other members return the PostgreSQL value; capability
/// guards keep those SQL paths unreachable for MongoDB.
nonisolated struct SQLDialect: Sendable, Equatable {
  private enum Engine: Sendable, Equatable {
    case postgresql
    case sqlite
    case duckdb
    case mysql
    case mongodb
  }

  private let engine: Engine

  static let postgresql = SQLDialect(engine: .postgresql)
  static let sqlite = SQLDialect(engine: .sqlite)
  static let duckdb = SQLDialect(engine: .duckdb)
  static let mysql = SQLDialect(engine: .mysql)
  static let mongodb = SQLDialect(engine: .mongodb)

  /// Name used in prompts ("PostgreSQL", "SQLite", "DuckDB", "MySQL").
  var promptName: String {
    switch engine {
    case .postgresql, .mongodb: "PostgreSQL"
    case .sqlite: "SQLite"
    case .duckdb: "DuckDB"
    case .mysql: "MySQL"
    }
  }

  /// Schema omitted by `qualified` when the caller passes it explicitly.
  /// MySQL has none: its schema is the connected database, so any named schema stays.
  var defaultSchema: String {
    switch engine {
    case .postgresql, .mongodb: "public"
    case .sqlite, .duckdb: "main"
    case .mysql: ""
    }
  }

  /// Whether `UPDATE ONLY` is meaningful (PostgreSQL inheritance).
  var supportsUpdateOnly: Bool {
    switch engine {
    case .postgresql, .mongodb: true
    case .sqlite, .duckdb, .mysql: false
    }
  }

  /// SQLite and MySQL (default `_ci` collations) `LIKE` fold case, and neither has `ILIKE`.
  /// PostgreSQL and DuckDB `LIKE` do not (`ILIKE` does).
  var likeIsCaseInsensitive: Bool {
    switch engine {
    case .sqlite, .mysql: true
    case .postgresql, .duckdb, .mongodb: false
    }
  }

  /// `"name"` with embedded `"` doubled; MySQL `` `name` `` with embedded `` ` `` doubled.
  /// Rejects a NUL anywhere in `name`, and every name on MongoDB (`notSQL`).
  func quoteIdentifier(_ name: String) throws -> String {
    let quote: String
    switch engine {
    case .postgresql, .sqlite, .duckdb: quote = "\""
    case .mysql: quote = "`"
    case .mongodb: throw SQLDialectError.notSQL
    }
    guard !name.contains("\0") else {
      throw SQLDialectError.nulInIdentifier
    }
    return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
  }

  /// `quoteIdentifier(name)`, or `schema.name` when `schema` is not the default.
  func qualified(schema: String?, name: String) throws -> String {
    let quotedName = try quoteIdentifier(name)
    guard let schema, schema != defaultSchema else {
      return quotedName
    }
    return try quoteIdentifier(schema) + "." + quotedName
  }

  /// SQL literal for a result cell. JSON is quoted text, not a PostgreSQL json cast.
  func literal(_ value: CellValue) -> String {
    switch value {
    case .null:
      "NULL"
    case .bool(let flag):
      flag ? "TRUE" : "FALSE"
    case .int(let number):
      String(number)
    case .double(let number):
      doubleLiteral(number)
    case .string(let text), .json(let text):
      quoteLiteral(text)
    case .date(let date):
      quoteLiteral(ISO8601DateFormatter().string(from: date))
    case .data(let data):
      dataLiteral(data)
    }
  }

  /// PostgreSQL and DuckDB `$n`, SQLite `?n`. `index` is written as given (1-based).
  /// MySQL is a bare `?`: binds are positional, so `index` is ignored.
  func placeholder(_ index: Int) -> String {
    switch engine {
    case .postgresql, .duckdb, .mongodb: "$\(index)"
    case .sqlite: "?\(index)"
    case .mysql: "?"
    }
  }

  func limitOffset(limit: Int, offset: Int) -> String {
    "LIMIT \(limit) OFFSET \(offset)"
  }

  /// PostgreSQL `EXPLAIN` with optional ANALYZE, BUFFERS, and FORMAT.
  /// SQLite is always `EXPLAIN QUERY PLAN`. DuckDB is `EXPLAIN (FORMAT <format>)` or
  /// `EXPLAIN (ANALYZE, FORMAT <format>)` (the plan view reads JSON), and `EXPLAIN` or
  /// `EXPLAIN ANALYZE` (text) without a format, with `buffers` ignored. MySQL is
  /// `EXPLAIN ANALYZE` (format ignored), `EXPLAIN FORMAT=<format>`, or `EXPLAIN`, with `buffers`
  /// ignored.
  func explainPrefix(analyze: Bool, buffers: Bool, format: String?) -> String {
    switch engine {
    case .sqlite:
      return "EXPLAIN QUERY PLAN"
    case .duckdb:
      guard let format else { return analyze ? "EXPLAIN ANALYZE" : "EXPLAIN" }
      let options = (analyze ? ["ANALYZE"] : []) + ["FORMAT \(format.uppercased())"]
      return "EXPLAIN (\(options.joined(separator: ", ")))"
    case .mysql:
      if analyze { return "EXPLAIN ANALYZE" }
      if let format { return "EXPLAIN FORMAT=\(format.uppercased())" }
      return "EXPLAIN"
    case .postgresql, .mongodb:
      var options: [String] = []
      if analyze { options.append("ANALYZE") }
      if buffers { options.append("BUFFERS") }
      if let format { options.append("FORMAT \(format.uppercased())") }
      if options.isEmpty {
        return "EXPLAIN"
      }
      return "EXPLAIN (\(options.joined(separator: ", ")))"
    }
  }

  /// `column` as text for `LIKE`: PostgreSQL `::text`, DuckDB `::VARCHAR`, MySQL `CAST(.. AS CHAR)`,
  /// SQLite unchanged.
  func likeSubject(_ column: String) -> String {
    switch engine {
    case .postgresql, .mongodb: "\(column)::text"
    case .sqlite: column
    case .duckdb: "\(column)::VARCHAR"
    case .mysql: "CAST(\(column) AS CHAR)"
    }
  }

  /// `column` and `pattern` are SQL fragments, inserted unchanged.
  func caseInsensitiveLike(column: String, pattern: String) -> String {
    switch engine {
    case .postgresql, .mongodb: "\(column)::text ILIKE \(pattern)"
    case .sqlite: "\(column) LIKE \(pattern)"
    case .duckdb: "\(column)::VARCHAR ILIKE \(pattern)"
    case .mysql: "CAST(\(column) AS CHAR) LIKE \(pattern)"
    }
  }

  /// `'text'`, with `'` doubled. PostgreSQL text that contains `\` is `E'...'`:
  /// every `\` becomes `\\` and every `'` becomes `''`, so those characters stay
  /// data with `standard_conforming_strings` on or off. SQLite and DuckDB never use `E`: their
  /// plain strings have no backslash escapes. MySQL plain strings do: every `\` becomes `\\`
  /// with no prefix.
  private func quoteLiteral(_ text: String) -> String {
    let doubledQuotes = text.replacingOccurrences(of: "'", with: "''")
    guard text.contains("\\") else {
      return "'\(doubledQuotes)'"
    }
    let escaped = doubledQuotes.replacingOccurrences(of: "\\", with: "\\\\")
    switch engine {
    case .postgresql, .mongodb: return "E'\(escaped)'"
    case .mysql: return "'\(escaped)'"
    case .sqlite, .duckdb: return "'\(doubledQuotes)'"
    }
  }

  private func doubleLiteral(_ number: Double) -> String {
    if number.isFinite { return String(number) }
    switch engine {
    case .sqlite, .mysql:
      return "NULL"
    case .postgresql, .mongodb:
      if number.isNaN { return "'NaN'::float8" }
      return number > 0 ? "'Infinity'::float8" : "'-Infinity'::float8"
    case .duckdb:
      if number.isNaN { return "'NaN'::DOUBLE" }
      return number > 0 ? "'Infinity'::DOUBLE" : "'-Infinity'::DOUBLE"
    }
  }

  private func dataLiteral(_ data: Data) -> String {
    switch engine {
    case .postgresql, .mongodb:
      let hex = data.map { String(format: "%02x", $0) }.joined()
      return "'\\x\(hex)'"
    case .sqlite, .mysql:
      let hex = data.map { String(format: "%02X", $0) }.joined()
      return "X'\(hex)'"
    case .duckdb:
      let escaped = data.map { String(format: "\\x%02X", $0) }.joined()
      return "'\(escaped)'::BLOB"
    }
  }
}
