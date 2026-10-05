// SQLParameterRewriter.swift
// Rewrites :name placeholders into dialect positional parameters.

import Foundation

/// Rewrites `:name` into PostgreSQL `$n` or SQLite `?n`.
/// One placeholder per distinct name, in first-occurrence order. The name keeps the
/// source spelling. A statement with no `:name` is returned unchanged.
nonisolated enum SQLParameterRewriter: Sendable {

  /// `statement` with each `:name` replaced, plus the distinct names in first-seen order.
  static func rewrite(
    statement: String, dialect: SQLDialect
  ) -> (text: String, names: [String]) {
    let (scalars, lexemes) = scan(statement, dialect: dialect)
    let hits = namedParameters(in: lexemes, scalars: scalars)
    guard !hits.isEmpty else { return (statement, []) }
    return apply(hits, to: scalars, dialect: dialect)
  }

  /// Distinct `:name` values in `script`, in first-occurrence order.
  static func parameterNames(in script: String, dialect: SQLDialect) -> [String] {
    let (scalars, lexemes) = scan(script, dialect: dialect)
    var names: [String] = []
    var seen: Set<String> = []
    for hit in namedParameters(in: lexemes, scalars: scalars) where seen.insert(hit.name).inserted {
      names.append(hit.name)
    }
    return names
  }

  /// PostgreSQL `$n`, or SQLite `?` / `?n`. Does not rewrite.
  static func containsPositionalPlaceholder(in statement: String, dialect: SQLDialect) -> Bool {
    let (scalars, lexemes) = scan(statement, dialect: dialect)
    if dialect == .postgresql {
      for index in lexemes.indices {
        guard isSymbol(lexemes[index], scalars, "$"), index + 1 < lexemes.count else { continue }
        if case .number = lexemes[index + 1].kind { return true }
      }
      return false
    }
    return lexemes.contains { isSymbol($0, scalars, "?") }
  }

  private struct NamedParameter {
    let name: String
    let range: Range<Int>
  }

  /// A `:` symbol lexeme, not half of `::`, immediately followed by a word (not a number),
  /// and not glued to a preceding word, number, `)` or `]`.
  private static func namedParameters(
    in lexemes: [SQLLexeme], scalars: [Unicode.Scalar]
  ) -> [NamedParameter] {
    var hits: [NamedParameter] = []
    for index in lexemes.indices {
      guard isSymbol(lexemes[index], scalars, ":") else { continue }
      let next = index + 1
      guard next < lexemes.count, isWord(lexemes[next]) else { continue }
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
      if let existing = indexByName[hit.name] {
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
    case .whitespace, .comment, .quoted, .dollarString:
      return false
    }
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
