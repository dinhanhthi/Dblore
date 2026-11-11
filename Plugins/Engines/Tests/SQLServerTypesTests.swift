// SQLServerTypesTests.swift
// The pure parts of the SQL Server engine (SQLServerTypes.swift), without FreeTDS: cells from
// buffers recorded in the shim's layouts (dblore_tds.h), server errors, the bind encoding, and
// the TLS plan's fallback rule.

import Foundation
import Testing

// MARK: - Recorded buffers

/// `value` as little-endian bytes
nonisolated private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

/// The decimal layout: precision, scale, sign (1: negative), big-endian magnitude of `digits`
nonisolated private func decimalBuffer(
  _ digits: String, precision: UInt8, scale: UInt8, negative: Bool, bytes: Int = 16
) -> [UInt8] {
  var magnitude = [UInt8](repeating: 0, count: bytes)
  for digit in digits.utf8 {
    var carry = Int(digit - 48)
    for index in magnitude.indices.reversed() {
      let value = Int(magnitude[index]) * 10 + carry
      magnitude[index] = UInt8(value & 0xFF)
      carry = value >> 8
    }
  }
  return [precision, scale, negative ? 1 : 0] + magnitude
}

/// The 16-byte date and time layout
nonisolated private func dateTimeBuffer(
  time: UInt64, days: Int32, offset: Int16 = 0, precision: UInt8
) -> [UInt8] {
  le(time) + le(days) + le(offset) + [precision, 3]
}

/// 2024-05-01, in days since 1900-01-01
nonisolated private let may1st2024: Int32 = 45_411

// MARK: - Cells

@Suite struct SQLServerCellTests {
  @Test func decimalsAndMoneyAreExactText() throws {
    // 29 significant digits: a Double keeps about 16
    #expect(
      try SQLServerTypes.cell(
        type: .decimal,
        bytes: decimalBuffer(
          "12345678901234567890123456789", precision: 38, scale: 9, negative: false))
        == .decimal("12345678901234567890.123456789"))
    #expect(
      try SQLServerTypes.cell(
        type: .numeric, bytes: decimalBuffer("5", precision: 5, scale: 3, negative: true, bytes: 2))
        == .decimal("-0.005"))
    // A negative zero is shown as zero
    #expect(
      try SQLServerTypes.cell(
        type: .numeric, bytes: decimalBuffer("0", precision: 5, scale: 2, negative: true, bytes: 2))
        == .decimal("0.00"))
    #expect(
      try SQLServerTypes.cell(type: .money, bytes: le(Int64.min))
        == .decimal("-922337203685477.5808"))
    #expect(try SQLServerTypes.cell(type: .smallMoney, bytes: le(Int32(5))) == .decimal("0.0005"))
  }

  @Test func naiveDateTimesKeepTheirWallClock() throws {
    let seconds: UInt64 = 13 * 3600 + 45 * 60 + 30
    let time = seconds * 10_000_000 + 1_234_567
    #expect(
      try SQLServerTypes.cell(
        type: .dateTime2, bytes: dateTimeBuffer(time: time, days: may1st2024, precision: 7))
        == .date("2024-05-01T13:45:30.1234567Z"))
    // datetime: ticks of 1/300 s, shown in milliseconds as the server rounds them
    let ticks = UInt32(seconds * 300 + 299)
    #expect(
      try SQLServerTypes.cell(type: .dateTime, bytes: le(may1st2024) + le(ticks))
        == .date("2024-05-01T13:45:30.997Z"))
    // Before 1900 the day count is negative
    #expect(
      try SQLServerTypes.cell(
        type: .dateTime2, bytes: dateTimeBuffer(time: 0, days: -693_595, precision: 0))
        == .date("0001-01-01T00:00:00Z"))
    let column = SQLServerColumn(
      name: "at", type: .dateTime2, serverType: .dateTime2, userType: 0, maxLength: 8)
    #expect(column.event.wallClock)
  }

  @Test func dateTimeOffsetKeepsItsOffset() throws {
    // Stored in UTC: 2024-05-01 23:30 UTC at +02:00 is 01:30 the next day there
    let utc: UInt64 = (23 * 3600 + 30 * 60) * 10_000_000
    #expect(
      try SQLServerTypes.cell(
        type: .dateTimeOffset,
        bytes: dateTimeBuffer(time: utc, days: may1st2024, offset: 120, precision: 0))
        == .date("2024-05-02T01:30:00+02:00"))
    #expect(
      try SQLServerTypes.cell(
        type: .dateTimeOffset,
        bytes: dateTimeBuffer(time: 3600 * 10_000_000, days: may1st2024, offset: -330, precision: 2)
      )
        == .date("2024-04-30T19:30:00.00-05:30"))
    let column = SQLServerColumn(
      name: "at", type: .dateTimeOffset, serverType: .dateTimeOffset, userType: 0, maxLength: 10)
    #expect(!column.event.wallClock)
  }

  @Test func uniqueIdentifierIsUpperCaseText() throws {
    let bytes: [UInt8] = [
      0xFF, 0x19, 0x96, 0x6F, 0x86, 0x8B, 0x11, 0xD0, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64,
      0xFF,
    ]
    #expect(
      try SQLServerTypes.cell(type: .uniqueIdentifier, bytes: bytes)
        == .text("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
  }

  @Test func aHostileDateTimeNeverTraps() throws {
    // Out-of-range time and day counts from a server: no overflow trap in the host process
    #expect(
      try SQLServerTypes.cell(
        type: .dateTimeOffset,
        bytes: dateTimeBuffer(time: .max, days: .max, offset: .max, precision: 7)) == .null)
    #expect(
      try SQLServerTypes.cell(
        type: .dateTime2, bytes: dateTimeBuffer(time: 0, days: .min, precision: 7)) == .null)
  }

  @Test func aValueOverTheLimitFailsBeforeItIsCopied() throws {
    // A buffer that only claims its size: decoding it would read unmapped memory
    let size = EnginePluginProtocol.maxValueBytes + 1
    let bytes = UnsafeRawBufferPointer(
      start: UnsafeRawPointer(bitPattern: 0x1000), count: size)
    do {
      _ = try SQLServerTypes.cell(type: .varBinary, bytes: bytes)
      Issue.record("an oversized value was accepted")
    } catch let failure as EngineFailure {
      #expect(failure.code == .tooLarge)
    }
  }
}

// MARK: - Errors

@Suite struct SQLServerErrorTests {
  @Test func aServerErrorKeepsTheServerText() {
    let failure = SQLServerTypes.failure(
      code: .query, message: "Invalid object name 'dbo.Missing'.", number: 208, state: 1)
    #expect(failure.message == "Invalid object name 'dbo.Missing'. (state 1)")
    #expect(failure.serverCode == "208")
    #expect(failure.code == .query)
  }
}

// MARK: - Binds

/// The values of every `'...'` literal in `text`, read per scalar as SQL Server lexes them (`''`
/// is one quote, a lone `'` ends the literal), and the text after the last one. A backslash
/// directly before CR or LF inside a literal is recorded in `continuations`.
nonisolated private func literals(
  in text: String
) -> (values: [[Unicode.Scalar]], rest: [Unicode.Scalar], continuations: Int) {
  let scalars = Array(text.unicodeScalars)
  var values: [[Unicode.Scalar]] = []
  var continuations = 0
  var index = 0
  var restStart = 0
  while index < scalars.count {
    guard scalars[index] == "'" else {
      index += 1
      continue
    }
    var value: [Unicode.Scalar] = []
    index += 1
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "'" {
        if index + 1 < scalars.count, scalars[index + 1] == "'" {
          value.append("'")
          index += 2
          continue
        }
        break
      }
      if scalar == "\\", index + 1 < scalars.count, ["\r", "\n"].contains(scalars[index + 1]) {
        continuations += 1
      }
      value.append(scalar)
      index += 1
    }
    values.append(value)
    index += 1
    restStart = index
  }
  return (values, Array(scalars[min(restStart, scalars.count)...]), continuations)
}

/// Hostile and harmless values: quotes and backslashes followed by combining or joining scalars,
/// line breaks after a backslash, and plain Unicode
nonisolated private let trickyValues = [
  "x'\u{0301}y", "'\u{FE0F}", "a'\u{200D}'", "a\\\r", "a\\\n", "a\\\r\nb", "\\\u{0301}\n",
  "日本語 ✓", "",
]

@Suite struct SQLServerBindTests {
  @Test func bindsAreDeclaredAheadOfTheStatement() {
    let sql = "UPDATE t SET a = @p1, b = @p2, c = @p3 WHERE d = @p4"
    #expect(
      SQLServerTypes.batch(sql, binds: ["O'Brien", nil, "", "日本語 ✓"])
        == "DECLARE @p1 nvarchar(max) = N'O''Brien', @p2 nvarchar(max) = NULL, "
        + "@p3 nvarchar(max) = N'', @p4 nvarchar(max) = N'日本語 ✓'; " + sql)
    // Without binds the statement goes as it is, quotes untouched
    #expect(SQLServerTypes.batch("SELECT 'x'", binds: []) == "SELECT 'x'")
  }

  @Test(arguments: trickyValues)
  func everyValueReadsBackWhole(_ value: String) {
    let read = literals(in: SQLServerTypes.batch("SELECT @p1", binds: [value]))
    // Every literal piece joined is the value, scalar for scalar, and nothing leaks out of them
    #expect(read.values.joined().map { $0 } == Array(value.unicodeScalars))
    #expect(String(String.UnicodeScalarView(read.rest)) == "; SELECT @p1")
    #expect(read.continuations == 0)
  }

  @Test(arguments: ["a]\u{0301}b", "]\u{FE0F}", "x]]\u{200D}", "plain"])
  func identifiersReadBackWhole(_ name: String) {
    let quoted = Array(SQLServerTypes.quoted(name).unicodeScalars)
    #expect(quoted.first == "[" && quoted.last == "]")
    // Inside the brackets every `]` is doubled, so none ends the identifier early
    var name2: [Unicode.Scalar] = []
    var index = 1
    while index < quoted.count - 1 {
      if quoted[index] == "]" {
        #expect(quoted[index + 1] == "]")
        index += 1
      }
      name2.append(quoted[index])
      index += 1
    }
    #expect(name2 == Array(name.unicodeScalars))
  }

  @Test func aBackslashBeforeALineBreakIsKept() {
    // T-SQL would drop `\` and the break after it inside one literal
    #expect(
      SQLServerTypes.expression("a\\\nb") == "CAST(N'a\\' AS nvarchar(max)) + N'\nb'")
    #expect(
      SQLServerTypes.expression("c\\\r\nd'") == "CAST(N'c\\' AS nvarchar(max)) + N'\r\nd'''")
    // Elsewhere a backslash is plain text
    #expect(SQLServerTypes.expression("e\\f\\") == "N'e\\f\\'")
  }
}

// MARK: - TLS plan

@Suite struct SQLServerTLSPlanTests {
  private let strict = SQLServerTLSPlan.Attempt(
    encryption: .strict, verifiesChain: true, checksHostName: true)
  private let mandatory = SQLServerTLSPlan.Attempt(
    encryption: .require, verifiesChain: true, checksHostName: true)

  @Test func onlyAFailureBeforeAnyCertificateFallsBack() {
    let plan = SQLServerTLSPlan(mode: .verifyFull)
    #expect(plan.first == strict)
    for failure: SQLServerTLSPlan.Failure in [
      .afterCertificate, .unencrypted, .unreachable, .local, .refused,
    ] {
      #expect(plan.next(after: strict, failure: failure) == nil, "\(failure)")
    }
    let fallback = plan.next(after: strict, failure: .beforeCertificate)
    #expect(fallback == mandatory)
    // Once only
    #expect(plan.next(after: mandatory, failure: .beforeCertificate) == nil)
  }

  @Test func withoutStrictVerifyFullIsMandatoryTLSWithTheHostCheck() {
    let plan = SQLServerTLSPlan(mode: .verifyFull, tdsStrict: false)
    #expect(plan.attempts == [mandatory])
    #expect(plan.next(after: mandatory, failure: .beforeCertificate) == nil)
  }

  @Test func mandatoryModesNeverFallBack() {
    for mode: EngineRequest.Open.TLS.Mode in [.require, .verifyCA] {
      let plan = SQLServerTLSPlan(mode: mode)
      #expect(plan.first.requiresEncryption, "\(mode)")
      #expect(plan.next(after: plan.first, failure: .beforeCertificate) == nil, "\(mode)")
      #expect(plan.next(after: plan.first, failure: .unencrypted) == nil, "\(mode)")
    }
  }
}
