// SQLFingerprint.swift
// The shape of a recorded statement with its literal values removed, for Query Insights.

import Foundation

/// Two runs of one statement that differ only in values share a fingerprint. SQL is lexed with
/// the connection's dialect (`SQLTokenizer.lexeme`): strings, numbers and dollar-quoted strings
/// become `?`, an `IN (?, ?, …)` list becomes `IN (?)`, comments are dropped, keywords (the
/// highlighter's, for the dialect) are uppercased and tokens are joined by single spaces. Other
/// words and quoted identifiers keep their text. MongoDB is `mongosh(_:)`.
nonisolated enum SQLFingerprint {
  static func fingerprint(_ sql: String, dialect: SQLDialect) -> String {
    dialect == .mongodb ? mongosh(sql) : self.sql(sql, dialect: dialect)
  }

  // MARK: - SQL

  private struct Piece {
    enum Kind { case word, identifier, literal, symbol, parameter }

    var kind: Kind
    var text: String
    /// No whitespace or comment between this piece and the one before it in the source
    var isAdjacent: Bool

    func isSymbol(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
  }

  private static let operatorSymbols: Set<String> = [
    "<", ">", "=", "!", "|", "&", ":", "~", "+", "-", "*", "/", "%", "^", "#", "@",
  ]

  private static func sql(_ sql: String, dialect: SQLDialect) -> String {
    let tokenizer = SQLTokenizer(dialect: dialect)
    let scalars = Array(sql.unicodeScalars)
    var pieces: [Piece] = []
    var isAdjacent = false
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      var end = lexeme.range.upperBound
      switch lexeme.kind {
      case .whitespace, .comment:
        isAdjacent = false
        i = end
        continue
      case .number:
        // `$1` and `?1` are parameters, not values
        if isAdjacent, let last = pieces.last, last.isSymbol("$") || last.isSymbol("?") {
          pieces.append(
            Piece(
              kind: .parameter, text: SQLTokenizer.text(scalars, lexeme.range), isAdjacent: true))
        } else {
          end = numberEnd(scalars, digitsStart: i, digitsEnd: end)
          appendLiteral(to: &pieces, isAdjacent: isAdjacent)
        }
      case .quoted(.quotedIdentifier, _):
        pieces.append(
          Piece(
            kind: .identifier, text: SQLTokenizer.text(scalars, lexeme.range),
            isAdjacent: isAdjacent))
      case .quoted, .dollarString:
        appendLiteral(to: &pieces, isAdjacent: isAdjacent)
      case .word:
        pieces.append(
          Piece(
            kind: .word, text: keywordCased(SQLTokenizer.text(scalars, lexeme.range), dialect),
            isAdjacent: isAdjacent))
      case .executableComment:
        pieces.append(
          Piece(
            kind: .symbol, text: SQLTokenizer.text(scalars, lexeme.range), isAdjacent: isAdjacent))
      case .symbol:
        // `.5` after anything but a name or a closing bracket is a number
        if scalars[i] == ".", i + 1 < scalars.count, isDigit(scalars[i + 1]),
          !(pieces.last.map(endsOperand) ?? false)
        {
          end = numberEnd(scalars, digitsStart: i, digitsEnd: i)
          appendLiteral(to: &pieces, isAdjacent: isAdjacent)
        } else {
          pieces.append(
            Piece(
              kind: .symbol, text: SQLTokenizer.text(scalars, lexeme.range),
              isAdjacent: isAdjacent))
        }
      }
      isAdjacent = true
      i = end
    }
    return render(collapsingInLists(pieces))
  }

  /// `word` uppercased when the highlighter colors it as a keyword for `dialect`, else as typed.
  /// Only all-ASCII words can be keywords: `Set<String>` uses canonical equivalence.
  private static func keywordCased(_ word: String, _ dialect: SQLDialect) -> String {
    guard word.unicodeScalars.allSatisfy(\.isASCII) else { return word }
    let upper = SQLTokenizer.asciiUppercased(word)
    let isKeyword =
      SQLSyntaxHighlighter.keywords.contains(upper)
      || (dialect == .mysql && SQLSyntaxHighlighter.mysqlKeywords.contains(upper))
    return isKeyword ? upper : word
  }

  /// A word, quoted name, value or closing bracket: a `-` or `.` after it is not a sign or a
  /// decimal point.
  private static func endsOperand(_ piece: Piece) -> Bool {
    piece.kind != .symbol || piece.text == ")" || piece.text == "]"
  }

  /// `?`, taking a sign written right before it after an operator or an opening bracket
  /// (`= -1`, `(+2`), so `-1` and `1` share a fingerprint. `a - 1` keeps its minus.
  private static func appendLiteral(to pieces: inout [Piece], isAdjacent: Bool) {
    var isAdjacent = isAdjacent
    if isAdjacent, let sign = pieces.last, sign.isSymbol("-") || sign.isSymbol("+"),
      !(pieces.dropLast().last.map(endsOperand) ?? false)
    {
      isAdjacent = sign.isAdjacent
      pieces.removeLast()
    }
    pieces.append(Piece(kind: .literal, text: "?", isAdjacent: isAdjacent))
  }

  /// End of a number whose digits are `digitsStart..<digitsEnd`: a fraction (`.5`), an exponent
  /// (`e-3`) or a `0x` hex tail, which the lexer reads as separate tokens.
  private static func numberEnd(
    _ s: [Unicode.Scalar], digitsStart: Int, digitsEnd: Int
  ) -> Int {
    var end = digitsEnd
    func digits(from start: Int, _ predicate: (Unicode.Scalar) -> Bool) -> Int {
      var j = start
      while j < s.count, predicate(s[j]) { j += 1 }
      return j
    }
    if end - digitsStart == 1, s[digitsStart] == "0", end + 1 < s.count,
      s[end] == "x" || s[end] == "X", isHexDigit(s[end + 1])
    {
      return digits(from: end + 1, isHexDigit)
    }
    if end < s.count, s[end] == ".", end + 1 < s.count, isDigit(s[end + 1]) {
      end = digits(from: end + 1, isDigit)
    }
    if end < s.count, s[end] == "e" || s[end] == "E" {
      var j = end + 1
      if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
      if j < s.count, isDigit(s[j]) { end = digits(from: j, isDigit) }
    }
    return end
  }

  /// `IN ( ? , ? , … )` becomes `IN ( ? )`, so lists of any length share a fingerprint.
  private static func collapsingInLists(_ pieces: [Piece]) -> [Piece] {
    var result: [Piece] = []
    var i = 0
    while i < pieces.count {
      result.append(pieces[i])
      guard pieces[i].kind == .word, pieces[i].text == "IN", i + 2 < pieces.count,
        pieces[i + 1].isSymbol("("), pieces[i + 2].kind == .literal
      else {
        i += 1
        continue
      }
      var j = i + 3
      while j + 1 < pieces.count, pieces[j].isSymbol(","), pieces[j + 1].kind == .literal {
        j += 2
      }
      guard j < pieces.count, pieces[j].isSymbol(")") else {
        i += 1
        continue
      }
      result.append(contentsOf: [pieces[i + 1], pieces[i + 2], pieces[j]])
      i = j + 1
    }
    return result
  }

  /// One space between pieces, none inside brackets or around `.` and `,`, and none inside an
  /// operator written as one (`<=`, `::`, `->>`).
  private static func render(_ pieces: [Piece]) -> String {
    var text = ""
    var previous: Piece?
    for piece in pieces {
      if let previous, !joins(previous, piece) {
        text += " "
      }
      text += piece.text
      previous = piece
    }
    return text
  }

  private static func joins(_ previous: Piece, _ piece: Piece) -> Bool {
    if piece.kind == .parameter { return true }
    if previous.isSymbol("(") || previous.isSymbol(".") { return true }
    if piece.kind == .symbol, [")", ",", ".", ";"].contains(piece.text) { return true }
    return piece.isAdjacent && previous.kind == .symbol && piece.kind == .symbol
      && operatorSymbols.contains(previous.text) && operatorSymbols.contains(piece.text)
  }

  private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }

  private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
    isDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
  }

  // MARK: - mongosh

  /// Each `MongoshSplitter` command, joined by `; `. Strings, numbers and regex literals become
  /// `?` (a quoted string followed by `:` is a key and stays), comments are dropped, whitespace
  /// is kept only as one space between two names, and an array of values (`[?, ?]`) becomes
  /// `[?]`. Names keep their case: JavaScript is case-sensitive.
  private static func mongosh(_ text: String) -> String {
    MongoshSplitter.split(text).map(mongoshCommand).joined(separator: "; ")
  }

  private static func mongoshCommand(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var output: [UInt8] = []
    var pendingSpace = false
    var i = 0
    func emit(_ piece: some Collection<UInt8>) {
      if pendingSpace, let last = output.last, isMongoshName(last),
        let first = piece.first, isMongoshName(first)
      {
        output.append(0x20)
      }
      pendingSpace = false
      output.append(contentsOf: piece)
    }
    let question = [UInt8(ascii: "?")]
    while i < bytes.count {
      let byte = bytes[i]
      let next: UInt8? = i + 1 < bytes.count ? bytes[i + 1] : nil
      switch byte {
      case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
        pendingSpace = true
        i += 1
      case UInt8(ascii: "/") where next == UInt8(ascii: "/"):
        while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
        pendingSpace = true
      case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
        i = blockCommentEnd(bytes, from: i)
        pendingSpace = true
      case UInt8(ascii: "\""), UInt8(ascii: "'"):
        let end = stringEnd(bytes, from: i)
        emit(isKey(bytes, after: end) ? bytes[i..<end] : question[...])
        i = end
      case UInt8(ascii: "/")
      where startsValue(output.last)
        && MongoRelaxedJSON.Lexer.regexLiteralEnd(in: bytes, from: i + 1) != nil:
        var end = (MongoRelaxedJSON.Lexer.regexLiteralEnd(in: bytes, from: i + 1) ?? i) + 1
        while end < bytes.count, isMongoshName(bytes[end]) { end += 1 }
        emit(question)
        i = end
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
        // Not a number when it continues a name (`t1`, `$2`)
        if !(output.last.map(isMongoshName) ?? false) || pendingSpace,
          let number = MongoRelaxedJSON.Lexer.number(in: bytes, from: i)
        {
          emit(question)
          i = number.end
        } else {
          emit([byte])
          i += 1
        }
      default:
        emit([byte])
        i += 1
      }
    }
    return String(decoding: output, as: UTF8.self).replacing(/\[\?(?:,\?)+\]/, with: "[?]")
  }

  /// A `/` after one of these (or at the start) begins a regex literal, as `MongoshSplitter`
  /// reads it.
  private static func startsValue(_ last: UInt8?) -> Bool {
    guard let last else { return true }
    return [
      UInt8(ascii: "("), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "["),
      UInt8(ascii: "{"), UInt8(ascii: "="),
    ].contains(last)
  }

  /// `[A-Za-z0-9_$]` and the `?` placeholder
  private static func isMongoshName(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
      || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte == UInt8(ascii: "?")
  }

  /// The next byte after whitespace is `:`: the string is an object key.
  private static func isKey(_ bytes: [UInt8], after end: Int) -> Bool {
    var j = end
    while j < bytes.count, [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(bytes[j]) { j += 1 }
    return j < bytes.count && bytes[j] == UInt8(ascii: ":")
  }

  /// Index after the closing quote (`\` escapes the next byte), or the end of the text.
  private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
    let quote = bytes[start]
    var j = start + 1
    while j < bytes.count {
      if bytes[j] == quote { return j + 1 }
      j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
    }
    return bytes.count
  }

  /// Index after the `*/` closing the comment at `start`, or the end of the text.
  private static func blockCommentEnd(_ bytes: [UInt8], from start: Int) -> Int {
    var j = start + 2
    while j + 1 < bytes.count {
      if bytes[j] == UInt8(ascii: "*"), bytes[j + 1] == UInt8(ascii: "/") { return j + 2 }
      j += 1
    }
    return bytes.count
  }
}
