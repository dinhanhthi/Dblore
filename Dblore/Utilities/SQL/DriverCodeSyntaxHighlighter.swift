//
//  DriverCodeSyntaxHighlighter.swift
//  Dblore
//
//  Token coloring for the driver code of the MongoDB Export Code sheet
//

import Foundation
import SwiftUI

/// Driver code highlighter: one linear pass over UTF-16 units, colored with the SQL highlighter's
/// token types. Line comments (`#` in Python, `//` elsewhere) and quoted strings come first; then
/// language keywords, names after `new` as types, called names as functions and other capitalized
/// names (all-caps constants aside) as types. A name followed by `:` (an object key or a Go struct
/// field) stays in the default color.
enum DriverCodeSyntaxHighlighter {
  typealias TokenType = SQLSyntaxHighlighter.TokenType

  struct Token: Equatable {
    let range: NSRange
    let type: TokenType
  }

  static func keywords(for language: MongoDriverCode.Language) -> Set<String> {
    switch language {
    case .node:
      [
        "async", "await", "catch", "const", "else", "false", "finally", "for", "function", "if",
        "let", "new", "null", "of", "require", "return", "true", "try", "undefined", "var",
      ]
    case .python:
      [
        "and", "as", "def", "else", "False", "for", "from", "if", "import", "in", "None", "not",
        "or", "return", "True", "try", "with",
      ]
    case .java:
      [
        "boolean", "catch", "class", "double", "else", "false", "final", "for", "if", "import",
        "int", "long", "new", "null", "public", "return", "static", "throws", "true", "try",
        "var", "void",
      ]
    case .go:
      [
        "bool", "byte", "const", "defer", "else", "false", "float64", "for", "func", "if",
        "import", "int", "int32", "int64", "nil", "package", "range", "return", "string", "true",
        "var",
      ]
    case .csharp:
      [
        "await", "bool", "byte", "decimal", "double", "else", "false", "for", "foreach", "if",
        "in", "int", "long", "new", "null", "return", "string", "true", "using", "var",
      ]
    }
  }

  /// Tokens of `text`, in order and disjoint
  static func tokens(in text: String, language: MongoDriverCode.Language) -> [Token] {
    var scanner = Scanner(buffer: Array(text.utf16), language: language)
    scanner.run()
    return scanner.tokens
  }

  /// `code` with the token colors; plain when syntax highlighting is off in Settings
  static func highlight(_ code: String, language: MongoDriverCode.Language) -> AttributedString {
    var result = AttributedString(code)
    guard AppSettings.shared.syntaxHighlightingEnabled else { return result }
    for token in tokens(in: code, language: language) {
      guard let range = Range(token.range, in: code).flatMap({ Range($0, in: result) }) else {
        continue
      }
      result[range].foregroundColor = color(for: token.type)
    }
    return result
  }

  private static func color(for type: TokenType) -> Color {
    switch type {
    case .keyword: .syntaxKeyword
    case .function, .type: .syntaxFunction
    case .string: .syntaxString
    case .number: .syntaxNumber
    case .comment: .syntaxComment
    case .operator: .syntaxOperator
    case .identifier: .foreground
    }
  }
}

// MARK: - Scanner

extension DriverCodeSyntaxHighlighter {
  private struct Scanner {
    let buffer: [unichar]
    let keywords: Set<String>
    let hashComments: Bool
    var tokens: [Token] = []

    private var i = 0
    /// The previous word was `new`: the next one names a type, even when called
    private var afterNew = false

    init(buffer: [unichar], language: MongoDriverCode.Language) {
      self.buffer = buffer
      self.keywords = DriverCodeSyntaxHighlighter.keywords(for: language)
      self.hashComments = language == .python
    }

    private static let slash = unichar(UInt8(ascii: "/"))
    private static let hash = unichar(UInt8(ascii: "#"))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let dot = unichar(UInt8(ascii: "."))
    private static let colon = unichar(UInt8(ascii: ":"))

    mutating func run() {
      let n = buffer.count
      while i < n {
        let c = buffer[i]
        let next: unichar = i + 1 < n ? buffer[i + 1] : 0
        if hashComments ? c == Self.hash : (c == Self.slash && next == Self.slash) {
          var k = i + 1
          while k < n && !isLineBreak(buffer[k]) { k += 1 }
          emit(i, k, .comment)
          i = k
        } else if c == 0x22 || c == 0x27 {  // " '
          scanString(quote: c)
        } else if isDigit(c) {
          scanNumber()
        } else if isWordStart(c) {
          scanWord()
        } else {
          i += 1
        }
      }
    }

    private mutating func emit(_ start: Int, _ end: Int, _ type: TokenType) {
      tokens.append(Token(range: NSRange(location: start, length: end - start), type: type))
    }

    /// A one-line string: `\` escapes the next character; without a closer it ends at the line
    private mutating func scanString(quote: unichar) {
      let n = buffer.count
      var k = i + 1
      while k < n && !isLineBreak(buffer[k]) {
        if buffer[k] == quote {
          k += 1
          break
        }
        k += buffer[k] == Self.backslash && k + 1 < n && !isLineBreak(buffer[k + 1]) ? 2 : 1
      }
      emit(i, k, .string)
      i = k
    }

    /// Digits with a fraction, a signed exponent and literal suffixes (`5L`, `1e-3`, `0x1F`)
    private mutating func scanNumber() {
      let n = buffer.count
      var k = i + 1
      while k < n {
        let d = buffer[k]
        if isWordPart(d) {
          k += 1
        } else if d == Self.dot && k + 1 < n && isDigit(buffer[k + 1]) {
          k += 1
        } else if (d == 0x2B || d == 0x2D) && buffer[k - 1] | 0x20 == 0x65  // + - after e E
          && k + 1 < n && isDigit(buffer[k + 1])
        {
          k += 1
        } else {
          break
        }
      }
      emit(i, k, .number)
      i = k
    }

    private mutating func scanWord() {
      let n = buffer.count
      let start = i
      var end = i + 1
      while end < n && isWordPart(buffer[end]) { end += 1 }
      let word = String(decoding: buffer[start..<end], as: UTF16.self)
      var k = end
      while k < n && isBlank(buffer[k]) { k += 1 }
      let follower: unichar = k < n ? buffer[k] : 0
      let afterFollower: unichar = k + 1 < n ? buffer[k + 1] : 0

      let type: TokenType?
      if keywords.contains(word) {
        type = .keyword
      } else if afterNew {
        type = .type
      } else if follower == Self.colon && afterFollower != 0x3D && afterFollower != Self.colon {
        type = nil  // key: but not := or ::
      } else if follower == 0x28 {  // (
        type = .function
      } else if (0x41...0x5A).contains(buffer[start]), !isConstant(word) {
        type = .type
      } else {
        type = nil
      }
      if let type { emit(start, end, type) }
      afterNew = word == "new"
      i = end
    }

    // MARK: Characters

    /// An all-caps name with `_` (`MONGODB_URI`): a constant, not a type like `D` or `MongoClient`
    private func isConstant(_ word: String) -> Bool {
      word.contains("_") && !word.contains(where: \.isLowercase)
    }

    private func isDigit(_ c: unichar) -> Bool { (0x30...0x39).contains(c) }

    private func isWordStart(_ c: unichar) -> Bool {
      (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F || c == 0x24  // _ $
    }

    private func isWordPart(_ c: unichar) -> Bool { isWordStart(c) || isDigit(c) }

    private func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    private func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
  }
}
