import Foundation

nonisolated enum ImportTypeInference {
  enum Kind: Sendable, Equatable {
    case integer
    case decimal
    case boolean
    case date
    case timestamp
    case localTimestamp
    case text

    func sqlType(dialect: SQLDialect) -> String {
      switch dialect {
      case .sqlite:
        // Decimals as TEXT: SQLite has no exact decimal type, and REAL keeps about 15 digits
        switch self {
        case .integer, .boolean: "INTEGER"
        case .date, .timestamp, .localTimestamp, .text, .decimal: "TEXT"
        }
      case .mysql:
        // The widest exact DECIMAL, not DOUBLE (about 15 digits) or bare DECIMAL (which is
        // DECIMAL(10,0) and drops fractions)
        switch self {
        case .integer: "BIGINT"
        case .decimal: "DECIMAL(65,30)"
        case .boolean: "BOOLEAN"
        case .date: "DATE"
        case .timestamp: "DATETIME(6)"
        case .localTimestamp: "DATETIME(6)"
        case .text: "LONGTEXT"
        }
      // Without its digits a decimal is text: a bare DECIMAL is DECIMAL(18,3), which rounds
      // fractions (`ImportSQLBuilder.createTable` writes DECIMAL(p,s) from the digits)
      case .duckdb where self == .decimal: Kind.text.postgresSQLType
      case .postgresql, .duckdb: postgresSQLType
      default: postgresSQLType
      }
    }

    private var postgresSQLType: String {
      switch self {
      case .integer: "bigint"
      case .decimal: "numeric"
      case .boolean: "boolean"
      case .date: "date"
      case .timestamp: "timestamptz"
      case .localTimestamp: "timestamp"
      case .text: "text"
      }
    }
  }

  /// A decimal column's widest observed digits: `precision` is the integer plus fraction
  /// digits, `scale` the fraction digits
  struct PrecisionScale: Sendable, Equatable {
    var precision: Int
    var scale: Int
  }

  /// The widest integer and fraction digits of plain-notation decimals (`0.5` counts its `0`,
  /// so it needs DECIMAL(2,1)). Nil when a value is not plain notation, or all are blank.
  static func decimalDigits(_ values: [String?]) -> PrecisionScale? {
    var accumulator = Accumulator()
    for value in values {
      accumulator.add(value)
      guard accumulator.isPlain else { return nil }
    }
    return accumulator.digits
  }

  /// `decimalDigits` one value at a time, so a file read in blocks gets the digits of every row
  struct Accumulator: Sendable, Equatable {
    private var integer = 0
    private var fraction = 0
    private var found = false
    /// False once a value is not plain notation: the column has no digits, whatever follows
    private(set) var isPlain = true

    var digits: PrecisionScale? {
      isPlain && found ? PrecisionScale(precision: integer + fraction, scale: fraction) : nil
    }

    mutating func add(_ raw: String?) {
      guard isPlain,
        let value = normalizedValue(raw)?.trimmingCharacters(in: .whitespacesAndNewlines)
      else { return }
      let unsigned =
        value.utf8.first == UInt8(ascii: "-") ? value.utf8.dropFirst() : value.utf8[...]
      let parts = unsigned.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count),
        parts.allSatisfy({
          !$0.isEmpty && $0.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        })
      else {
        isPlain = false
        return
      }
      integer = max(integer, parts[0].count)
      fraction = max(fraction, parts.count == 2 ? parts[1].count : 0)
      found = true
    }
  }

  static func normalizedValue(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  /// The ISO 8601 forms `infer` accepts as `.timestamp`: a full date (UTC midnight), or a date
  /// and time with `Z` or an offset, with or without fractional seconds.
  struct TimestampParser {
    let dateFormatter = ISO8601DateFormatter()
    let timestampFormatter = ISO8601DateFormatter()
    let fractionalFormatter = ISO8601DateFormatter()

    init() {
      dateFormatter.formatOptions = [.withFullDate]
      dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)!
      timestampFormatter.formatOptions = [.withInternetDateTime]
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func date(from value: String) -> Date? {
      if isDate(value, formatter: dateFormatter) { return dateFormatter.date(from: value) }
      return timestampFormatter.date(from: value) ?? fractionalFormatter.date(from: value)
    }
  }

  static func infer(rows: [[String?]], columnCount: Int) -> [Kind] {
    let parser = TimestampParser()
    let dateFormatter = parser.dateFormatter

    return (0..<max(columnCount, 0)).map { column in
      let values = rows.compactMap { row -> String? in
        guard column < row.count else { return nil }
        return normalizedValue(row[column])?.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !values.isEmpty else { return .text }
      if values.allSatisfy(isInteger) { return .integer }
      if values.allSatisfy(isDecimal) { return .decimal }
      if values.allSatisfy({
        $0.caseInsensitiveCompare("true") == .orderedSame
          || $0.caseInsensitiveCompare("false") == .orderedSame
      }) {
        return .boolean
      }
      if values.allSatisfy({ isDate($0, formatter: dateFormatter) }) { return .date }
      if values.allSatisfy({ parser.date(from: $0) != nil }) {
        return .timestamp
      }
      if values.allSatisfy({ isLocalTimestamp($0, dates: dateFormatter) }) {
        return .localTimestamp
      }
      return .text
    }
  }

  /// Leading zeros ("00501") stay text so they are not lost
  private static func isInteger(_ value: String) -> Bool {
    Int64(value) != nil
      && value.range(of: #"^-?(?:0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
  }

  /// Plain notation that fits MySQL's DECIMAL(65,30): up to 35 integer and 30 fraction digits.
  /// Scientific notation (`1e40`, `3.2e-45`) is text, so its value is never rounded or rejected.
  private static func isDecimal(_ value: String) -> Bool {
    value.range(
      of: #"^-?(?:0|[1-9][0-9]{0,34})(?:\.[0-9]{1,30})?$"#,
      options: .regularExpression
    ) != nil
  }

  /// `yyyy-MM-dd[ T]HH:mm:ss[.f{1,6}]` with no zone (a naive timestamp export). Only checked:
  /// its binds stay the file text, so the server keeps the wall clock.
  private static func isLocalTimestamp(_ value: String, dates: ISO8601DateFormatter) -> Bool {
    let pattern =
      #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]"#
      + #"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,6})?$"#
    return value.range(of: pattern, options: .regularExpression) != nil
      && isDate(String(value.prefix(10)), formatter: dates)
  }

  private static func isDate(_ value: String, formatter: ISO8601DateFormatter) -> Bool {
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }
}
