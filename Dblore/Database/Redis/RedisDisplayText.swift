// RedisDisplayText.swift
// Server text escaped for display only (the reply view's Grid and Raw text). On top of the
// escapes of `RedisTokenizer.label`, a scalar from U+0080 that is a control, format, line or
// paragraph separator character (C1 controls and NEL, bidi controls, zero-width characters,
// U+2028 / U+2029) or default ignorable (Hangul fillers, CGJ, variation selectors but a non-ASCII
// emoji's text / emoji presentation one, unassigned ignorables) shows as `\u{XXXX}`, so a value can
// neither break a line nor hide or reorder its text. Logs and command round-trips keep using
// `RedisTokenizer`.

import Foundation

nonisolated enum RedisDisplayText {
  /// `string` as one line: a backslash as `\\`, LF, CR and tab as `\n \r \t`, other ASCII
  /// control characters as `\xHH`, invisible or line-breaking scalars as `\u{XXXX}`. Bytes that
  /// are not UTF-8 show every byte from 0x80 as `\xHH`, even when a cut prefix of them decodes.
  static func line(_ string: RedisReplyString) -> String {
    var out = String.UnicodeScalarView()
    switch string {
    case .text(let text):
      var previous: Unicode.Scalar?
      for scalar in text.unicodeScalars {
        appendEscaped(scalar, after: previous, to: &out)
        previous = scalar
      }
    case .bytes(let bytes):
      for byte in bytes {
        if byte < 0x80 {
          appendEscaped(Unicode.Scalar(byte), after: nil, to: &out)
        } else {
          appendHex(byte, to: &out)
        }
      }
    }
    return String(out)
  }

  /// `text` with its line breaks: LF stays, CRLF becomes LF, tab and backslash stay; every other
  /// character `line` escapes (a lone CR included) is escaped as there.
  static func lines(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    var pendingReturn = false
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      defer { previous = scalar }
      if pendingReturn {
        pendingReturn = false
        if scalar != "\n" { out.append(contentsOf: #"\r"#.unicodeScalars) }
      }
      switch scalar {
      case "\r": pendingReturn = true
      case "\n", "\t", "\\": out.append(scalar)
      default: appendEscaped(scalar, after: previous, to: &out)
      }
    }
    if pendingReturn { out.append(contentsOf: #"\r"#.unicodeScalars) }
    return String(out)
  }

  // MARK: - Private

  /// `previous` is the scalar before `scalar`, which decides whether a presentation selector shows
  private static func appendEscaped(
    _ scalar: Unicode.Scalar, after previous: Unicode.Scalar?,
    to out: inout String.UnicodeScalarView
  ) {
    switch scalar.value {
    case 0x5C: out.append(contentsOf: #"\\"#.unicodeScalars)
    case 0x0A: out.append(contentsOf: #"\n"#.unicodeScalars)
    case 0x0D: out.append(contentsOf: #"\r"#.unicodeScalars)
    case 0x09: out.append(contentsOf: #"\t"#.unicodeScalars)
    case 0x00..<0x20, 0x7F: appendHex(UInt8(scalar.value), to: &out)
    case 0x80... where isInvisible(scalar, after: previous):
      let digits = String(scalar.value, radix: 16, uppercase: true)
      let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
      out.append(contentsOf: #"\u{"#.unicodeScalars)
      out.append(contentsOf: padded.unicodeScalars)
      out.append("}")
    default: out.append(scalar)
    }
  }

  /// Controls (C1, NEL), format characters (bidi controls, zero-width characters, BOM), the
  /// line and paragraph separators, and default ignorable scalars but U+FE0E / U+FE0F right
  /// after a non-ASCII emoji, where they pick its text or emoji presentation (elsewhere they draw
  /// nothing; digits, `#` and `*` count as emoji, so a keycap shows its selector escaped)
  private static func isInvisible(
    _ scalar: Unicode.Scalar, after previous: Unicode.Scalar?
  ) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator: return true
    default:
      guard scalar.properties.isDefaultIgnorableCodePoint else { return false }
      let picksPresentation = scalar.value == 0xFE0E || scalar.value == 0xFE0F
      guard picksPresentation, let previous, previous.value >= 0x80 else { return true }
      return !previous.properties.isEmoji
    }
  }

  private static func appendHex(_ byte: UInt8, to out: inout String.UnicodeScalarView) {
    let digits = Array("0123456789abcdef".unicodeScalars)
    out.append(contentsOf: [
      "\\", "x", digits[Int(byte >> 4)], digits[Int(byte & 0x0F)],
    ])
  }
}
