// SQLDialect.swift
// Quote, literal, and statement-fragment rules for PostgreSQL, SQLite, and DuckDB.

import Foundation

/// Identifier quoting failed.
nonisolated enum SQLDialectError: Error, Equatable, Sendable {
  /// `name` contains a NUL (`U+0000`) and cannot be placed in SQL text.
  case nulInIdentifier
}

/// How one database spells identifiers, literals, and a few statement fragments.
nonisolated struct SQLDialect: Sendable, Equatable {
  private enum Engine: Sendable, Equatable {
    case postgresql
    case sqlite
    case duckdb
  }

  private let engine: Engine

  static let postgresql = SQLDialect(engine: .postgresql)
  static let sqlite = SQLDialect(engine: .sqlite)
  static let duckdb = SQLDialect(engine: .duckdb)

  /// Name used in prompts ("PostgreSQL", "SQLite", "DuckDB").
  var promptName: String {
    switch engine {
    case .postgresql: "PostgreSQL"
    case .sqlite: "SQLite"
    case .duckdb: "DuckDB"
    }
  }

  /// Schema omitted by `qualified` when the caller passes it explicitly.
  var defaultSchema: String {
    switch engine {
    case .postgresql: "public"
    case .sqlite, .duckdb: "main"
    }
  }

  /// Whether `UPDATE ONLY` is meaningful (PostgreSQL inheritance).
  var supportsUpdateOnly: Bool {
    engine == .postgresql
  }

  /// SQLite `LIKE` folds case. PostgreSQL and DuckDB `LIKE` do not (`ILIKE` does).
  var likeIsCaseInsensitive: Bool {
    engine == .sqlite
  }

  /// `"name"`, with embedded `"` doubled. Rejects a NUL anywhere in `name`.
  func quoteIdentifier(_ name: String) throws -> String {
    guard !name.contains("\0") else {
      throw SQLDialectError.nulInIdentifier
    }
    return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
  func placeholder(_ index: Int) -> String {
    switch engine {
    case .postgresql, .duckdb: "$\(index)"
    case .sqlite: "?\(index)"
    }
  }

  func limitOffset(limit: Int, offset: Int) -> String {
    "LIMIT \(limit) OFFSET \(offset)"
  }

  /// PostgreSQL `EXPLAIN` with optional ANALYZE, BUFFERS, and FORMAT.
  /// SQLite is always `EXPLAIN QUERY PLAN`. DuckDB is text only: `EXPLAIN` or `EXPLAIN ANALYZE`,
  /// with `buffers` and `format` ignored.
  func explainPrefix(analyze: Bool, buffers: Bool, format: String?) -> String {
    switch engine {
    case .sqlite:
      return "EXPLAIN QUERY PLAN"
    case .duckdb:
      return analyze ? "EXPLAIN ANALYZE" : "EXPLAIN"
    case .postgresql:
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

  /// `column` as text for `LIKE`: PostgreSQL `::text`, DuckDB `::VARCHAR`, SQLite unchanged.
  func likeSubject(_ column: String) -> String {
    switch engine {
    case .postgresql: "\(column)::text"
    case .sqlite: column
    case .duckdb: "\(column)::VARCHAR"
    }
  }

  /// `column` and `pattern` are SQL fragments, inserted unchanged.
  func caseInsensitiveLike(column: String, pattern: String) -> String {
    switch engine {
    case .postgresql: "\(column)::text ILIKE \(pattern)"
    case .sqlite: "\(column) LIKE \(pattern)"
    case .duckdb: "\(column)::VARCHAR ILIKE \(pattern)"
    }
  }

  /// `'text'`, with `'` doubled. PostgreSQL text that contains `\` is `E'...'`:
  /// every `\` becomes `\\` and every `'` becomes `''`, so those characters stay
  /// data with `standard_conforming_strings` on or off. SQLite and DuckDB never use `E`: their
  /// plain strings have no backslash escapes.
  private func quoteLiteral(_ text: String) -> String {
    let doubledQuotes = text.replacingOccurrences(of: "'", with: "''")
    guard engine == .postgresql, text.contains("\\") else {
      return "'\(doubledQuotes)'"
    }
    let escaped = doubledQuotes.replacingOccurrences(of: "\\", with: "\\\\")
    return "E'\(escaped)'"
  }

  private func doubleLiteral(_ number: Double) -> String {
    if number.isFinite { return String(number) }
    switch engine {
    case .sqlite:
      return "NULL"
    case .postgresql:
      if number.isNaN { return "'NaN'::float8" }
      return number > 0 ? "'Infinity'::float8" : "'-Infinity'::float8"
    case .duckdb:
      if number.isNaN { return "'NaN'::DOUBLE" }
      return number > 0 ? "'Infinity'::DOUBLE" : "'-Infinity'::DOUBLE"
    }
  }

  private func dataLiteral(_ data: Data) -> String {
    switch engine {
    case .postgresql:
      let hex = data.map { String(format: "%02x", $0) }.joined()
      return "'\\x\(hex)'"
    case .sqlite:
      let hex = data.map { String(format: "%02X", $0) }.joined()
      return "X'\(hex)'"
    case .duckdb:
      let escaped = data.map { String(format: "\\x%02X", $0) }.joined()
      return "'\(escaped)'::BLOB"
    }
  }
}
