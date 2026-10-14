// MongoBSONMapping.swift
// BSON <-> `MongoValue`, `MongoValue` -> `CellValue`, and result columns for document results
// (Key decision d). Both directions read and write the BSON bytes themselves:
// - BSON 8.2.2 stops iterating a document at the first type byte it does not know (undefined,
//   DBPointer, symbol), which would silently drop every later field;
// - `Document.appendValue(Date)` truncates milliseconds (`Int(seconds * 1000)`), and dates are
//   read through a `Double`, so dates are copied as the raw Int64 here;
// - `Decimal128` has no public initializer or text API.
// Build command and filter documents with `bsonDocument(_:)` (byte exact). Never append a `Date`
// primitive returned by `primitive(_:)` to another document: BSON re-encodes it with truncation.
//
// Read fallbacks (types without a `MongoValue` case, same shapes as canonical Extended JSON):
// - JavaScript code (0x0D) -> `{$code: "…"}`, code with scope (0x0F) -> `{$code: "…", $scope: {…}}`.
//   The writer turns exactly these shapes back into 0x0D / 0x0F, so a read-then-write keeps the
//   type. Like every Extended JSON wrapper, a stored document whose keys are exactly `$code`
//   (string) or `$code` + `$scope` (document), in that order, is therefore written as JavaScript
//   code. Being documents, JavaScript values show as `.json` cells (not mongosh `.string` like
//   other types).
// - DBPointer (0x0C, deprecated) -> `{$dbPointer: {$ref: "<ns>", $id: ObjectId}}` (read only,
//   written back as that plain document). Symbol (0x0E, deprecated) -> string. Undefined (0x06,
//   deprecated) -> null. Any other type byte throws (its length is unknown, so nothing after it
//   could be read).
//
// Writer choices: regex options are written in alphabetical order (BSON spec), keys, regex
// patterns and options must not contain NUL, and Decimal128 text is encoded exactly (see
// `Decimal128Text`).
//
// Column type names (`ColumnInfo.type`) are MongoDB's `$type` aliases:
//   objectId, string, int (int32), long (int64), double, decimal (Decimal128), bool, date,
//   binData, object (document), array, null, regex, timestamp, minKey, maxKey,
//   javascript, javascriptWithScope; `mixed` when a column holds different types.
// Null and missing values never make a column `mixed`; a column with only nulls is `null`.

import BSON
import Foundation

nonisolated enum MongoBSONMapping {
  /// A malformed BSON buffer, or a value that cannot be written as BSON.
  nonisolated struct MappingError: Error, Equatable, Sendable, LocalizedError {
    let message: String

    var errorDescription: String? { message }
  }

  /// Nesting guard for both directions: MongoDB stores at most 100 levels and replies wrap a few
  /// more. Protects the stack (512 KiB on secondary threads) against a hostile or corrupt buffer.
  static let maxDepth = 128

  /// `ColumnInfo.type` of a column whose non-null values have different BSON types.
  static let mixedTypeName = "mixed"

  // MARK: - BSON -> MongoValue

  /// A whole BSON document (or array, when `isArray`), keeping key order and duplicate keys.
  static func document(_ document: Document) throws(MappingError) -> MongoValue {
    var reader = Reader(bytes: Array(document.makeData()))
    let value = try reader.readDocument(isArray: document.isArray, depth: 1)
    guard reader.offset == reader.bytes.count else {
      throw MappingError(message: "Unexpected bytes after the BSON document")
    }
    return value
  }

  /// One BSON value as the driver hands it out (a document field, an array item, a reply value).
  static func value(from primitive: any Primitive) throws(MappingError) -> MongoValue {
    switch primitive {
    case let document as Document: return try self.document(document)
    case let number as Int32: return .int32(number)
    case let number as Int: return .int64(Int64(number))
    case let number as Double: return .double(number)
    case let flag as Bool: return .bool(flag)
    case let text as String: return .string(text)
    case let date as Date: return .date(millis(of: date))
    case let binary as Binary:
      return .binary(subtype: subtypeByte(binary.subType), data: binary.data)
    case let id as ObjectId:
      guard let hex = MongoObjectId(hex: id.hexString) else {
        throw MappingError(message: "Invalid ObjectId")
      }
      return .objectId(hex)
    case is Null: return .null
    case let regex as RegularExpression:
      return .regex(pattern: regex.pattern, options: regex.options)
    case let stamp as Timestamp:
      return .timestamp(
        t: UInt32(bitPattern: stamp.timestamp), i: UInt32(bitPattern: stamp.increment))
    case is MinKey: return .minKey
    case is MaxKey: return .maxKey
    case let decimal as Decimal128:
      // BSON keeps the 16 bytes internal: read them back from a one-key document.
      var holder = Document()
      holder.appendValue(decimal, forKey: "v")
      guard case .document(let fields) = try document(holder), let field = fields.first else {
        throw MappingError(message: "Invalid Decimal128")
      }
      return field.value
    case let code as JavaScriptCode: return javaScript(code: code.code, scope: nil)
    case let code as JavaScriptCodeWithScope:
      return javaScript(code: code.code, scope: try document(code.scope))
    default:
      return .string(String(describing: primitive))
    }
  }

  // MARK: - MongoValue -> BSON

  /// A `.document` (or `.array`) as a BSON `Document`, byte exact (dates, Decimal128, duplicate
  /// keys). Throws for any other value, a NUL in a key or regex, invalid Decimal128 text, or a
  /// value nested deeper than `maxDepth`.
  static func bsonDocument(_ value: MongoValue) throws(MappingError) -> Document {
    var writer = Writer()
    switch value {
    case .document(let fields):
      try writer.writeDocument(fields.map { ($0.key, $0.value) }, depth: 1)
      return Document(bytes: writer.bytes)
    case .array(let items):
      try writer.writeDocument(Writer.indexed(items), depth: 1)
      return Document(bytes: writer.bytes, isArray: true)
    default:
      throw MappingError(message: "A BSON document needs a document or an array")
    }
  }

  /// Any value as a BSON primitive (built through a one-key document). Dates come back as
  /// `Date`, which BSON re-encodes with millisecond truncation: embed dates in a document built by
  /// `bsonDocument(_:)` instead.
  static func primitive(_ value: MongoValue) throws(MappingError) -> any Primitive {
    var writer = Writer()
    try writer.writeDocument([("v", value)], depth: 0)
    guard let primitive = Document(bytes: writer.bytes)["v"] else {
      throw MappingError(message: "The value cannot be read back as BSON")
    }
    return primitive
  }

  // MARK: - Cells and columns

  /// The result-grid cell of a value (Key decision d).
  static func cellValue(_ value: MongoValue) -> CellValue {
    switch value {
    case .int32(let number): .int(Int(number))
    case .int64(let number): .int(Int(number))
    case .double(let number): .double(number)
    case .bool(let flag): .bool(flag)
    case .date(let millis): .date(Date(timeIntervalSince1970: Double(millis) / 1000))
    case .binary(_, let data): .data(data)
    case .decimal128(let text): .string(text)
    case .objectId(let id): .string(id.hex)
    case .string(let text): .string(text)
    case .null: .null
    case .document, .array: .json(MongoRelaxedJSON.render(value, as: .canonicalExtendedJSON))
    case .regex, .timestamp, .minKey, .maxKey:
      .string(MongoRelaxedJSON.render(value, as: .mongosh))
    }
  }

  /// MongoDB's `$type` alias of a value (see the file header).
  static func typeName(_ value: MongoValue) -> String {
    switch value {
    case .document(let fields):
      javaScriptShape(fields).map { $0.scope == nil ? "javascript" : "javascriptWithScope" }
        ?? "object"
    case .array: "array"
    case .string: "string"
    case .int32: "int"
    case .int64: "long"
    case .double: "double"
    case .decimal128: "decimal"
    case .bool: "bool"
    case .null: "null"
    case .objectId: "objectId"
    case .date: "date"
    case .binary: "binData"
    case .regex: "regex"
    case .timestamp: "timestamp"
    case .minKey: "minKey"
    case .maxKey: "maxKey"
    }
  }

  /// Union of the top-level keys: `_id` first (when any document has it), the rest in first-seen
  /// order. No documents gives just `_id` typed `objectId`, so an empty collection still has an
  /// insertable result. Non-document values are skipped.
  static func columns(for documents: [MongoValue]) -> [ColumnInfo] {
    guard !documents.isEmpty else { return [ColumnInfo(name: "_id", type: "objectId")] }
    var names: [String] = []
    var types: [String: String] = [:]
    for case .document(let fields) in documents {
      for field in fields {
        let type = typeName(field.value)
        switch types[field.key] {
        case nil:
          names.append(field.key)
          types[field.key] = type
        case "null"?: types[field.key] = type
        case type?: break
        default: if type != "null" { types[field.key] = mixedTypeName }
        }
      }
    }
    if let index = names.firstIndex(of: "_id") {
      names.insert(names.remove(at: index), at: 0)
    }
    return names.map { ColumnInfo(name: $0, type: types[$0] ?? "null") }
  }

  /// The cells of one document in `columns` order: a missing key is `.null`, a duplicate key
  /// shows its first value, and a non-document value gives an all-null row.
  static func row(for document: MongoValue, columns: [ColumnInfo]) -> [CellValue] {
    guard case .document(let fields) = document else {
      return Array(repeating: .null, count: columns.count)
    }
    var values: [String: MongoValue] = [:]
    for field in fields where values[field.key] == nil {
      values[field.key] = field.value
    }
    return columns.map { values[$0.name].map(cellValue) ?? .null }
  }

  // MARK: - Helpers

  /// The `{$code}` / `{$code, $scope}` shape that stands for BSON JavaScript code.
  static func javaScriptShape(
    _ fields: [MongoValue.Field]
  ) -> (code: String, scope: [MongoValue.Field]?)? {
    guard let first = fields.first, first.key == "$code", case .string(let code) = first.value
    else { return nil }
    switch fields.count {
    case 1: return (code, nil)
    case 2:
      guard fields[1].key == "$scope", case .document(let scope) = fields[1].value else {
        return nil
      }
      return (code, scope)
    default: return nil
    }
  }

  private static func javaScript(code: String, scope: MongoValue?) -> MongoValue {
    var fields = [MongoValue.Field("$code", .string(code))]
    if let scope { fields.append(MongoValue.Field("$scope", scope)) }
    return .document(fields)
  }

  /// Milliseconds of a driver `Date` (built from Int64 milliseconds, so rounding recovers them).
  private static func millis(of date: Date) -> Int64 {
    let millis = (date.timeIntervalSince1970 * 1000).rounded()
    return Int64(exactly: millis) ?? (millis < 0 ? .min : .max)
  }

  private static func subtypeByte(_ subtype: Binary.SubType) -> UInt8 {
    switch subtype {
    case .generic: 0x00
    case .function: 0x01
    case .uuid: 0x04
    case .md5: 0x05
    case .userDefined(let byte): byte
    }
  }
}

// MARK: - Reader

nonisolated extension MongoBSONMapping {
  /// Reads BSON bytes; every read is bounded by the buffer, never by a length field alone.
  fileprivate nonisolated struct Reader {
    let bytes: [UInt8]
    var offset = 0

    private func failure(_ message: String) -> MappingError {
      MappingError(message: "Malformed BSON at byte \(offset): \(message)")
    }

    private mutating func take(_ count: Int) throws(MappingError) -> ArraySlice<UInt8> {
      guard count >= 0, count <= bytes.count - offset else { throw failure("truncated value") }
      defer { offset += count }
      return bytes[offset..<offset + count]
    }

    private mutating func littleEndian<T: FixedWidthInteger>(_: T.Type) throws(MappingError) -> T {
      try take(MemoryLayout<T>.size).reversed().reduce(T.zero) { $0 << 8 | T($1) }
    }

    private mutating func length() throws(MappingError) -> Int {
      Int(try littleEndian(Int32.self))
    }

    private mutating func cString() throws(MappingError) -> String {
      guard let end = bytes[offset...].firstIndex(of: 0) else {
        throw failure("unterminated string")
      }
      let text = String(decoding: try take(end - offset), as: UTF8.self)
      offset += 1
      return text
    }

    private mutating func string() throws(MappingError) -> String {
      let count = try length()
      guard count >= 1 else { throw failure("invalid string length") }
      let body = try take(count)
      guard body.last == 0 else { throw failure("unterminated string") }
      return String(decoding: body.dropLast(), as: UTF8.self)
    }

    private mutating func objectId() throws(MappingError) -> MongoValue {
      let hex = try take(12).map { String(format: "%02x", $0) }.joined()
      guard let id = MongoObjectId(hex: hex) else { throw failure("invalid ObjectId") }
      return .objectId(id)
    }

    mutating func readDocument(isArray: Bool, depth: Int) throws(MappingError) -> MongoValue {
      guard depth <= MongoBSONMapping.maxDepth else { throw failure("nested too deeply") }
      let start = offset
      let size = try length()
      guard size >= 5, size <= bytes.count - start else { throw failure("invalid document size") }
      let end = start + size
      var fields: [MongoValue.Field] = []
      while true {
        guard offset < end else { throw failure("document overruns its size") }
        let type = bytes[offset]
        offset += 1
        if type == 0 { break }
        let key = try cString()
        // Only nesting types recurse; scalars are read in their own frame (Debug frames of the
        // full switch would overflow a 512 KiB thread stack long before `maxDepth`).
        let value =
          switch type {
          case 0x03, 0x04: try readDocument(isArray: type == 0x04, depth: depth + 1)
          case 0x0F: try codeWithScope(depth: depth)
          default: try readScalar(type: type)
          }
        fields.append(MongoValue.Field(key, value))
      }
      guard offset == end else { throw failure("document size mismatch") }
      return isArray ? .array(fields.map(\.value)) : .document(fields)
    }

    private mutating func codeWithScope(depth: Int) throws(MappingError) -> MongoValue {
      let start = offset
      let size = try length()
      let code = try string()
      let scope = try readDocument(isArray: false, depth: depth + 1)
      guard offset - start == size else { throw failure("code with scope size mismatch") }
      return MongoBSONMapping.javaScript(code: code, scope: scope)
    }

    private mutating func readScalar(type: UInt8) throws(MappingError) -> MongoValue {
      switch type {
      case 0x01: return .double(Double(bitPattern: try littleEndian(UInt64.self)))
      case 0x02: return .string(try string())
      case 0x05:
        let count = try length()
        let subtype = try take(1).first ?? 0
        return .binary(subtype: subtype, data: Data(try take(count)))
      case 0x06: return .null
      case 0x07: return try objectId()
      case 0x08: return .bool(try take(1).first != 0)
      case 0x09: return .date(try littleEndian(Int64.self))
      case 0x0A: return .null
      case 0x0B: return .regex(pattern: try cString(), options: try cString())
      case 0x0C:
        let namespace = try string()
        let pointer = MongoValue.document([
          MongoValue.Field("$ref", .string(namespace)), MongoValue.Field("$id", try objectId()),
        ])
        return .document([MongoValue.Field("$dbPointer", pointer)])
      case 0x0D: return MongoBSONMapping.javaScript(code: try string(), scope: nil)
      case 0x0E: return .string(try string())
      case 0x10: return .int32(try littleEndian(Int32.self))
      case 0x11:
        let increment = try littleEndian(UInt32.self)
        return .timestamp(t: try littleEndian(UInt32.self), i: increment)
      case 0x12: return .int64(try littleEndian(Int64.self))
      case 0x13:
        let low = try littleEndian(UInt64.self)
        let high = try littleEndian(UInt64.self)
        return .decimal128(Decimal128Text.format(low: low, high: high))
      case 0x7F: return .maxKey
      case 0xFF: return .minKey
      default:
        throw failure("unsupported BSON type 0x\(String(format: "%02X", type))")
      }
    }
  }
}

// MARK: - Writer

nonisolated extension MongoBSONMapping {
  fileprivate nonisolated struct Writer {
    var bytes: [UInt8] = []

    static func indexed(_ items: [MongoValue]) -> [(String, MongoValue)] {
      items.enumerated().map { (String($0.offset), $0.element) }
    }

    private mutating func littleEndian<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func int32(_ count: Int) throws(MappingError) -> Int32 {
      guard let value = Int32(exactly: count) else {
        throw MappingError(message: "The value is too large for BSON")
      }
      return value
    }

    /// Reserves an int32 size at the current position; `endSize` fills it in.
    private mutating func beginSize() -> Int {
      bytes.append(contentsOf: [0, 0, 0, 0])
      return bytes.count - 4
    }

    private mutating func endSize(at start: Int) throws(MappingError) {
      let size = try Self.int32(bytes.count - start)
      withUnsafeBytes(of: size.littleEndian) { bytes.replaceSubrange(start..<start + 4, with: $0) }
    }

    private mutating func cString(_ text: String, _ what: String) throws(MappingError) {
      guard !text.utf8.contains(0) else {
        throw MappingError(message: "BSON \(what) cannot contain a NUL character")
      }
      bytes.append(contentsOf: text.utf8)
      bytes.append(0)
    }

    private mutating func string(_ text: String) throws(MappingError) {
      littleEndian(try Self.int32(text.utf8.count + 1))
      bytes.append(contentsOf: text.utf8)
      bytes.append(0)
    }

    mutating func writeDocument(
      _ fields: [(String, MongoValue)], depth: Int
    ) throws(MappingError) {
      guard depth <= MongoBSONMapping.maxDepth else {
        throw MappingError(message: "The value is nested too deeply for BSON")
      }
      let start = beginSize()
      for (key, value) in fields {
        try element(key, value, depth: depth)
      }
      bytes.append(0)
      try endSize(at: start)
    }

    private mutating func element(
      _ key: String, _ value: MongoValue, depth: Int
    ) throws(MappingError) {
      let typeIndex = bytes.count
      bytes.append(0)
      try cString(key, "keys")
      let type: UInt8
      switch value {
      case .document(let fields):
        if let code = MongoBSONMapping.javaScriptShape(fields) {
          type = try javaScript(code, depth: depth)
        } else {
          type = 0x03
          try writeDocument(fields.map { ($0.key, $0.value) }, depth: depth + 1)
        }
      case .array(let items):
        type = 0x04
        try writeDocument(Self.indexed(items), depth: depth + 1)
      default:
        type = try scalar(value)
      }
      bytes[typeIndex] = type
    }

    /// Writes a non-nesting value and returns its BSON type byte.
    private mutating func scalar(_ value: MongoValue) throws(MappingError) -> UInt8 {
      switch value {
      case .string(let text):
        try string(text)
        return 0x02
      case .int32(let number):
        littleEndian(number)
        return 0x10
      case .int64(let number):
        littleEndian(number)
        return 0x12
      case .double(let number):
        littleEndian(number.bitPattern)
        return 0x01
      case .decimal128(let text):
        let bits = try Decimal128Text.encode(text)
        littleEndian(bits.low)
        littleEndian(bits.high)
        return 0x13
      case .bool(let flag):
        bytes.append(flag ? 1 : 0)
        return 0x08
      case .null:
        return 0x0A
      case .objectId(let id):
        bytes.append(contentsOf: Self.hexBytes(id.hex))
        return 0x07
      case .date(let millis):
        littleEndian(millis)
        return 0x09
      case .binary(let subtype, let data):
        littleEndian(try Self.int32(data.count))
        bytes.append(subtype)
        bytes.append(contentsOf: data)
        return 0x05
      case .regex(let pattern, let options):
        try cString(pattern, "regex patterns")
        try cString(String(options.sorted()), "regex options")
        return 0x0B
      case .timestamp(let t, let i):
        littleEndian(i)
        littleEndian(t)
        return 0x11
      case .minKey:
        return 0xFF
      case .maxKey:
        return 0x7F
      case .document, .array:
        throw MappingError(message: "Not a scalar")
      }
    }

    private mutating func javaScript(
      _ code: (code: String, scope: [MongoValue.Field]?), depth: Int
    ) throws(MappingError) -> UInt8 {
      guard let scope = code.scope else {
        try string(code.code)
        return 0x0D
      }
      let start = beginSize()
      try string(code.code)
      try writeDocument(scope.map { ($0.key, $0.value) }, depth: depth + 1)
      try endSize(at: start)
      return 0x0F
    }

    /// 24 hex characters (checked by `MongoObjectId`) to 12 bytes.
    private static func hexBytes(_ hex: String) -> [UInt8] {
      let digits = Array(hex.utf8)
      return stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16) ?? 0
      }
    }
  }
}

// MARK: - Decimal128 text

/// IEEE 754-2008 decimal128 (BID encoding) to and from the canonical text of the BSON Decimal128
/// / Extended JSON spec. `low`/`high` are the BSON wire words (each little-endian on the wire).
///
/// Encoding is exact or throws: no rounding, so the stored value is the typed one.
/// - Accepts what `MongoRelaxedJSON.Lexer.isDecimal` accepts: `[+-]digits[.digits][e[+-]digits]`
///   and a signed `Inf`, `Infinity` or `NaN` in any case (`-NaN` keeps its sign bit; it formats
///   as `NaN`, like the server).
/// - Leading zeros are not significant; more than 34 significant digits throws, except trailing
///   zeros that an exponent increase absorbs exactly.
/// - Exponent range -6176...6111: a larger exponent is clamped by padding the coefficient with
///   zeros (up to 34 digits), a smaller one by dropping trailing zeros; if neither is exact it
///   throws. A zero coefficient takes any exponent, clamped into the range.
nonisolated enum Decimal128Text {
  static let maxDigits = 34
  static let exponentRange = -6176...6111
  private static let exponentBias = 6176

  static func encode(
    _ text: String
  ) throws(MongoBSONMapping.MappingError) -> (low: UInt64, high: UInt64) {
    guard MongoRelaxedJSON.Lexer.isDecimal(text) else {
      throw MongoBSONMapping.MappingError(message: "\"\(text)\" is not a decimal number")
    }
    var bytes = Array(text.utf8)[...]
    let negative = bytes.first == UInt8(ascii: "-")
    if negative || bytes.first == UInt8(ascii: "+") { bytes = bytes.dropFirst() }
    let sign: UInt64 = negative ? 1 << 63 : 0
    switch String(decoding: bytes, as: UTF8.self).lowercased() {
    case "nan": return (0, sign | 0x7C00_0000_0000_0000)
    case "inf", "infinity": return (0, sign | 0x7800_0000_0000_0000)
    default: break
    }

    var digits: [UInt8] = []
    var exponent = 0
    var inFraction = false
    while let byte = bytes.first, byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") {
      bytes = bytes.dropFirst()
      if byte == UInt8(ascii: ".") {
        inFraction = true
        continue
      }
      if digits.isEmpty && byte == UInt8(ascii: "0") {
        if inFraction { exponent -= 1 }
        continue  // Leading zeros are not significant.
      }
      digits.append(byte - UInt8(ascii: "0"))
      if inFraction { exponent -= 1 }
    }
    if !bytes.isEmpty {
      exponent += exponentValue(bytes.dropFirst())
    }

    guard !digits.isEmpty else {
      let clamped = min(max(exponent, exponentRange.lowerBound), exponentRange.upperBound)
      return (0, sign | UInt64(clamped + exponentBias) << 49)
    }
    while digits.count > maxDigits, digits.last == 0 {
      digits.removeLast()
      exponent += 1
    }
    guard digits.count <= maxDigits else {
      throw MongoBSONMapping.MappingError(
        message: "\"\(text)\" has more than 34 significant digits (Decimal128 cannot store it)")
    }
    while exponent > exponentRange.upperBound, digits.count < maxDigits {
      digits.append(0)
      exponent -= 1
    }
    while exponent < exponentRange.lowerBound, digits.last == 0 {
      digits.removeLast()
      exponent += 1
    }
    guard exponentRange.contains(exponent) else {
      throw MongoBSONMapping.MappingError(message: "\"\(text)\" is out of the Decimal128 range")
    }

    // Coefficient < 10^34 < 2^113, so the normal BID form (no `11` combination) always fits.
    var high: UInt64 = 0
    var low: UInt64 = 0
    for digit in digits {
      let product = low.multipliedFullWidth(by: 10)
      let (sum, carry) = product.low.addingReportingOverflow(UInt64(digit))
      low = sum
      high = high * 10 + product.high + (carry ? 1 : 0)
    }
    return (low, sign | UInt64(exponent + exponentBias) << 49 | high)
  }

  /// Exponent digits, saturated far beyond any representable value.
  private static func exponentValue(_ bytes: ArraySlice<UInt8>) -> Int {
    var rest = bytes
    let negative = rest.first == UInt8(ascii: "-")
    if negative || rest.first == UInt8(ascii: "+") { rest = rest.dropFirst() }
    var value = 0
    for byte in rest {
      value = min(value * 10 + Int(byte - UInt8(ascii: "0")), 1_000_000_000)
    }
    return negative ? -value : value
  }

  /// The canonical string (spec "To String"), e.g. `1.50`, `-0`, `1E+10`, `1E-7`, `NaN`.
  static func format(low: UInt64, high: UInt64) -> String {
    let sign = high >> 63 == 1 ? "-" : ""
    let combination = (high >> 58) & 0x1F
    if combination == 0x1F { return "NaN" }
    if combination == 0x1E { return sign + "Infinity" }

    let biased: UInt64
    var parts: [UInt32]
    if (high >> 61) & 0x3 == 0x3 {
      biased = (high >> 47) & 0x3FFF
      parts = [0, 0, 0, 0]  // Non-canonical: the coefficient is above 10^34 - 1, so 0.
    } else {
      biased = (high >> 49) & 0x3FFF
      let significandHigh = high & 0x1_FFFF_FFFF_FFFF
      parts = [
        UInt32(significandHigh >> 32), UInt32(significandHigh & 0xFFFF_FFFF),
        UInt32(low >> 32), UInt32(low & 0xFFFF_FFFF),
      ]
    }
    let exponent = Int(biased) - exponentBias

    // Base 10^9 chunks by long division of the 128-bit coefficient.
    var chunks: [UInt32] = []
    while parts.contains(where: { $0 != 0 }) {
      var remainder: UInt64 = 0
      for index in parts.indices {
        let current = remainder << 32 | UInt64(parts[index])
        parts[index] = UInt32(current / 1_000_000_000)
        remainder = current % 1_000_000_000
      }
      chunks.append(UInt32(remainder))
    }
    var digits = chunks.reversed().enumerated().map { index, chunk in
      index == 0
        ? String(chunk) : String(repeating: "0", count: 9 - String(chunk).count) + String(chunk)
    }.joined()
    if digits.isEmpty { digits = "0" }
    if digits.count > maxDigits { digits = "0" }

    let adjusted = exponent + digits.count - 1
    if exponent > 0 || adjusted < -6 {
      var text = String(digits.prefix(1))
      if digits.count > 1 { text += "." + digits.dropFirst() }
      return sign + text + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }
    if exponent == 0 { return sign + digits }
    let point = digits.count + exponent
    if point > 0 {
      return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }
    return sign + "0." + String(repeating: "0", count: -point) + digits
  }
}
