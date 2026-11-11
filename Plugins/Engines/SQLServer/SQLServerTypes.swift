// SQLServerTypes.swift
// The pure parts of the SQL Server engine, free of FreeTDS so the host-less tests compile them:
// the TLS plan of an open, the TDS type codes and the mapping of the shim's cell buffers
// (dblore_tds.h) to engine cells, column type names, table names from the app, statement
// parameters, result column origins from a describe and server errors.
//
// Cells (by the type code db-lib gives each cell):
// - decimal / numeric and money / smallmoney → exact decimal text, never through a Double
// - datetime, smalldatetime, datetime2 → an ISO-8601 instant holding the stored wall clock in
//   UTC (the column is marked `wallClock`); datetimeoffset → its local time and offset
// - date and time → text (`2024-05-01`, `13:45:00.1234567`)
// - uniqueidentifier → upper-case text; xml and every character type → text
// - binary, varbinary, image, timestamp, CLR types → bytes
// - bit → bool; tinyint to bigint → int; real and float → double
// - sql_variant → text: db-lib does not tell its inner type, so its bytes are text when they
//   are readable UTF-8, else bytes
// A value over `EnginePluginProtocol.maxValueBytes` fails with `tooLarge` before it is copied.
//
// Binds: `batch` declares them as batch variables `@p1`, `@p2`, ... ahead of the statement.

import Foundation

// MARK: - TLS

/// FreeTDS `encryption` values
enum SQLServerEncryption: String, Sendable {
  case off, request, require, strict
}

/// The TLS attempts of one open, from `open.tls.mode`:
/// - off, request, require: that FreeTDS encryption; require is mandatory TLS without checks.
/// - verifyCA: mandatory TLS, chain checked.
/// - verifyFull: strict encryption (TDS 8.0) with chain and host name checked, then, only after
///   a failure before any certificate, mandatory TLS with chain and host name checked (servers
///   before SQL Server 2022 have no strict). `tdsStrict: false` skips the strict attempt.
/// A certificate, chain or host-name failure never falls back, nor does any other failure.
struct SQLServerTLSPlan: Equatable, Sendable {
  struct Attempt: Equatable, Sendable {
    let encryption: SQLServerEncryption
    /// The chain is checked against the CA (the connection's or the system's)
    let verifiesChain: Bool
    /// The certificate must name `tlsServerName`
    let checksHostName: Bool

    /// The session must stay encrypted after the login
    var requiresEncryption: Bool { encryption == .require || encryption == .strict }
  }

  /// How an attempt failed
  enum Failure: Equatable, Sendable {
    /// Before the server was tried (configuration, temporary files, login fields)
    case local
    /// No TCP connection to the server
    case unreachable
    /// The server was reached, but presents no certificate to a direct TLS handshake: it has no
    /// strict encryption (a transport or protocol failure before any certificate)
    case beforeCertificate
    /// The server presents a certificate: the chain, the host name or the login failed
    case afterCertificate
    /// The login succeeded but the session was not kept encrypted
    case unencrypted
    /// Any other failure of an attempt without a fallback
    case refused
  }

  /// In order; only the first may fall back, to the second
  let attempts: [Attempt]

  init(mode: EngineRequest.Open.TLS.Mode, tdsStrict: Bool = true) {
    switch mode {
    case .off: attempts = [Attempt(encryption: .off, verifiesChain: false, checksHostName: false)]
    case .request:
      attempts = [Attempt(encryption: .request, verifiesChain: false, checksHostName: false)]
    case .require:
      attempts = [Attempt(encryption: .require, verifiesChain: false, checksHostName: false)]
    case .verifyCA:
      attempts = [Attempt(encryption: .require, verifiesChain: true, checksHostName: false)]
    case .verifyFull:
      let mandatory = Attempt(encryption: .require, verifiesChain: true, checksHostName: true)
      attempts =
        tdsStrict
        ? [Attempt(encryption: .strict, verifiesChain: true, checksHostName: true), mandatory]
        : [mandatory]
    }
  }

  var first: Attempt { attempts[0] }

  /// Whether a failure of `attempt` may lead to another attempt, so it is worth telling a
  /// failure before the certificate from one after it
  func mayFallBack(from attempt: Attempt) -> Bool {
    attempts.count > 1 && attempts[0] == attempt && attempt.encryption == .strict
  }

  /// The attempt after `attempt` failed with `failure`, nil when the open fails
  func next(after attempt: Attempt, failure: Failure) -> Attempt? {
    guard failure == .beforeCertificate, mayFallBack(from: attempt) else { return nil }
    return attempts[1]
  }
}

// MARK: - Type codes

/// A TDS / db-lib type code, as the shim reports it per column and cell
struct TDSType: RawRepresentable, Hashable, Sendable {
  let rawValue: Int32

  static let image = Self(rawValue: 34)
  static let text = Self(rawValue: 35)
  static let uniqueIdentifier = Self(rawValue: 36)
  static let varBinaryLegacy = Self(rawValue: 37)
  static let intN = Self(rawValue: 38)
  static let varCharLegacy = Self(rawValue: 39)
  static let date = Self(rawValue: 40)
  static let time = Self(rawValue: 41)
  static let dateTime2 = Self(rawValue: 42)
  static let dateTimeOffset = Self(rawValue: 43)
  static let binaryLegacy = Self(rawValue: 45)
  static let charLegacy = Self(rawValue: 47)
  static let tinyInt = Self(rawValue: 48)
  static let bit = Self(rawValue: 50)
  static let smallInt = Self(rawValue: 52)
  static let decimalLegacy = Self(rawValue: 55)
  static let int = Self(rawValue: 56)
  static let smallDateTime = Self(rawValue: 58)
  static let real = Self(rawValue: 59)
  static let money = Self(rawValue: 60)
  static let dateTime = Self(rawValue: 61)
  static let float = Self(rawValue: 62)
  static let numericLegacy = Self(rawValue: 63)
  static let variant = Self(rawValue: 98)
  static let nText = Self(rawValue: 99)
  static let nVarCharLegacy = Self(rawValue: 103)
  static let bitN = Self(rawValue: 104)
  static let decimal = Self(rawValue: 106)
  static let numeric = Self(rawValue: 108)
  static let floatN = Self(rawValue: 109)
  static let moneyN = Self(rawValue: 110)
  static let dateTimeN = Self(rawValue: 111)
  static let smallMoney = Self(rawValue: 122)
  static let bigInt = Self(rawValue: 127)
  static let varBinary = Self(rawValue: 165)
  static let varChar = Self(rawValue: 167)
  static let binary = Self(rawValue: 173)
  static let char = Self(rawValue: 175)
  static let longBinary = Self(rawValue: 225)
  static let nVarChar = Self(rawValue: 231)
  static let nChar = Self(rawValue: 239)
  static let udt = Self(rawValue: 240)
  static let xml = Self(rawValue: 241)

  /// UTF-8 text in a cell buffer
  static let textual: Set<TDSType> = [
    .text, .varCharLegacy, .charLegacy, .nText, .nVarCharLegacy, .varChar, .char, .nVarChar,
    .nChar, .xml,
  ]
  /// Bytes in a cell buffer
  static let binaryTypes: Set<TDSType> = [
    .image, .varBinaryLegacy, .binaryLegacy, .varBinary, .binary, .longBinary, .udt,
  ]

  /// The server's user type of `timestamp` / `rowversion` (a binary(8))
  static let timestampUserType: Int32 = 80
}

// MARK: - Columns

/// One result column as the shim describes it (`dblore_tds_column`)
struct SQLServerColumn: Equatable, Sendable {
  let name: String
  /// The type of its cells
  let type: TDSType
  /// The type the server declared; 0 when unknown
  let serverType: TDSType
  let userType: Int32
  let maxLength: Int

  /// The server type's name (`nvarchar`, `datetime2`, `decimal`, ...), lower case, without
  /// length or precision
  var typeName: String {
    if userType == TDSType.timestampUserType, serverType == .binary || serverType == .binaryLegacy {
      return "timestamp"
    }
    // An int, float, money or datetime of a given length (intN, ...) is named by its cells' type
    return Self.names[serverType] ?? Self.names[type] ?? "unknown"
  }

  /// A naive date-time: its instants hold the stored wall clock in UTC
  var isWallClock: Bool { [.dateTime, .smallDateTime, .dateTime2].contains(type) }

  var event: EngineEvent.Column {
    EngineEvent.Column(name: name, type: typeName, wallClock: isWallClock)
  }

  private static let names: [TDSType: String] = [
    .image: "image", .text: "text", .uniqueIdentifier: "uniqueidentifier",
    .varBinaryLegacy: "varbinary", .varCharLegacy: "varchar", .date: "date", .time: "time",
    .dateTime2: "datetime2", .dateTimeOffset: "datetimeoffset", .binaryLegacy: "binary",
    .charLegacy: "char", .tinyInt: "tinyint", .bit: "bit", .smallInt: "smallint",
    .decimalLegacy: "decimal", .int: "int", .smallDateTime: "smalldatetime", .real: "real",
    .money: "money", .dateTime: "datetime", .float: "float", .numericLegacy: "numeric",
    .variant: "sql_variant", .nText: "ntext", .nVarCharLegacy: "nvarchar", .bitN: "bit",
    .decimal: "decimal", .numeric: "numeric", .smallMoney: "smallmoney", .bigInt: "bigint",
    .varBinary: "varbinary", .varChar: "varchar", .binary: "binary", .char: "char",
    .nVarChar: "nvarchar", .nChar: "nchar", .udt: "udt", .xml: "xml",
  ]
}

// MARK: - Cells

enum SQLServerTypes {
  /// The cell of a shim buffer (dblore_tds.h layouts); nil `bytes` is NULL
  static func cell(type: TDSType, bytes: UnsafeRawBufferPointer?) throws -> EngineCell {
    guard let bytes else { return .null }
    guard bytes.count <= EnginePluginProtocol.maxValueBytes else {
      throw EngineFailure(
        code: .tooLarge, message: "A value is over the 256 MiB limit of one cell.")
    }
    if TDSType.textual.contains(type) { return .text(String(decoding: bytes, as: UTF8.self)) }
    if TDSType.binaryTypes.contains(type) { return .bytes(Data(bytes)) }
    switch type {
    case .tinyInt where bytes.count >= 1: return .int(Int(bytes[0]))
    case .smallInt where bytes.count >= 2: return .int(Int(Int16(littleEndian: load(bytes))))
    case .int where bytes.count >= 4: return .int(Int(Int32(littleEndian: load(bytes))))
    case .bigInt where bytes.count >= 8: return .int(Int(Int64(littleEndian: load(bytes))))
    case .bit where bytes.count >= 1: return .bool(bytes[0] != 0)
    case .real where bytes.count >= 4:
      // Through the float's shortest text, so 0.1 stays 0.1 and not 0.100000001490116
      let value = Float(bitPattern: UInt32(littleEndian: load(bytes)))
      return .double(Double("\(value)") ?? Double(value))
    case .float where bytes.count >= 8:
      return .double(Double(bitPattern: UInt64(littleEndian: load(bytes))))
    case .money where bytes.count >= 8:
      return .decimal(money(Int64(littleEndian: load(bytes))))
    case .smallMoney where bytes.count >= 4:
      return .decimal(money(Int64(Int32(littleEndian: load(bytes)))))
    case .decimal, .numeric, .decimalLegacy, .numericLegacy:
      return decimal(bytes).map(EngineCell.decimal) ?? .null
    case .dateTime where bytes.count >= 8:
      return .date(
        dateTime(
          days: Int(Int32(littleEndian: load(bytes))),
          ticks: Int(UInt32(littleEndian: load(bytes, at: 4)))))
    case .smallDateTime where bytes.count >= 4:
      let days = Int(UInt16(littleEndian: load(bytes)))
      let minutes = Int(UInt16(littleEndian: load(bytes, at: 2)))
      return .date(civilDate(days: days) + "T" + clock(seconds: minutes * 60) + "Z")
    case .date, .time, .dateTime2, .dateTimeOffset:
      return dateTimeAll(type: type, bytes) ?? .null
    case .uniqueIdentifier where bytes.count >= 16: return .text(uniqueIdentifier(bytes))
    case .variant: return variant(bytes)
    default: return .bytes(Data(bytes))
    }
  }

  /// `cell(type:bytes:)` over an array (recorded buffers)
  static func cell(type: TDSType, bytes: [UInt8]?) throws -> EngineCell {
    guard let bytes else { return .null }
    return try bytes.withUnsafeBytes { try cell(type: type, bytes: $0) }
  }

  private static func load<T: FixedWidthInteger>(
    _ bytes: UnsafeRawBufferPointer, at offset: Int = 0
  ) -> T {
    bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
  }

  /// Ten-thousandths as decimal text with four fraction digits
  static func money(_ value: Int64) -> String {
    let magnitude = value.magnitude
    let fraction = String(magnitude % 10_000)
    let digits =
      String(magnitude / 10_000) + "." + String(repeating: "0", count: 4 - fraction.count)
      + fraction
    return value < 0 ? "-" + digits : digits
  }

  /// precision, scale, sign (1: negative), big-endian magnitude → exact decimal text
  static func decimal(_ bytes: UnsafeRawBufferPointer) -> String? {
    guard bytes.count >= 3 else { return nil }
    let scale = Int(bytes[1])
    let negative = bytes[2] != 0
    var magnitude = Array(bytes[3...])
    // Repeated division by 10 of the big-endian integer, least significant digit first
    var digits: [UInt8] = []
    while magnitude.contains(where: { $0 != 0 }) {
      var remainder = 0
      for index in magnitude.indices {
        let value = remainder << 8 | Int(magnitude[index])
        magnitude[index] = UInt8(value / 10)
        remainder = value % 10
      }
      digits.append(UInt8(remainder))
    }
    while digits.count <= scale { digits.append(0) }
    var text = String(digits.reversed().map { Character(String($0)) })
    if scale > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -scale)) }
    let isZero = digits.allSatisfy { $0 == 0 }
    return negative && !isZero ? "-" + text : text
  }

  /// `datetime`: days since 1900-01-01 and ticks of 1/300 s, in milliseconds as the server
  /// shows them (.000, .003, .007)
  static func dateTime(days: Int, ticks: Int) -> String {
    let milliseconds = (ticks * 10 + 1) / 3
    let seconds = milliseconds / 1000
    let fraction = String(milliseconds % 1000)
    return civilDate(days: days) + "T" + clock(seconds: seconds) + "."
      + String(repeating: "0", count: 3 - fraction.count) + fraction + "Z"
  }

  /// The 16-byte date and time layout (time of day in 100 ns, days since 1900-01-01, offset in
  /// minutes, precision, flags)
  /// nil for values out of the types' range (a server never sends them), so no arithmetic traps
  static func dateTimeAll(type: TDSType, _ bytes: UnsafeRawBufferPointer) -> EngineCell? {
    let units = 864_000_000_000  // 100 ns per day
    guard bytes.count >= 16,
      var time = Int(exactly: UInt64(littleEndian: load(bytes))), time < units
    else { return nil }
    var days = Int(Int32(littleEndian: load(bytes, at: 8)))
    let offset = Int(Int16(littleEndian: load(bytes, at: 12)))
    // 0001-01-01 ... 9999-12-31, and offsets within a day
    guard (-693_595...2_958_463).contains(days), abs(offset) < 24 * 60 else { return nil }
    let precision = min(Int(bytes[14]), 7)
    switch type {
    case .date: return .text(civilDate(days: days))
    case .time: return .text(clockWithFraction(time, precision: precision))
    case .dateTime2:
      return .date(
        civilDate(days: days) + "T" + clockWithFraction(time, precision: precision) + "Z")
    default:
      // Stored in UTC: shown at its own offset, which names the same instant
      let local = days * units + time + offset * 600_000_000
      days = local >= 0 ? local / units : (local - units + 1) / units
      time = local - days * units
      let sign = offset < 0 ? "-" : "+"
      let zone = sign + two(abs(offset) / 60) + ":" + two(abs(offset) % 60)
      return .date(
        civilDate(days: days) + "T" + clockWithFraction(time, precision: precision) + zone)
    }
  }

  /// `HH:MM:SS` and `precision` fraction digits of a time of day in 100 ns units
  private static func clockWithFraction(_ time: Int, precision: Int) -> String {
    let text = clock(seconds: time / 10_000_000)
    guard precision > 0 else { return text }
    var divisor = 1
    for _ in precision..<7 { divisor *= 10 }
    let fraction = String((time % 10_000_000) / divisor)
    return text + "." + String(repeating: "0", count: precision - fraction.count) + fraction
  }

  private static func clock(seconds: Int) -> String {
    two(seconds / 3600) + ":" + two(seconds / 60 % 60) + ":" + two(seconds % 60)
  }

  private static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

  /// `YYYY-MM-DD` of days since 1900-01-01 (proleptic Gregorian)
  static func civilDate(days: Int) -> String {
    // Days since 0000-03-01, in 400-year eras
    let z = days + 693_901
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    let yearText = String(year)
    return String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText + "-"
      + two(month) + "-" + two(day)
  }

  /// `6F9619FF-8B86-D011-B42D-00C04FC964FF`: three little-endian fields, then 8 bytes
  static func uniqueIdentifier(_ bytes: UnsafeRawBufferPointer) -> String {
    func hex(_ value: UInt64, _ digits: Int) -> String {
      let text = String(value, radix: 16, uppercase: true)
      return String(repeating: "0", count: digits - text.count) + text
    }
    let data1 = UInt64(UInt32(littleEndian: load(bytes)))
    let data2 = UInt64(UInt16(littleEndian: load(bytes, at: 4)))
    let data3 = UInt64(UInt16(littleEndian: load(bytes, at: 6)))
    let tail = (8..<16).map { hex(UInt64(bytes[$0]), 2) }
    return hex(data1, 8) + "-" + hex(data2, 4) + "-" + hex(data3, 4) + "-"
      + tail[0..<2].joined() + "-" + tail[2...].joined()
  }

  /// sql_variant: text when its bytes are UTF-8 without control characters (tab and line
  /// breaks aside), else bytes
  private static func variant(_ bytes: UnsafeRawBufferPointer) -> EngineCell {
    guard let text = String(bytes: Data(bytes), encoding: .utf8),
      !text.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control && !["\t", "\n", "\r"].contains($0)
      })
    else { return .bytes(Data(bytes)) }
    return .text(text)
  }

  // MARK: Catalog types

  /// A catalog column's type as T-SQL writes it: `nvarchar(50)`, `varbinary(max)`,
  /// `decimal(18,2)`, `datetime2(3)`; other types by name alone
  static func displayType(name: String, maxLength: Int, precision: Int, scale: Int) -> String {
    switch name {
    case "varchar", "char", "varbinary", "binary":
      return maxLength == -1 ? "\(name)(max)" : "\(name)(\(maxLength))"
    case "nvarchar", "nchar":
      return maxLength == -1 ? "\(name)(max)" : "\(name)(\(maxLength / 2))"
    case "decimal", "numeric": return "\(name)(\(precision),\(scale))"
    case "datetime2", "time", "datetimeoffset": return "\(name)(\(scale))"
    default: return name
    }
  }

  // MARK: Statements

  /// `sql` with `binds` as `@p1`, `@p2`, ...: one batch that declares them as nvarchar(max)
  /// variables (nil is NULL), then runs `sql` as it is, so each of its statements reports its
  /// own row count (a DONE token) as an unbound statement does. Without binds, `sql` as it is.
  static func batch(_ sql: String, binds: [String?]) -> String {
    guard !binds.isEmpty else { return sql }
    let declarations = binds.enumerated().map { index, value in
      "@p\(index + 1) nvarchar(max) = \(value.map(expression) ?? "NULL")"
    }
    return "DECLARE " + declarations.joined(separator: ", ") + "; " + sql
  }

  /// Whether result `index` (0-based) of a `batch` adds its row count. With binds, the first
  /// result is the declaring prelude's: SQL Server counts a variable assignment as one row, a
  /// row of no statement of `sql`, so it is not added.
  static func countsRows(result index: Int, hasBinds: Bool) -> Bool {
    !hasBinds || index > 0
  }

  /// `text` as an nvarchar(max) expression of T-SQL Unicode literals (`'` doubled). T-SQL drops a
  /// backslash directly followed by a line break inside a literal, with the break, so the text is
  /// cut after every such backslash and the pieces concatenated. Read per Unicode scalar, as the
  /// server lexes it: a `\` or CR / LF scalar counts even when a combining scalar joins it into
  /// one Character.
  static func expression(_ text: String) -> String {
    var pieces: [String.UnicodeScalarView] = []
    var current = String.UnicodeScalarView()
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      if previous == "\\", scalar == "\n" || scalar == "\r" {
        pieces.append(current)
        current = String.UnicodeScalarView()
      }
      current.append(scalar)
      previous = scalar
    }
    pieces.append(current)
    guard pieces.count > 1 else { return literal(text) }
    // Cast first: concatenated literals would otherwise stop at 4000 characters
    return "CAST(\(literal(String(pieces[0]))) AS nvarchar(max))"
      + pieces.dropFirst().map { " + " + literal(String($0)) }.joined()
  }

  /// A T-SQL Unicode literal: every `'` scalar doubled (see `expression` for line breaks after a
  /// backslash)
  static func literal(_ text: String) -> String {
    "N'" + doubling("'", in: text) + "'"
  }

  /// A bracket identifier: every `]` scalar doubled
  static func quoted(_ name: String) -> String {
    "[" + doubling("]", in: name) + "]"
  }

  /// `text` with every `scalar` written twice. Per Unicode scalar, never per Character: a quote
  /// followed by a combining scalar is one Character that String matching would skip, while the
  /// server still reads the quote.
  static func doubling(_ scalar: Unicode.Scalar, in text: String) -> String {
    var out = String.UnicodeScalarView()
    for each in text.unicodeScalars {
      out.append(each)
      if each == scalar { out.append(each) }
    }
    return String(out)
  }

  // MARK: Catalog names

  /// A table name from the app, `table` or `schema.table`: a part is `[…]` (`]]` for a `]`, a
  /// `.` inside is part of the name) or bare, taken as written (the app sends an unquoted name
  /// upper-cased; the lookup then relies on a case-insensitive collation). Nil for anything else:
  /// an unclosed or empty bracket, text after a `]`, an empty part, a bare `[` or `]`, or more
  /// than two parts. Read per Unicode scalar, as the server lexes it: a `]` or `.` counts even
  /// when a combining scalar joins it into one Character.
  static func qualifiedName(_ name: String) -> (schema: String?, table: String)? {
    let scalars = Array(name.unicodeScalars)
    var parts: [String] = []
    var index = 0
    while true {
      var part = String.UnicodeScalarView()
      if index < scalars.count, scalars[index] == "[" {
        index += 1
        var closed = false
        while index < scalars.count {
          if scalars[index] == "]" {
            guard index + 1 < scalars.count, scalars[index + 1] == "]" else {
              index += 1
              closed = true
              break
            }
            index += 1
          }
          part.append(scalars[index])
          index += 1
        }
        guard closed else { return nil }
      } else {
        while index < scalars.count, scalars[index] != "." {
          guard scalars[index] != "[", scalars[index] != "]" else { return nil }
          part.append(scalars[index])
          index += 1
        }
      }
      guard !part.isEmpty else { return nil }
      parts.append(String(part))
      if index == scalars.count { break }
      guard scalars[index] == ".", parts.count < 2 else { return nil }
      index += 1
    }
    return parts.count == 2 ? (parts[0], parts[1]) : (nil, parts[0])
  }

  // MARK: Result column origins

  /// The describe of a query's first result set with browse information, `@p1` the query and
  /// `@p2` its `@params` (`describeParameters`). Inside an open transaction the DMF: a failing
  /// EXEC dooms the transaction under XACT_ABORT ON, the DMF returns the error as a row. Else
  /// the procedure: under IMPLICIT_TRANSACTIONS ON the DMF's SELECT would open a transaction.
  /// The two branches return different columns: read them by name (`describedColumns`).
  static let describeSQL = """
    IF @@TRANCOUNT > 0
      SELECT is_hidden, column_ordinal, name, source_server, source_database, source_schema,
        source_table, source_column, error_number
      FROM sys.dm_exec_describe_first_result_set(@p1, @p2, 1)
      ORDER BY column_ordinal
    ELSE
      EXEC sys.sp_describe_first_result_set @p1, @p2, 1
    """

  /// The `@params` of a describe: every `@p<digits>` name in `sql` (the app's binds, `batch`;
  /// `@P` too, which the app also reads as a bind) once, as `@p<digits>`, in order of first
  /// use, as `nvarchar(max)`; nil when there is none. `@p` without digits, a name that runs on
  /// into an identifier scalar (`@p1x`) or follows one (`a@p1`, `@@p1`) is not one. A name
  /// inside a string or comment only declares an unused parameter.
  static func describeParameters(_ sql: String) -> String? {
    func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
      CharacterSet.alphanumerics.contains(scalar) || "_@#$".unicodeScalars.contains(scalar)
    }
    let scalars = Array(sql.unicodeScalars)
    var names: [String] = []
    var index = 0
    while index < scalars.count {
      guard scalars[index] == "@", index + 1 < scalars.count,
        "pP".unicodeScalars.contains(scalars[index + 1]),
        index == 0 || !isIdentifier(scalars[index - 1])
      else {
        index += 1
        continue
      }
      var end = index + 2
      while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1 }
      if end > index + 2, end == scalars.count || !isIdentifier(scalars[end]) {
        let name = "@p" + String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
        if !names.contains(name) { names.append(name) }
      }
      index = end
    }
    return names.isEmpty ? nil : names.map { "\($0) nvarchar(max)" }.joined(separator: ", ")
  }

  /// One row of a describe (`describeSQL`)
  struct DescribedColumn: Equatable, Sendable {
    var isHidden = false
    let ordinal: Int
    /// Empty for a column without a name
    let name: String
    var server: String? = nil
    var database: String? = nil
    var schema: String? = nil
    var table: String? = nil
    var column: String? = nil
  }

  /// The rows of a describe whose columns came back named `names`, or nil when it reports an
  /// error (a non-NULL `error_number`, the DMF's), lacks a column the origins need, or has a
  /// row it cannot read
  static func describedColumns(names: [String], rows: [[EngineCell]]) -> [DescribedColumn]? {
    func index(_ name: String) -> Int? {
      names.firstIndex { $0.unicodeScalars.elementsEqual(name.unicodeScalars) }
    }
    guard let hidden = index("is_hidden"), let ordinal = index("column_ordinal"),
      let name = index("name"), let server = index("source_server"),
      let database = index("source_database"), let schema = index("source_schema"),
      let table = index("source_table"), let column = index("source_column")
    else { return nil }
    let error = index("error_number")
    var described: [DescribedColumn] = []
    for row in rows {
      guard row.count == names.count, error.map({ row[$0] == .null }) ?? true else { return nil }
      let isHidden: Bool
      switch row[hidden] {
      case .bool(let flag): isHidden = flag
      case .int(let value): isHidden = value != 0
      default: return nil
      }
      guard case .int(let position) = row[ordinal] else { return nil }
      func text(_ index: Int) -> String? {
        if case .text(let text) = row[index] { text } else { nil }
      }
      described.append(
        DescribedColumn(
          isHidden: isHidden, ordinal: position, name: text(name) ?? "", server: text(server),
          database: text(database), schema: text(schema), table: text(table),
          column: text(column)))
    }
    return described
  }

  /// `columns` with the origin of each one the describe names a base column of in `database`
  /// (the connection's `DB_NAME()`): no linked server, and schema, table and column all known.
  /// Fails closed (no origin at all) unless the visible rows (`is_hidden` 0), in ordinal order,
  /// match `columns` one to one by name, per Unicode scalar. An origin only ever comes from
  /// `described`: one the columns came with is dropped.
  static func originColumns(
    _ columns: [EngineEvent.Column], described: [DescribedColumn]?, database: String?
  ) -> [EngineEvent.Column] {
    let plain = columns.map {
      EngineEvent.Column(name: $0.name, type: $0.type, wallClock: $0.wallClock)
    }
    let visible = (described ?? []).filter { !$0.isHidden }.sorted { $0.ordinal < $1.ordinal }
    guard let database, described != nil, visible.count == columns.count,
      zip(columns, visible).allSatisfy({
        $0.name.unicodeScalars.elementsEqual($1.name.unicodeScalars)
      })
    else { return plain }
    return zip(plain, visible).map { column, source in
      var column = column
      if source.server == nil,
        source.database?.unicodeScalars.elementsEqual(database.unicodeScalars) == true,
        let schema = source.schema, let table = source.table, let name = source.column
      {
        column.origin = .init(schema: schema, table: table, column: name)
      }
      return column
    }
  }

  /// The result columns of an `enrichColumnTypes` request (`EngineEvent.Column` objects, an
  /// origin ignored), nil when the list or a column is malformed
  static func requestColumns(_ value: EngineJSONValue?) -> [EngineEvent.Column]? {
    guard case .array(let items)? = value else { return nil }
    var columns: [EngineEvent.Column] = []
    for item in items {
      guard case .object(let object) = item, case .string(let name)? = object["name"],
        case .string(let type)? = object["type"]
      else { return nil }
      var wallClock = false
      if let flag = object["wallClock"] {
        guard case .bool(let value) = flag else { return nil }
        wallClock = value
      }
      columns.append(EngineEvent.Column(name: name, type: type, wallClock: wallClock))
    }
    return columns
  }

  // MARK: Errors

  /// The failure of a statement or an open: the server's text as it is, then its state; the
  /// error number as `serverCode`
  static func failure(
    code: EngineErrorCode, message: String, number: Int32, state: Int32
  ) -> EngineFailure {
    var text = message.isEmpty ? "The server refused the request." : message
    if number != 0, state != 0 { text += " (state \(state))" }
    return EngineFailure(code: code, message: text, serverCode: number != 0 ? String(number) : nil)
  }
}
