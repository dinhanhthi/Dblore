// PostgresNumericDecodingTests.swift
// A PostgreSQL NUMERIC decodes to its exact text (`.decimal`), never through Double: every digit
// and the scale's zeros are kept, and NaN / Infinity / -Infinity are values, not NULL or 0.

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@MainActor @Suite struct PostgresNumericDecodingTests {
  private static func cell(_ bytes: ByteBuffer, format: PostgresFormat) -> CellValue {
    DatabaseConnectionManager.parseCellValue(
      from: PostgresCell(
        bytes: bytes, dataType: .numeric, format: format, columnName: "amount", columnIndex: 0))
  }

  /// numeric_send: digit count, weight, sign, display scale (Int16 each, big-endian), then the
  /// base-10000 digits
  private static func binary(
    _ digits: [Int16], weight: Int16, sign: UInt16 = 0, dscale: Int16
  ) -> CellValue {
    var buffer = ByteBuffer()
    buffer.writeInteger(Int16(digits.count), endianness: .big)
    buffer.writeInteger(weight, endianness: .big)
    buffer.writeInteger(sign, endianness: .big)
    buffer.writeInteger(dscale, endianness: .big)
    for digit in digits { buffer.writeInteger(digit, endianness: .big) }
    return cell(buffer, format: .binary)
  }

  /// `text` (plain digits) as numeric_send writes it: groups of four digits around the point,
  /// without leading or trailing zero groups
  private static func binary(plain text: String) -> CellValue {
    let negative = text.hasPrefix("-")
    let parts = text.drop { $0 == "-" }.split(separator: ".", omittingEmptySubsequences: false)
    let integer = String(parts[0])
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    let paddedInteger = String(repeating: "0", count: (4 - integer.count % 4) % 4) + integer
    let paddedFraction = fraction + String(repeating: "0", count: (4 - fraction.count % 4) % 4)
    var groups = Array(paddedInteger + paddedFraction).chunked(4).map { Int16(String($0))! }
    var weight = Int16(paddedInteger.count / 4) - 1
    while groups.first == 0 {
      groups.removeFirst()
      weight -= 1
    }
    while groups.last == 0 { groups.removeLast() }
    if groups.isEmpty { weight = 0 }
    return binary(
      groups, weight: weight, sign: negative ? 0x4000 : 0, dscale: Int16(fraction.count))
  }

  @Test("NaN and Infinity decode as values, not NULL or 0 (regression N2)")
  func specialValues() {
    #expect(Self.binary([], weight: 0, sign: 0xC000, dscale: 0) == .decimal("NaN"))
    #expect(Self.binary([], weight: 0, sign: 0xD000, dscale: 0) == .decimal("Infinity"))
    #expect(Self.binary([], weight: 0, sign: 0xF000, dscale: 0) == .decimal("-Infinity"))
    #expect(Self.cell(ByteBuffer(string: "NaN"), format: .text) == .decimal("NaN"))
    #expect(Self.cell(ByteBuffer(string: "-Infinity"), format: .text) == .decimal("-Infinity"))
  }

  @Test("Binary NUMERIC is the server's text: scale zeros, sign, zero and small fractions kept")
  func binaryText() {
    #expect(Self.binary([19, 9000], weight: 0, dscale: 2) == .decimal("19.90"))
    #expect(Self.binary([1329, 9800], weight: 0, sign: 0x4000, dscale: 2) == .decimal("-1329.98"))
    #expect(Self.binary([], weight: 0, dscale: 2) == .decimal("0.00"))
    #expect(Self.binary([1], weight: 1, dscale: 0) == .decimal("10000"))
    #expect(Self.binary([1], weight: -1, dscale: 4) == .decimal("0.0001"))
    #expect(Self.binary([1200], weight: -2, dscale: 6) == .decimal("0.000012"))
    #expect(Self.cell(ByteBuffer(string: "19.90"), format: .text) == .decimal("19.90"))
  }

  @Test("40- and 309-digit values decode exactly")
  func longValuesExact() {
    let forty = "1234567890123456789012345678901234567890"
    #expect(Self.binary(plain: forty) == .decimal(forty))
    let long = String(repeating: "123456789", count: 34) + "123"
    #expect(long.count == 309)
    #expect(Self.binary(plain: long) == .decimal(long))
    let fraction = "-" + forty + "." + forty
    #expect(Self.binary(plain: fraction) == .decimal(fraction))
  }

  @Test("An edit of a decoded NUMERIC binds the typed text exactly (regression N1)")
  func editBindsTypedText() {
    let typed = "12345678901234567890.12"
    let decoded = Self.binary(plain: typed)
    let edited = NotebookViewModel.editedCellValue(typed, original: decoded)
    #expect(CellUpdateStatement.inputText(edited, dialect: .postgresql) == typed)
  }
}

extension Array {
  fileprivate func chunked(_ size: Int) -> [ArraySlice<Element>] {
    stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
  }
}
