// UUIDGenerator.swift
// UUID text for "Generate UUID" and "Generate UUIDv7": lowercase canonical 8-4-4-4-12 form.
// v4 comes from Foundation, v7 follows RFC 9562 section 5.7; `fits` picks the columns.

import Foundation

nonisolated enum UUIDGenerator {
  /// Whether a result column of `columnType` can hold UUID text: `uuid`, a text type, or a
  /// character type of at least 36 characters. A character type with no length in the name
  /// (MySQL result columns, PostgreSQL `varchar`) is offered and the server checks it.
  static func fits(columnType: String) -> Bool {
    let type = columnType.lowercased().trimmingCharacters(in: .whitespaces)
    let base = String(type.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
    if base == "uuid" || base.hasSuffix("text") { return true }
    let characterTypes: Set<String> = [
      "char", "character", "varchar", "character varying", "bpchar", "nchar", "nvarchar",
    ]
    guard characterTypes.contains(base) else { return false }
    guard let open = type.firstIndex(of: "("), let close = type.firstIndex(of: ")"), open < close
    else { return true }
    let length = Int(type[type.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    return length.map { $0 >= 36 } ?? false
  }

  /// A random (version 4) UUID
  static func v4() -> String {
    UUID().uuidString.lowercased()
  }

  /// A time-ordered (version 7) UUID for the current time
  static func v7() -> String {
    var random = SystemRandomNumberGenerator()
    let milliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    return v7(milliseconds: milliseconds, using: &random)
  }

  /// RFC 9562 section 5.7: the low 48 bits of `milliseconds` (Unix epoch) big-endian in bytes
  /// 0-5, version 7 in the high nibble of byte 6, variant `10` in the high bits of byte 8, and
  /// every other bit from `random`.
  static func v7(milliseconds: UInt64, using random: inout some RandomNumberGenerator) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0..<6 {
      bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
    }
    for index in 6..<16 {
      bytes[index] = random.next()
    }
    bytes[6] = 0x70 | (bytes[6] & 0x0F)
    bytes[8] = 0x80 | (bytes[8] & 0x3F)
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString.lowercased()
  }
}
