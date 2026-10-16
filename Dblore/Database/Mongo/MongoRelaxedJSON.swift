// MongoRelaxedJSON.swift
// Parses relaxed JSON (mongosh literals and canonical Extended JSON wrappers) into `MongoValue`,
// and renders `MongoValue` as canonical Extended JSON, relaxed Extended JSON or mongosh notation.
// Pure Swift: never runs JavaScript and never touches the driver.

import Foundation

/// Relaxed JSON for MongoDB values.
///
/// Accepted syntax: JSON plus unquoted keys (`[A-Za-z_$][A-Za-z0-9_$]*`), single-quoted strings,
/// trailing commas, `//` and `/* */` comments, `Infinity`/`-Infinity`/`NaN`, regex literals
/// `/pattern/flags`, the mongosh helpers `ObjectId`, `ISODate`, `new Date`, `NumberLong`,
/// `NumberInt`, `NumberDecimal`, `Timestamp`, `BinData`, `RegExp`, `MinKey`, `MaxKey`, and the
/// canonical Extended JSON wrappers (`$oid`, `$date`, `$numberLong`, ...). A wrapper is recognised
/// only when the object has exactly the wrapper's keys; any other object is a plain document.
///
/// Number typing: an integer literal is int32 when it fits, else int64, else double; a literal
/// with a fraction or an exponent is a double. mongosh reads every plain number as a double;
/// Dblore keeps integers, so `{qty: 5}` stores an int32, not a double.
///
/// Formats: canonical Extended JSON and mongosh notation round-trip exactly
/// (`parse(render(x)) == x`, keeping int32 vs int64 vs double). Relaxed Extended JSON is for
/// display and copy only: int64 and dates lose their type, so it is never stored or edited.
nonisolated enum MongoRelaxedJSON {
  static let maxDepth = 100
  /// Input limit in UTF-8 bytes.
  static let maxInputBytes = 1_048_576

  nonisolated enum Format: Sendable {
    /// Extended JSON v2 canonical: every number wrapped, `$date` as `{$numberLong}`.
    case canonicalExtendedJSON
    /// Extended JSON v2 relaxed: plain numbers, `$date` as an ISO string from 1970 to 9999.
    case relaxedExtendedJSON
    /// mongosh shell notation (`ObjectId("…")`, `NumberLong("…")`, `ISODate("…")`, ...).
    case mongosh
  }

  /// A parse failure. `offset` counts UTF-16 code units from the start of the text (the unit of
  /// `NSRange` in text views).
  nonisolated struct ParseError: Error, Equatable, Sendable, LocalizedError {
    let message: String
    let offset: Int

    var errorDescription: String? { message }
  }

  static func parse(_ text: String) throws(ParseError) -> MongoValue {
    guard text.utf8.count <= maxInputBytes else {
      throw ParseError(message: "The text is larger than 1 MiB", offset: 0)
    }
    var parser = Parser(text: text)
    return try parser.parseAll()
  }

  /// Parses one value at byte `start` of `bytes` (leading whitespace and comments skipped) and
  /// returns it with the byte index just after it. Text after the value is left to the caller.
  /// Error offsets count UTF-16 code units from the start of `bytes`. Used by `MongoshParser`
  /// for command arguments; the caller enforces `maxInputBytes`.
  static func parseValue(
    in bytes: [UInt8], from start: Int
  ) throws(ParseError) -> (value: MongoValue, end: Int) {
    var parser = Parser(bytes: bytes, position: start)
    return try parser.parseOne()
  }

  /// `value` as text in `format`. `indented` writes one key or array element per line with a
  /// 2-space indent (key order kept); empty `{}` / `[]` and Extended JSON wrappers stay inline.
  static func render(_ value: MongoValue, as format: Format, indented: Bool = false) -> String {
    var renderer = Renderer(format: format, indented: indented)
    renderer.write(value)
    return renderer.output
  }
}

// MARK: - Parser

nonisolated extension MongoRelaxedJSON {
  /// Recursive descent over the UTF-8 bytes of the text.
  fileprivate nonisolated struct Parser {
    /// Wrapper payloads (`{$date: {$numberLong}}`) may sit two braces below the deepest document.
    private static let wrapperSlack = 2

    private let bytes: [UInt8]
    private var pos = 0
    /// Byte offset of the first bracket nested deeper than `maxDepth`.
    private var firstTooDeep: Int?

    init(text: String) {
      bytes = Array(text.utf8)
    }

    init(bytes: [UInt8], position: Int) {
      self.bytes = bytes
      pos = position
    }

    mutating func parseAll() throws(ParseError) -> MongoValue {
      let value = try parseValue(depth: 0)
      try skipTrivia()
      guard pos == bytes.count else { throw failure("Unexpected text after the value", at: pos) }
      // Wrapper braces do not count, so the logical depth is checked on the tree.
      if firstTooDeep != nil, value.nestingDepth > MongoRelaxedJSON.maxDepth { throw tooDeep() }
      return value
    }

    /// One value, depth-checked like `parseAll`, without the end-of-text check.
    mutating func parseOne() throws(ParseError) -> (value: MongoValue, end: Int) {
      let value = try parseValue(depth: 0)
      if firstTooDeep != nil, value.nestingDepth > MongoRelaxedJSON.maxDepth { throw tooDeep() }
      return (value, pos)
    }

    // MARK: Errors

    private func failure(_ message: String, at byteOffset: Int) -> ParseError {
      var end = min(byteOffset, bytes.count)
      while end > 0, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
      let offset = String(decoding: bytes[..<end], as: UTF8.self).utf16.count
      return ParseError(message: message, offset: offset)
    }

    private func tooDeep() -> ParseError {
      failure("Nesting is deeper than \(MongoRelaxedJSON.maxDepth) levels", at: firstTooDeep ?? pos)
    }

    // MARK: Trivia and tokens

    private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private mutating func skipTrivia() throws(ParseError) {
      while let byte = peek() {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
          pos += 1
        case UInt8(ascii: "/") where pos + 1 < bytes.count && bytes[pos + 1] == UInt8(ascii: "/"):
          while let next = peek(), next != 0x0A, next != 0x0D { pos += 1 }
        case UInt8(ascii: "/") where pos + 1 < bytes.count && bytes[pos + 1] == UInt8(ascii: "*"):
          let start = pos
          pos += 2
          while pos + 1 < bytes.count,
            !(bytes[pos] == UInt8(ascii: "*") && bytes[pos + 1] == UInt8(ascii: "/"))
          {
            pos += 1
          }
          guard pos + 1 < bytes.count else { throw failure("Unterminated comment", at: start) }
          pos += 2
        default:
          return
        }
      }
    }

    private mutating func take(_ ascii: Unicode.Scalar) -> Bool {
      guard peek() == UInt8(ascii: ascii) else { return false }
      pos += 1
      return true
    }

    private mutating func scanIdentifier() -> String {
      let start = pos
      while let byte = peek(), byte.isIdentifierChar { pos += 1 }
      return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    // MARK: Values

    private mutating func parseValue(depth: Int) throws(ParseError) -> MongoValue {
      try skipTrivia()
      guard let byte = peek() else { throw failure("Expected a value", at: pos) }
      switch byte {
      case UInt8(ascii: "{"): return try parseObject(depth: depth)
      case UInt8(ascii: "["): return try parseArray(depth: depth)
      case UInt8(ascii: "\""), UInt8(ascii: "'"):
        let text = try parseString()
        return .string(text)
      case UInt8(ascii: "/"): return try parseRegexLiteral()
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
      case _ where byte.isIdentifierStart: return try parseWord(depth: depth)
      default: throw failure("Expected a value", at: pos)
      }
    }

    private mutating func enterContainer(depth: Int) throws(ParseError) {
      if depth >= MongoRelaxedJSON.maxDepth, firstTooDeep == nil { firstTooDeep = pos }
      if depth >= MongoRelaxedJSON.maxDepth + Self.wrapperSlack { throw tooDeep() }
      pos += 1
    }

    private mutating func parseObject(depth: Int) throws(ParseError) -> MongoValue {
      let start = pos
      try enterContainer(depth: depth)
      var fields: [MongoValue.Field] = []
      while true {
        try skipTrivia()
        if take("}") { break }
        let key = try parseKey()
        try skipTrivia()
        guard take(":") else { throw failure("Expected ':' after the key", at: pos) }
        let value = try parseValue(depth: depth + 1)
        fields.append(MongoValue.Field(key, value))
        try skipTrivia()
        if take(",") { continue }
        if take("}") { break }
        throw failure("Expected ',' or '}'", at: pos)
      }
      return try wrapper(fields, at: start) ?? .document(fields)
    }

    private mutating func parseKey() throws(ParseError) -> String {
      guard let byte = peek() else { throw failure("Expected a key", at: pos) }
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "'"): return try parseString()
      case _ where byte.isIdentifierStart: return scanIdentifier()
      default: throw failure("Expected a key", at: pos)
      }
    }

    private mutating func parseArray(depth: Int) throws(ParseError) -> MongoValue {
      try enterContainer(depth: depth)
      var items: [MongoValue] = []
      while true {
        try skipTrivia()
        if take("]") { break }
        let item = try parseValue(depth: depth + 1)
        items.append(item)
        try skipTrivia()
        if take(",") { continue }
        if take("]") { break }
        throw failure("Expected ',' or ']'", at: pos)
      }
      return .array(items)
    }

    // MARK: Strings

    private mutating func parseString() throws(ParseError) -> String {
      let start = pos
      let quote = bytes[pos]
      pos += 1
      var output: [UInt8] = []
      var runStart = pos
      while let byte = peek() {
        switch byte {
        case quote:
          output += bytes[runStart..<pos]
          pos += 1
          return String(decoding: output, as: UTF8.self)
        case 0x0A, 0x0D:
          throw failure("Unterminated string", at: start)
        case UInt8(ascii: "\\"):
          output += bytes[runStart..<pos]
          try parseEscape(into: &output)
          runStart = pos
        default:
          pos += 1
        }
      }
      throw failure("Unterminated string", at: start)
    }

    private mutating func parseEscape(into output: inout [UInt8]) throws(ParseError) {
      let start = pos
      pos += 1
      guard let byte = peek() else { throw failure("Unterminated string", at: start) }
      pos += 1
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "\\"), UInt8(ascii: "/"):
        output.append(byte)
      case UInt8(ascii: "b"): output.append(0x08)
      case UInt8(ascii: "f"): output.append(0x0C)
      case UInt8(ascii: "n"): output.append(0x0A)
      case UInt8(ascii: "r"): output.append(0x0D)
      case UInt8(ascii: "t"): output.append(0x09)
      case UInt8(ascii: "u"):
        let scalar = try parseUnicodeEscape(start: start)
        output += Array(String(scalar).utf8)
      default:
        throw failure("Unsupported escape sequence", at: start)
      }
    }

    /// `\uXXXX` (the `\u` already consumed), joining a surrogate pair into one scalar.
    private mutating func parseUnicodeEscape(start: Int) throws(ParseError) -> Unicode.Scalar {
      guard let high = hex4(at: pos) else { throw failure("Invalid \\u escape", at: start) }
      pos += 4
      var value = high
      if (0xD800...0xDBFF).contains(high) {
        guard take("\\"), take("u"), let low = hex4(at: pos), (0xDC00...0xDFFF).contains(low) else {
          throw failure("Unpaired surrogate in \\u escape", at: start)
        }
        pos += 4
        value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
      }
      guard let scalar = Unicode.Scalar(value) else {
        throw failure("Unpaired surrogate in \\u escape", at: start)
      }
      return scalar
    }

    private func hex4(at index: Int) -> UInt32? {
      guard index + 4 <= bytes.count else { return nil }
      let digits = bytes[index..<index + 4]
      guard digits.allSatisfy(\.isASCIIHexDigit) else { return nil }
      return UInt32(String(decoding: digits, as: UTF8.self), radix: 16)
    }

    // MARK: Numbers, words and regex literals

    private mutating func parseNumber() throws(ParseError) -> MongoValue {
      let start = pos
      if bytes[pos] == UInt8(ascii: "-"), pos + 1 < bytes.count, bytes[pos + 1].isIdentifierStart {
        pos += 1
        guard scanIdentifier() == "Infinity" else { throw failure("Invalid number", at: start) }
        return .double(-.infinity)
      }
      guard let lexeme = Lexer.number(in: bytes, from: start) else {
        throw failure("Invalid number", at: start)
      }
      pos = lexeme.end
      if let next = peek(), next.isIdentifierChar || next == UInt8(ascii: ".") {
        throw failure("Invalid number", at: start)
      }
      let text = String(decoding: bytes[start..<pos], as: UTF8.self)
      return Lexer.numberValue(text, isInteger: lexeme.isInteger)
    }

    private mutating func parseRegexLiteral() throws(ParseError) -> MongoValue {
      let start = pos
      guard let end = Lexer.regexLiteralEnd(in: bytes, from: pos + 1) else {
        throw failure("Unterminated regular expression", at: start)
      }
      let pattern = String(decoding: bytes[(pos + 1)..<end], as: UTF8.self)
      pos = end + 1
      let flagsStart = pos
      while let byte = peek(), byte.isASCIILetter { pos += 1 }
      if let next = peek(), next.isIdentifierChar {
        throw failure("Invalid regular expression flags", at: flagsStart)
      }
      let options = String(decoding: bytes[flagsStart..<pos], as: UTF8.self)
      return .regex(pattern: pattern, options: options)
    }

    private static let helperNames: Set<String> = [
      "ObjectId", "ISODate", "NumberLong", "NumberInt", "NumberDecimal", "Timestamp", "BinData",
      "RegExp", "MinKey", "MaxKey",
    ]

    /// Recursive through helper arguments, so the conversion lives in `helper(_:_:at:)`: one
    /// frame per nesting level stays small (Debug frames hold every case's temporaries).
    private mutating func parseWord(depth: Int) throws(ParseError) -> MongoValue {
      let start = pos
      var word = scanIdentifier()
      switch word {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      case "Infinity": return .double(.infinity)
      case "NaN": return .double(.nan)
      case "new":
        try skipTrivia()
        let datePos = pos
        guard scanIdentifier() == "Date" else {
          throw failure("Only new Date(…) is supported", at: datePos)
        }
        word = "new Date"
      default:
        guard Self.helperNames.contains(word) else {
          throw failure("Unknown identifier \(word)", at: start)
        }
      }
      return try helper(word, arguments(depth: depth), at: start)
    }

    private typealias Argument = (value: MongoValue, offset: Int)

    /// Helper arguments nest one level deeper, like brackets: `ObjectId(ObjectId(…` must stop
    /// here, as the helper rejects the inner value before any tree exists to check.
    private mutating func arguments(depth: Int) throws(ParseError) -> [Argument] {
      if depth >= MongoRelaxedJSON.maxDepth + Self.wrapperSlack { throw tooDeep() }
      try skipTrivia()
      guard take("(") else { throw failure("Expected '('", at: pos) }
      var arguments: [Argument] = []
      while true {
        try skipTrivia()
        if take(")") { break }
        let offset = pos
        let value = try parseValue(depth: depth + 1)
        arguments.append((value, offset))
        try skipTrivia()
        if take(",") { continue }
        if take(")") { break }
        throw failure("Expected ',' or ')'", at: pos)
      }
      return arguments
    }
  }
}

// MARK: - mongosh helpers and Extended JSON wrappers

nonisolated extension MongoRelaxedJSON.Parser {
  /// The value of the helper `name` (`new Date` included) called with `arguments`.
  private func helper(
    _ name: String, _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    switch name {
    case "new Date": return try newDate(arguments, at: start)
    case "ObjectId": return try objectId(arguments, at: start)
    case "ISODate": return try isoDate(arguments, at: start)
    case "NumberLong": return try numberLong(arguments, at: start)
    case "NumberInt": return try numberInt(arguments, at: start)
    case "NumberDecimal": return try numberDecimal(arguments, at: start)
    case "Timestamp": return try timestamp(arguments, at: start)
    case "BinData": return try binData(arguments, at: start)
    case "RegExp": return try regExp(arguments, at: start)
    case "MinKey", "MaxKey":
      guard arguments.isEmpty else { throw failure("\(name)() takes no arguments", at: start) }
      return name == "MinKey" ? .minKey : .maxKey
    default:
      throw failure("Unknown identifier \(name)", at: start)
    }
  }

  private func onlyArgument(
    _ arguments: [Argument], _ name: String, at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> Argument
  {
    guard arguments.count == 1 else { throw failure("\(name) takes one argument", at: start) }
    return arguments[0]
  }

  private func objectId(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "ObjectId", at: start)
    guard case .string(let hex) = argument.value, let id = MongoObjectId(hex: hex) else {
      throw failure("ObjectId needs a 24-character hex string", at: argument.offset)
    }
    return .objectId(id)
  }

  private func isoDate(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "ISODate", at: start)
    guard case .string(let text) = argument.value, let millis = MongoDateText.millis(from: text)
    else { throw failure("ISODate needs an ISO 8601 date string", at: argument.offset) }
    return .date(millis)
  }

  private func newDate(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "new Date", at: start)
    switch argument.value {
    case .string(let text):
      if let millis = MongoDateText.millis(from: text) { return .date(millis) }
    case .int32, .int64:
      if let millis = argument.value.integer { return .date(millis) }
    default:
      break
    }
    throw failure(
      "new Date needs an ISO 8601 string or integer milliseconds", at: argument.offset)
  }

  private func numberLong(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "NumberLong", at: start)
    if let value = argument.value.integer ?? argument.value.integerText.flatMap({ Int64($0) }) {
      return .int64(value)
    }
    throw failure("NumberLong needs a 64-bit integer", at: argument.offset)
  }

  private func numberInt(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "NumberInt", at: start)
    if let value = argument.value.integer.flatMap({ Int32(exactly: $0) })
      ?? argument.value.integerText.flatMap({ Int32($0) })
    {
      return .int32(value)
    }
    throw failure("NumberInt needs a 32-bit integer", at: argument.offset)
  }

  private func numberDecimal(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let argument = try onlyArgument(arguments, "NumberDecimal", at: start)
    guard case .string(let text) = argument.value, MongoRelaxedJSON.Lexer.isDecimal(text) else {
      throw failure("NumberDecimal needs a decimal number string", at: argument.offset)
    }
    return .decimal128(text)
  }

  private func timestamp(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    if arguments.count == 2, let t = arguments[0].value.uint32, let i = arguments[1].value.uint32 {
      return .timestamp(t: t, i: i)
    }
    if arguments.count == 1, case .document(let fields) = arguments[0].value,
      let parts = fields.exactly(["t", "i"]), let t = parts["t"]?.uint32, let i = parts["i"]?.uint32
    {
      return .timestamp(t: t, i: i)
    }
    throw failure("Timestamp needs two unsigned 32-bit integers (t, i)", at: start)
  }

  private func binData(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    guard arguments.count == 2,
      let subtype = arguments[0].value.integer.flatMap({ UInt8(exactly: $0) }),
      case .string(let base64) = arguments[1].value, let data = Data(base64Encoded: base64)
    else { throw failure("BinData needs a subtype (0-255) and a base64 string", at: start) }
    return .binary(subtype: subtype, data: data)
  }

  private func regExp(
    _ arguments: [Argument], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue
  {
    let strings = arguments.compactMap { argument -> String? in
      if case .string(let text) = argument.value { return text }
      return nil
    }
    guard strings.count == arguments.count, (1...2).contains(strings.count) else {
      throw failure("RegExp needs a pattern string and an optional options string", at: start)
    }
    return .regex(pattern: strings[0], options: strings.count == 2 ? strings[1] : "")
  }

  /// The value an Extended JSON wrapper stands for, nil for a plain document.
  func wrapper(
    _ fields: [MongoValue.Field], at start: Int
  )
    throws(MongoRelaxedJSON.ParseError) -> MongoValue?
  {
    guard fields.count == 1, fields[0].key.hasPrefix("$") else { return nil }
    let key = fields[0].key
    let value = fields[0].value
    let result: MongoValue?
    switch key {
    case "$oid": result = value.string.flatMap(MongoObjectId.init(hex:)).map(MongoValue.objectId)
    case "$date": result = dateWrapper(value)
    case "$numberLong": result = value.integerText.flatMap { Int64($0) }.map(MongoValue.int64)
    case "$numberInt": result = value.integerText.flatMap { Int32($0) }.map(MongoValue.int32)
    case "$numberDouble": result = value.string.flatMap(MongoRelaxedJSON.Lexer.double(from:))
    case "$numberDecimal":
      result = value.string.flatMap {
        MongoRelaxedJSON.Lexer.isDecimal($0) ? MongoValue.decimal128($0) : nil
      }
    case "$binary": result = binaryWrapper(value)
    case "$regularExpression": result = regexWrapper(value)
    case "$timestamp": result = timestampWrapper(value)
    case "$minKey": result = value == .int32(1) ? .minKey : nil
    case "$maxKey": result = value == .int32(1) ? .maxKey : nil
    default: return nil
    }
    guard let result else { throw failure("Invalid \(key) value", at: start) }
    return result
  }

  private func dateWrapper(_ value: MongoValue) -> MongoValue? {
    switch value {
    case .int64(let millis): .date(millis)
    case .string(let text): MongoDateText.millis(from: text).map(MongoValue.date)
    default: nil
    }
  }

  private func binaryWrapper(_ value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value, let parts = fields.exactly(["base64", "subType"]),
      let base64 = parts["base64"]?.string, let data = Data(base64Encoded: base64),
      let subType = parts["subType"]?.string, (1...2).contains(subType.utf8.count),
      subType.utf8.allSatisfy(\.isASCIIHexDigit), let subtype = UInt8(subType, radix: 16)
    else { return nil }
    return .binary(subtype: subtype, data: data)
  }

  private func regexWrapper(_ value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value, let parts = fields.exactly(["pattern", "options"]),
      let pattern = parts["pattern"]?.string, let options = parts["options"]?.string
    else { return nil }
    return .regex(pattern: pattern, options: options)
  }

  private func timestampWrapper(_ value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value, let parts = fields.exactly(["t", "i"]),
      let t = parts["t"]?.uint32, let i = parts["i"]?.uint32
    else { return nil }
    return .timestamp(t: t, i: i)
  }
}

nonisolated extension MongoValue {
  fileprivate var string: String? {
    if case .string(let text) = self { return text }
    return nil
  }

  /// An int32 or int64 value (never a double).
  fileprivate var integer: Int64? {
    switch self {
    case .int32(let value): Int64(value)
    case .int64(let value): value
    default: nil
    }
  }

  fileprivate var uint32: UInt32? { integer.flatMap { UInt32(exactly: $0) } }

  /// A string holding only an optional `-` and digits.
  fileprivate var integerText: String? {
    guard let text = string,
      let lexeme = MongoRelaxedJSON.Lexer.number(in: Array(text.utf8), from: 0),
      lexeme.isInteger, lexeme.end == text.utf8.count
    else { return nil }
    return text
  }
}

nonisolated extension [MongoValue.Field] {
  /// The fields by key when the keys are exactly `keys` (any order, no duplicates).
  fileprivate func exactly(_ keys: Set<String>) -> [String: MongoValue]? {
    guard count == keys.count, Set(map(\.key)) == keys else { return nil }
    return Dictionary(uniqueKeysWithValues: map { ($0.key, $0.value) })
  }
}

// MARK: - Lexical helpers

nonisolated extension MongoRelaxedJSON {
  nonisolated enum Lexer {
    /// The longest JSON number (`-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`) at `start`.
    static func number(in bytes: [UInt8], from start: Int) -> (end: Int, isInteger: Bool)? {
      var index = start
      func digits() -> Int {
        let first = index
        while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
        return index - first
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
      let integerStart = index
      let integerDigits = digits()
      guard integerDigits > 0, integerDigits == 1 || bytes[integerStart] != UInt8(ascii: "0") else {
        return nil
      }
      var isInteger = true
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        isInteger = false
        guard digits() > 0 else { return nil }
      }
      if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
        index += 1
        isInteger = false
        if index < bytes.count,
          bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
        {
          index += 1
        }
        guard digits() > 0 else { return nil }
      }
      return (index, isInteger)
    }

    /// int32 if it fits, else int64, else double, for an integer literal; double otherwise.
    static func numberValue(_ text: String, isInteger: Bool) -> MongoValue {
      if isInteger {
        if let value = Int32(text) { return .int32(value) }
        if let value = Int64(text) { return .int64(value) }
      }
      return .double(Double(text) ?? .nan)
    }

    /// A `$numberDouble` string: `Infinity`, `-Infinity`, `NaN`, or a JSON number.
    static func double(from text: String) -> MongoValue? {
      switch text {
      case "Infinity": return .double(.infinity)
      case "-Infinity": return .double(-.infinity)
      case "NaN": return .double(.nan)
      default:
        let bytes = Array(text.utf8)
        guard let lexeme = number(in: bytes, from: 0), lexeme.end == bytes.count else { return nil }
        return .double(Double(text) ?? .nan)
      }
    }

    /// Decimal128 text syntax: `[+-]?(digits[.digits?] | .digits)([eE][+-]?digits)?`, or a
    /// signed `Inf`, `Infinity` or `NaN` in any case. Range and precision are not checked here.
    static func isDecimal(_ text: String) -> Bool {
      var bytes = Array(text.utf8)[...]
      if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
        bytes = bytes.dropFirst()
      }
      let word = String(decoding: bytes, as: UTF8.self).lowercased()
      if ["inf", "infinity", "nan"].contains(word) { return true }
      let integerDigits = bytes.prefix(while: \.isASCIIDigit).count
      bytes = bytes.dropFirst(integerDigits)
      var fractionDigits = 0
      if bytes.first == UInt8(ascii: ".") {
        bytes = bytes.dropFirst()
        fractionDigits = bytes.prefix(while: \.isASCIIDigit).count
        bytes = bytes.dropFirst(fractionDigits)
      }
      guard integerDigits + fractionDigits > 0 else { return false }
      if let marker = bytes.first, marker | 0x20 == UInt8(ascii: "e") {
        bytes = bytes.dropFirst()
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
          bytes = bytes.dropFirst()
        }
        let exponentDigits = bytes.prefix(while: \.isASCIIDigit).count
        guard exponentDigits > 0 else { return false }
        bytes = bytes.dropFirst(exponentDigits)
      }
      return bytes.isEmpty
    }

    /// Index of the `/` that closes a regex literal whose pattern starts at `start`: `\` escapes
    /// the next character and `/` inside `[...]` does not close it. Nil at a line break or the end.
    static func regexLiteralEnd(in bytes: [UInt8], from start: Int) -> Int? {
      var index = start
      var inClass = false
      while index < bytes.count {
        switch bytes[index] {
        case 0x0A, 0x0D:
          return nil
        case UInt8(ascii: "\\"):
          index += 1
          guard index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D else { return nil }
        case UInt8(ascii: "["):
          inClass = true
        case UInt8(ascii: "]"):
          inClass = false
        case UInt8(ascii: "/") where !inClass:
          return index
        default:
          break
        }
        index += 1
      }
      return nil
    }
  }
}

// MARK: - ISO 8601 dates

/// ISO 8601 text to and from epoch milliseconds, UTC, years 0000-9999 (proleptic Gregorian).
private nonisolated enum MongoDateText {
  /// Earliest and latest instants with a four-digit year.
  static let fourDigitYears: ClosedRange<Int64> = -62_167_219_200_000...253_402_300_799_999
  private static let millisPerDay: Int64 = 86_400_000

  /// `YYYY-MM-DD`, optionally followed by `THH:MM[:SS[.fraction]]` and `Z`, `±HH:MM`, `±HHMM` or
  /// `±HH`. No zone means UTC (as mongosh `ISODate`). Fractions beyond milliseconds are dropped.
  static func millis(from text: String) -> Int64? {
    var scanner = Scanner(bytes: Array(text.utf8))
    guard let year = scanner.digits(4), scanner.take("-"), let month = scanner.digits(2),
      scanner.take("-"), let day = scanner.digits(2), (1...12).contains(month),
      (1...daysInMonth(year: year, month: month)).contains(day)
    else { return nil }
    var seconds = 0
    var millis = 0
    if scanner.take("T") {
      guard let hour = scanner.digits(2), scanner.take(":"), let minute = scanner.digits(2),
        hour <= 23, minute <= 59
      else { return nil }
      seconds = hour * 3600 + minute * 60
      if scanner.take(":") {
        guard let second = scanner.digits(2), second <= 59 else { return nil }
        seconds += second
        if scanner.take(".") {
          guard let fraction = scanner.fractionMillis() else { return nil }
          millis = fraction
        }
      }
      guard let offset = scanner.zoneOffsetSeconds() else { return nil }
      seconds -= offset
    }
    guard scanner.atEnd else { return nil }
    let days = daysFromCivil(year: year, month: month, day: day)
    return days * millisPerDay + Int64(seconds) * 1000 + Int64(millis)
  }

  /// `YYYY-MM-DDTHH:MM:SS.sssZ`; only for `fourDigitYears`.
  static func string(fromMillis millis: Int64) -> String {
    var (days, remainder) = millis.quotientAndRemainder(dividingBy: millisPerDay)
    if remainder < 0 {
      days -= 1
      remainder += millisPerDay
    }
    let (year, month, day) = civilFromDays(days)
    let time = Int(remainder)
    let hour = time / 3_600_000
    let minute = time / 60_000 % 60
    let second = time / 1000 % 60
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):"
      + "\(pad(second, 2)).\(pad(time % 1000, 3))Z"
  }

  private static func pad(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    return [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
  }

  /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
    let y = Int64(month <= 2 ? year - 1 : year)
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  /// Inverse of `daysFromCivil` (Howard Hinnant's `civil_from_days`).
  private static func civilFromDays(_ days: Int64) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (Int(year), Int(month), Int(day))
  }

  private nonisolated struct Scanner {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index == bytes.count }

    mutating func take(_ ascii: Unicode.Scalar) -> Bool {
      guard index < bytes.count, bytes[index] == UInt8(ascii: ascii) else { return false }
      index += 1
      return true
    }

    mutating func digits(_ count: Int) -> Int? {
      guard index + count <= bytes.count else { return nil }
      var value = 0
      for byte in bytes[index..<index + count] {
        guard byte.isASCIIDigit else { return nil }
        value = value * 10 + Int(byte - UInt8(ascii: "0"))
      }
      index += count
      return value
    }

    /// One or more digits; the first three are milliseconds.
    mutating func fractionMillis() -> Int? {
      let start = index
      while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
      guard index > start else { return nil }
      let firstThree = bytes[start..<min(index, start + 3)].map { Int($0 - UInt8(ascii: "0")) }
      return (firstThree + [0, 0, 0]).prefix(3).reduce(0) { $0 * 10 + $1 }
    }

    /// Seconds east of UTC: 0 for `Z` or no zone.
    mutating func zoneOffsetSeconds() -> Int? {
      if atEnd { return 0 }
      if take("Z") { return 0 }
      let sign: Int
      if take("+") {
        sign = 1
      } else if take("-") {
        sign = -1
      } else {
        return nil
      }
      guard let hours = digits(2), hours <= 23 else { return nil }
      var minutes = 0
      if take(":") {
        guard let value = digits(2) else { return nil }
        minutes = value
      } else if !atEnd {
        guard let value = digits(2) else { return nil }
        minutes = value
      }
      guard minutes <= 59 else { return nil }
      return sign * (hours * 3600 + minutes * 60)
    }
  }
}

// MARK: - Renderer

nonisolated extension MongoRelaxedJSON {
  fileprivate nonisolated struct Renderer {
    let format: Format
    let indented: Bool
    var output = ""
    /// Containers open around the value being written (indented output only).
    var level = 0

    /// Dates the relaxed form shows as an ISO string (Extended JSON v2: years 1970-9999).
    private static let relaxedISODates: ClosedRange<Int64> =
      0...MongoDateText.fourDigitYears.upperBound

    mutating func write(_ value: MongoValue) {
      switch value {
      case .document(let fields): writeDocument(fields)
      case .array(let items): writeArray(items)
      case .string(let text): output += Self.quoted(text)
      case .int32(let number):
        output +=
          format == .canonicalExtendedJSON ? wrapped("$numberInt", "\(number)") : "\(number)"
      case .int64(let number): writeInt64(number)
      case .double(let number): writeDouble(number)
      case .decimal128(let text):
        output +=
          format == .mongosh
          ? "NumberDecimal(\(Self.quoted(text)))" : wrapped("$numberDecimal", text)
      case .bool(let flag): output += flag ? "true" : "false"
      case .null: output += "null"
      case .objectId(let id):
        output += format == .mongosh ? "ObjectId(\(Self.quoted(id.hex)))" : wrapped("$oid", id.hex)
      case .date(let millis): writeDate(millis)
      case .binary(let subtype, let data): writeBinary(subtype: subtype, data: data)
      case .regex(let pattern, let options): writeRegex(pattern: pattern, options: options)
      case .timestamp(let t, let i):
        output +=
          format == .mongosh
          ? "Timestamp(\(t), \(i))" : "{\"$timestamp\": {\"t\": \(t), \"i\": \(i)}}"
      case .minKey: output += format == .mongosh ? "MinKey()" : "{\"$minKey\": 1}"
      case .maxKey: output += format == .mongosh ? "MaxKey()" : "{\"$maxKey\": 1}"
      }
    }

    private func wrapped(_ key: String, _ text: String) -> String {
      "{\(Self.quoted(key)): \(Self.quoted(text))}"
    }

    private mutating func writeDocument(_ fields: [MongoValue.Field]) {
      guard !fields.isEmpty else {
        output += "{}"
        return
      }
      open("{")
      for (index, field) in fields.enumerated() {
        if index > 0 { separate() }
        output +=
          format == .mongosh && field.key.isPlainIdentifier ? field.key : Self.quoted(field.key)
        output += ": "
        write(field.value)
      }
      close("}")
    }

    private mutating func writeArray(_ items: [MongoValue]) {
      guard !items.isEmpty else {
        output += "[]"
        return
      }
      open("[")
      for (index, item) in items.enumerated() {
        if index > 0 { separate() }
        write(item)
      }
      close("]")
    }

    /// Opens a non-empty document or array; indented, its first entry starts a deeper line.
    private mutating func open(_ bracket: String) {
      if indented {
        level += 1
        output += bracket + "\n" + indentation
      } else {
        output += format == .mongosh ? bracket + " " : bracket
      }
    }

    private mutating func separate() {
      output += indented ? ",\n" + indentation : ", "
    }

    private mutating func close(_ bracket: String) {
      if indented {
        level -= 1
        output += "\n" + indentation + bracket
      } else {
        output += format == .mongosh ? " " + bracket : bracket
      }
    }

    private var indentation: String { String(repeating: "  ", count: level) }

    private mutating func writeInt64(_ number: Int64) {
      switch format {
      case .canonicalExtendedJSON: output += wrapped("$numberLong", "\(number)")
      case .relaxedExtendedJSON: output += "\(number)"
      case .mongosh: output += "NumberLong(\(Self.quoted("\(number)")))"
      }
    }

    private mutating func writeDouble(_ number: Double) {
      let text = Self.doubleText(number)
      switch format {
      case .canonicalExtendedJSON: output += wrapped("$numberDouble", text)
      case .relaxedExtendedJSON: output += number.isFinite ? text : wrapped("$numberDouble", text)
      case .mongosh: output += text
      }
    }

    /// Shortest round-trip text that always reads back as a double (`1.0`, `1e+20`, `NaN`).
    private static func doubleText(_ number: Double) -> String {
      if number.isNaN { return "NaN" }
      if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
      let text = number.description
      return text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? text : text + ".0"
    }

    private mutating func writeDate(_ millis: Int64) {
      switch format {
      case .relaxedExtendedJSON where Self.relaxedISODates.contains(millis):
        output += wrapped("$date", MongoDateText.string(fromMillis: millis))
      case .mongosh where MongoDateText.fourDigitYears.contains(millis):
        output += "ISODate(\(Self.quoted(MongoDateText.string(fromMillis: millis))))"
      case .mongosh:
        output += "new Date(\(millis))"
      default:
        output += "{\"$date\": \(wrapped("$numberLong", "\(millis)"))}"
      }
    }

    private mutating func writeBinary(subtype: UInt8, data: Data) {
      let base64 = data.base64EncodedString()
      if format == .mongosh {
        output += "BinData(\(subtype), \(Self.quoted(base64)))"
      } else {
        let hex = String(subtype, radix: 16)
        let subType = hex.count == 1 ? "0" + hex : hex
        output += "{\"$binary\": {\"base64\": \(Self.quoted(base64)), \"subType\": \"\(subType)\"}}"
      }
    }

    private mutating func writeRegex(pattern: String, options: String) {
      guard format == .mongosh else {
        output +=
          "{\"$regularExpression\": {\"pattern\": \(Self.quoted(pattern)), "
          + "\"options\": \(Self.quoted(options))}}"
        return
      }
      if Self.isLiteralSafe(pattern: pattern, options: options) {
        output += "/\(pattern)/\(options)"
      } else {
        output += "RegExp(\(Self.quoted(pattern)), \(Self.quoted(options)))"
      }
    }

    /// True when `/pattern/options` parses back to exactly this pattern and these options: the
    /// pattern is not empty, does not open a comment, and the literal scan ends at its end.
    private static func isLiteralSafe(pattern: String, options: String) -> Bool {
      let bytes = Array(pattern.utf8)
      guard let first = bytes.first, first != UInt8(ascii: "*"),
        options.utf8.allSatisfy(\.isASCIILetter)
      else { return false }
      return Lexer.regexLiteralEnd(in: bytes + [UInt8(ascii: "/")], from: 0) == bytes.count
    }

    /// A JSON string literal (also valid in mongosh).
    static func quoted(_ text: String) -> String {
      var result = "\""
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{8}": result += "\\b"
        case "\u{C}": result += "\\f"
        case _ where scalar.value < 0x20:
          let hex = String(scalar.value, radix: 16)
          result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default:
          result.unicodeScalars.append(scalar)
        }
      }
      return result + "\""
    }
  }
}

// MARK: - Byte classes

nonisolated extension UInt8 {
  fileprivate var isASCIIDigit: Bool { (0x30...0x39).contains(self) }

  fileprivate var isASCIILetter: Bool {
    (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
  }

  fileprivate var isIdentifierStart: Bool {
    isASCIILetter || self == UInt8(ascii: "_") || self == UInt8(ascii: "$")
  }

  fileprivate var isIdentifierChar: Bool { isIdentifierStart || isASCIIDigit }
}

nonisolated extension String {
  /// A key mongosh can write without quotes (`[A-Za-z_$][A-Za-z0-9_$]*`).
  fileprivate var isPlainIdentifier: Bool {
    guard let first = utf8.first, first.isIdentifierStart else { return false }
    return utf8.allSatisfy(\.isIdentifierChar)
  }
}
