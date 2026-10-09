// SQLTokenizer.swift
// Pure, isolation-free SQL scanning helpers following PostgreSQL lexical rules

import Foundation

/// Stateless SQL scanning helpers. Safe to call from any isolation domain.
/// `dialect` selects the lexical rules. The default, and every static entry point, is
/// PostgreSQL. Both entry points lex Unicode scalars with the shared scanner in
/// `SQLTokenizer+Scanning.swift`, so the splitter and the tokenizer agree on every token.
nonisolated struct SQLTokenizer: Sendable {

  /// Lexical rules for this scanner. PostgreSQL keeps dollar quotes, `E'…'` escapes,
  /// nested block comments, and `.backslashString`.
  let dialect: SQLDialect

  init(dialect: SQLDialect = .postgresql) {
    self.dialect = dialect
  }

  /// Split SQL string into individual statements at `;` tokens, using `dialect`.
  /// The PostgreSQL rules (also used by `splitStatements(_:)` with no receiver) are:
  /// - String literals (single and double quotes, `''` escapes)
  /// - Escape strings (`E'...'`) with backslash escapes
  /// - Dollar-quoted strings (`$$...$$`, `$tag$...$tag$`)
  /// - Comments (single-line -- and nested multi-line /* */)
  /// SQLite strings are `'…'` with doubled quotes only, identifiers may use `"…"`, `[…]`,
  /// or backticks, block comments do not nest, and `$` is not a quote.
  /// Returns the statements trimmed of PostgreSQL whitespace; each is an exact substring of
  /// the input (same Unicode scalars), so execution sends exactly what the user typed.
  func splitStatements(_ sql: String) -> [String] {
    let scalars = Array(sql.unicodeScalars)
    var statements: [String] = []
    var start = 0
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      if case .symbol = lexeme.kind, scalars[i] == ";" {
        Self.appendTrimmed(scalars, start..<i, to: &statements)
        start = lexeme.range.upperBound
      }
      i = lexeme.range.upperBound
    }
    Self.appendTrimmed(scalars, start..<scalars.count, to: &statements)
    return statements
  }

  /// PostgreSQL `splitStatements`. Callers that have no dialect keep this path.
  static func splitStatements(_ sql: String) -> [String] {
    SQLTokenizer().splitStatements(sql)
  }

  /// Lex a single SQL statement into tokens, dropping whitespace and comments.
  /// Words and numbers are uppercased (ASCII letters only, see `asciiUppercased`); string literals (including `E'...'` and dollar quotes on PostgreSQL)
  /// and quoted identifiers are opaque tokens, so their contents never match keywords.
  /// `depth` is the parenthesis nesting level: `(`/`)` carry the outer depth, tokens
  /// between them carry outer + 1.
  /// On PostgreSQL, block comments nest and line comments end at CR or LF.
  func tokens(_ sql: String) -> [SQLToken] {
    let scalars = Array(sql.unicodeScalars)
    var result: [SQLToken] = []
    var depth = 0
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      let raw = Self.text(scalars, lexeme.range)
      switch lexeme.kind {
      case .whitespace, .comment:
        break
      case .word, .number:
        result.append(SQLToken(kind: .word, text: Self.asciiUppercased(raw), depth: depth))
      case .quoted(let kind, let content):
        result.append(SQLToken(kind: kind, text: content, depth: depth))
      case .dollarString:
        result.append(SQLToken(kind: .string, text: raw, depth: depth))
      case .symbol:
        if scalars[i] == ")" { depth = max(0, depth - 1) }
        result.append(SQLToken(kind: .symbol, text: raw, depth: depth))
        if scalars[i] == "(" { depth += 1 }
      }
      i = lexeme.range.upperBound
    }
    return result
  }

  /// PostgreSQL `tokens`. Callers that have no dialect keep this path.
  static func tokens(_ sql: String) -> [SQLToken] {
    SQLTokenizer().tokens(sql)
  }

  /// `text` with only ASCII `a`-`z` mapped to `A`-`Z`, as PostgreSQL folds identifiers
  /// (`downcase_identifier`, `pg_strcasecmp`). Every other scalar is kept, so look-alikes such
  /// as U+212A KELVIN SIGN, U+017F LONG S or U+0131 DOTLESS I never become ASCII letters.
  static func asciiUppercased(_ text: String) -> String {
    mapASCII(text, from: "a"..."z", offset: -32)
  }

  /// `text` with only ASCII `A`-`Z` mapped to `a`-`z` (see `asciiUppercased`).
  static func asciiLowercased(_ text: String) -> String {
    mapASCII(text, from: "A"..."Z", offset: 32)
  }

  private static func mapASCII(
    _ text: String, from letters: ClosedRange<Unicode.Scalar>, offset: Int32
  ) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let mapped =
        letters.contains(scalar) ? Unicode.Scalar(UInt32(Int32(scalar.value) + offset)) : nil
      result.append(mapped ?? scalar)
    }
    return String(result)
  }

  /// Append `scalars[range]` without leading/trailing PostgreSQL whitespace, if non-empty.
  private static func appendTrimmed(
    _ scalars: [Unicode.Scalar], _ range: Range<Int>, to statements: inout [String]
  ) {
    var lower = range.lowerBound
    var upper = range.upperBound
    while lower < upper, isWhitespace(scalars[lower]) { lower += 1 }
    while upper > lower, isWhitespace(scalars[upper - 1]) { upper -= 1 }
    if lower < upper {
      statements.append(text(scalars, lower..<upper))
    }
  }
}

/// A lexical token produced by `SQLTokenizer.tokens(_:)`.
nonisolated struct SQLToken: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    /// Keyword, unquoted identifier or number (ASCII letters uppercased)
    case word
    /// `"..."` identifier (content, original case)
    case quotedIdentifier
    /// `'...'`, `E'...'` (content) or dollar-quoted string (raw, including tags)
    case string
    /// Plain `'...'` string containing a backslash (content). With
    /// `standard_conforming_strings = off` the server treats the backslash as an escape,
    /// so where the string ends is ambiguous and the classifier must fail closed.
    /// PostgreSQL only: SQLite and DuckDB plain strings have no backslash escapes.
    case backslashString
    /// Any other single (ASCII) scalar, including `(`, `)`, `,`, `=`
    case symbol
  }

  let kind: Kind
  let text: String
  let depth: Int

  /// `text` if every scalar is ASCII, else nil. Keyword comparisons go through this, because
  /// Swift `String ==` uses canonical equivalence (U+212A KELVIN SIGN == "K").
  var asciiText: String? { text.unicodeScalars.allSatisfy(\.isASCII) ? text : nil }

  /// Text of an all-ASCII word (a possible keyword), else nil.
  var keyword: String? { kind == .word ? asciiText : nil }

  func isWord(_ word: String) -> Bool { keyword == word }
  func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
}
