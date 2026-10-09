// SQLStatementClassifier+FunctionCalls.swift
// Whether a statement may call a function. A capped read with no app transaction is stopped by
// closing the session, which aborts the statement on the server and rolls back whatever a
// function it called wrote (`SELECT archive_row(id) FROM t`): such reads must drain instead.

import Foundation

nonisolated extension SQLStatementClassifier {
  /// SQL keywords that may be followed by `(` without calling a function (subqueries, lists,
  /// grouping, casts, window / aggregate clauses). Anything else before `(` may be a function.
  static let nonCallKeywords: Set<String> = [
    "IN", "EXISTS", "VALUES", "CAST", "ARRAY", "ROW", "OVER", "FILTER", "GROUP", "AS", "FROM",
    "JOIN", "ON", "USING", "WHERE", "AND", "OR", "NOT", "SELECT", "ANY", "ALL", "SOME",
    "BETWEEN", "UNION", "EXCEPT", "INTERSECT", "DISTINCT", "WHEN", "THEN", "ELSE", "HAVING",
    "BY", "LATERAL", "LIMIT", "OFFSET",
  ]

  /// True when a word or quoted identifier other than `nonCallKeywords` is directly followed by
  /// `(`, at any depth. Fail-safe: pure functions (`upper`, `count(*)`), set-returning functions
  /// in FROM (`generate_series(...)`), type modifiers (`numeric(10, 2)`) and column alias lists
  /// (`AS t(a, b)`) count too; they only make a capped read drain instead of reset.
  /// Blind spots: functions called without parentheses (`t.fn` functional notation), inside
  /// views, operators and triggers.
  /// `dialect` picks the tokenizer; the capped-read callers are PostgreSQL-only.
  static func mayCallFunctions(_ sql: String, dialect: SQLDialect = .postgresql) -> Bool {
    let tokens = SQLTokenizer(dialect: dialect).tokens(sql)
    return zip(tokens, tokens.dropFirst()).contains { token, next in
      guard next.isSymbol("(") else { return false }
      switch token.kind {
      case .quotedIdentifier: return true
      case .word: return !nonCallKeywords.contains(token.keyword ?? "")
      default: return false
      }
    }
  }
}
