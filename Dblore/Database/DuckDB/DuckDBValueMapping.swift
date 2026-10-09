// DuckDBValueMapping.swift
// DuckDB result vectors become CellValue. Scalars map the way PostgreSQL values do (integers to
// .int, DECIMAL to .double, dates and timestamps to .date, UUID to its string). Nested values
// (LIST, ARRAY, STRUCT, MAP, UNION) and TIME / INTERVAL become text in DuckDB's own `::VARCHAR`
// style: `[1, 2]`, `{'a': 1, 'b': x}`, `{k=1}`, `1 year 2 months 3 days 04:05:06.789`.

import Foundation

/// `DUCKDB_TYPE` values (duckdb.h v1.5.6).
nonisolated enum DuckDBTypeID {
  static let boolean: Int32 = 1
  static let tinyint: Int32 = 2
  static let smallint: Int32 = 3
  static let integer: Int32 = 4
  static let bigint: Int32 = 5
  static let utinyint: Int32 = 6
  static let usmallint: Int32 = 7
  static let uinteger: Int32 = 8
  static let ubigint: Int32 = 9
  static let float: Int32 = 10
  static let double: Int32 = 11
  static let timestamp: Int32 = 12
  static let date: Int32 = 13
  static let time: Int32 = 14
  static let interval: Int32 = 15
  static let hugeint: Int32 = 16
  static let varchar: Int32 = 17
  static let blob: Int32 = 18
  static let decimal: Int32 = 19
  static let timestampS: Int32 = 20
  static let timestampMS: Int32 = 21
  static let timestampNS: Int32 = 22
  static let enumeration: Int32 = 23
  static let list: Int32 = 24
  static let structure: Int32 = 25
  static let map: Int32 = 26
  static let uuid: Int32 = 27
  static let union: Int32 = 28
  static let bit: Int32 = 29
  static let timeTZ: Int32 = 30
  static let timestampTZ: Int32 = 31
  static let uhugeint: Int32 = 32
  static let array: Int32 = 33
  static let bignum: Int32 = 35
  static let sqlNull: Int32 = 36
  static let timeNS: Int32 = 39
  static let geometry: Int32 = 40
  static let variant: Int32 = 41

  static let scalarNames: [Int32: String] = [
    boolean: "BOOLEAN", tinyint: "TINYINT", smallint: "SMALLINT", integer: "INTEGER",
    bigint: "BIGINT", utinyint: "UTINYINT", usmallint: "USMALLINT", uinteger: "UINTEGER",
    ubigint: "UBIGINT", float: "FLOAT", double: "DOUBLE", timestamp: "TIMESTAMP", date: "DATE",
    time: "TIME", interval: "INTERVAL", hugeint: "HUGEINT", varchar: "VARCHAR", blob: "BLOB",
    timestampS: "TIMESTAMP_S", timestampMS: "TIMESTAMP_MS", timestampNS: "TIMESTAMP_NS",
    uuid: "UUID", bit: "BIT", timeTZ: "TIME WITH TIME ZONE",
    timestampTZ: "TIMESTAMP WITH TIME ZONE", uhugeint: "UHUGEINT", bignum: "BIGNUM",
    sqlNull: "NULL", timeNS: "TIME_NS", geometry: "GEOMETRY", variant: "VARIANT",
  ]
}

/// A column's logical type, read once per result so the logical type handles can be freed.
nonisolated indirect enum DuckDBTypeNode: Sendable {
  case scalar(Int32)
  case json
  case decimal(width: UInt8, scale: UInt8, storage: Int32)
  case enumeration(storage: Int32, labels: [String])
  case list(DuckDBTypeNode)
  case array(DuckDBTypeNode, size: Int)
  case structure([(name: String, type: DuckDBTypeNode)])
  case map(key: DuckDBTypeNode, value: DuckDBTypeNode)
  case union([(name: String, type: DuckDBTypeNode)])

  /// Type name shown in the result header, e.g. `DECIMAL(18,3)`, `INTEGER[]`, `STRUCT(a INTEGER)`.
  var name: String {
    switch self {
    case .scalar(let id): DuckDBTypeID.scalarNames[id] ?? "UNKNOWN(\(id))"
    case .json: "JSON"
    case .decimal(let width, let scale, _): "DECIMAL(\(width),\(scale))"
    case .enumeration: "ENUM"
    case .list(let child): "\(child.name)[]"
    case .array(let child, let size): "\(child.name)[\(size)]"
    case .structure(let fields):
      "STRUCT(" + fields.map { "\($0.name) \($0.type.name)" }.joined(separator: ", ") + ")"
    case .map(let key, let value): "MAP(\(key.name), \(value.name))"
    case .union(let members):
      "UNION(" + members.map { "\($0.name) \($0.type.name)" }.joined(separator: ", ") + ")"
    }
  }
}

/// Reads DuckDB logical types and vectors through the loaded C API. Runs on the session queue.
nonisolated struct DuckDBValueMapping {
  let library: DuckDBLibrary

  // MARK: - Logical types

  /// Describes `type` and destroys it.
  func node(consuming type: OpaquePointer?) -> DuckDBTypeNode {
    var type = type
    defer { library.destroyLogicalType(&type) }
    return node(type)
  }

  private func node(_ type: OpaquePointer?) -> DuckDBTypeNode {
    let id = library.typeID(type)
    switch id {
    case DuckDBTypeID.varchar:
      return alias(of: type)?.uppercased() == "JSON" ? .json : .scalar(id)
    case DuckDBTypeID.decimal:
      return .decimal(
        width: library.decimalWidth(type), scale: library.decimalScale(type),
        storage: library.decimalInternalType(type))
    case DuckDBTypeID.enumeration:
      let count = UInt64(library.enumDictionarySize(type))
      let labels = (0..<count).map { take(library.enumDictionaryValue(type, $0)) ?? "" }
      return .enumeration(storage: library.enumInternalType(type), labels: labels)
    case DuckDBTypeID.list:
      return .list(node(consuming: library.listTypeChild(type)))
    case DuckDBTypeID.array:
      return .array(
        node(consuming: library.arrayTypeChild(type)),
        size: Int(truncatingIfNeeded: library.arrayTypeSize(type)))
    case DuckDBTypeID.structure:
      let fields = (0..<library.structTypeChildCount(type)).map { index in
        (
          name: take(library.structTypeChildName(type, index)) ?? "",
          type: node(consuming: library.structTypeChildType(type, index))
        )
      }
      return .structure(fields)
    case DuckDBTypeID.map:
      return .map(
        key: node(consuming: library.mapTypeKey(type)),
        value: node(consuming: library.mapTypeValue(type)))
    case DuckDBTypeID.union:
      let members = (0..<library.unionMemberCount(type)).map { index in
        (
          name: take(library.unionMemberName(type, index)) ?? "",
          type: node(consuming: library.unionMemberType(type, index))
        )
      }
      return .union(members)
    default:
      return .scalar(id)
    }
  }

  private func alias(of type: OpaquePointer?) -> String? {
    take(library.logicalTypeAlias(type))
  }

  /// Copies a C string DuckDB allocated, then frees it with `duckdb_free`.
  private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { library.free(pointer) }
    return String(cString: pointer)
  }

  // MARK: - Rows

  /// Every row of one data chunk.
  func rows(chunk: OpaquePointer?, types: [DuckDBTypeNode]) -> [[CellValue]] {
    let count = Int(truncatingIfNeeded: library.dataChunkSize(chunk))
    let vectors = types.indices.map { library.dataChunkVector(chunk, UInt64($0)) }
    return (0..<count).map { row in
      types.indices.map { column in cell(types[column], vectors[column], row) }
    }
  }

  private func isValid(_ vector: OpaquePointer?, _ row: Int) -> Bool {
    guard let validity = library.vectorValidity(vector) else { return true }
    return validity[row / 64] & (UInt64(1) << UInt64(row % 64)) != 0
  }

  private func cell(_ type: DuckDBTypeNode, _ vector: OpaquePointer?, _ row: Int) -> CellValue {
    guard isValid(vector, row) else { return .null }
    switch type {
    case .structure, .union, .array: return .string(text(type, vector, row))
    default: break
    }
    guard let data = library.vectorData(vector) else { return .null }
    switch type {
    case .scalar(let id):
      return scalarCell(id, data, row)
    case .json:
      let text = Self.string(data, row)
      return SQLiteValueMapping.isValidJSON(text) ? .json(text) : .string(text)
    case .decimal(_, let scale, let storage):
      let text = Self.decimalText(integer: Self.integerText(storage, data, row), scale: scale)
      return Double(text).map(CellValue.double) ?? .string(text)
    default:
      return .string(text(type, vector, row))
    }
  }

  private func scalarCell(_ id: Int32, _ data: UnsafeMutableRawPointer, _ row: Int) -> CellValue {
    switch id {
    case DuckDBTypeID.boolean: return .bool(data.load(fromByteOffset: row, as: UInt8.self) != 0)
    case DuckDBTypeID.tinyint, DuckDBTypeID.smallint, DuckDBTypeID.integer, DuckDBTypeID.bigint,
      DuckDBTypeID.utinyint, DuckDBTypeID.usmallint, DuckDBTypeID.uinteger, DuckDBTypeID.ubigint,
      DuckDBTypeID.hugeint, DuckDBTypeID.uhugeint:
      let text = Self.integerText(id, data, row)
      return Int(text).map(CellValue.int) ?? .string(text)
    case DuckDBTypeID.float:
      return .double(Double(data.load(fromByteOffset: row * 4, as: Float.self)))
    case DuckDBTypeID.double:
      return .double(data.load(fromByteOffset: row * 8, as: Double.self))
    case DuckDBTypeID.varchar: return .string(Self.string(data, row))
    case DuckDBTypeID.blob: return .data(Self.bytes(data, row))
    case DuckDBTypeID.date:
      let days = data.load(fromByteOffset: row * 4, as: Int32.self)
      if days == Int32.max || days == -Int32.max {
        return .string(days > 0 ? "infinity" : "-infinity")
      }
      return .date(Date(timeIntervalSince1970: Double(days) * 86_400))
    case DuckDBTypeID.timestamp, DuckDBTypeID.timestampTZ, DuckDBTypeID.timestampS,
      DuckDBTypeID.timestampMS, DuckDBTypeID.timestampNS:
      guard let micros = Self.timestampMicros(id, data, row) else {
        return .string(Self.infinityText(data, row))
      }
      return .date(Date(timeIntervalSince1970: Double(micros) / 1_000_000))
    case DuckDBTypeID.sqlNull: return .null
    default: return .string(scalarText(id, data, row))
    }
  }

  // MARK: - Text

  /// DuckDB `::VARCHAR` style text of one value, used for nested values and text-only types.
  private func text(_ type: DuckDBTypeNode, _ vector: OpaquePointer?, _ row: Int) -> String {
    guard isValid(vector, row) else { return "NULL" }
    // STRUCT, UNION and ARRAY vectors have no data buffer of their own, only child vectors.
    switch type {
    case .array(let child, let size):
      let childVector = library.arrayVectorChild(vector)
      return "["
        + (0..<size).map { text(child, childVector, row * size + $0) }.joined(separator: ", ")
        + "]"
    case .structure(let fields):
      let parts = fields.enumerated().map { index, field in
        let child = library.structVectorChild(vector, UInt64(index))
        return "'\(field.name)': \(text(field.type, child, row))"
      }
      return "{" + parts.joined(separator: ", ") + "}"
    case .union(let members):
      let tags = library.structVectorChild(vector, 0)
      guard let tagData = library.vectorData(tags) else { return "NULL" }
      let tag = Int(tagData.load(fromByteOffset: row, as: UInt8.self))
      guard members.indices.contains(tag) else { return "NULL" }
      return text(members[tag].type, library.structVectorChild(vector, UInt64(tag + 1)), row)
    default:
      break
    }
    guard let data = library.vectorData(vector) else { return "NULL" }
    switch type {
    case .structure, .union, .array:
      return "NULL"
    case .scalar(let id):
      return scalarText(id, data, row)
    case .json:
      return Self.string(data, row)
    case .decimal(_, let scale, let storage):
      return Self.decimalText(integer: Self.integerText(storage, data, row), scale: scale)
    case .enumeration(let storage, let labels):
      let index = Int(Self.integerText(storage, data, row)) ?? -1
      return labels.indices.contains(index) ? labels[index] : ""
    case .list(let child):
      let (offset, length) = Self.listEntry(data, row)
      let childVector = library.listVectorChild(vector)
      return "["
        + (0..<length).map { text(child, childVector, offset + $0) }.joined(separator: ", ")
        + "]"
    case .map(let key, let value):
      let (offset, length) = Self.listEntry(data, row)
      let entries = library.listVectorChild(vector)
      let keys = library.structVectorChild(entries, 0)
      let values = library.structVectorChild(entries, 1)
      let parts = (0..<length).map {
        "\(text(key, keys, offset + $0))=\(text(value, values, offset + $0))"
      }
      return "{" + parts.joined(separator: ", ") + "}"
    }
  }

  private func scalarText(_ id: Int32, _ data: UnsafeMutableRawPointer, _ row: Int) -> String {
    switch id {
    case DuckDBTypeID.boolean:
      return data.load(fromByteOffset: row, as: UInt8.self) != 0 ? "true" : "false"
    case DuckDBTypeID.tinyint, DuckDBTypeID.smallint, DuckDBTypeID.integer, DuckDBTypeID.bigint,
      DuckDBTypeID.utinyint, DuckDBTypeID.usmallint, DuckDBTypeID.uinteger, DuckDBTypeID.ubigint,
      DuckDBTypeID.hugeint, DuckDBTypeID.uhugeint:
      return Self.integerText(id, data, row)
    case DuckDBTypeID.float:
      return String(data.load(fromByteOffset: row * 4, as: Float.self))
    case DuckDBTypeID.double:
      return String(data.load(fromByteOffset: row * 8, as: Double.self))
    case DuckDBTypeID.varchar:
      return Self.string(data, row)
    case DuckDBTypeID.blob:
      return Self.blobText(Self.bytes(data, row))
    case DuckDBTypeID.bit:
      return Self.bitText(Self.bytes(data, row))
    case DuckDBTypeID.date:
      let days = data.load(fromByteOffset: row * 4, as: Int32.self)
      if days == Int32.max || days == -Int32.max { return days > 0 ? "infinity" : "-infinity" }
      return Self.dayFormatter.string(from: Date(timeIntervalSince1970: Double(days) * 86_400))
    case DuckDBTypeID.timestamp, DuckDBTypeID.timestampTZ, DuckDBTypeID.timestampS,
      DuckDBTypeID.timestampMS, DuckDBTypeID.timestampNS:
      guard let micros = Self.timestampMicros(id, data, row) else {
        return Self.infinityText(data, row)
      }
      let (seconds, fraction) = micros.quotientAndRemainder(dividingBy: 1_000_000)
      let whole = fraction < 0 ? seconds - 1 : seconds
      let day = Self.secondFormatter.string(from: Date(timeIntervalSince1970: Double(whole)))
      let time = Self.timeText(micros: (fraction + 1_000_000) % 1_000_000)
      return day + time.drop { $0 != "." }
    case DuckDBTypeID.time:
      return Self.timeText(micros: data.load(fromByteOffset: row * 8, as: Int64.self))
    case DuckDBTypeID.timeNS:
      let nanos = data.load(fromByteOffset: row * 8, as: Int64.self)
      return Self.timeText(micros: nanos / 1_000)
    case DuckDBTypeID.timeTZ:
      return Self.timeTZText(bits: data.load(fromByteOffset: row * 8, as: UInt64.self))
    case DuckDBTypeID.interval:
      return Self.intervalText(
        months: data.load(fromByteOffset: row * 16, as: Int32.self),
        days: data.load(fromByteOffset: row * 16 + 4, as: Int32.self),
        micros: data.load(fromByteOffset: row * 16 + 8, as: Int64.self))
    case DuckDBTypeID.uuid:
      return Self.uuidText(
        lower: data.load(fromByteOffset: row * 16, as: UInt64.self),
        upper: data.load(fromByteOffset: row * 16 + 8, as: UInt64.self))
    case DuckDBTypeID.sqlNull:
      return "NULL"
    default:
      let name = DuckDBTypeID.scalarNames[id] ?? "type \(id)"
      return "<\(name) value>"
    }
  }

  // MARK: - Fixed layouts

  /// `duckdb_string_t`: 16 bytes. Length first; up to 12 bytes inline, else a pointer at 8.
  private static func bytes(_ data: UnsafeMutableRawPointer, _ row: Int) -> Data {
    let base = data + row * 16
    let length = Int(base.load(as: UInt32.self))
    if length <= 12 { return Data(bytes: base + 4, count: length) }
    guard let pointer = base.load(fromByteOffset: 8, as: UnsafeRawPointer?.self) else {
      return Data()
    }
    return Data(bytes: pointer, count: length)
  }

  private static func string(_ data: UnsafeMutableRawPointer, _ row: Int) -> String {
    String(decoding: bytes(data, row), as: UTF8.self)
  }

  /// `duckdb_list_entry`: offset and length, both `uint64_t`.
  private static func listEntry(_ data: UnsafeMutableRawPointer, _ row: Int) -> (Int, Int) {
    (
      Int(truncatingIfNeeded: data.load(fromByteOffset: row * 16, as: UInt64.self)),
      Int(truncatingIfNeeded: data.load(fromByteOffset: row * 16 + 8, as: UInt64.self))
    )
  }

  /// Exact decimal text of an integer column (or a DECIMAL/ENUM's storage type).
  private static func integerText(
    _ id: Int32, _ data: UnsafeMutableRawPointer, _ row: Int
  )
    -> String
  {
    switch id {
    case DuckDBTypeID.tinyint: String(data.load(fromByteOffset: row, as: Int8.self))
    case DuckDBTypeID.smallint: String(data.load(fromByteOffset: row * 2, as: Int16.self))
    case DuckDBTypeID.integer: String(data.load(fromByteOffset: row * 4, as: Int32.self))
    case DuckDBTypeID.bigint: String(data.load(fromByteOffset: row * 8, as: Int64.self))
    case DuckDBTypeID.utinyint: String(data.load(fromByteOffset: row, as: UInt8.self))
    case DuckDBTypeID.usmallint: String(data.load(fromByteOffset: row * 2, as: UInt16.self))
    case DuckDBTypeID.uinteger: String(data.load(fromByteOffset: row * 4, as: UInt32.self))
    case DuckDBTypeID.ubigint: String(data.load(fromByteOffset: row * 8, as: UInt64.self))
    case DuckDBTypeID.hugeint:
      // duckdb_hugeint: lower uint64_t, then upper int64_t.
      int128Text(
        lower: data.load(fromByteOffset: row * 16, as: UInt64.self),
        upper: data.load(fromByteOffset: row * 16 + 8, as: UInt64.self), signed: true)
    case DuckDBTypeID.uhugeint:
      int128Text(
        lower: data.load(fromByteOffset: row * 16, as: UInt64.self),
        upper: data.load(fromByteOffset: row * 16 + 8, as: UInt64.self), signed: false)
    default: ""
    }
  }

  /// 128-bit two's complement to decimal text without `Int128` (macOS 15+ only).
  private static func int128Text(lower: UInt64, upper: UInt64, signed: Bool) -> String {
    var high = upper
    var low = lower
    let negative = signed && high >> 63 == 1
    if negative {
      // Negate: invert and add one.
      high = ~high
      low = ~low
      let (sum, overflow) = low.addingReportingOverflow(1)
      low = sum
      if overflow { high &+= 1 }
    }
    if high == 0 { return (negative ? "-" : "") + String(low) }
    // Divide by 10^19 (fits in UInt64) until the value fits in one word.
    let divisor: UInt64 = 10_000_000_000_000_000_000
    var groups: [UInt64] = []
    while high != 0 {
      let (quotientHigh, remainderHigh) = high.quotientAndRemainder(dividingBy: divisor)
      let (quotientLow, remainder) = divisor.dividingFullWidth((remainderHigh, low))
      high = quotientHigh
      low = quotientLow
      groups.append(remainder)
    }
    var text = String(low)
    for group in groups.reversed() {
      let digits = String(group)
      text += String(repeating: "0", count: 19 - digits.count) + digits
    }
    return (negative ? "-" : "") + text
  }

  private static func decimalText(integer: String, scale: UInt8) -> String {
    guard scale > 0 else { return integer }
    let negative = integer.hasPrefix("-")
    var digits = negative ? String(integer.dropFirst()) : integer
    let scale = Int(scale)
    if digits.count <= scale {
      digits = String(repeating: "0", count: scale - digits.count + 1) + digits
    }
    let point = digits.index(digits.endIndex, offsetBy: -scale)
    return (negative ? "-" : "") + digits[..<point] + "." + digits[point...]
  }

  /// DuckDB stores UUID as a hugeint with the top bit flipped so it sorts as unsigned.
  private static func uuidText(lower: UInt64, upper: UInt64) -> String {
    let high = (upper ^ (UInt64(1) << 63)).bigEndian
    let low = lower.bigEndian
    var bytes = [UInt8](repeating: 0, count: 16)
    withUnsafeBytes(of: high) { bytes.replaceSubrange(0..<8, with: $0) }
    withUnsafeBytes(of: low) { bytes.replaceSubrange(8..<16, with: $0) }
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString
  }

  /// `HH:MM:SS[.ffffff]`, trailing fraction zeros dropped like DuckDB. `magnitude`, not `abs`:
  /// an INTERVAL can hold `Int64.min` microseconds.
  private static func timeText(micros: Int64) -> String {
    let negative = micros < 0
    let value = micros.magnitude
    let seconds = value / 1_000_000
    var text = String(
      format: "%02llu:%02llu:%02llu", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    let fraction = value % 1_000_000
    if fraction != 0 {
      var digits = String(format: "%06llu", fraction)
      while digits.hasSuffix("0") { digits.removeLast() }
      text += "." + digits
    }
    return (negative ? "-" : "") + text
  }

  /// TIME WITH TIME ZONE: micros in the upper 40 bits, `57599 - offset seconds` in the lower 24.
  private static func timeTZText(bits: UInt64) -> String {
    let micros = Int64(bits >> 24)
    let offset = 57_599 - Int64(bits & 0xFF_FFFF)
    let sign = offset < 0 ? "-" : "+"
    let hours = abs(offset) / 3_600
    let minutes = abs(offset) / 60 % 60
    var zone = sign + String(format: "%02lld", hours)
    if minutes != 0 { zone += String(format: ":%02lld", minutes) }
    return timeText(micros: micros) + zone
  }

  /// `1 year 2 months 3 days 04:05:06.789`, `00:00:00` when every part is zero.
  private static func intervalText(months: Int32, days: Int32, micros: Int64) -> String {
    var parts: [String] = []
    func add(_ value: Int64, _ unit: String) {
      guard value != 0 else { return }
      parts.append("\(value) \(unit)\(abs(value) == 1 ? "" : "s")")
    }
    add(Int64(months / 12), "year")
    add(Int64(months % 12), "month")
    add(Int64(days), "day")
    if micros != 0 || parts.isEmpty { parts.append(timeText(micros: micros)) }
    return parts.joined(separator: " ")
  }

  /// Printable ASCII as is, other bytes as `\xHH`, like DuckDB's BLOB text.
  private static func blobText(_ data: Data) -> String {
    data.map { byte in
      (0x20..<0x7F).contains(byte) && byte != 0x5C
        ? String(UnicodeScalar(byte)) : String(format: "\\x%02X", byte)
    }.joined()
  }

  /// BIT: first byte is the count of padding bits at the start of the second byte.
  private static func bitText(_ data: Data) -> String {
    guard let padding = data.first else { return "" }
    let bits = data.dropFirst().flatMap { byte in
      (0..<8).reversed().map { (byte >> UInt8($0)) & 1 == 1 ? "1" : "0" }
    }
    return bits.dropFirst(Int(padding)).joined()
  }

  /// Microseconds since the epoch; nil for `infinity` / `-infinity`.
  private static func timestampMicros(
    _ id: Int32, _ data: UnsafeMutableRawPointer, _ row: Int
  )
    -> Int64?
  {
    let value = data.load(fromByteOffset: row * 8, as: Int64.self)
    if value == Int64.max || value == -Int64.max { return nil }
    switch id {
    case DuckDBTypeID.timestampS:
      return value.multipliedReportingOverflow(by: 1_000_000).partialValue
    case DuckDBTypeID.timestampMS: return value.multipliedReportingOverflow(by: 1_000).partialValue
    case DuckDBTypeID.timestampNS: return value / 1_000
    default: return value
    }
  }

  private static func infinityText(_ data: UnsafeMutableRawPointer, _ row: Int) -> String {
    data.load(fromByteOffset: row * 8, as: Int64.self) > 0 ? "infinity" : "-infinity"
  }

  private static let dayFormatter = utcFormatter("yyyy-MM-dd")
  private static let secondFormatter = utcFormatter("yyyy-MM-dd HH:mm:ss")

  private static func utcFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter
  }
}
