// MongoshSplitter.swift
// Splits a mongosh cell into commands for `MongoshParser`. Pure scanning, never fails.

import Foundation

/// Splits mongosh text at a top-level `;`, or at a line break that ends a complete command:
/// brackets balanced, outside strings, regex literals and comments, and the next non-blank,
/// non-comment text does not start with `.` (a line starting with `.` continues the chain) and
/// the command does not end with `.`.
///
/// Each piece is an exact substring of the input trimmed of whitespace, as
/// `SQLTokenizer.splitStatements` returns them. Unlike SQL, pieces holding only comments are
/// dropped (the SQL comment-only filter does not know `//`), and comments before a command stay
/// with it. An unterminated string, bracket or block comment makes the rest one piece.
/// Text above `MongoRelaxedJSON.maxInputBytes` is one piece, left whole for the parser to refuse.
nonisolated enum MongoshSplitter {
  static func split(_ text: String) -> [String] {
    guard text.utf8.count <= MongoRelaxedJSON.maxInputBytes else { return [text] }
    var scanner = Scanner(bytes: Array(text.utf8))
    return scanner.split()
  }
}

nonisolated extension MongoshSplitter {
  /// Works on UTF-8 bytes: every delimiter is ASCII, so cuts fall on character boundaries.
  fileprivate nonisolated struct Scanner {
    let bytes: [UInt8]
    private var pieces: [String] = []
    private var start = 0
    private var depth = 0
    /// Last byte of the current piece outside whitespace and comments, nil before any.
    private var last: UInt8?
    /// End of the line where a regex literal scan last failed: no `/` before it starts one, so a
    /// line like `/[/[/[…` is scanned once, not once per `/`. A heuristic: a later `/` that the
    /// failed scan saw inside `[...]` is not tried, and the line is broken text either way.
    private var regexBlockedBefore = 0

    init(bytes: [UInt8]) {
      self.bytes = bytes
    }

    mutating func split() -> [String] {
      var index = 0
      while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case 0x0A, 0x0D:
          guard depth == 0, let last, last != UInt8(ascii: ".") else {
            index += 1
            continue
          }
          // Whitespace and comments up to the next text change nothing, so skip them once.
          let following = nextText(after: index)
          if following == bytes.count || bytes[following] != UInt8(ascii: ".") {
            cut(at: index, next: index)
          }
          index = following
        case 0x20, 0x09, 0x0B, 0x0C:
          index += 1
        case UInt8(ascii: "/") where next(index) == UInt8(ascii: "/"):
          index = lineCommentEnd(from: index)
        case UInt8(ascii: "/") where next(index) == UInt8(ascii: "*"):
          index = blockCommentEnd(from: index) ?? bytes.count
        case UInt8(ascii: ";") where depth == 0:
          cut(at: index, next: index + 1)
          index += 1
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
          index = stringEnd(from: index)
          last = byte
        default:
          if byte == UInt8(ascii: "/"), startsValue, index >= regexBlockedBefore {
            if let end = MongoRelaxedJSON.Lexer.regexLiteralEnd(in: bytes, from: index + 1) {
              index = end + 1
              last = byte
              continue
            }
            regexBlockedBefore = lineEnd(from: index)
          }
          if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
            depth += 1
          } else if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]")
            || byte == UInt8(ascii: "}")
          {
            depth = max(0, depth - 1)
          }
          last = byte
          index += 1
        }
      }
      cut(at: bytes.count, next: bytes.count)
      return pieces
    }

    /// Ends the current piece at `end` (kept only if it has content) and starts the next at `next`.
    private mutating func cut(at end: Int, next: Int) {
      if last != nil {
        var lower = start
        var upper = end
        while lower < upper, bytes[lower].isMongoshWhitespace { lower += 1 }
        while upper > lower, bytes[upper - 1].isMongoshWhitespace { upper -= 1 }
        pieces.append(String(decoding: bytes[lower..<upper], as: UTF8.self))
      }
      start = next
      last = nil
    }

    private func next(_ index: Int) -> UInt8? {
      index + 1 < bytes.count ? bytes[index + 1] : nil
    }

    /// A `/` here starts a regex literal (as in `MongoRelaxedJSON`): it follows a piece start
    /// or a byte after which a value comes.
    private var startsValue: Bool {
      guard let last else { return true }
      return [
        UInt8(ascii: "("), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "["),
        UInt8(ascii: "{"), UInt8(ascii: "="),
      ].contains(last)
    }

    /// Index of the first byte after `index` outside whitespace, blank lines and comments, or
    /// the end of the text (also when a block comment never closes).
    private func nextText(after index: Int) -> Int {
      var cursor = index
      while cursor < bytes.count {
        let byte = bytes[cursor]
        if byte.isMongoshWhitespace {
          cursor += 1
        } else if byte == UInt8(ascii: "/"), next(cursor) == UInt8(ascii: "/") {
          cursor = lineCommentEnd(from: cursor)
        } else if byte == UInt8(ascii: "/"), next(cursor) == UInt8(ascii: "*") {
          guard let end = blockCommentEnd(from: cursor) else { return bytes.count }
          cursor = end
        } else {
          return cursor
        }
      }
      return bytes.count
    }

    /// Index of the line break ending the `//` comment at `index` (or the end of the text).
    private func lineCommentEnd(from index: Int) -> Int {
      lineEnd(from: index + 2)
    }

    /// Index of the first line break at or after `index` (or the end of the text).
    private func lineEnd(from index: Int) -> Int {
      var cursor = index
      while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D { cursor += 1 }
      return cursor
    }

    /// Index after the `*/` closing the comment at `index`, nil when it never closes.
    private func blockCommentEnd(from index: Int) -> Int? {
      var cursor = index + 2
      while cursor + 1 < bytes.count {
        if bytes[cursor] == UInt8(ascii: "*"), bytes[cursor + 1] == UInt8(ascii: "/") {
          return cursor + 2
        }
        cursor += 1
      }
      return nil
    }

    /// Index after the quote closing the string at `index` (`\` escapes the next byte), or the
    /// end of the text when it never closes.
    private func stringEnd(from index: Int) -> Int {
      let quote = bytes[index]
      var cursor = index + 1
      while cursor < bytes.count {
        switch bytes[cursor] {
        case quote: return cursor + 1
        case UInt8(ascii: "\\"): cursor += 2
        default: cursor += 1
        }
      }
      return bytes.count
    }
  }
}

nonisolated extension UInt8 {
  /// The whitespace `SQLTokenizer` trims: space, tab, LF, CR, form feed, vertical tab.
  fileprivate var isMongoshWhitespace: Bool {
    self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D || self == 0x0C || self == 0x0B
  }
}
