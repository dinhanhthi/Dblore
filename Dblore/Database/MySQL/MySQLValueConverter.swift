// MySQLValueConverter.swift
// MySQL / MariaDB result values become CellValue, decoded from the raw row bytes because
// mysql-nio's MySQLData accessors are lossy in the binary protocol (spike 2.3: TIME drops days
// and sign, zero dates come back empty, BIT reads one byte, DECIMAL/JSON/YEAR `.string` is nil).
// Integers to .int (text when beyond Int, e.g. BIGINT UNSIGNED), FLOAT/DOUBLE to .double,
// DECIMAL as exact text, DATE/DATETIME/TIMESTAMP to .date (UTC wall clock, like a PostgreSQL
// `timestamp`) except zero dates, TIME as text, BIT as an integer, JSON to .json, binary
// collation strings and GEOMETRY (SRID + WKB) to .data, other strings (ENUM, SET) to text.
// Never call `MySQLData.description`: it force-unwraps.

import Foundation
import MySQLNIO
import NIOCore

nonisolated enum MySQLValueConverter {
  /// The column metadata a value needs beyond MySQLData's type and signedness.
  struct Column: Sendable {
    /// `binary` (63) marks BLOB / BINARY / VARBINARY bytes; anything else is text.
    var characterSet: MySQLProtocol.CharacterSet
    /// Fractional-second digits of TIME / DATETIME / TIMESTAMP (0...6).
    var decimals: UInt8

    init(characterSet: MySQLProtocol.CharacterSet, decimals: UInt8) {
      self.characterSet = characterSet
      self.decimals = decimals
    }

    init(_ definition: MySQLProtocol.ColumnDefinition41) {
      self.init(characterSet: definition.characterSet, decimals: definition.decimals)
    }
  }

  /// Every value of `row`, in column order.
  static func cells(_ row: MySQLRow) -> [CellValue] {
    zip(row.columnDefinitions, row.values).map { definition, buffer in
      cell(
        MySQLData(
          type: definition.columnType, format: row.format, buffer: buffer,
          isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)),
        column: Column(definition))
    }
  }

  static func cell(_ data: MySQLData, column: Column) -> CellValue {
    guard let buffer = data.buffer, data.type != .null else { return .null }
    let bytes = Array(buffer.readableBytesView)
    let isText = data.format == .text
    switch data.type {
    case .tiny, .short, .int24, .long, .longlong, .year:
      return isText
        ? integer(text: string(bytes))
        : integer(littleEndian: bytes, unsigned: data.isUnsigned || data.type == .year)
    case .float:
      guard !isText else { return double(text: string(bytes)) }
      guard bytes.count == 4 else { return .null }
      // Through its shortest text, so binary FLOAT 1.1 shows as 1.1 like the text protocol.
      let value = Float(bitPattern: UInt32(littleEndian: load(bytes)))
      return double(text: String(value))
    case .double:
      guard !isText else { return double(text: string(bytes)) }
      guard bytes.count == 8 else { return .null }
      return .double(Double(bitPattern: UInt64(littleEndian: load(bytes))))
    case .decimal, .newdecimal:
      return .string(string(bytes))
    case .date, .newdate, .datetime, .datetime2, .timestamp, .timestamp2:
      let isDate = data.type == .date || data.type == .newdate
      let parts = isText ? DateParts(text: string(bytes)) : DateParts(binary: bytes)
      guard let parts else { return .string(string(bytes)) }
      return dateCell(parts, isDate: isDate, decimals: column.decimals)
    case .time, .time2:
      return .string(isText ? string(bytes) : timeText(binary: bytes, decimals: column.decimals))
    case .bit:
      guard bytes.count <= 8 else { return .data(Data(bytes)) }
      return integer(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    case .json:
      return .json(string(bytes))
    case .geometry:
      return .data(Data(bytes))
    default:
      // VARCHAR, CHAR, TEXT / BLOB, ENUM, SET.
      return column.characterSet == .binary ? .data(Data(bytes)) : .string(string(bytes))
    }
  }

  // MARK: - Numbers

  private static func string(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// First `bytes.count` bytes as a fixed-width integer (little-endian layout of the host).
  private static func load<T: FixedWidthInteger>(_ bytes: [UInt8]) -> T {
    bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
  }

  private static func integer(text: String) -> CellValue {
    Int(text).map(CellValue.int) ?? .string(text)
  }

  private static func integer(_ value: UInt64) -> CellValue {
    Int(exactly: value).map(CellValue.int) ?? .string(String(value))
  }

  /// TINY 1, SHORT / YEAR 2, INT24 / LONG 4, LONGLONG 8 bytes, little-endian.
  private static func integer(littleEndian bytes: [UInt8], unsigned: Bool) -> CellValue {
    switch (bytes.count, unsigned) {
    case (1, false): .int(Int(Int8(bitPattern: bytes[0])))
    case (1, true): .int(Int(bytes[0]))
    case (2, false): .int(Int(Int16(littleEndian: load(bytes))))
    case (2, true): .int(Int(UInt16(littleEndian: load(bytes))))
    case (4, false): .int(Int(Int32(littleEndian: load(bytes))))
    case (4, true): .int(Int(UInt32(littleEndian: load(bytes))))
    case (8, false): .int(Int(Int64(littleEndian: load(bytes))))
    case (8, true): integer(UInt64(littleEndian: load(bytes)))
    default: .null
    }
  }

  private static func double(text: String) -> CellValue {
    Double(text).map(CellValue.double) ?? .string(text)
  }

  // MARK: - Dates and times

  private struct DateParts {
    var year = 0
    var month = 0
    var day = 0
    var hour = 0
    var minute = 0
    var second = 0
    var micros = 0

    /// `YYYY-MM-DD[ HH:MM:SS[.ffffff]]`. Nil for a field out of MySQL's range (a hostile
    /// server's huge field would overflow the date arithmetic), so the value stays text.
    init?(text: String) {
      let fields = text.split(whereSeparator: { "- :.".contains($0) }).map(String.init)
      guard fields.count == 3 || fields.count >= 6,
        let year = Int(fields[0]), (0...9999).contains(year),
        let month = Int(fields[1]), (0...12).contains(month),
        let day = Int(fields[2]), (0...31).contains(day)
      else { return nil }
      (self.year, self.month, self.day) = (year, month, day)
      if fields.count >= 6 {
        guard let hour = Int(fields[3]), (0...23).contains(hour),
          let minute = Int(fields[4]), (0...59).contains(minute),
          let second = Int(fields[5]), (0...59).contains(second)
        else { return nil }
        (self.hour, self.minute, self.second) = (hour, minute, second)
      }
      if fields.count == 7 {
        guard fields[6].count <= 6 else { return nil }
        let digits = fields[6].padding(toLength: 6, withPad: "0", startingAt: 0)
        guard let fraction = Int(digits), fraction >= 0 else { return nil }
        micros = fraction
      }
    }

    /// Length 0 (zero date), 4 (date), 7 (+ time) or 11 (+ microseconds); year u16 LE,
    /// month, day, hour, minute, second, micros u32 LE.
    init?(binary bytes: [UInt8]) {
      guard [0, 4, 7, 11].contains(bytes.count) else { return nil }
      guard bytes.count >= 4 else { return }
      year = Int(bytes[0]) | Int(bytes[1]) << 8
      (month, day) = (Int(bytes[2]), Int(bytes[3]))
      if bytes.count >= 7 { (hour, minute, second) = (Int(bytes[4]), Int(bytes[5]), Int(bytes[6])) }
      if bytes.count == 11 {
        micros = bytes[7...10].reversed().reduce(0) { $0 << 8 | Int($1) }
      }
    }
  }

  /// `.date` for a real date; MySQL's own text for a zero date or a zero month / day.
  private static func dateCell(_ parts: DateParts, isDate: Bool, decimals: UInt8) -> CellValue {
    guard parts.year == 0 || parts.month == 0 || parts.day == 0 else {
      let seconds =
        daysSinceEpoch(year: parts.year, month: parts.month, day: parts.day) * 86_400
        + parts.hour * 3_600 + parts.minute * 60 + parts.second
      return .date(Date(timeIntervalSince1970: Double(seconds) + Double(parts.micros) / 1_000_000))
    }
    var text = String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    if !isDate {
      text += String(format: " %02d:%02d:%02d", parts.hour, parts.minute, parts.second)
      text += fractionText(micros: parts.micros, decimals: decimals)
    }
    return .string(text)
  }

  /// Days from 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
  private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  /// Binary TIME: length 0 (zero), 8 or 12; is_negative, days u32 LE, hour, minute, second,
  /// micros u32 LE. Days fold into the hours, as the server's text shows `25:30:15`.
  private static func timeText(binary bytes: [UInt8], decimals: UInt8) -> String {
    guard bytes.count >= 8 else { return "00:00:00" + fractionText(micros: 0, decimals: decimals) }
    let days = bytes[1...4].reversed().reduce(0) { $0 << 8 | Int($1) }
    let hours = days * 24 + Int(bytes[5])
    let micros = bytes.count >= 12 ? bytes[8...11].reversed().reduce(0) { $0 << 8 | Int($1) } : 0
    return (bytes[0] == 1 ? "-" : "")
      + String(format: "%02d:%02d:%02d", hours, Int(bytes[6]), Int(bytes[7]))
      + fractionText(micros: micros, decimals: decimals)
  }

  /// `.fff` to the column's precision; nothing for precision 0 or an unknown one (> 6).
  private static func fractionText(micros: Int, decimals: UInt8) -> String {
    guard (1...6).contains(decimals) else { return "" }
    return "." + String(String(format: "%06d", micros).prefix(Int(decimals)))
  }
}
