import Foundation

nonisolated enum ImportTypeInference {
  enum Kind: Sendable, Equatable {
    case integer
    case decimal
    case boolean
    case date
    case timestamp
    case text

    func sqlType(dialect: SQLDialect) -> String {
      switch dialect {
      case .sqlite:
        switch self {
        case .integer, .boolean: "INTEGER"
        case .decimal: "REAL"
        case .date, .timestamp, .text: "TEXT"
        }
      case .mysql:
        // DOUBLE, not bare DECIMAL (which is DECIMAL(10,0) and drops fractions)
        switch self {
        case .integer: "BIGINT"
        case .decimal: "DOUBLE"
        case .boolean: "BOOLEAN"
        case .date: "DATE"
        case .timestamp: "DATETIME(6)"
        case .text: "LONGTEXT"
        }
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
      case .text: "text"
      }
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
      return .text
    }
  }

  /// Leading zeros ("00501") stay text so they are not lost
  private static func isInteger(_ value: String) -> Bool {
    Int64(value) != nil
      && value.range(of: #"^-?(?:0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
  }

  private static func isDecimal(_ value: String) -> Bool {
    value.range(
      of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#,
      options: .regularExpression
    ) != nil
  }

  private static func isDate(_ value: String, formatter: ISO8601DateFormatter) -> Bool {
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }
}
