// SQLTokenizer+Scanning.swift
// Unicode-scalar lexeme scanner shared by statement splitting and tokenizing

import Foundation

/// One lexeme of SQL text: a kind and a range of offsets into the scalar array.
nonisolated struct SQLLexeme {
  enum Kind {
    case whitespace
    case comment
    /// Keyword or identifier: starts with an ASCII letter, `_` or non-ASCII scalar, and
    /// continues with those, ASCII digits and `$` (on SQL Server, no other currency sign)
    case word
    /// Run of ASCII digits. A following `$` starts a new token, as in PostgreSQL. SQL Server
    /// reads a whole T-SQL number (`0x1F`, `1.5`, `.5`, `1E-5`).
    case number
    /// `'...'`, `E'...'` or `"..."` with its content (doubled quotes collapsed)
    case quoted(SQLToken.Kind, content: String)
    /// `$tag$...$tag$` (raw, including tags)
    case dollarString
    /// MySQL `/*! ... */` or `/*M! ... */` (raw): the server runs its content
    case executableComment
    /// Any other single scalar
    case symbol
  }

  let kind: Kind
  let range: Range<Int>
}

/// PostgreSQL lexes UTF-8 bytes: every comparison below is against exact ASCII scalars
/// (no grapheme clustering, no canonical equivalence), and any non-ASCII scalar is an
/// identifier character. `lexeme(in:at:)` on a value follows `dialect`; the static
/// `lexeme(in:at:dialect:)` defaults to the PostgreSQL scanner.
/// DuckDB uses the PostgreSQL scanner, except that a plain `'...'` string has no backslash
/// escapes (only `''`), so it is `.string`, never `.backslashString`.
/// MySQL has its own scanner (`mysqlLexeme`), so its rules never reach PostgreSQL.
/// SQL Server (`sqlserverLexeme`) adds `[…]` identifiers and T-SQL numbers and drops dollar
/// quotes, `E'…'` and backslash escapes, so a keyword the server runs is never hidden in a
/// PostgreSQL-only quote. ClickHouse (`clickhouseLexeme`) follows the server's lexer: backslash
/// escapes in every quote, Unicode quotes, `#` and `//` comments, heredocs, and `--` comments
/// that end at LF only.
nonisolated extension SQLTokenizer {

  /// The lexeme starting at scalar offset `i` (which must be a token boundary).
  func lexeme(in s: [Unicode.Scalar], at i: Int) -> SQLLexeme {
    if dialect == .sqlite {
      return sqliteLexeme(in: s, at: i)
    }
    if dialect == .duckdb {
      return SQLTokenizer.lexeme(in: s, at: i, markBackslash: false)
    }
    if dialect == .mysql {
      return mysqlLexeme(in: s, at: i)
    }
    if dialect == .sqlserver {
      return sqlserverLexeme(in: s, at: i)
    }
    if dialect == .clickhouse {
      return clickhouseLexeme(in: s, at: i)
    }
    return SQLTokenizer.lexeme(in: s, at: i, markBackslash: !standardConformingStrings)
  }

  /// MySQL optimizer hints: the raw text of every `/*+ ... */` comment in `sql`, outside
  /// strings and other comments. The server applies them; the tokenizer drops them like any
  /// comment, so the classifier reads them here.
  func optimizerHints(_ sql: String) -> [String] {
    let scalars = Array(sql.unicodeScalars)
    var hints: [String] = []
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      if case .comment = lexeme.kind, lexeme.range.count > 2, scalars[i] == "/",
        scalars[i + 2] == "+"
      {
        hints.append(Self.text(scalars, lexeme.range))
      }
      i = lexeme.range.upperBound
    }
    return hints
  }

  /// The lexeme starting at scalar offset `i` (which must be a token boundary), using
  /// `dialect` (PostgreSQL by default).
  static func lexeme(
    in s: [Unicode.Scalar], at i: Int, dialect: SQLDialect = .postgresql
  ) -> SQLLexeme {
    SQLTokenizer(dialect: dialect).lexeme(in: s, at: i)
  }

  /// PostgreSQL rules. `markBackslash` turns a plain string that contains `\` into
  /// `.backslashString` (PostgreSQL); DuckDB passes false.
  private static func lexeme(
    in s: [Unicode.Scalar], at i: Int, markBackslash: Bool
  ) -> SQLLexeme {
    let char = s[i]
    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil

    if isWhitespace(char) {
      return SQLLexeme(kind: .whitespace, range: i..<scan(s, from: i + 1, while: isWhitespace))
    }
    if char == "-" && next == "-" {
      let end = scan(s, from: i, while: { !isLineBreak($0) })
      return SQLLexeme(kind: .comment, range: i..<end)
    }
    if let end = blockCommentEnd(in: s, at: i) {
      return SQLLexeme(kind: .comment, range: i..<end)
    }
    if let tagEnd = dollarQuoteTagEnd(in: s, at: i) {
      let end = closingTagEnd(of: s[i..<tagEnd], in: s, from: tagEnd) ?? s.count
      return SQLLexeme(kind: .dollarString, range: i..<end)
    }
    if char == "'" {
      return quoted(
        s, start: i, quoteAt: i, escape: false, kind: .string, markBackslash: markBackslash)
    }
    if char == "\"" {
      return quoted(s, start: i, quoteAt: i, escape: false, kind: .quotedIdentifier)
    }
    if isIdentifierStart(char) {
      let end = scan(s, from: i + 1, while: isIdentifierCharacter)
      if end == i + 1 && (char == "E" || char == "e") && end < s.count && s[end] == "'" {
        return quoted(s, start: i, quoteAt: end, escape: true, kind: .string)
      }
      return SQLLexeme(kind: .word, range: i..<end)
    }
    if isDigit(char) {
      return SQLLexeme(kind: .number, range: i..<scan(s, from: i + 1, while: isDigit))
    }
    return SQLLexeme(kind: .symbol, range: i..<(i + 1))
  }

  /// String built from exactly the scalars in `range` (an exact substring of the input).
  static func text(_ s: [Unicode.Scalar], _ range: Range<Int>) -> String {
    var result = ""
    result.unicodeScalars.append(contentsOf: s[range])
    return result
  }

  /// PostgreSQL `space`: only space, `\t`, `\n`, `\r`, `\f` and `\v`.
  static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case " ", "\t", "\n", "\r", "\u{0C}", "\u{0B}": true
    default: false
    }
  }

  // MARK: - Private helpers

  private static func scan(
    _ s: [Unicode.Scalar], from start: Int, while predicate: (Unicode.Scalar) -> Bool
  ) -> Int {
    var j = start
    while j < s.count, predicate(s[j]) {
      j += 1
    }
    return j
  }

  /// Quoted lexeme from `start` (the `E` of an escape string, else the quote) whose opening
  /// quote is at `quoteAt`. A doubled quote is an escaped quote; `escape` enables backslash
  /// escapes (E'...'). Unterminated quotes run to the end of the input.
  private static func quoted(
    _ s: [Unicode.Scalar], start: Int, quoteAt: Int, escape: Bool, kind: SQLToken.Kind,
    markBackslash: Bool = true
  ) -> SQLLexeme {
    let quote = s[quoteAt]
    var content = String.UnicodeScalarView()
    var j = quoteAt + 1
    while j < s.count {
      let char = s[j]
      if escape && char == "\\" && j + 1 < s.count {
        content.append(char)
        content.append(s[j + 1])
        j += 2
        continue
      }
      if char == quote {
        guard j + 1 < s.count, s[j + 1] == quote else {
          j += 1
          break
        }
        content.append(char)
        j += 2
        continue
      }
      content.append(char)
      j += 1
    }
    let isBackslashString =
      markBackslash && !escape && kind == .string && content.contains("\\")
    return SQLLexeme(
      kind: .quoted(isBackslashString ? .backslashString : kind, content: String(content)),
      range: start..<j)
  }

  /// If a block comment starts at `i`, returns the offset after its end (or `s.count` when
  /// unterminated). Block comments nest: each `/*` needs its own `*/`.
  private static func blockCommentEnd(in s: [Unicode.Scalar], at i: Int) -> Int? {
    guard i + 1 < s.count, s[i] == "/", s[i + 1] == "*" else { return nil }
    var depth = 0
    var j = i
    while j < s.count {
      if j + 1 < s.count && s[j] == "/" && s[j + 1] == "*" {
        depth += 1
        j += 2
      } else if j + 1 < s.count && s[j] == "*" && s[j + 1] == "/" {
        depth -= 1
        j += 2
        if depth == 0 { return j }
      } else {
        j += 1
      }
    }
    return s.count
  }

  /// If a dollar-quote opening tag (`$$` or `$tag$`) starts at `i`, returns the offset after
  /// it. PostgreSQL rule (`dolq_start`/`dolq_cont`): `$` + optional tag (ASCII letter, `_` or
  /// non-ASCII to start; digits may follow) + `$`. Called only at token boundaries, so `a$b`
  /// (one identifier) never reaches it, while `$$a$$$$b$$` opens a second quote. `$1` is not
  /// a tag (a digit cannot start one).
  private static func dollarQuoteTagEnd(in s: [Unicode.Scalar], at i: Int) -> Int? {
    guard s[i] == "$", i + 1 < s.count else { return nil }
    var j = i + 1
    if s[j] != "$" {
      guard isTagCharacter(s[j], first: true) else { return nil }
      j = scan(s, from: j + 1, while: { isTagCharacter($0, first: false) })
      guard j < s.count, s[j] == "$" else { return nil }
    }
    return j + 1
  }

  /// Offset after the first occurrence of `tag` in `s` at or after `start`, or nil.
  private static func closingTagEnd(
    of tag: ArraySlice<Unicode.Scalar>, in s: [Unicode.Scalar], from start: Int
  ) -> Int? {
    guard s.count - start >= tag.count else { return nil }
    for j in start...(s.count - tag.count) where s[j..<(j + tag.count)].elementsEqual(tag) {
      return j + tag.count
    }
    return nil
  }

  /// PostgreSQL ends `--` comments only at CR or LF.
  private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "\n" || scalar == "\r"
  }

  private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }

  /// PostgreSQL `ident_start`: ASCII letters, `_` and any non-ASCII byte.
  private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
    !scalar.isASCII || isASCIILetter(scalar) || scalar == "_"
  }

  /// PostgreSQL `ident_cont`: `ident_start`, ASCII digits and `$`.
  private static func isIdentifierCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isIdentifierStart(scalar) || isDigit(scalar) || scalar == "$"
  }

  /// PostgreSQL `dolq_start` (`first`) / `dolq_cont`: `ident_start`, plus ASCII digits
  /// except in first position.
  private static func isTagCharacter(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
    isIdentifierStart(scalar) || (!first && isDigit(scalar))
  }

  /// SQLite lexeme. Strings are `'…'` with doubled quotes only. Identifiers use `"…"`,
  /// `[…]` (closed by the first `]`), and backticks (doubled backtick is one backtick).
  /// Block comments end at the first `*/`. `$` is a symbol or an identifier character, never a quote.
  private func sqliteLexeme(in s: [Unicode.Scalar], at i: Int) -> SQLLexeme {
    let char = s[i]
    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil

    if Self.isWhitespace(char) {
      return SQLLexeme(
        kind: .whitespace, range: i..<Self.scan(s, from: i + 1, while: Self.isWhitespace))
    }
    // SQLite ends a line comment at LF only (a CR inside it is still comment)
    if char == "-" && next == "-" {
      let end = Self.scan(s, from: i, while: { $0 != "\n" })
      return SQLLexeme(kind: .comment, range: i..<end)
    }
    if let end = Self.sqliteBlockCommentEnd(in: s, at: i) {
      return SQLLexeme(kind: .comment, range: i..<end)
    }
    if char == "'" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: false, kind: .string, markBackslash: false)
    }
    if char == "\"" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: false, kind: .quotedIdentifier, markBackslash: false)
    }
    if char == "[" {
      return Self.bracketIdentifier(s, start: i)
    }
    if char == "`" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: false, kind: .quotedIdentifier, markBackslash: false)
    }
    if Self.isIdentifierStart(char) {
      let end = Self.scan(s, from: i + 1, while: Self.isIdentifierCharacter)
      return SQLLexeme(kind: .word, range: i..<end)
    }
    if Self.isDigit(char) {
      return SQLLexeme(kind: .number, range: i..<Self.scan(s, from: i + 1, while: Self.isDigit))
    }
    return SQLLexeme(kind: .symbol, range: i..<(i + 1))
  }

  /// `[…]` identifier. The first `]` closes it; `]]` is not an escape.
  private static func bracketIdentifier(_ s: [Unicode.Scalar], start: Int) -> SQLLexeme {
    var content = String.UnicodeScalarView()
    var j = start + 1
    while j < s.count {
      if s[j] == "]" {
        j += 1
        break
      }
      content.append(s[j])
      j += 1
    }
    return SQLLexeme(
      kind: .quoted(.quotedIdentifier, content: String(content)), range: start..<j)
  }

  /// If a block comment starts at `i`, returns the offset after the first `*/`
  /// (or `s.count` when unterminated). SQLite comments do not nest.
  private static func sqliteBlockCommentEnd(in s: [Unicode.Scalar], at i: Int) -> Int? {
    guard i + 1 < s.count, s[i] == "/", s[i + 1] == "*" else { return nil }
    var j = i + 2
    while j + 1 < s.count {
      if s[j] == "*" && s[j + 1] == "/" {
        return j + 2
      }
      j += 1
    }
    return s.count
  }

  /// SQL Server lexeme. Strings are `'…'` (`N'…'` is the word `N` and a string) with doubled
  /// quotes only: no `E'…'` or backslash escapes. A currency sign (`$`, `£`, `€`, ...: the server
  /// reads one as a money prefix, `£1.50`) is a symbol, never a quote, and ends a word, except
  /// that `$` may continue one as in a T-SQL identifier (`a$b`). Identifiers use `"…"` and `[…]`
  /// (`]]` is one `]`). Numbers are T-SQL numbers (`sqlserverNumberEnd`). Whitespace, `--`
  /// comments (ended by CR or LF), nested `/* */` comments and symbols follow the PostgreSQL
  /// scanner.
  private func sqlserverLexeme(in s: [Unicode.Scalar], at i: Int) -> SQLLexeme {
    let char = s[i]
    if char == "[" {
      return Self.sqlserverBracketIdentifier(s, start: i)
    }
    if char == "'" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: false, kind: .string, markBackslash: false)
    }
    if Self.isCurrencySymbol(char) {
      return SQLLexeme(kind: .symbol, range: i..<(i + 1))
    }
    if Self.isIdentifierStart(char) {
      let end = Self.scan(s, from: i + 1) {
        Self.isIdentifierCharacter($0) && ($0 == "$" || !Self.isCurrencySymbol($0))
      }
      return SQLLexeme(kind: .word, range: i..<end)
    }
    if let end = Self.sqlserverNumberEnd(in: s, at: i) {
      return SQLLexeme(kind: .number, range: i..<end)
    }
    return Self.lexeme(in: s, at: i, markBackslash: false)
  }

  /// If a T-SQL number starts at `i`, returns the offset after it: `0x` and its hex digits (a
  /// binary constant; `0x` alone is one), else `digits[.digits]`, `digits.` or `.digits`, with
  /// an exponent only as `E`, an optional sign and at least one digit. Letters right after it
  /// start the next lexeme, as on the server (`SELECT 1abc` is `1 AS abc`).
  private static func sqlserverNumberEnd(in s: [Unicode.Scalar], at i: Int) -> Int? {
    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
    if s[i] == "0", next == "x" || next == "X" {
      return scan(s, from: i + 2, while: isHexDigit)
    }
    guard isDigit(s[i]) || (s[i] == "." && next.map(isDigit) == true) else { return nil }
    var j = scan(s, from: i, while: isDigit)
    if j < s.count, s[j] == "." {
      j = scan(s, from: j + 1, while: isDigit)
    }
    if j < s.count, s[j] == "E" || s[j] == "e" {
      var k = j + 1
      if k < s.count, s[k] == "+" || s[k] == "-" { k += 1 }
      if k < s.count, isDigit(s[k]) { j = scan(s, from: k, while: isDigit) }
    }
    return j
  }

  private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
    isDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
  }

  /// Unicode general category Sc (`$`, `¢`, `£`, `€`, `¥`, `₩`, `₹`, ...)
  private static func isCurrencySymbol(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .currencySymbol
  }

  /// Whether a number lexeme in `sql` runs straight into a word (`0xTRUNCATE`, `1eKILL`). A
  /// scanner that splits the two differently from the server (an empty exponent, a binary
  /// constant) could hide a verb in that word, so the SQL Server classifier fails closed on it.
  func numberRunsIntoWord(_ sql: String) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    var afterNumber = false
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      if afterNumber, case .word = lexeme.kind { return true }
      if case .number = lexeme.kind { afterNumber = true } else { afterNumber = false }
      i = lexeme.range.upperBound
    }
    return false
  }

  /// SQL Server text the classifier cannot read as the server does, so it fails closed:
  /// `numberRunsIntoWord`, `hasUnicodeSpace`, `endsCommentAtLoneCR` or
  /// `hasBatchSeparatorLine`.
  func sqlserverFailsClosed(_ sql: String) -> Bool {
    numberRunsIntoWord(sql) || hasUnicodeSpace(sql) || endsCommentAtLoneCR(sql)
      || hasBatchSeparatorLine(sql)
  }

  /// Whether a `--` comment in `sql` ends at a CR that no LF follows. The scanner ends it there;
  /// a server that ends it at LF only reads the rest of the line as comment, so the two could
  /// disagree on where a string or quoted name starts.
  func endsCommentAtLoneCR(_ sql: String) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      let end = lexeme.range.upperBound
      if case .comment = lexeme.kind, scalars[i] == "-", end < scalars.count, scalars[end] == "\r",
        end + 1 < scalars.count, scalars[end + 1] != "\n"
      {
        return true
      }
      i = end
    }
    return false
  }

  /// Whether `sql` holds a `GO` batch-separator line: `GO`, maybe with a count, alone on its
  /// line apart from whitespace and comments (outside strings, quoted names and comments).
  /// The app does not split batches there, so a statement holding one fails closed.
  func hasBatchSeparatorLine(_ sql: String) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    var lexemes: [SQLLexeme] = []
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      lexemes.append(lexeme)
      i = lexeme.range.upperBound
    }
    func breaksLine(_ lexeme: SQLLexeme) -> Bool {
      guard case .whitespace = lexeme.kind else { return false }
      return scalars[lexeme.range].contains { $0 == "\n" || $0 == "\r" }
    }
    var lineStart = true
    for (index, lexeme) in lexemes.enumerated() {
      switch lexeme.kind {
      case .whitespace:
        if breaksLine(lexeme) { lineStart = true }
      case .comment:
        break
      case .word
      where lineStart
        && Self.asciiUppercased(Self.text(scalars, lexeme.range)) == "GO":
        let rest = lexemes[(index + 1)...].prefix { !breaksLine($0) }
        let alone = rest.allSatisfy {
          switch $0.kind {
          case .whitespace, .comment, .number: true
          default: false
          }
        }
        if alone { return true }
        lineStart = false
      default:
        lineStart = false
      }
    }
    return false
  }

  /// Whether `sql` holds a non-ASCII space, control or format scalar (general category Zs, Zl,
  /// Zp, Cc or Cf: NBSP, U+0085, U+200B, U+2061, U+FEFF, ...) outside strings, quoted
  /// identifiers and comments, or a Unicode line break (U+0085, U+2028, U+2029) inside a
  /// comment. The scanner reads one as part of a word or comment, and the server may read it as
  /// a space or a line end, so the SQL Server classifier fails closed on it.
  func hasUnicodeSpace(_ sql: String) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      switch lexeme.kind {
      case .quoted: break
      // The server may end a `--` comment at a Unicode line break: fail closed
      case .comment:
        if scalars[lexeme.range].contains(where: { [0x0085, 0x2028, 0x2029].contains($0.value) }) {
          return true
        }
      default: if scalars[lexeme.range].contains(where: Self.isUnicodeSpace) { return true }
      }
      i = lexeme.range.upperBound
    }
    return false
  }

  private static func isUnicodeSpace(_ scalar: Unicode.Scalar) -> Bool {
    guard !scalar.isASCII else { return false }
    switch scalar.properties.generalCategory {
    case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format: return true
    default: return false
    }
  }

  /// SQL Server `[…]` identifier: `]]` is one `]`. Unterminated runs to the end of the input.
  private static func sqlserverBracketIdentifier(
    _ s: [Unicode.Scalar], start: Int
  ) -> SQLLexeme {
    var content = String.UnicodeScalarView()
    var j = start + 1
    while j < s.count {
      if s[j] == "]" {
        guard j + 1 < s.count, s[j + 1] == "]" else {
          j += 1
          break
        }
        content.append("]")
        j += 2
        continue
      }
      content.append(s[j])
      j += 1
    }
    return SQLLexeme(
      kind: .quoted(.quotedIdentifier, content: String(content)), range: start..<j)
  }

  /// ClickHouse lexeme, after the server's lexer (`src/Parsers/Lexer.cpp`). `'…'` strings and
  /// `"…"` / `` `…` `` identifiers take backslash escapes and doubled quotes; `‘…’` strings and
  /// `“…”` identifiers end at the closing quote. `--` and `//` comments end at LF only; `#`
  /// followed by a space or `!` is a comment to LF too (any other `#` is a symbol, which the server
  /// refuses). `$tag$` (a tag of ASCII letters, digits and `_`, maybe empty) opens a heredoc when
  /// the same tag appears again later: it runs to the end of that copy. Otherwise a `$` before
  /// an ASCII letter, digit or `_` starts a word, and any other `$` is a symbol. Numbers follow
  /// `clickhouseNumberEnd`. No `E'…'`: `E` is a word. Whitespace, nested `/* */` comments and
  /// symbols follow the PostgreSQL scanner.
  private func clickhouseLexeme(in s: [Unicode.Scalar], at i: Int) -> SQLLexeme {
    let char = s[i]
    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
    if (char == "-" && next == "-") || (char == "/" && next == "/")
      || (char == "#" && (next == " " || next == "!"))
    {
      return SQLLexeme(kind: .comment, range: i..<Self.scan(s, from: i, while: { $0 != "\n" }))
    }
    if char == "'" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: true, kind: .string, markBackslash: false)
    }
    if char == "\"" || char == "`" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: true, kind: .quotedIdentifier, markBackslash: false)
    }
    if char == "\u{2018}" || char == "\u{201C}" {
      let close: Unicode.Scalar = char == "\u{2018}" ? "\u{2019}" : "\u{201D}"
      let closeAt = s[(i + 1)...].firstIndex(of: close)
      let content = Self.text(s, (i + 1)..<(closeAt ?? s.count))
      let end = closeAt.map { $0 + 1 } ?? s.count
      return SQLLexeme(
        kind: .quoted(char == "\u{2018}" ? .string : .quotedIdentifier, content: content),
        range: i..<end)
    }
    if char == "$" {
      let tagEnd = Self.scan(s, from: i + 1, while: Self.isASCIIWordCharacter)
      if tagEnd < s.count, s[tagEnd] == "$",
        let end = Self.closingTagEnd(of: s[i...tagEnd], in: s, from: tagEnd + 1)
      {
        return SQLLexeme(kind: .dollarString, range: i..<end)
      }
      guard let next, Self.isASCIIWordCharacter(next) else {
        return SQLLexeme(kind: .symbol, range: i..<(i + 1))
      }
      return SQLLexeme(
        kind: .word, range: i..<Self.scan(s, from: i + 1, while: Self.isIdentifierCharacter))
    }
    if Self.isIdentifierStart(char) {
      let end = Self.scan(s, from: i + 1, while: Self.isIdentifierCharacter)
      return SQLLexeme(kind: .word, range: i..<end)
    }
    if Self.isDigit(char) {
      let end = Self.clickhouseNumberEnd(in: s, at: i)
      guard end < s.count, Self.isASCIIWordCharacter(s[end]) else {
        return SQLLexeme(kind: .number, range: i..<end)
      }
      // A number run straight into letters is one identifier (`1abc`)
      return SQLLexeme(
        kind: .word, range: i..<Self.scan(s, from: end, while: Self.isASCIIWordCharacter))
    }
    return Self.lexeme(in: s, at: i, markBackslash: false)
  }

  /// The end of a ClickHouse number at `i` (a digit): `0x` + hex digits or `0b` + binary digits,
  /// else digits, with `_` between digits, an optional `.` fraction, and an optional exponent
  /// (`e` / `E`, hex `p` / `P`) with a sign, as the server reads one that follows no `.`. After a
  /// `.` the server reads only digits (`x.1.1`), so a sign it leaves out may start a `--`
  /// comment: `clickhouseFailsClosed` refuses a number that ends in `-` before another `-`.
  private static func clickhouseNumberEnd(in s: [Unicode.Scalar], at i: Int) -> Int {
    var j = i
    var hex = false
    if i + 2 < s.count, s[i] == "0" {
      if s[i + 1] == "x" || s[i + 1] == "X", isHexDigit(s[i + 2]) {
        hex = true
        j = i + 2
      } else if s[i + 1] == "b" || s[i + 1] == "B", s[i + 2] == "0" || s[i + 2] == "1" {
        j = i + 2
      }
    }
    let isHex = hex
    func isDigitOf(_ scalar: Unicode.Scalar) -> Bool {
      isHex ? isHexDigit(scalar) : isDigit(scalar)
    }
    func digits(from start: Int) -> Int {
      var k = start
      while k < s.count,
        isDigitOf(s[k]) || (s[k] == "_" && k > start && k + 1 < s.count && isDigitOf(s[k + 1]))
      {
        k += 1
      }
      return k
    }
    j = digits(from: j)
    if j < s.count, s[j] == "." { j = digits(from: j + 1) }
    let exponent: Set<Unicode.Scalar> = hex ? ["p", "P"] : ["e", "E"]
    if j + 1 < s.count, exponent.contains(s[j]) {
      j += 1
      if j + 1 < s.count, s[j] == "-" || s[j] == "+" { j += 1 }
      while j < s.count, isDigit(s[j]) || (s[j] == "_" && j + 1 < s.count && isDigit(s[j + 1])) {
        j += 1
      }
    }
    return j
  }

  /// ClickHouse `isWordCharASCII`: an ASCII letter, digit or `_`
  private static func isASCIIWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isASCIILetter(scalar) || isDigit(scalar) || scalar == "_"
  }

  /// Whether the ClickHouse classifier must fail closed on `sql`: a non-ASCII scalar outside
  /// quotes, heredocs and comments (the server reads a Unicode space as a space and a U+2212 as
  /// a minus, and refuses any other), a number ending in a `-` sign right before another `-`
  /// (after a `.` the server leaves the sign out and reads `--` as a comment), or a `$` that opens
  /// no heredoc here (servers before the word-character tag rule take any text up to the next
  /// `$` as the tag).
  func clickhouseFailsClosed(_ sql: String) -> Bool {
    let scalars = Array(sql.unicodeScalars)
    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      let end = lexeme.range.upperBound
      switch lexeme.kind {
      case .quoted, .dollarString, .comment: break
      case .number where scalars[end - 1] == "-" && end < scalars.count && scalars[end] == "-":
        return true
      case .symbol where scalars[i] == "$", .word where scalars[i] == "$":
        return true
      default:
        if scalars[lexeme.range].contains(where: { !$0.isASCII }) { return true }
      }
      i = end
    }
    return false
  }

  /// MySQL lexeme. `'…'` and `"…"` are strings with backslash and doubled-quote escapes;
  /// backticks quote identifiers (doubled backtick is one backtick). `#` and `-- ` (a `--`
  /// followed by whitespace, a control character or the end) are comments to the next `\n`,
  /// as in the server lexer. Block comments do not nest; `/*!` and `/*M!` open an
  /// `.executableComment`. `$` is a symbol or an identifier character, never a quote.
  private func mysqlLexeme(in s: [Unicode.Scalar], at i: Int) -> SQLLexeme {
    let char = s[i]
    let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil

    if Self.isWhitespace(char) {
      return SQLLexeme(
        kind: .whitespace, range: i..<Self.scan(s, from: i + 1, while: Self.isWhitespace))
    }
    if char == "#" || (char == "-" && next == "-" && Self.endsMySQLDashes(s, at: i + 2)) {
      return SQLLexeme(kind: .comment, range: i..<Self.scan(s, from: i, while: { $0 != "\n" }))
    }
    if let end = Self.executableCommentEnd(in: s, at: i) {
      return SQLLexeme(kind: .executableComment, range: i..<end)
    }
    if let end = Self.sqliteBlockCommentEnd(in: s, at: i) {
      return SQLLexeme(kind: .comment, range: i..<end)
    }
    if char == "'" || char == "\"" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: true, kind: .string, markBackslash: false)
    }
    if char == "`" {
      return Self.quoted(
        s, start: i, quoteAt: i, escape: false, kind: .quotedIdentifier, markBackslash: false)
    }
    if Self.isIdentifierStart(char) {
      let end = Self.scan(s, from: i + 1, while: Self.isIdentifierCharacter)
      return SQLLexeme(kind: .word, range: i..<end)
    }
    if Self.isDigit(char) {
      return SQLLexeme(kind: .number, range: i..<Self.scan(s, from: i + 1, while: Self.isDigit))
    }
    return SQLLexeme(kind: .symbol, range: i..<(i + 1))
  }

  /// Whether `--` ending before offset `i` starts a MySQL comment: the next scalar is
  /// whitespace or a control character, or the input ends.
  private static func endsMySQLDashes(_ s: [Unicode.Scalar], at i: Int) -> Bool {
    i >= s.count || s[i].value <= 0x20 || s[i].value == 0x7F
  }

  /// If a MySQL executable comment (`/*!` or MariaDB `/*M!`, optionally with version digits)
  /// starts at `i`, returns the offset after the first `*/` (or `s.count` when unterminated).
  private static func executableCommentEnd(in s: [Unicode.Scalar], at i: Int) -> Int? {
    guard i + 2 < s.count, s[i] == "/", s[i + 1] == "*" else { return nil }
    let isMariaDB = s[i + 2] == "M" && i + 3 < s.count && s[i + 3] == "!"
    guard s[i + 2] == "!" || isMariaDB else { return nil }
    var j = i + (isMariaDB ? 4 : 3)
    while j + 1 < s.count {
      if s[j] == "*" && s[j + 1] == "/" {
        return j + 2
      }
      j += 1
    }
    return s.count
  }
}
