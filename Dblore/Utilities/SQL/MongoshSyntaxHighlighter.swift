//
//  MongoshSyntaxHighlighter.swift
//  Dblore
//
//  Token coloring for mongosh cells (the Dblore MongoDB subset)
//

import AppKit

/// mongosh highlighter: one linear pass over UTF-16 units, colored with the SQL highlighter's
/// token types. `db`, `new`, `true`, `false`, `null` and `$` operators and stages are keywords,
/// called names are functions, BSON constructors are types, regex literals are strings, and
/// collection names are identifiers. Unterminated strings and block comments run to the end.
enum MongoshSyntaxHighlighter {
  typealias TokenType = SQLSyntaxHighlighter.TokenType

  struct Token: Equatable {
    let range: NSRange
    let type: TokenType
  }

  static let constructors: Set<String> = [
    "ObjectId", "ISODate", "NumberLong", "NumberDecimal", "NumberInt", "Timestamp", "BinData",
    "RegExp", "MinKey", "MaxKey",
  ]

  static let literals: Set<String> = ["db", "new", "true", "false", "null"]

  /// Tokens inside `range`, in order and disjoint. `range` is scanned as a whole cell.
  static func tokens(in text: NSString, range: NSRange) -> [Token] {
    guard range.length > 0 else { return [] }
    var buffer = [unichar](repeating: 0, count: range.length)
    text.getCharacters(&buffer, range: range)
    var scanner = Scanner(buffer: buffer, base: range.location)
    scanner.run()
    return scanner.tokens
  }

  /// Comments and strings (regex literals included) inside `range`, in order
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
    for token in tokens(in: storage.string as NSString, range: range)
    where token.type != .identifier {
      storage.addAttribute(
        .foregroundColor, value: palette.color(for: token.type), range: token.range)
    }
  }
}

// MARK: - Scanner

extension MongoshSyntaxHighlighter {
  private struct Scanner {
    let buffer: [unichar]
    let base: Int
    var tokens: [Token] = []

    private var i = 0
    /// Last significant character (outside comments), 0 at the start
    private var previous: unichar = 0
    /// The last significant item was this word
    private var lastWord: String?
    /// The word right before the last `.`
    private var dotOwner: String?
    /// A failed regex scan stopped here; every `/` before it is plain
    private var regexFailsBefore = 0

    init(buffer: [unichar], base: Int) {
      self.buffer = buffer
      self.base = base
    }

    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let minus = unichar(UInt8(ascii: "-"))
    private static let dollar = unichar(UInt8(ascii: "$"))
    /// Characters after which `/` starts a regex literal
    private static let regexPrefixes = Set("(,:[{=!&|?;".utf16)
    /// Characters after which `-` is a binary operator, not a sign
    private static let valueEnds = Set("\"')]".utf16)

    mutating func run() {
      let n = buffer.count
      while i < n {
        let c = buffer[i]
        let next: unichar = i + 1 < n ? buffer[i + 1] : 0
        if c == Self.slash && next == Self.slash {
          var k = i + 2
          while k < n && !isLineBreak(buffer[k]) { k += 1 }
          emit(i, k, .comment)
          i = k
        } else if c == Self.slash && next == Self.star {
          var k = i + 2
          while k + 1 < n && !(buffer[k] == Self.star && buffer[k + 1] == Self.slash) { k += 1 }
          let end = k + 1 < n ? k + 2 : n
          emit(i, end, .comment)
          i = end
        } else if c == 0x22 || c == 0x27 {  // " '
          scanString(quote: c)
        } else if c == Self.slash, i >= regexFailsBefore,
          previous == 0 || Self.regexPrefixes.contains(previous)
        {
          scanRegex()
        } else if isDigit(c)
          || (c == Self.minus && isDigit(next) && !endsValue(previous))
          || (c == Self.dot && isDigit(next) && !endsValue(previous))
        {
          scanNumber()
        } else if isWordStart(c) {
          scanWord()
        } else {
          if !isBlank(c) {
            dotOwner = c == Self.dot ? lastWord : nil
            lastWord = nil
            previous = c
          }
          i += 1
        }
      }
    }

    // MARK: Tokens

    private mutating func emit(_ start: Int, _ end: Int, _ type: TokenType) {
      tokens.append(Token(range: NSRange(location: base + start, length: end - start), type: type))
    }

    /// Marks `[start, end)` as the last significant item
    private mutating func consumed(_ start: Int, _ end: Int, word: String? = nil) {
      previous = buffer[end - 1]
      lastWord = word
      dotOwner = nil
      i = end
    }

    private mutating func scanString(quote: unichar) {
      let n = buffer.count
      var k = i + 1
      var end = n
      while k < n {
        let d = buffer[k]
        if d == quote {
          end = k + 1
          break
        }
        k += d == Self.backslash ? 2 : 1
      }
      emit(i, end, .string)
      consumed(i, end)
    }

    /// `/pattern/flags` on one line: `\` escapes the next character and `/` inside `[...]`
    /// does not close it. Without a closer the `/` is a plain character.
    private mutating func scanRegex() {
      let n = buffer.count
      var k = i + 1
      var inClass = false
      while k < n && !isLineBreak(buffer[k]) {
        let d = buffer[k]
        if d == Self.backslash {
          if k + 1 < n && !isLineBreak(buffer[k + 1]) { k += 2 } else { break }
          continue
        }
        if d == 0x5B {  // [
          inClass = true
        } else if d == 0x5D {  // ]
          inClass = false
        } else if d == Self.slash && !inClass {
          var end = k + 1
          while end < n && isLetter(buffer[end]) { end += 1 }
          emit(i, end, .string)
          consumed(i, end)
          return
        }
        k += 1
      }
      regexFailsBefore = k
      previous = Self.slash
      lastWord = nil
      dotOwner = nil
      i += 1
    }

    private mutating func scanNumber() {
      let n = buffer.count
      var k = i
      if buffer[k] == Self.minus { k += 1 }
      while k < n && isDigit(buffer[k]) { k += 1 }
      if k + 1 < n && buffer[k] == Self.dot && isDigit(buffer[k + 1]) {
        k += 1
        while k < n && isDigit(buffer[k]) { k += 1 }
      }
      if k < n && buffer[k] | 0x20 == 0x65 {  // e E
        var m = k + 1
        if m < n && (buffer[m] == 0x2B || buffer[m] == Self.minus) { m += 1 }
        if m < n && isDigit(buffer[m]) {
          k = m
          while k < n && isDigit(buffer[k]) { k += 1 }
        }
      }
      emit(i, k, .number)
      consumed(i, k)
    }

    private mutating func scanWord() {
      let n = buffer.count
      let start = i
      var end = i + 1
      while end < n && isWordPart(buffer[end]) { end += 1 }
      let word = String(decoding: buffer[start..<end], as: UTF16.self)
      let afterDot = previous == Self.dot
      let follower = nextSignificant(from: end)

      let type: TokenType?
      if buffer[start] == Self.dollar {
        type = .keyword
      } else if follower == 0x3A {  // ":" object key
        type = nil
      } else if afterDot {
        type = follower == 0x28 ? .function : (dotOwner == "db" ? .identifier : nil)
      } else if literals.contains(word) {
        type = .keyword
      } else if constructors.contains(word) || (word == "Date" && lastWord == "new") {
        type = .type
      } else if follower == 0x28 {  // (
        type = .function
      } else {
        type = nil
      }
      if let type { emit(start, end, type) }
      consumed(start, end, word: afterDot ? nil : word)
    }

    // MARK: Characters

    /// First non-blank character at or after `index`, 0 at the end
    private func nextSignificant(from index: Int) -> unichar {
      var k = index
      while k < buffer.count && isBlank(buffer[k]) { k += 1 }
      return k < buffer.count ? buffer[k] : 0
    }

    private func endsValue(_ c: unichar) -> Bool {
      isWordPart(c) || Self.valueEnds.contains(c)
    }

    private func isDigit(_ c: unichar) -> Bool { (0x30...0x39).contains(c) }

    private func isLetter(_ c: unichar) -> Bool {
      (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }

    private func isWordStart(_ c: unichar) -> Bool {
      isLetter(c) || c == 0x5F || c == Self.dollar
    }

    private func isWordPart(_ c: unichar) -> Bool { isWordStart(c) || isDigit(c) }

    private func isLineBreak(_ c: unichar) -> Bool {
      c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
    }

    private func isBlank(_ c: unichar) -> Bool {
      c == 0x20 || (0x09...0x0D).contains(c) || c == 0xA0 || c == 0x2028 || c == 0x2029
    }
  }
}
