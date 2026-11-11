// SQLServerTypesTests.swift
// The pure parts of the SQL Server engine (SQLServerTypes.swift), without FreeTDS: cells from
// buffers recorded in the shim's layouts (dblore_tds.h), server errors, the bind encoding, the
// catalog's table names from the app, result column origins from describe rows, and the TLS
// plan's fallback rule.

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

  @Test func theBindPreludeCountsNoRows() {
    // The prelude's DECLARE is the first result of a batch with binds: its one row is not added
    #expect(!SQLServerTypes.countsRows(result: 0, hasBinds: true))
    #expect(SQLServerTypes.countsRows(result: 1, hasBinds: true))
    #expect(SQLServerTypes.countsRows(result: 2, hasBinds: true))
    // Without binds every result is the statement's own
    #expect(SQLServerTypes.countsRows(result: 0, hasBinds: false))
    #expect(SQLServerTypes.countsRows(result: 1, hasBinds: false))
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

// MARK: - Catalog names

/// Names with brackets, dots and combining scalars after a `]`
nonisolated private let trickyNames = [
  "a]\u{0301}b", "]\u{FE0F}", "x]]\u{200D}", "plain", "a.b", "[x]", ".", "with space", "日本語",
]

@Suite struct SQLServerNameTests {
  @Test(arguments: trickyNames)
  func aBracketedNameReadsBackWhole(_ name: String) throws {
    let both = SQLServerTypes.quoted(name) + "." + SQLServerTypes.quoted(name + "2")
    let parts = try #require(SQLServerTypes.qualifiedName(both))
    #expect(parts.schema.map { Array($0.unicodeScalars) } == Array(name.unicodeScalars))
    #expect(Array(parts.table.unicodeScalars) == Array((name + "2").unicodeScalars))
    let alone = try #require(SQLServerTypes.qualifiedName(SQLServerTypes.quoted(name)))
    #expect(alone.schema == nil)
    #expect(Array(alone.table.unicodeScalars) == Array(name.unicodeScalars))
  }

  @Test func bareAndMixedPartsAreTakenAsWritten() throws {
    for (name, schema, table): (String, String?, String) in [
      ("users", nil, "users"), ("DBO.USERS", "DBO", "USERS"),
      ("SALES.[order.items]", "SALES", "order.items"),
      ("[dbo].T", "dbo", "T"),
    ] {
      let parts = try #require(SQLServerTypes.qualifiedName(name), "\(name)")
      #expect(parts.schema == schema, "\(name)")
      #expect(parts.table == table, "\(name)")
    }
  }

  /// An unclosed bracket (`]]` is no close), text after `]`, an empty part, three parts, a bare
  /// bracket
  @Test(arguments: ["[dbo].[t", "[a]]", "[a]b", "[]", ".t", "a.b.c", "a]b"])
  func aMalformedNameIsRefused(_ name: String) {
    #expect(SQLServerTypes.qualifiedName(name) == nil)
  }
}

// MARK: - Result column origins

@Suite struct SQLServerOriginTests {
  private typealias Described = SQLServerTypes.DescribedColumn

  /// The procedure's column names (the DMF adds `error_number`)
  private static let procedureNames = [
    "is_hidden", "column_ordinal", "name", "is_nullable", "system_type_id", "source_server",
    "source_database", "source_schema", "source_table", "source_column",
  ]

  private func base(_ ordinal: Int, _ name: String, column: String? = nil) -> Described {
    Described(
      ordinal: ordinal, name: name, database: "shop", schema: "dbo", table: "orders",
      column: column ?? name)
  }

  private func columns(_ names: String...) -> [EngineEvent.Column] {
    names.map { EngineEvent.Column(name: $0, type: "int") }
  }

  @Test func paramsDeclareEveryAppBindOnce() {
    #expect(
      SQLServerTypes.describeParameters("SELECT * FROM t WHERE a = @p1 AND b = @p2 OR c = @p1")
        == "@p1 nvarchar(max), @p2 nvarchar(max)")
    #expect(SQLServerTypes.describeParameters("SELECT @p12") == "@p12 nvarchar(max)")
    #expect(SQLServerTypes.describeParameters("@p3,@p1") == "@p3 nvarchar(max), @p1 nvarchar(max)")
    // The app reads `@P1` as bind 1 too
    #expect(SQLServerTypes.describeParameters("SELECT @P1, @p1") == "@p1 nvarchar(max)")
  }

  @Test(arguments: [
    "SELECT * FROM t", "SELECT @p", "SELECT @pX", "SELECT @p1x", "SELECT a@p1",
    "SELECT @@p1", "SELECT @p_1",
  ])
  func paramsIgnoreWhatIsNoAppBind(_ sql: String) {
    #expect(SQLServerTypes.describeParameters(sql) == nil)
  }

  @Test func procedureRowsAreReadByName() throws {
    let rows: [[EngineCell]] = [
      [
        .bool(false), .int(1), .text("id"), .bool(false), .int(56), .null, .text("shop"),
        .text("dbo"), .text("orders"), .text("id"),
      ],
      [.bool(false), .int(2), .null, .bool(true), .int(56), .null, .null, .null, .null, .null],
    ]
    let described = try #require(
      SQLServerTypes.describedColumns(names: Self.procedureNames, rows: rows))
    #expect(described == [base(1, "id"), Described(ordinal: 2, name: "")])
  }

  @Test func dmfErrorRowsOrAMissingColumnGiveNothing() {
    let names = [
      "is_hidden", "column_ordinal", "name", "source_server", "source_database",
      "source_schema", "source_table", "source_column", "error_number",
    ]
    let error: [EngineCell] = [.null, .null, .null, .null, .null, .null, .null, .null, .int(208)]
    #expect(SQLServerTypes.describedColumns(names: names, rows: [error]) == nil)
    let fine: [EngineCell] = [
      .bool(false), .int(1), .text("id"), .null, .text("shop"), .text("dbo"), .text("orders"),
      .text("id"), .null,
    ]
    #expect(SQLServerTypes.describedColumns(names: names, rows: [fine]) == [base(1, "id")])
    #expect(SQLServerTypes.describedColumns(names: Array(names.dropFirst()), rows: []) == nil)
    // A row of another width
    #expect(SQLServerTypes.describedColumns(names: names, rows: [Array(fine.dropLast())]) == nil)
  }

  @Test func baseColumnsGetOriginsAliasesTheirBaseExpressionsNone() {
    let described = [
      base(2, "order_id", column: "id"), base(1, "note"), Described(ordinal: 3, name: "two"),
      // Browse mode adds the key when the result lacks it
      Described(
        isHidden: true, ordinal: 4, name: "id", database: "shop", schema: "dbo",
        table: "orders", column: "id"),
    ]
    let origins = SQLServerTypes.originColumns(
      columns("note", "order_id", "two"), described: described, database: "shop"
    ).map(\.origin)
    #expect(
      origins == [
        .init(schema: "dbo", table: "orders", column: "note"),
        .init(schema: "dbo", table: "orders", column: "id"), nil,
      ])
  }

  @Test func anotherDatabaseOrServerOrAPartialSourceHasNoOrigin() {
    var otherDatabase = base(1, "a")
    otherDatabase.database = "archive"
    var linked = base(2, "b")
    linked.server = "remote"
    var noTable = base(3, "c")
    noTable.table = nil
    let kept = SQLServerTypes.originColumns(
      columns("a", "b", "c", "d"), described: [otherDatabase, linked, noTable, base(4, "d")],
      database: "shop")
    #expect(
      kept.map(\.origin) == [nil, nil, nil, .init(schema: "dbo", table: "orders", column: "d")])
  }

  @Test func aCountOrNameMismatchFailsClosed() {
    let input = columns("id", "note").map {
      var column = $0
      column.origin = .init(schema: "x", table: "y", column: "z")
      column.wallClock = true
      return column
    }
    for described: [Described]? in [
      [base(1, "id")], [base(1, "id"), base(2, "Note")], [base(1, "id"), base(2, "note\u{301}")],
      [base(1, "id"), base(2, "note"), base(3, "extra")], nil,
    ] {
      let kept = SQLServerTypes.originColumns(input, described: described, database: "shop")
      #expect(kept.map(\.origin) == [nil, nil])
      #expect(kept.map(\.name) == ["id", "note"])
      #expect(kept.allSatisfy { $0.wallClock })
    }
    // No database read
    #expect(
      SQLServerTypes.originColumns(
        columns("id"), described: [base(1, "id")], database: nil
      ).map(\.origin) == [nil])
  }

  @Test func requestColumnsDecodeTheWireFormAndDropOrigins() {
    let wire = EngineJSONValue.array([
      .object(["name": .string("id"), "type": .string("int"), "wallClock": .bool(false)]),
      .object([
        "name": .string("at"), "type": .string("datetime2"), "wallClock": .bool(true),
        "origin": .object([
          "schema": .string("dbo"), "table": .string("t"), "column": .string("at"),
        ]),
      ]),
    ])
    #expect(
      SQLServerTypes.requestColumns(wire) == [
        .init(name: "id", type: "int"), .init(name: "at", type: "datetime2", wallClock: true),
      ])
    #expect(SQLServerTypes.requestColumns(nil) == nil)
    #expect(SQLServerTypes.requestColumns(.array([.object(["name": .string("id")])])) == nil)
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
