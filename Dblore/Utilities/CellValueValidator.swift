//
//  CellValueValidator.swift
//  Dblore
//
//  Validation logic for cell values based on their type.
//  Extracted from CellInfoContent for testability.
//

import Foundation

/// Result of validation for a cell value
enum ValidationResult: Equatable, Sendable {
  case valid
  case invalid(String)

  nonisolated var isValid: Bool {
    if case .valid = self {
      return true
    }
    return false
  }

  nonisolated var errorMessage: String? {
    if case .invalid(let message) = self {
      return message
    }
    return nil
  }
}

/// Validates user input for cell values based on the target type
struct CellValueValidator: Sendable {

  /// Validates input string for a given cell value type
  /// - Parameters:
  ///   - input: The input string to validate
  ///   - valueType: The target CellValue type
  ///   - columnType: The column's type, checked instead when `valueType` is NULL
  ///   - wallClock: the column's `ColumnInfo.wallClock`: zone-less date text is its wall clock
  /// - Returns: ValidationResult indicating if input is valid or error message
  nonisolated static func validate(
    _ input: String, for valueType: CellValue, columnType: String = "", wallClock: Bool = false
  ) -> ValidationResult {
    // String type accepts anything
    if case .string = valueType {
      return .valid
    }

    // Validate based on the target value type
    switch valueType {
    case .int:
      return validateInteger(input)

    case .double:
      return validateDouble(input)

    case .null:
      // Empty or "null" keeps NULL; any other value is checked as the column's type
      if input.isEmpty || input.lowercased() == "null" { return .valid }
      let placeholder = CellValue.placeholder(forColumnType: columnType)
      // A NULL bytea cell binds the typed text as bytea input, not base64
      if case .data = placeholder { return .valid }
      return validate(input, for: placeholder, wallClock: wallClock)

    case .json:
      return validateJSON(input)

    case .date:
      return validateDate(input, wallClock: wallClock)

    case .bool:
      return validateBoolean(input)

    case .data:
      return validateBinaryData(input)

    case .decimal:
      return validateDecimal(input)

    case .string:
      return .valid
    }
  }

  // MARK: - Type-specific Validators

  nonisolated private static func validateInteger(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Value cannot be empty")
    }

    if Int(input) == nil {
      return .invalid("Invalid integer format")
    }

    return .valid
  }

  nonisolated private static func validateDouble(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Value cannot be empty")
    }

    if Double(input) == nil {
      return .invalid("Invalid number format")
    }

    return .valid
  }

  /// Exact NUMERIC / DECIMAL text (`DecimalText.isValid`): plain digits with an optional `-`
  /// and fraction, or `NaN`, `Infinity`, `-Infinity`. Those keywords pass for every engine (the
  /// check has no connection): PostgreSQL NUMERIC stores them; another engine treats them as any
  /// text sent to a number column.
  nonisolated private static func validateDecimal(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Value cannot be empty")
    }

    if !DecimalText.isValid(input) {
      return .invalid("Invalid decimal format (use digits like -12.50)")
    }

    return .valid
  }

  nonisolated private static func validateJSON(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("JSON cannot be empty")
    }

    // Try to parse the input as JSON
    guard let data = input.data(using: .utf8),
      (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) != nil
    else {
      return .invalid("Invalid JSON syntax")
    }

    return .valid
  }

  nonisolated private static func validateDate(
    _ input: String, wallClock: Bool
  ) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Date cannot be empty")
    }

    // Plain DATE value: a real calendar day, so the round trip refuses rollovers like 2026-02-30
    if let parsedDate = plainDateFormatter.date(from: input),
      plainDateFormatter.string(from: parsedDate) == input
    {
      return .valid
    }

    // The editor's own text (the grid's display text), then ISO 8601
    if date(from: input, wallClock: wallClock) != nil { return .valid }
    let iso8601Formatter = ISO8601DateFormatter()
    if let parsedDate = iso8601Formatter.date(from: input),
      iso8601Formatter.string(from: parsedDate) == input
    {
      return .valid
    }

    return .invalid("Invalid date format (use yyyy-MM-dd, yyyy-MM-dd HH:mm:ss or ISO8601)")
  }

  /// The instant of a date-time typed as `CellValue.displayString(wallClock:)` shows it:
  /// `yyyy-MM-dd HH:mm:ss` (`T` also separates; `HH:mm` alone is zero seconds), an optional
  /// fraction of 1 to 6 digits after the seconds and an optional zone: `Z`, `±HH:MM`, `±HHMM` or `±HH` (`±HH:MM:SS`, as a local mean time offset
  /// shows). Without a zone the text is a wall clock: UTC for a naive column (`wallClock`), else
  /// the zone zoned dates show in. Nil for any other text (ASCII digits only), an impossible
  /// date or time, or a zone-less zoned time that zone skips.
  nonisolated static func date(from text: String, wallClock: Bool) -> Date? {
    let pattern =
      /([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,6}))?)?(Z|[+-][0-9]{2}(?::?[0-9]{2}(?::[0-9]{2})?)?)?/
    guard let match = text.wholeMatch(of: pattern),
      let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
      let hour = Int(match.4), let minute = Int(match.5),
      let second = match.6.map({ Int($0) }) ?? 0,
      (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
    else { return nil }
    let days = CivilDate.daysSince1970(year: year, month: month, day: day)
    // A day past the month's end (2026-02-30) rolls into the next month: refused
    guard
      CivilDate.text(daysSince1970: days, bcSuffix: "") == match.1 + "-" + match.2 + "-" + match.3
    else { return nil }
    let digits = match.7.map(String.init) ?? ""
    let fraction = Int64(digits.padding(toLength: 6, withPad: "0", startingAt: 0)) ?? 0
    let wallMicros =
      (Int64(days) * 86_400 + Int64(hour * 3_600 + minute * 60 + second)) * 1_000_000 + fraction
    let offset: Int
    if let zone = match.8 {
      guard let seconds = offsetSeconds(String(zone)) else { return nil }
      offset = seconds
    } else if wallClock {
      offset = 0
    } else {
      // The wall clock's offset, read again at the instant it gives so a DST change between them
      // is taken into account
      let local = CellValue.displayZone ?? NSTimeZone.default
      let guess = local.secondsFromGMT(for: Date(timeIntervalSince1970: Double(wallMicros) / 1e6))
      let instant = Double(wallMicros - Int64(guess) * 1_000_000) / 1e6
      offset = local.secondsFromGMT(for: Date(timeIntervalSince1970: instant))
      // A wall clock the zone skips (spring forward) shows another time again: refused
      let result = Date(timeIntervalSince1970: Double(wallMicros - Int64(offset) * 1_000_000) / 1e6)
      guard local.secondsFromGMT(for: result) == offset else { return nil }
    }
    return Date(timeIntervalSince1970: Double(wallMicros - Int64(offset) * 1_000_000) / 1_000_000)
  }

  /// `Z`, `±HH`, `±HHMM`, `±HH:MM` or `±HH:MM:SS` as seconds east of UTC; nil past 15:59:59
  private nonisolated static func offsetSeconds(_ zone: String) -> Int? {
    if zone == "Z" { return 0 }
    let digits = zone.dropFirst().filter(\.isNumber)
    let parts = stride(from: 0, to: digits.count, by: 2).map { start in
      Int(String(digits.dropFirst(start).prefix(2))) ?? 0
    }
    let hours = parts[0]
    let minutes = parts.count > 1 ? parts[1] : 0
    let seconds = parts.count > 2 ? parts[2] : 0
    guard hours < 16, minutes < 60, seconds < 60 else { return nil }
    let magnitude = hours * 3_600 + minutes * 60 + seconds
    return zone.hasPrefix("-") ? -magnitude : magnitude
  }

  private nonisolated static let plainDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.isLenient = false
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  nonisolated private static func validateBoolean(_ input: String) -> ValidationResult {
    let lowercased = input.lowercased()
    let validBooleans = ["true", "false", "1", "0", "t", "f", "yes", "no", "y", "n"]

    if !validBooleans.contains(lowercased) {
      return .invalid("Invalid boolean value (use true/false)")
    }

    return .valid
  }

  nonisolated private static func validateBinaryData(_ input: String) -> ValidationResult {
    if input.isEmpty {
      return .invalid("Binary data cannot be empty")
    }

    // The edit is the value's base64 text, sent as the decoded bytes
    if Data(base64Encoded: input) == nil {
      return .invalid("Invalid base64 (binary values are edited as base64)")
    }
    return .valid
  }
}
