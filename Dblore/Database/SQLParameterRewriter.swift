// SQLParameterRewriter.swift
// Rewrites :name placeholders into dialect positional parameters.

import Foundation

/// Rewrites `:name` into PostgreSQL and DuckDB `$n`, SQLite `?n`, MySQL `?`, or ClickHouse
/// `{pN:String}`. One placeholder per distinct name, in first-occurrence order; MySQL binds are
/// positional, so it gets one `?` per occurrence. The name keeps the source spelling. A ClickHouse
/// query parameter the user wrote (`{name:Type}`) is not a `:name`. A statement with no
/// `:name` is returned unchanged. MongoDB and Redis have no parameters: their text is never
/// scanned, so `{a :b}` is not `:b`, `$set` is not a placeholder and `GET :a` stays as typed.
nonisolated enum SQLParameterRewriter: Sendable {

  /// `statement` with each `:name` replaced, plus the distinct names in first-seen order
  /// (MySQL: one name per occurrence, in order, so each `?` has its bind).
  static func rewrite(
    statement: String, dialect: SQLDialect
  ) -> (text: String, names: [String]) {
    switch dialect.language {
    case .sql: break
    case .mongosh, .redis: return (statement, [])
    }
    let (scalars, lexemes) = scan(statement, dialect: dialect)
    let hits = namedParameters(in: lexemes, scalars: scalars, dialect: dialect)
    guard !hits.isEmpty else { return (statement, []) }
    return apply(hits, to: scalars, dialect: dialect)
  }

  /// Distinct `:name` values in `script`, in first-occurrence order.
  static func parameterNames(in script: String, dialect: SQLDialect) -> [String] {
    switch dialect.language {
    case .sql: break
    case .mongosh, .redis: return []
    }
    let (scalars, lexemes) = scan(script, dialect: dialect)
    var names: [String] = []
    var seen: Set<String> = []
    for hit in namedParameters(in: lexemes, scalars: scalars, dialect: dialect)
    where seen.insert(hit.name).inserted {
      names.append(hit.name)
    }
    return names
  }

  /// PostgreSQL `$n`, DuckDB `?` / `$n` / `$name`, SQLite `?` / `?n` / `@name` / `$name`, or
  /// MySQL `?`. Does not rewrite. SQLite numbers `@name` and `$name` after the `?n` from
  /// `:name`, and nothing binds them. DuckDB `@` is an operator, not a placeholder, and MySQL
  /// `@name` is a user variable. ClickHouse has only the query parameter `{name:Type}`, which
  /// counts (a `{p1:String}` the user wrote would take the bind of the first `:name`); `?` is
  /// its ternary operator. SQL Server `@var` / `@@var` are T-SQL variables and `$1.00` money, so
  /// only `?` and a written `@pN` (ASCII, any case, not after `@@`) count: the engine plugin
  /// declares bind N as the variable `@pN`.
  static func containsPositionalPlaceholder(in statement: String, dialect: SQLDialect) -> Bool {
    switch dialect.language {
    case .sql: break
    case .mongosh, .redis: return false
    }
    let (scalars, lexemes) = scan(statement, dialect: dialect)
    if dialect == .clickhouse {
      return lexemes.indices.contains { isQueryParameterColon(at: $0, in: lexemes, scalars) }
    }
    if dialect == .sqlserver {
      return lexemes.indices.contains { index in
        isSymbol(lexemes[index], scalars, "?") || isBindVariable(at: index, in: lexemes, scalars)
      }
    }
    if dialect == .postgresql {
      for index in lexemes.indices {
        guard isSymbol(lexemes[index], scalars, "$"), index + 1 < lexemes.count else { continue }
        if case .number = lexemes[index + 1].kind { return true }
      }
      return false
    }
    let namePrefixes: [String] =
      switch dialect {
      case .duckdb: ["$"]
      case .mysql: []
      // Unreachable: MongoDB and Redis returned above.
      case .mongodb, .redis: []
      default: ["@", "$"]
      }
    for index in lexemes.indices {
      if isSymbol(lexemes[index], scalars, "?") { return true }
      guard namePrefixes.contains(where: { isSymbol(lexemes[index], scalars, $0) }),
        index + 1 < lexemes.count
      else { continue }
      switch lexemes[index + 1].kind {
      case .word, .number: return true
      default: continue
      }
    }
    return false
  }

  private struct NamedParameter {
    let name: String
    let range: Range<Int>
  }

  /// A `:` symbol lexeme, not half of `::`, immediately followed by a word (not a number),
  /// and not glued to a preceding word, number, `)` or `]`. On ClickHouse, not the `:` of a
  /// query parameter (`{name :Type}`) or right after a `.` (`json.a.:Int64`).
  private static func namedParameters(
    in lexemes: [SQLLexeme], scalars: [Unicode.Scalar], dialect: SQLDialect
  ) -> [NamedParameter] {
    var hits: [NamedParameter] = []
    for index in lexemes.indices {
      guard isSymbol(lexemes[index], scalars, ":") else { continue }
      // `{name :Type}` is the user's own parameter; `json.path.:Type` a JSON subcolumn's type
      if dialect == .clickhouse,
        isQueryParameterColon(at: index, in: lexemes, scalars)
          || (index > 0 && isSymbol(lexemes[index - 1], scalars, "."))
      {
        continue
      }
      let next = index + 1
      guard next < lexemes.count, isWord(lexemes[next]) else { continue }
      // `arr[:n]` and `arr[lo :hi]` read as a parameter, as psql `:var` does. A missing
      // value refuses the run, so nothing reaches the server unnoticed.
      if index > 0 {
        let previous = lexemes[index - 1]
        if isSymbol(previous, scalars, ":") || blocksNamedParameter(previous, scalars) {
          continue
        }
      }
      let word = lexemes[next]
      hits.append(
        NamedParameter(
          name: SQLTokenizer.text(scalars, word.range),
          range: lexemes[index].range.lowerBound..<word.range.upperBound))
    }
    return hits
  }

  private static func apply(
    _ hits: [NamedParameter], to scalars: [Unicode.Scalar], dialect: SQLDialect
  ) -> (text: String, names: [String]) {
    var names: [String] = []
    var indexByName: [String: Int] = [:]
    var output = String.UnicodeScalarView()
    var cursor = 0
    for hit in hits {
      output.append(contentsOf: scalars[cursor..<hit.range.lowerBound])
      let index: Int
      if dialect == .mysql {
        names.append(hit.name)
        index = names.count
      } else if let existing = indexByName[hit.name] {
        index = existing
      } else {
        names.append(hit.name)
        index = names.count
        indexByName[hit.name] = index
      }
      output.append(contentsOf: dialect.placeholder(index).unicodeScalars)
      cursor = hit.range.upperBound
    }
    output.append(contentsOf: scalars[cursor..<scalars.count])
    return (String(output), names)
  }

  private static func scan(
    _ sql: String, dialect: SQLDialect
  ) -> (scalars: [Unicode.Scalar], lexemes: [SQLLexeme]) {
    let scalars = Array(sql.unicodeScalars)
    let tokenizer = SQLTokenizer(dialect: dialect)
    var lexemes: [SQLLexeme] = []
    var index = 0
    while index < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: index)
      lexemes.append(lexeme)
      index = lexeme.range.upperBound
    }
    return (scalars, lexemes)
  }

  private static func blocksNamedParameter(
    _ lexeme: SQLLexeme, _ scalars: [Unicode.Scalar]
  ) -> Bool {
    switch lexeme.kind {
    case .word, .number:
      return true
    case .symbol:
      let symbol = SQLTokenizer.text(scalars, lexeme.range)
      return symbol == ")" || symbol == "]"
    case .whitespace, .comment, .quoted, .dollarString, .executableComment:
      return false
    }
  }

  /// The `:` of a ClickHouse query parameter: `{`, a word, then this `:`, with only whitespace
  /// and comments between them
  private static func isQueryParameterColon(
    at index: Int, in lexemes: [SQLLexeme], _ scalars: [Unicode.Scalar]
  ) -> Bool {
    guard isSymbol(lexemes[index], scalars, ":") else { return false }
    var before: [SQLLexeme] = []
    var cursor = index - 1
    while cursor >= 0, before.count < 2 {
      switch lexemes[cursor].kind {
      case .whitespace, .comment: break
      default: before.append(lexemes[cursor])
      }
      cursor -= 1
    }
    return before.count == 2 && isWord(before[0]) && isSymbol(before[1], scalars, "{")
  }

  /// `@` (not after another `@`) directly followed by the word `p<digits>`, ASCII, any case
  private static func isBindVariable(
    at index: Int, in lexemes: [SQLLexeme], _ scalars: [Unicode.Scalar]
  ) -> Bool {
    guard isSymbol(lexemes[index], scalars, "@"), index + 1 < lexemes.count,
      isWord(lexemes[index + 1]), !(index > 0 && isSymbol(lexemes[index - 1], scalars, "@"))
    else { return false }
    let name = scalars[lexemes[index + 1].range]
    return name.count > 1 && (name.first == "p" || name.first == "P")
      && name.dropFirst().allSatisfy { ("0"..."9").contains($0) }
  }

  private static func isWord(_ lexeme: SQLLexeme) -> Bool {
    if case .word = lexeme.kind { return true }
    return false
  }

  private static func isSymbol(
    _ lexeme: SQLLexeme, _ scalars: [Unicode.Scalar], _ symbol: String
  ) -> Bool {
    guard case .symbol = lexeme.kind else { return false }
    return SQLTokenizer.text(scalars, lexeme.range) == symbol
  }
}
