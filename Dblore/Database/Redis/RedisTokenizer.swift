// RedisTokenizer.swift
// Redis command text to exact argument bytes and back, with the quoting rules of the Redis
// command-line client (redis-cli)

import Foundation

/// Splits Redis command text into argument arrays and renders argument arrays back to text.
///
/// One command per line (lines end at LF; a CR is whitespace, so CRLF text works). Blank lines
/// and lines whose first non-space character is `#` are skipped. Within a line:
/// - Unquoted words end at a space, tab, CR, vertical tab, form feed or NUL. A backslash is a
///   plain character there, and a quote opens a quoted part of the same word (`a"b c"` is `ab c`).
/// - `"…"` reads the escapes `\n \r \t \b \a \\ \"` and `\xHH` (two hex digits, any byte);
///   any other escaped character stands for itself (`\q` is `q`). A `\x` without two hex digits
///   is refused: the command-line client would read it as the letter `x` and send other bytes
///   than the ones the text seems to name.
/// - `'…'` reads only `\'` as an escape; everything else, backslashes included, is literal.
/// - A closing quote must be followed by whitespace or the end of the line.
/// A quote never spans lines. Any error refuses the whole text: no command is returned.
/// Everything works on UTF-8 bytes, so Unicode text is sent exactly as typed (no normalization).
nonisolated enum RedisTokenizer {

  nonisolated enum TokenizeError: Error, Equatable, Sendable, LocalizedError {
    /// A quote is not closed before the end of its line
    case unterminatedQuote(line: Int)
    /// A closing quote is followed by something other than whitespace or the end of the line
    case quoteNotFollowedBySpace(line: Int)
    /// `\x` inside double quotes is not followed by two hex digits
    case invalidHexEscape(line: Int)

    var errorDescription: String? {
      switch self {
      case .unterminatedQuote(let line):
        "Line \(line): a quote is not closed before the end of the line."
      case .quoteNotFollowedBySpace(let line):
        "Line \(line): a closing quote must be followed by a space or the end of the line."
      case .invalidHexEscape(let line):
        "Line \(line): \\x must be followed by two hex digits, such as \\x0a."
      }
    }
  }

  /// The argument arrays of `text`, one per command line, with the exact bytes each argument
  /// stands for. Line numbers in errors start at 1.
  static func tokenize(_ text: String) throws(TokenizeError) -> [[Data]] {
    var commands: [[Data]] = []
    let lines = Array(text.utf8).split(separator: lf, omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      let line = Array(line)
      guard let first = line.first(where: { !isSpace($0) }), first != hash else { continue }
      commands.append(try arguments(of: line, lineNumber: index + 1))
    }
    return commands
  }

  /// Command text that `tokenize` reads back as exactly `args` (one line). An argument is
  /// written bare when that is unambiguous, else in double quotes: when it is empty, holds a
  /// space, control character, quote or backslash, is not valid UTF-8 (each byte from 0x80 is
  /// then `\xHH`), or is the first argument and starts with `#` (a comment line).
  /// An empty array renders as "", which is no command.
  static func render(_ args: [Data]) -> String {
    args.enumerated().map { index, argument in
      let text = utf8Text(argument)
      let needsQuotes =
        argument.isEmpty || text == nil || (index == 0 && argument.first == hash)
        || argument.contains(where: forcesQuotes)
      if !needsQuotes, let text { return text }
      return "\"" + escaped(argument, keepsUTF8: text != nil, escapesQuote: true) + "\""
    }
    .joined(separator: " ")
  }

  /// A one-line, human-readable label of `bytes` for the UI and logs: valid UTF-8 shows as text,
  /// a backslash as `\\`, CR, LF and tab as `\r \n \t`, other control bytes (and every byte from
  /// 0x80 when the bytes are not valid UTF-8) as `\xHH`. Display only: two different byte strings
  /// can share a label; only `render` is read back.
  static func label(_ bytes: Data) -> String {
    escaped(bytes, keepsUTF8: utf8Text(bytes) != nil, escapesQuote: false)
  }

  // MARK: - Scanning

  private static let lf: UInt8 = 0x0A
  private static let hash = UInt8(ascii: "#")
  private static let dquote = UInt8(ascii: "\"")
  private static let squote = UInt8(ascii: "'")
  private static let backslash = UInt8(ascii: "\\")

  /// Space, tab, CR, vertical tab, form feed and NUL end an unquoted word
  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0B || byte == 0x0C || byte == 0x00
  }

  /// The arguments of one non-blank, non-comment line (without its LF)
  private static func arguments(of line: [UInt8], lineNumber: Int) throws(TokenizeError) -> [Data] {
    var args: [Data] = []
    var index = 0
    while true {
      while index < line.count, isSpace(line[index]) { index += 1 }
      guard index < line.count else { return args }
      var current: [UInt8] = []
      while index < line.count, !isSpace(line[index]) {
        switch line[index] {
        case dquote:
          index = try readDoubleQuoted(
            line, from: index + 1, into: &current, lineNumber: lineNumber)
        case squote:
          index = try readSingleQuoted(
            line, from: index + 1, into: &current, lineNumber: lineNumber)
        default:
          current.append(line[index])
          index += 1
        }
      }
      args.append(Data(current))
    }
  }

  /// Reads a `"…"` body starting after the opening quote; returns the index after the closing one
  private static func readDoubleQuoted(
    _ line: [UInt8], from start: Int, into current: inout [UInt8], lineNumber: Int
  ) throws(TokenizeError) -> Int {
    var index = start
    while index < line.count {
      let byte = line[index]
      if byte == backslash, index + 1 < line.count {
        let escape = line[index + 1]
        if escape == UInt8(ascii: "x") {
          guard index + 3 < line.count, let high = hexValue(line[index + 2]),
            let low = hexValue(line[index + 3])
          else { throw .invalidHexEscape(line: lineNumber) }
          current.append(high << 4 | low)
          index += 4
        } else {
          current.append(unescaped(escape))
          index += 2
        }
      } else if byte == dquote {
        return try closingQuote(in: line, at: index, lineNumber: lineNumber)
      } else {
        current.append(byte)
        index += 1
      }
    }
    throw .unterminatedQuote(line: lineNumber)
  }

  /// Reads a `'…'` body starting after the opening quote; returns the index after the closing one
  private static func readSingleQuoted(
    _ line: [UInt8], from start: Int, into current: inout [UInt8], lineNumber: Int
  ) throws(TokenizeError) -> Int {
    var index = start
    while index < line.count {
      let byte = line[index]
      if byte == backslash, index + 1 < line.count, line[index + 1] == squote {
        current.append(squote)
        index += 2
      } else if byte == squote {
        return try closingQuote(in: line, at: index, lineNumber: lineNumber)
      } else {
        current.append(byte)
        index += 1
      }
    }
    throw .unterminatedQuote(line: lineNumber)
  }

  /// The index after the closing quote at `index`, which must end the word
  private static func closingQuote(
    in line: [UInt8], at index: Int, lineNumber: Int
  ) throws(TokenizeError) -> Int {
    let next = index + 1
    guard next == line.count || isSpace(line[next]) else {
      throw .quoteNotFollowedBySpace(line: lineNumber)
    }
    return next
  }

  /// The byte of a one-letter escape in double quotes; an unknown letter stands for itself
  private static func unescaped(_ letter: UInt8) -> UInt8 {
    switch letter {
    case UInt8(ascii: "n"): 0x0A
    case UInt8(ascii: "r"): 0x0D
    case UInt8(ascii: "t"): 0x09
    case UInt8(ascii: "b"): 0x08
    case UInt8(ascii: "a"): 0x07
    default: letter
    }
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }

  // MARK: - Rendering

  /// Space, control characters, quotes and backslash make an argument quoted
  private static func forcesQuotes(_ byte: UInt8) -> Bool {
    byte <= 0x20 || byte == 0x7F || byte == dquote || byte == squote || byte == backslash
  }

  /// `bytes` as text when they are valid UTF-8 (decoding gives back the same bytes), else nil
  private static func utf8Text(_ bytes: Data) -> String? {
    guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
      return nil
    }
    return text
  }

  /// `bytes` with backslash, control characters and (unless `keepsUTF8`) bytes from 0x80
  /// escaped as `tokenize` reads them inside double quotes; `"` too when `escapesQuote`
  private static func escaped(_ bytes: Data, keepsUTF8: Bool, escapesQuote: Bool) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for byte in bytes {
      switch byte {
      case backslash: out += [backslash, backslash]
      case dquote where escapesQuote: out += [backslash, dquote]
      case 0x0A: out += Array(#"\n"#.utf8)
      case 0x0D: out += Array(#"\r"#.utf8)
      case 0x09: out += Array(#"\t"#.utf8)
      case 0x00..<0x20, 0x7F: out += hexEscape(byte)
      case 0x80... where !keepsUTF8: out += hexEscape(byte)
      default: out.append(byte)
      }
    }
    // Valid UTF-8: ASCII escapes plus the raw bytes of a valid UTF-8 argument
    return String(decoding: out, as: UTF8.self)
  }

  private static func hexEscape(_ byte: UInt8) -> [UInt8] {
    let digits = Array("0123456789abcdef".utf8)
    return [backslash, UInt8(ascii: "x"), digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
  }
}
