// PostgresDateDecodingTests.swift
// A PostgreSQL DATE has no time and no time zone: it decodes to its `YYYY-MM-DD` text, never
// to midnight UTC (which showed the day before west of UTC).

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@Suite struct PostgresDateDecodingTests {
  private static func cell(_ bytes: ByteBuffer, format: PostgresFormat) -> CellValue {
    DatabaseConnectionManager.parseCellValue(
      from: PostgresCell(
        bytes: bytes, dataType: .date, format: format, columnName: "day", columnIndex: 0))
  }

  /// Binary DATE: big-endian Int32 days since 2000-01-01.
  private static func binary(days: Int32) -> CellValue {
    var buffer = ByteBuffer()
    buffer.writeInteger(days, endianness: .big)
    return cell(buffer, format: .binary)
  }

  @MainActor @Test("A binary DATE decodes to its date text, not midnight UTC")
  func binaryDateIsDateText() {
    // 2000-01-01 + 25 years with 7 leap days.
    #expect(Self.binary(days: 9_132) == .string("2025-01-01"))
    #expect(Self.binary(days: 0) == .string("2000-01-01"))
    // Proleptic Gregorian before the 1582 reform and BC years, as the server prints them.
    #expect(Self.binary(days: -730_119) == .string("0001-01-01"))
    #expect(Self.binary(days: -730_485) == .string("0001-01-01 BC"))
    #expect(Self.binary(days: Int32.max) == .string("infinity"))
    #expect(Self.binary(days: Int32.min) == .string("-infinity"))
  }

  @MainActor @Test("A text DATE keeps the server's text")
  func textDateIsKept() {
    #expect(Self.cell(ByteBuffer(string: "2025-01-01"), format: .text) == .string("2025-01-01"))
  }
}
