// SQLTokenizer+Scanning.swift
// Unicode-scalar lexeme scanner shared by statement splitting and tokenizing

import Foundation

/// One lexeme of SQL text: a kind and a range of offsets into the scalar array.
nonisolated struct SQLLexeme {
  enum Kind {
    case whitespace
    case comment
    /// Keyword or identifier: starts with an ASCII letter, `_` or non-ASCII scalar, and
    /// continues with those, ASCII digits and `$`
    case word
    /// Run of ASCII digits. A following `$` starts a new token, as in PostgreSQL.
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
