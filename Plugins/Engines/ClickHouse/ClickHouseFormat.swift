// ClickHouseFormat.swift
// The reply format of the ClickHouse engine: JSONCompactEachRowWithNamesAndTypes, one JSON array
// per line (names, then types, then one line per row), read as raw tokens so no digit is lost.
//
// Cells by type (Nullable and LowCardinality unwrapped first):
// - Int8...Int32, UInt8...UInt32 → int; Int64 / UInt64 (quoted by the server) → int when they fit
//   in `Int`, else decimal text (UInt64 above `Int.max`); Int128 / Int256 / UInt128 / UInt256 and
//   Decimal → decimal text.
// - Float32 / Float64 → double (inf and nan arrive quoted); Bool → bool.
// - DateTime / DateTime64 → an ISO-8601 instant (`date_time_output_format=iso`, UTC).
// - Array, Map, Tuple, Nested, JSON, Object, Variant, Dynamic → json (the raw JSON text).
// - Everything else (String, FixedString, UUID, Enum, Date, IPv4, ...) → text.
//
// An exception the server writes into the body after rows (it has sent 200 by then) fails the
// query with the server's text: a line that is not an array of the column count (plain text, the
// default since server 25.11), or a last row holding only `"Code: N. DB::Exception: ..."` (the
// JSON form servers 23.9 to 25.10 write; a one-column String result whose last value reads like
// that is taken for an exception too).

import Foundation

enum ClickHouseFormat {
  static let name = "JSONCompactEachRowWithNamesAndTypes"

  /// URL settings of every statement
  static let settings: [(String, String)] = [
    ("default_format", name),
    ("date_time_output_format", "iso"),
    ("output_format_json_quote_64bit_integers", "1"),
    ("output_format_json_quote_decimals", "1"),
    ("output_format_json_quote_denormals", "1"),
  ]

  /// The largest server error text kept (the rest of the body is dropped)
  static let maxErrorBytes = 16 << 10

  // MARK: Types

  /// How a column's values become cells
  enum Kind: Equatable, Sendable {
    case int, wideInt, decimal, double, bool, instant, json, text
  }

  /// `type` without its Nullable / LowCardinality wrappers
  static func unwrapped(_ type: String) -> String {
    var type = Substring(type.trimmingCharacters(in: .whitespaces))
    while true {
      var stripped = false
      for wrapper in ["Nullable(", "LowCardinality("]
      where type.hasPrefix(wrapper) && type.hasSuffix(")") {
        type = type.dropFirst(wrapper.count).dropLast()
        stripped = true
      }
      if !stripped { return String(type) }
    }
  }

  /// Whether the column holds NULLs
  static func isNullable(_ type: String) -> Bool {
    var type = Substring(type.trimmingCharacters(in: .whitespaces))
    while type.hasPrefix("LowCardinality(") && type.hasSuffix(")") {
      type = type.dropFirst("LowCardinality(".count).dropLast()
    }
    return type.hasPrefix("Nullable(")
  }

  static func kind(of type: String) -> Kind {
    let type = unwrapped(type)
    let base = type.prefix { $0 != "(" }
    switch base {
    case "Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32": return .int
    case "Int64", "UInt64": return .wideInt
    case "Int128", "Int256", "UInt128", "UInt256": return .decimal
    case "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256": return .decimal
    case "Float32", "Float64", "BFloat16": return .double
    case "Bool", "Boolean": return .bool
    case "DateTime", "DateTime64": return .instant
    case "Array", "Map", "Tuple", "Nested", "JSON", "Object", "Variant", "Dynamic": return .json
    default: return .text
    }
  }

  // MARK: Rows

  /// One JSON value of a row line, as sent
  enum Token: Equatable, Sendable {
    /// A string, unescaped
    case string(String)
    /// `null`
    case null
    /// A number, `true` or `false`, as written
    case literal(String)
    /// An array or object, as written
    case nested(String)
  }

  /// The values of one line holding a JSON array; nil when the line is anything else
  static func tokens(of line: Data) -> [Token]? {
    line.withUnsafeBytes { raw -> [Token]? in
      var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self))
      return scanner.array()
    }
  }

  /// The cell of `token` in a column of `kind`. A value that does not read as its kind (a type
  /// this table does not know well) is kept as text.
  static func cell(_ token: Token, kind: Kind) -> EngineCell {
    switch token {
    case .null: return .null
    case .nested(let json): return .json(json)
    case .string(let text):
      switch kind {
      case .int, .wideInt: return Int(text).map(EngineCell.int) ?? decimal(text) ?? .text(text)
      case .decimal: return decimal(text) ?? .text(text)
      case .double: return Double(floatText: text).map(EngineCell.double) ?? .text(text)
      case .bool: return Bool(text).map(EngineCell.bool) ?? .text(text)
      case .instant: return .date(text)
      case .json: return .json(jsonString(text))
      case .text: return .text(text)
      }
    case .literal(let text):
      switch kind {
      case .int, .wideInt: return Int(text).map(EngineCell.int) ?? decimal(text) ?? .text(text)
      case .decimal: return decimal(text) ?? .text(text)
      case .double: return Double(text).map(EngineCell.double) ?? .text(text)
      case .bool: return Bool(text).map(EngineCell.bool) ?? .text(text)
      case .json: return .json(text)
      case .instant, .text: return .text(text)
      }
    }
  }

  /// Decimal text (`-12.5`, `1e30`), only when it reads as a number
  private static func decimal(_ text: String) -> EngineCell? {
    var digits = 0
    var seenDot = false
    var seenExponent = false
    var previous: UInt8 = 0
    for (index, byte) in text.utf8.enumerated() {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digits += 1
      case UInt8(ascii: "-"), UInt8(ascii: "+"):
        guard index == 0 || previous == UInt8(ascii: "e") || previous == UInt8(ascii: "E")
        else { return nil }
      case UInt8(ascii: "."):
        guard !seenDot, !seenExponent, digits > 0 else { return nil }
        seenDot = true
      case UInt8(ascii: "e"), UInt8(ascii: "E"):
        guard !seenExponent, digits > 0 else { return nil }
        seenExponent = true
      default: return nil
      }
      previous = byte
    }
    guard digits > 0, previous >= UInt8(ascii: "0") && previous <= UInt8(ascii: "9") else {
      return nil
    }
    return .decimal(text)
  }

  /// A JSON-typed column's string value as JSON text
  private static func jsonString(_ text: String) -> String {
    guard let data = try? JSONEncoder().encode(text) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Errors

  /// The server's error text in a body (a failed status, or a line that broke the rows): the
  /// `Code: N.` number as `serverCode`, the exception markers of newer servers removed
  static func failure(fromBody body: Data, headerCode: String?) -> EngineFailure {
    let text = String(decoding: body.prefix(maxErrorBytes), as: UTF8.self)
    let lines = text.split(whereSeparator: \.isNewline).map { line in
      // JSON formats may write the exception as `{"exception": "..."}`
      if line.hasPrefix("{"),
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let exception = object["exception"] as? String
      {
        return exception.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return line.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && $0 != "__exception__" && !isExceptionTag($0) }
    let message = lines.joined(separator: "\n")
    let code = headerCode ?? serverCode(in: message)
    return EngineFailure(
      code: .query, message: message.isEmpty ? "The server refused the statement." : message,
      serverCode: code)
  }

  /// Whether `text` reads as a server exception (`Code: N. DB::Exception: ...`)
  static func isException(_ text: String) -> Bool {
    text.hasPrefix("Code: ") && text.contains("DB::Exception")
  }

  /// The N of `Code: N.`
  static func serverCode(in text: String) -> String? {
    guard let range = text.range(of: #"Code: [0-9]+"#, options: .regularExpression) else {
      return nil
    }
    return String(text[range].dropFirst("Code: ".count))
  }

  /// A random tag line (or `<length> <tag>`) of the exception block newer servers write
  private static func isExceptionTag(_ line: String) -> Bool {
    line.range(of: #"\A([0-9]+ )?[A-Za-z0-9]{16}\z"#, options: .regularExpression) != nil
  }
}

extension Double {
  /// A JSON-quoted float: `inf`, `-inf`, `nan` (any sign) and plain numbers
  fileprivate init?(floatText text: String) {
    switch text.lowercased() {
    case "inf", "+inf": self = .infinity
    case "-inf": self = -.infinity
    case "nan", "+nan", "-nan": self = .nan
    default:
      guard let value = Double(text) else { return nil }
      self = value
    }
  }
}

// MARK: - Scanner

/// Reads one line holding a JSON array into raw tokens
private struct Scanner {
  let bytes: UnsafeBufferPointer<UInt8>
  var index = 0

  init(bytes: UnsafeBufferPointer<UInt8>) {
    self.bytes = bytes
  }

  mutating func array() -> [ClickHouseFormat.Token]? {
    skipSpace()
    guard next() == UInt8(ascii: "[") else { return nil }
    var tokens: [ClickHouseFormat.Token] = []
    skipSpace()
    if peek() == UInt8(ascii: "]") {
      index += 1
    } else {
      while true {
        skipSpace()
        guard let token = value() else { return nil }
        tokens.append(token)
        skipSpace()
        let separator = next()
        if separator == UInt8(ascii: "]") { break }
        guard separator == UInt8(ascii: ",") else { return nil }
      }
    }
    skipSpace()
    return index == bytes.count ? tokens : nil
  }

  private mutating func value() -> ClickHouseFormat.Token? {
    switch peek() {
    case UInt8(ascii: "\""): return string().map(ClickHouseFormat.Token.string)
    case UInt8(ascii: "["), UInt8(ascii: "{"):
      let start = index
      guard skipNested() else { return nil }
      return .nested(text(start..<index))
    case nil: return nil
    default:
      let start = index
      while let byte = peek(), byte != UInt8(ascii: ","), byte != UInt8(ascii: "]"),
        !Self.isSpace(byte)
      {
        index += 1
      }
      guard index > start else { return nil }
      let literal = text(start..<index)
      return literal == "null" ? .null : .literal(literal)
    }
  }

  /// A balanced array or object, strings skipped whole
  private mutating func skipNested() -> Bool {
    var depth = 0
    while let byte = next() {
      switch byte {
      case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
      case UInt8(ascii: "]"), UInt8(ascii: "}"):
        depth -= 1
        if depth == 0 { return true }
      case UInt8(ascii: "\""):
        index -= 1
        guard skipString() else { return false }
      default: break
      }
    }
    return false
  }

  private mutating func skipString() -> Bool {
    index += 1
    while let byte = next() {
      if byte == UInt8(ascii: "\\") {
        guard next() != nil else { return false }
      } else if byte == UInt8(ascii: "\"") {
        return true
      }
    }
    return false
  }

  /// A string, unescaped. Bytes that are not UTF-8 are replaced.
  private mutating func string() -> String? {
    index += 1
    var out: [UInt8] = []
    while let byte = next() {
      switch byte {
      case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard let escaped = next() else { return nil }
        switch escaped {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
          guard var scalar = hex4() else { return nil }
          // A surrogate pair is one scalar; a lone surrogate becomes U+FFFD
          if (0xD800...0xDBFF).contains(scalar), peek() == UInt8(ascii: "\\"),
            index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u")
          {
            index += 2
            guard let low = hex4() else { return nil }
            scalar =
              (0xDC00...0xDFFF).contains(low)
              ? 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) : 0xFFFD
          }
          out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
        default: return nil
        }
      default: out.append(byte)
      }
    }
    return nil
  }

  private mutating func hex4() -> UInt32? {
    guard index + 4 <= bytes.count else { return nil }
    let text = String(
      decoding: UnsafeBufferPointer(rebasing: bytes[index..<index + 4]), as: UTF8.self)
    index += 4
    return UInt32(text, radix: 16)
  }

  private func text(_ range: Range<Int>) -> String {
    String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
  }

  private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

  private mutating func next() -> UInt8? {
    guard index < bytes.count else { return nil }
    defer { index += 1 }
    return bytes[index]
  }

  private mutating func skipSpace() {
    while let byte = peek(), Self.isSpace(byte) { index += 1 }
  }

  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
  }
}
