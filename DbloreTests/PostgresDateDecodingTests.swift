// PostgresDateDecodingTests.swift
// A PostgreSQL DATE has no time and no time zone: it decodes to its `YYYY-MM-DD` text, never
// to midnight UTC (which showed the day before west of UTC). Timestamps decode in both wire
// formats; a naive (wall-clock) column shows its stored wall clock under any time zone.

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@Suite(.serialized) struct PostgresDateDecodingTests {
  private static func cell(
    _ bytes: ByteBuffer, format: PostgresFormat, type: PostgresDataType = .date
  ) -> CellValue {
    DatabaseConnectionManager.parseCellValue(
      from: PostgresCell(
        bytes: bytes, dataType: type, format: format, columnName: "day", columnIndex: 0))
  }

  /// 2026-10-15 12:00:00 UTC.
  private static let noonSeconds: Double = 1_792_065_600

  /// `body` with `NSTimeZone.default` set to `identifier`, restored afterwards.
  private static func inZone<T>(_ identifier: String, _ body: () -> T) -> T {
    let saved = NSTimeZone.default
    NSTimeZone.default = TimeZone(identifier: identifier)!
    defer { NSTimeZone.default = saved }
    return body()
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

  @MainActor @Test("A text timestamp decodes instead of NULL, infinity included (regression N8)")
  func textTimestampDecodes() {
    let naive = Self.cell(
      ByteBuffer(string: "2026-10-15 12:00:00.123456"), format: .text, type: .timestamp)
    #expect(naive == .date(Date(timeIntervalSince1970: Self.noonSeconds + 0.123456)))
    let zoned = Self.cell(
      ByteBuffer(string: "2026-10-15 19:00:00.5+07"), format: .text, type: .timestamptz)
    #expect(zoned == .date(Date(timeIntervalSince1970: Self.noonSeconds + 0.5)))
    let halfHour = Self.cell(
      ByteBuffer(string: "2026-10-15 09:30:00-02:30"), format: .text, type: .timestamptz)
    #expect(halfHour == .date(Date(timeIntervalSince1970: Self.noonSeconds)))
    #expect(
      Self.cell(ByteBuffer(string: "infinity"), format: .text, type: .timestamp)
        == .string("infinity"))
    #expect(
      Self.cell(ByteBuffer(string: "-infinity"), format: .text, type: .timestamptz)
        == .string("-infinity"))
    // Another DateStyle keeps the server's text, never NULL
    #expect(
      Self.cell(ByteBuffer(string: "10/15/2026 12:00:00"), format: .text, type: .timestamp)
        == .string("10/15/2026 12:00:00"))
  }

  @MainActor @Test("A binary infinite timestamp is its word, not a far-future date")
  func binaryInfinityIsText() {
    var positive = ByteBuffer()
    positive.writeInteger(Int64.max, endianness: .big)
    #expect(Self.cell(positive, format: .binary, type: .timestamp) == .string("infinity"))
    var negative = ByteBuffer()
    negative.writeInteger(Int64.min, endianness: .big)
    #expect(Self.cell(negative, format: .binary, type: .timestamptz) == .string("-infinity"))
  }

  @Test("Only a naive timestamp column is wall clock")
  func postgresWallClockFlag() {
    #expect(DatabaseConnectionManager.postgresWallClock(.timestamp))
    #expect(!DatabaseConnectionManager.postgresWallClock(.timestamptz))
    #expect(!DatabaseConnectionManager.postgresWallClock(.date))
  }

  @Test("The wall-clock flag is an optional saved key; absent means zoned")
  func wallClockCoding() throws {
    let old = try JSONDecoder().decode(
      ColumnInfo.self, from: Data(#"{"name":"at","type":"TIMESTAMP"}"#.utf8))
    #expect(old.wallClock == false)
    let naive = ColumnInfo(name: "at", type: "TIMESTAMP", wallClock: true)
    let data = try JSONEncoder().encode(naive)
    #expect(try JSONDecoder().decode(ColumnInfo.self, from: data).wallClock)
    let zoned = try JSONEncoder().encode(ColumnInfo(name: "at", type: "TIMESTAMPTZ"))
    #expect(!String(decoding: zoned, as: UTF8.self).contains("wallClock"))
  }

  @Test("A naive timestamp shows its stored wall clock in any time zone")
  func naiveDisplayIsWallClock() {
    let value = CellValue.date(Date(timeIntervalSince1970: Self.noonSeconds + 0.123))
    let whole = CellValue.date(Date(timeIntervalSince1970: Self.noonSeconds))
    let micro = CellValue.date(Date(timeIntervalSince1970: Self.noonSeconds + 0.000001))
    for zone in ["Asia/Ho_Chi_Minh", "America/Los_Angeles", "UTC"] {
      let texts = Self.inZone(zone) {
        [value, whole, micro].map { $0.displayString(wallClock: true) }
      }
      #expect(
        texts == ["2026-10-15 12:00:00.123", "2026-10-15 12:00:00", "2026-10-15 12:00:00.000001"])
    }
  }

  @Test("A zoned timestamp shows Mac local time with its offset")
  func zonedDisplayCarriesOffset() {
    let value = CellValue.date(Date(timeIntervalSince1970: Self.noonSeconds + 0.123))
    #expect(
      Self.inZone("Asia/Ho_Chi_Minh") { value.displayString } == "2026-10-15 19:00:00.123+07:00")
    #expect(
      Self.inZone("America/St_Johns") { value.displayString(wallClock: false) }
        == "2026-10-15 09:30:00.123-02:30")
  }
}
