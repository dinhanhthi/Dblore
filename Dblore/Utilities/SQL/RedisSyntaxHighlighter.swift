//
//  RedisSyntaxHighlighter.swift
//  Dblore
//
//  Token coloring for Redis command cells (redis-cli quoting)
//

import AppKit

/// Redis highlighter: one linear pass over UTF-16 units, colored with the SQL highlighter's
/// token types and read as `RedisTokenizer` reads commands: one command per line (a line ends
/// at LF; CR is a space), a line whose first non-space character is `#` is a comment, and a
/// quote never spans lines. The first word of a line is a keyword when it is a known command
/// (`RedisCommandClassifier.commandNames`, any case), and so is the second when that command
/// takes it as a subcommand (`subcommandNames`). `"…"` and `'…'` are strings, escapes included,
/// and a quote may open mid-word; an unterminated quote, or a `\x` in `"…"` without two hex
/// digits after it (which the tokenizer refuses), runs to the line end.
/// A bare argument that is a decimal number is a number.
enum RedisSyntaxHighlighter {
  typealias TokenType = SQLSyntaxHighlighter.TokenType

  struct Token: Equatable {
    let range: NSRange
    let type: TokenType
  }

  /// Tokens inside `range`, in order and disjoint. `range` is scanned as a whole cell.
  static func tokens(in text: NSString, range: NSRange) -> [Token] {
    guard range.length > 0 else { return [] }
    var buffer = [unichar](repeating: 0, count: range.length)
    text.getCharacters(&buffer, range: range)
    var scanner = Scanner(buffer: buffer, base: range.location)
    scanner.run()
    return scanner.tokens
  }

  /// Comments and strings inside `range`, in order
  static func blockSpans(
    in text: NSString, range: NSRange
  ) -> [(range: NSRange, kind: SQLSyntaxHighlighter.BlockKind)] {
    tokens(in: text, range: range).compactMap {
      token -> (range: NSRange, kind: SQLSyntaxHighlighter.BlockKind)? in
      switch token.type {
      case .comment: (token.range, .comment)
      case .string: (token.range, .string)
      default: nil
      }
    }
  }

  /// Colors the tokens inside `range`; the caller has set the default attributes
  static func highlight(
    in storage: NSMutableAttributedString, range: NSRange,
    palette: SQLSyntaxHighlighter.Palette
  ) {
    for token in tokens(in: storage.string as NSString, range: range) {
      storage.addAttribute(
        .foregroundColor, value: palette.color(for: token.type), range: token.range)
    }
  }

  // MARK: - Characters (shared with RedisAutocompleteProvider)

  static let lineFeed: unichar = 0x0A
  static let hash = unichar(UInt8(ascii: "#"))
  static let doubleQuote: unichar = 0x22
  static let singleQuote: unichar = 0x27
  static let backslash = unichar(UInt8(ascii: "\\"))

  /// Space, tab, CR, vertical tab, form feed and NUL end an unquoted word (`RedisTokenizer`)
  static func isSpace(_ c: unichar) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C || c == 0x00
  }

  /// The end of the quoted part opened by the quote at `start` in `buffer[..<end]`: after its
  /// closing quote, or at the line end (`end` or the next LF) when it is not closed or holds a
  /// broken escape. In `"…"` a backslash escapes the next character, and `\x` the two hex digits
  /// after it (else the escape is broken); in `'…'` a backslash escapes only a `'`.
  static func quotedEnd(_ buffer: [unichar], from start: Int, to end: Int) -> Int {
    let quote = buffer[start]
    var k = start + 1
    while k < end && buffer[k] != lineFeed {
      let c = buffer[k]
      if c == quote { return k + 1 }
      guard c == backslash && k + 1 < end && buffer[k + 1] != lineFeed else {
        k += 1
        continue
      }
      if quote == singleQuote {
        k += buffer[k + 1] == singleQuote ? 2 : 1
      } else if buffer[k + 1] == hexEscape {
        guard k + 3 < end && isHexDigit(buffer[k + 2]) && isHexDigit(buffer[k + 3]) else {
          while k < end && buffer[k] != lineFeed { k += 1 }
          return k
        }
        k += 4
      } else {
        k += 2
      }
    }
    return k
  }

  private static let hexEscape = unichar(UInt8(ascii: "x"))

  private static func isHexDigit(_ c: unichar) -> Bool {
    (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c)
  }

  /// `buffer[start..<end]` upper-cased (ASCII), nil unless every unit is printable ASCII (the
  /// classifier's command-name rule) and the word is short enough to be a name
  static func upperName(_ buffer: [unichar], _ start: Int, _ end: Int) -> String? {
    guard end - start <= 32 else { return nil }
    var units = [unichar]()
    units.reserveCapacity(end - start)
    for c in buffer[start..<end] {
      guard (0x21...0x7E).contains(c) else { return nil }
      units.append((0x61...0x7A).contains(c) ? c - 0x20 : c)
    }
    return String(decoding: units, as: UTF16.self)
  }
}

// MARK: - Scanner

extension RedisSyntaxHighlighter {
  private struct Scanner {
    let buffer: [unichar]
    let base: Int
    var tokens: [Token] = []
    private var i = 0

    init(buffer: [unichar], base: Int) {
      self.buffer = buffer
      self.base = base
    }

    mutating func run() {
      while i < buffer.count {
        scanLine()
      }
    }

    /// One line, its LF included
    private mutating func scanLine() {
      let n = buffer.count
      while i < n && isSpace(buffer[i]) { i += 1 }
      if i < n && buffer[i] == hash {
        let start = i
        while i < n && buffer[i] != lineFeed { i += 1 }
        emit(start, i, .comment)
      }
      var argument = 0
      var command: String?
      while i < n && buffer[i] != lineFeed {
        if isSpace(buffer[i]) {
          i += 1
          continue
        }
        let start = i
        var quoted = false
        while i < n && buffer[i] != lineFeed && !isSpace(buffer[i]) {
          let c = buffer[i]
          if c == doubleQuote || c == singleQuote {
            quoted = true
            let end = quotedEnd(buffer, from: i, to: n)
            emit(i, end, .string)
            i = end
          } else {
            i += 1
          }
        }
        if !quoted {
          command = bareWord(start, i, argument: argument, command: command)
        }
        argument += 1
      }
      if i < n { i += 1 }
    }

    /// Colors the bare argument `[start, end)`; returns the command a subcommand may follow
    private mutating func bareWord(
      _ start: Int, _ end: Int, argument: Int, command: String?
    ) -> String? {
      if argument == 0 {
        guard let name = upperName(buffer, start, end),
          RedisCommandClassifier.commandNames.contains(name)
        else { return nil }
        emit(start, end, .keyword)
        return name
      }
      if argument == 1, let command,
        let subcommands = RedisCommandClassifier.subcommandNames[command],
        let name = upperName(buffer, start, end), subcommands.contains(name)
      {
        emit(start, end, .keyword)
      } else if isNumber(start, end) {
        emit(start, end, .number)
      }
      return command
    }

    /// `-?[0-9]+(\.[0-9]+)?`
    private func isNumber(_ start: Int, _ end: Int) -> Bool {
      var k = start
      if buffer[k] == 0x2D { k += 1 }  // -
      let intStart = k
      while k < end && isDigit(buffer[k]) { k += 1 }
      guard k > intStart else { return false }
      if k < end && buffer[k] == 0x2E {  // .
        k += 1
        let fractionStart = k
        while k < end && isDigit(buffer[k]) { k += 1 }
        guard k > fractionStart else { return false }
      }
      return k == end
    }

    private func isDigit(_ c: unichar) -> Bool { (0x30...0x39).contains(c) }

    private mutating func emit(_ start: Int, _ end: Int, _ type: TokenType) {
      tokens.append(Token(range: NSRange(location: base + start, length: end - start), type: type))
    }
  }
}
