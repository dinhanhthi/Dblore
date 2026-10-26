// MySQLValueConverterTests.swift
// MySQLData (text and binary protocol) -> CellValue, decoded from raw bytes where mysql-nio's
// accessors are lossy (spike 2.3), and MySQLServerInfo version parsing. The live round trip
// against the docker MySQL 8.4 / MariaDB 11.4 servers is opt-in (`.requiresMySQL`).
// Never interpolate or `#expect` a MySQLData: its `description` force-unwraps.

import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import Testing

@testable import Dblore

@Suite @MainActor struct MySQLValueConverterTests {
  private typealias DataType = MySQLProtocol.DataType

  // 2024-01-02 03:04:05 UTC.
  private static let epochSeconds: Double = 1_704_164_645

  private static func text(_ value: String, _ type: DataType, unsigned: Bool = false) -> MySQLData {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return MySQLData(type: type, format: .text, buffer: buffer, isUnsigned: unsigned)
  }

  private static func binary(
    _ bytes: [UInt8], _ type: DataType, unsigned: Bool = false
  )
    -> MySQLData
  {
    var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    return MySQLData(type: type, format: .binary, buffer: buffer, isUnsigned: unsigned)
  }

  private static func cell(
    _ data: MySQLData, charset: MySQLProtocol.CharacterSet = .utf8mb4, decimals: UInt8 = 0
  ) -> CellValue {
    MySQLValueConverter.cell(
      data, column: MySQLValueConverter.Column(characterSet: charset, decimals: decimals))
  }

  // MARK: - NULL and integers

  @Test func nullInBothProtocols() {
    #expect(Self.cell(MySQLData(type: .long, format: .text, buffer: nil)) == .null)
    #expect(Self.cell(MySQLData(type: .varString, format: .binary, buffer: nil)) == .null)
    #expect(Self.cell(MySQLData(type: .null, format: .binary, buffer: nil)) == .null)
    // An empty string is not NULL.
    #expect(Self.cell(Self.binary([], .varString)) == .string(""))
  }

  @Test func integersSignedAndUnsigned() {
    #expect(Self.cell(Self.text("-42", .long)) == .int(-42))
    #expect(Self.cell(Self.binary([0xD6], .tiny)) == .int(-42))
    #expect(Self.cell(Self.binary([0xD6], .tiny, unsigned: true)) == .int(214))
    #expect(Self.cell(Self.binary([0xFE, 0xFF], .short)) == .int(-2))
    #expect(Self.cell(Self.binary([0xFE, 0xFF, 0xFF, 0xFF], .int24)) == .int(-2))
    #expect(
      Self.cell(Self.binary([0xFE, 0xFF, 0xFF, 0xFF], .long, unsigned: true)) == .int(4_294_967_294)
    )
    #expect(
      Self.cell(Self.binary([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F], .longlong))
        == .int(Int.max))
  }

  @Test func unsignedBigintBeyondInt64IsText() {
    let max = "18446744073709551615"
    #expect(Self.cell(Self.text(max, .longlong, unsigned: true)) == .string(max))
    #expect(
      Self.cell(Self.binary([UInt8](repeating: 0xFF, count: 8), .longlong, unsigned: true))
        == .string(max))
  }

  // MARK: - FLOAT, DOUBLE, DECIMAL

  @Test func floatingPoint() {
    #expect(Self.cell(Self.text("1.5", .double)) == .double(1.5))
    #expect(Self.cell(Self.text("1.1", .float)) == .double(1.1))
    // Binary FLOAT shows the same value as the text protocol, not 1.100000023841858.
    let float = withUnsafeBytes(of: Float(1.1).bitPattern.littleEndian, Array.init)
    #expect(Self.cell(Self.binary(float, .float)) == .double(1.1))
    let double = withUnsafeBytes(of: (-2.25).bitPattern.littleEndian, Array.init)
    #expect(Self.cell(Self.binary(double, .double)) == .double(-2.25))
  }

  @Test func decimalIsExactText() {
    let value = "12345678901234567890.123456"
    #expect(Self.cell(Self.text(value, .newdecimal)) == .string(value))
    #expect(Self.cell(Self.binary(Array(value.utf8), .newdecimal)) == .string(value))
  }

  // MARK: - Dates and times

  @Test func datetimeWithMicroseconds() {
    let expected = CellValue.date(Date(timeIntervalSince1970: Self.epochSeconds + 0.123456))
    #expect(
      Self.cell(Self.text("2024-01-02 03:04:05.123456", .datetime), decimals: 6) == expected)
    // 2024 = 0x07E8; micros 123456 = 0x01E240.
    let bytes: [UInt8] = [0xE8, 0x07, 1, 2, 3, 4, 5, 0x40, 0xE2, 0x01, 0x00]
    #expect(Self.cell(Self.binary(bytes, .timestamp), decimals: 6) == expected)
    let whole = CellValue.date(Date(timeIntervalSince1970: Self.epochSeconds))
    #expect(Self.cell(Self.text("2024-01-02 03:04:05", .timestamp)) == whole)
    #expect(Self.cell(Self.binary(Array(bytes.prefix(7)), .datetime)) == whole)
  }

  @Test func dateValue() {
    // No time and no time zone: the date text, never midnight UTC.
    let expected = CellValue.string("2024-01-02")
    #expect(Self.cell(Self.text("2024-01-02", .date)) == expected)
    #expect(Self.cell(Self.binary([0xE8, 0x07, 1, 2], .date)) == expected)
    #expect(Self.cell(Self.text("1000-01-01", .date)) == .string("1000-01-01"))
    // Before the Gregorian reform: proleptic calendar, like the server.
    #expect(
      Self.cell(Self.text("1000-01-01 00:00:00", .datetime))
        == .date(Date(timeIntervalSince1970: -30_610_224_000)))
  }

  @Test func zeroDatesAreText() {
    #expect(Self.cell(Self.text("0000-00-00", .date)) == .string("0000-00-00"))
    #expect(Self.cell(Self.binary([], .date)) == .string("0000-00-00"))
    #expect(Self.cell(Self.binary([], .datetime)) == .string("0000-00-00 00:00:00"))
    #expect(
      Self.cell(Self.binary([], .datetime), decimals: 3) == .string("0000-00-00 00:00:00.000"))
    #expect(
      Self.cell(Self.text("0000-00-00 00:00:00", .timestamp)) == .string("0000-00-00 00:00:00"))
    // Zero month or day (NO_ZERO_IN_DATE off).
    #expect(Self.cell(Self.binary([0xE8, 0x07, 0, 0], .date)) == .string("2024-00-00"))
    #expect(Self.cell(Self.text("2024-02-00", .date)) == .string("2024-02-00"))
  }

  @Test func outOfRangeDateTextStaysText() {
    let hostile: [(String, DataType)] = [
      ("9223372036854775807-01-01", .date),
      ("10000-01-01", .newdate),
      ("2024-13-01", .date),
      ("2024-01-32", .date),
      ("2024-01-01 99999999999999999:00:00", .datetime),
      ("2024-01-01 24:00:00", .datetime2),
      ("2024-01-01 00:60:00", .timestamp),
      ("2024-01-01 00:00:9223372036854775807", .timestamp2),
      ("2024-01-01 00:00:00.1234567", .datetime),
    ]
    for (text, type) in hostile {
      #expect(Self.cell(Self.text(text, type)) == .string(text), "\(text)")
    }
  }

  @Test func timeIsTextIncludingDaysAndSign() {
    #expect(Self.cell(Self.text("25:30:15", .time)) == .string("25:30:15"))
    #expect(Self.cell(Self.text("-01:02:03", .time)) == .string("-01:02:03"))
    // is_negative, days (u32 LE), hour, minute, second.
    #expect(Self.cell(Self.binary([0, 1, 0, 0, 0, 1, 30, 15], .time)) == .string("25:30:15"))
    #expect(Self.cell(Self.binary([1, 0, 0, 0, 0, 1, 2, 3], .time)) == .string("-01:02:03"))
    #expect(
      Self.cell(Self.binary([0, 34, 0, 0, 0, 22, 59, 59], .time)) == .string("838:59:59"))
    #expect(Self.cell(Self.binary([], .time)) == .string("00:00:00"))
    // Fraction padded to the column's precision; 500000 micros = 0x07A120.
    let fraction: [UInt8] = [0, 0, 0, 0, 0, 12, 0, 0, 0x20, 0xA1, 0x07, 0x00]
    #expect(Self.cell(Self.binary(fraction, .time), decimals: 3) == .string("12:00:00.500"))
    #expect(Self.cell(Self.binary([], .time), decimals: 2) == .string("00:00:00.00"))
  }

  // MARK: - BIT, strings, binary, JSON, GEOMETRY

  @Test func bitIsBigEndianInteger() {
    // b'1010101010' in BIT(10): raw bytes in both protocols.
    #expect(Self.cell(Self.binary([0x02, 0xAA], .bit, unsigned: true)) == .int(682))
    var buffer = ByteBufferAllocator().buffer(capacity: 2)
    buffer.writeBytes([0x02, 0xAA])
    let text = MySQLData(type: .bit, format: .text, buffer: buffer, isUnsigned: true)
    #expect(Self.cell(text, charset: .binary) == .int(682))
    #expect(
      Self.cell(Self.binary([UInt8](repeating: 0xFF, count: 8), .bit, unsigned: true))
        == .string("18446744073709551615"))
  }

  @Test func textVersusBinaryCollation() {
    #expect(Self.cell(Self.text("héllo", .varString)) == .string("héllo"))
    #expect(Self.cell(Self.binary(Array("abc".utf8), .blob)) == .string("abc"))
    #expect(
      Self.cell(Self.binary([0x00, 0xFF, 0x10], .blob), charset: .binary)
        == .data(Data([0x00, 0xFF, 0x10])))
    #expect(
      Self.cell(Self.text("ab", .string), charset: .binary) == .data(Data("ab".utf8)))
    #expect(
      Self.cell(Self.binary([0x61, 0x00], .varString), charset: .binary)
        == .data(Data([0x61, 0x00])))
  }

  @Test func jsonIsText() {
    // MySQL reports JSON with the binary character set.
    #expect(
      Self.cell(Self.text("{\"a\": 1}", .json), charset: .binary) == .json("{\"a\": 1}"))
    #expect(
      Self.cell(Self.binary(Array("[1]".utf8), .json), charset: .binary) == .json("[1]"))
    // MariaDB: a LONGTEXT (BLOB type) with a utf8mb4 collation.
    #expect(Self.cell(Self.binary(Array("{}".utf8), .blob)) == .string("{}"))
  }

  // MARK: - Server info

  @Test(
    arguments: [
      ("8.4.11", MySQLServerInfo.Flavor.mysql, 8, 4, 11),
      ("11.4.13-MariaDB-ubu2404", .mariadb, 11, 4, 13),
      ("5.7.44-log", .mysql, 5, 7, 44),
      ("8.0.36-0ubuntu0.22.04.1", .mysql, 8, 0, 36),
      ("10.11.6-MariaDB-1:10.11.6+maria~ubu2204", .mariadb, 10, 11, 6),
      ("5.5.5-10.6.18-MariaDB", .mariadb, 10, 6, 18),
      ("9.1", .mysql, 9, 1, 0),
    ])
  func parsesVersion(
    text: String, flavor: MySQLServerInfo.Flavor, major: Int, minor: Int, patch: Int
  ) {
    let info = MySQLServerInfo(version: text)
    #expect(info == MySQLServerInfo(flavor: flavor, major: major, minor: minor, patch: patch))
  }

  @Test func rejectsUnparsableVersion() {
    #expect(MySQLServerInfo(version: "") == nil)
    #expect(MySQLServerInfo(version: "MariaDB") == nil)
  }

  @Test func explainAnalyzeNeedsMySQL8018() {
    #expect(MySQLServerInfo(version: "8.0.18")?.supportsExplainAnalyze == true)
    #expect(MySQLServerInfo(version: "8.0.17")?.supportsExplainAnalyze == false)
    #expect(MySQLServerInfo(version: "8.4.11")?.supportsExplainAnalyze == true)
    #expect(MySQLServerInfo(version: "5.7.44")?.supportsExplainAnalyze == false)
    #expect(MySQLServerInfo(version: "11.4.13-MariaDB")?.supportsExplainAnalyze == false)
  }

  @Test func statementTimeoutVariable() {
    let mysql = MySQLServerInfo(version: "8.4.11")
    #expect(mysql?.statementTimeoutVariable == "max_execution_time")
    #expect(mysql?.statementTimeoutValue(seconds: 60) == 60_000)
    let mariadb = MySQLServerInfo(version: "11.4.13-MariaDB-ubu2404")
    #expect(mariadb?.statementTimeoutVariable == "max_statement_time")
    #expect(mariadb?.statementTimeoutValue(seconds: 60) == 60)
  }

  // MARK: - Live round trip

  enum Server: String, CustomStringConvertible, Sendable {
    case mysql, mariadb
    var port: Int { self == .mysql ? TestMySQLDatabase.port : TestMySQLDatabase.mariaDBPort }
    var description: String { rawValue }
  }

  @Test(.requiresMySQL, arguments: [Server.mysql, .mariadb])
  func roundTripThroughBothProtocols(server: Server) async throws {
    let conn = try await MySQLConnection.connect(
      to: try SocketAddress(ipAddress: TestMySQLDatabase.host, port: server.port),
      username: TestMySQLDatabase.username,
      database: TestMySQLDatabase.database,
      password: TestMySQLDatabase.password,
      tlsConfiguration: nil,
      // Driver-level round trip against the local fixture: a cold auth cache needs the RSA key.
      allowPublicKeyRetrieval: true,
      on: MultiThreadedEventLoopGroup.singleton.next()
    ).get()
    do {
      try await Self.roundTrip(conn, server: server)
      try await conn.close().get()
    } catch {
      try? await conn.close().get()
      throw error
    }
  }

  private static func roundTrip(_ conn: MySQLConnection, server: Server) async throws {
    let table = "converter_types"
    _ = try await conn.simpleQuery("SET SESSION sql_mode = ''").get()
    _ = try await conn.simpleQuery("DROP TABLE IF EXISTS \(table)").get()
    _ = try await conn.simpleQuery(
      """
      CREATE TABLE \(table) (
        i INT, ti TINYINT, ub BIGINT UNSIGNED, f FLOAT, db DOUBLE, d DECIMAL(20,6),
        dt DATETIME(6), ts TIMESTAMP NULL, da DATE, tm TIME, tn TIME(3), zd DATE, zdt DATETIME,
        b BIT(10), j JSON, bl BLOB, vb VARBINARY(8), vc VARCHAR(10), e ENUM('a','b'),
        s SET('x','y'), y YEAR, g GEOMETRY, n INT)
      """
    ).get()
    _ = try await conn.simpleQuery(
      """
      INSERT INTO \(table) VALUES (
        -42, -1, 18446744073709551615, 1.5, -2.25, 12345.678900,
        '2024-01-02 03:04:05.123456', '2024-01-02 03:04:05', '2024-01-02', '25:30:15',
        '-01:02:03.500', '0000-00-00', '0000-00-00 00:00:00', b'1010101010', '{"a": 1}',
        x'00FF10', x'6100', 'héllo', 'b', 'x,y', 2024, ST_GeomFromText('POINT(1 2)'), NULL)
      """
    ).get()
    let sql = "SELECT * FROM \(table)"
    let binaryRows = try await conn.query(sql).get()
    let textRows = try await conn.simpleQuery(sql).get()
    _ = try await conn.simpleQuery("DROP TABLE \(table)").get()

    let binaryRow = try #require(binaryRows.first)
    let binary = MySQLValueConverter.cells(binaryRow)
    let text = MySQLValueConverter.cells(try #require(textRows.first))
    let names = binaryRow.columnDefinitions.map(\.name)
    #expect(names.count == 23)

    let geometryIndex = try #require(names.firstIndex(of: "g"))
    let point = try #require(binary[geometryIndex].dataValue, "\(server) geometry should be data")
    let expected: [String: CellValue] = [
      "i": .int(-42), "ti": .int(-1), "ub": .string("18446744073709551615"), "f": .double(1.5),
      "db": .double(-2.25), "d": .string("12345.678900"),
      "dt": .date(Date(timeIntervalSince1970: epochSeconds + 0.123456)),
      "ts": .date(Date(timeIntervalSince1970: epochSeconds)),
      "da": .string("2024-01-02"), "tm": .string("25:30:15"),
      "tn": .string("-01:02:03.500"), "zd": .string("0000-00-00"),
      "zdt": .string("0000-00-00 00:00:00"), "b": .int(682),
      "j": server == .mysql ? .json("{\"a\": 1}") : .string("{\"a\": 1}"),
      "bl": .data(Data([0x00, 0xFF, 0x10])), "vb": .data(Data([0x61, 0x00])),
      "vc": .string("héllo"), "e": .string("b"), "s": .string("x,y"), "y": .int(2024),
      "g": .data(point), "n": .null,
    ]
    #expect(point.count == 25)  // 4-byte SRID + 21-byte WKB POINT
    for (index, name) in names.enumerated() {
      #expect(binary[index] == expected[name], "\(server) binary \(name)")
      #expect(text[index] == expected[name], "\(server) text \(name)")
    }
  }
}

extension CellValue {
  fileprivate var dataValue: Data? {
    if case .data(let value) = self { return value }
    return nil
  }
}
