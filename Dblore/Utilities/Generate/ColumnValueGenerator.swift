// ColumnValueGenerator.swift
// Values for one column of a Generate Rows run, as bind text (nil is NULL). The kind comes from
// the column's type and name; bounds come from its type (length, precision, integer width, enum
// labels). Unique columns never repeat within a run: integer keys count up from the table's
// current MAX, other kinds carry a counter. Booleans are "1"/"0" and timestamps
// `yyyy-MM-dd HH:mm:ss`, which PostgreSQL, MySQL and SQLite all read from text binds.

import Foundation

nonisolated struct ColumnValueGenerator: Sendable {
  enum Kind: CaseIterable, Sendable {
    case firstName, lastName, fullName, email, phone, address, city, url, text
    case integer, decimal, boolean, date, timestamp, time
    case uuidV4, uuidV7, json, enumLabel

    /// Name shown in the Generate Rows column menu
    var label: String {
      switch self {
      case .firstName: "First name"
      case .lastName: "Last name"
      case .fullName: "Full name"
      case .email: "Email"
      case .phone: "Phone"
      case .address: "Address"
      case .city: "City"
      case .url: "URL"
      case .text: "Text"
      case .integer: "Integer"
      case .decimal: "Decimal"
      case .boolean: "Boolean"
      case .date: "Date"
      case .timestamp: "Timestamp"
      case .time: "Time"
      case .uuidV4: "UUID v4"
      case .uuidV7: "UUID v7"
      case .json: "JSON"
      case .enumLabel: "Enum label"
      }
    }
  }

  enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
    /// A unique column ran out of values its type holds (an integer range, both booleans,
    /// every label, the length of a short text)
    case uniqueValuesExhausted(column: String)
    /// An enum label column without labels
    case noLabels(column: String)

    var errorDescription: String? {
      switch self {
      case .uniqueValuesExhausted(let column):
        "\(column) has no more values that don't repeat. Generate fewer rows."
      case .noLabels(let column): "\(column) has no labels to pick from."
      }
    }
  }

  let column: String
  let kind: Kind
  let isUnique: Bool
  /// Share of NULLs, 0...1. Always 0 for a column that is NOT NULL or unique.
  let nullRatio: Double
  private let type: ColumnType
  private let labels: [String]
  /// Next unique integer or decimal key; nil once past `Int.max`
  private var nextKey: Int?
  /// Values given so far, NULLs left out: the tag of the current unique value
  private var count = 0

  /// `currentMax` is the table's MAX of an integer key, so the first key is one above it.
  /// `enumLabels` gives a PostgreSQL enum type's labels; MySQL labels come from the type.
  init(
    column: TableStructure.Column, kind: Kind, isUnique: Bool, nullRatio: Double = 0,
    currentMax: Int? = nil, enumLabels: [String] = []
  ) {
    self.column = column.name
    self.kind = kind
    self.isUnique = isUnique
    self.nullRatio = column.isNullable && !isUnique ? min(max(nullRatio, 0), 1) : 0
    type = ColumnType(column.columnType ?? column.dataType)
    labels = enumLabels.isEmpty ? type.labels : enumLabels
    let start = currentMax.map { $0 == .max ? nil : $0 + 1 } ?? 1
    nextKey = start.map { max($0, type.integerBounds?.lowerBound ?? $0) }
  }

  /// The generator a column gets unless the user picks another. Nil when there is none for its
  /// type (binary, network, geometric, interval, array, an enum type without labels).
  static func defaultKind(for column: TableStructure.Column, enumLabels: [String] = []) -> Kind? {
    let typeText = column.columnType ?? column.dataType
    let type = ColumnType(typeText)
    if !enumLabels.isEmpty || !type.labels.isEmpty { return .enumLabel }
    guard !type.isArray else { return nil }
    let base = type.base
    switch base {
    case "uuid", "uniqueidentifier": return .uuidV4
    case "bool", "boolean": return .boolean
    case "json", "jsonb": return .json
    case "date": return .date
    case "datetime", "smalldatetime", "datetime2": return .timestamp
    case "numeric", "decimal", "dec", "number", "fixed", "money", "real", "float4", "float8":
      return .decimal
    default: break
    }
    if base == "tinyint" && type.parameters == [1] { return .boolean }
    if base.hasPrefix("timestamp") { return .timestamp }
    if base.hasPrefix("time") { return .time }
    if base.hasPrefix("float") || base.hasPrefix("double") { return .decimal }
    if type.integerBounds != nil { return .integer }
    guard
      base.isEmpty || base.contains("char") || base.contains("text") || base.contains("clob")
        || base == "string"
    else { return nil }
    return textKind(name: column.name, typeText: typeText)
  }

  /// The next value; nil is NULL
  mutating func next(using random: inout some RandomNumberGenerator) throws -> String? {
    if nullRatio > 0, Double.random(in: 0..<1, using: &random) < nullRatio { return nil }
    count += 1
    switch kind {
    case .integer: return try integer(using: &random)
    case .decimal: return try decimal(using: &random)
    case .boolean:
      guard isUnique else { return Bool.random(using: &random) ? "1" : "0" }
      guard count <= 2 else { throw Error.uniqueValuesExhausted(column: column) }
      return count == 1 ? "0" : "1"
    case .enumLabel:
      guard !labels.isEmpty else { throw Error.noLabels(column: column) }
      guard isUnique else { return labels[Int.random(in: 0..<labels.count, using: &random)] }
      guard count <= labels.count else { throw Error.uniqueValuesExhausted(column: column) }
      return labels[count - 1]
    case .date:
      let day =
        isUnique
        ? Self.firstDay + count - 1 : Int.random(in: Self.firstDay...Self.lastDay, using: &random)
      return Self.dateText(day: day)
    case .timestamp:
      let second =
        isUnique
        ? Self.firstDay * 86_400 + count - 1
        : Int.random(in: Self.firstDay * 86_400..<(Self.lastDay + 1) * 86_400, using: &random)
      return Self.dateText(day: second / 86_400) + " " + Self.timeText(second: second % 86_400)
    case .time:
      guard isUnique else {
        return Self.timeText(second: Int.random(in: 0..<86_400, using: &random))
      }
      guard count <= 86_400 else { throw Error.uniqueValuesExhausted(column: column) }
      return Self.timeText(second: count - 1)
    case .uuidV4: return UUIDGenerator.v4(using: &random)
    case .uuidV7:
      let milliseconds = UInt64(
        Int.random(
          in: Self.firstDay * 86_400_000..<(Self.lastDay + 1) * 86_400_000, using: &random))
      return UUIDGenerator.v7(milliseconds: milliseconds, using: &random)
    case .json:
      let tag = Words.lorem[Int.random(in: 0..<Words.lorem.count, using: &random)]
      let score = Int.random(in: 0...100, using: &random)
      return "{\"id\": \(count), \"tag\": \"\(tag)\", \"score\": \(score)}"
    case .email:
      let (local, domain) = emailParts(using: &random)
      guard isUnique else { return fitted(local + "@" + domain) }
      let email = local + String(count) + "@" + domain
      if let maxLength = type.maxLength, email.count > maxLength { return try tagged(email) }
      return email
    case .firstName, .lastName, .fullName, .phone, .address, .city, .url, .text:
      let base = text(using: &random)
      return isUnique ? try tagged(base) : fitted(base)
    }
  }

  // MARK: - Numbers

  private mutating func integer(using random: inout some RandomNumberGenerator) throws -> String {
    let bounds = type.integerBounds ?? Int.min...Int.max
    guard isUnique else {
      let low = max(bounds.lowerBound, 0)
      return String(Int.random(in: low...max(low, min(bounds.upperBound, 100_000)), using: &random))
    }
    let key = try takeKey()
    guard bounds.contains(key) else { throw Error.uniqueValuesExhausted(column: column) }
    return String(key)
  }

  /// At most the type's integer and fraction digits (`numeric(5,2)`: 3 and 2); unbounded
  /// numbers and floats get 4 and 2
  private mutating func decimal(using random: inout some RandomNumberGenerator) throws -> String {
    let digits = type.decimalDigits
    guard isUnique else {
      let integerDigits = min(digits?.integer ?? 4, 6)
      let fractionDigits = min(digits?.fraction ?? 2, 6)
      let whole = Int.random(in: 0..<Self.power10(integerDigits), using: &random)
      guard fractionDigits > 0 else { return String(whole) }
      let fraction = Int.random(in: 0..<Self.power10(fractionDigits), using: &random)
      return "\(whole).\(Self.padded(fraction, fractionDigits))"
    }
    let key = try takeKey()
    if let digits, digits.integer < 18, key.magnitude >= Self.power10(digits.integer).magnitude {
      throw Error.uniqueValuesExhausted(column: column)
    }
    return String(key)
  }

  private mutating func takeKey() throws -> Int {
    guard let key = nextKey else { throw Error.uniqueValuesExhausted(column: column) }
    nextKey = key == .max ? nil : key + 1
    return key
  }

  // MARK: - Text

  private func text(using random: inout some RandomNumberGenerator) -> String {
    func pick(_ words: [String]) -> String {
      words[Int.random(in: 0..<words.count, using: &random)]
    }
    switch kind {
    case .firstName: return pick(Words.firstNames)
    case .lastName: return pick(Words.lastNames)
    case .fullName: return pick(Words.firstNames) + " " + pick(Words.lastNames)
    case .phone:
      // 555-0100...555-0199 are reserved for fiction in the North American plan
      let area = Int.random(in: 200...999, using: &random)
      return "+1 \(area)-555-01\(Self.padded(Int.random(in: 0...99, using: &random), 2))"
    case .address:
      let number = Int.random(in: 1...9_999, using: &random)
      return "\(number) \(pick(Words.streets)) \(pick(Words.streetSuffixes))"
    case .city: return pick(Words.cities)
    case .url:
      return "https://\(pick(Words.domains))/\(pick(Words.lorem))/\(pick(Words.lorem))"
    default:
      let wordCount = Int.random(in: 3...8, using: &random)
      return (0..<wordCount).map { _ in pick(Words.lorem) }.joined(separator: " ")
    }
  }

  /// `first.last` (letters and dots only, so a counter after it stays readable as one) and a
  /// reserved example domain (RFC 2606)
  private func emailParts(
    using random: inout some RandomNumberGenerator
  ) -> (local: String, domain: String) {
    let first = Words.firstNames[Int.random(in: 0..<Words.firstNames.count, using: &random)]
    let last = Words.lastNames[Int.random(in: 0..<Words.lastNames.count, using: &random)]
    let domain = Words.domains[Int.random(in: 0..<Words.domains.count, using: &random)]
    return (first.lowercased() + "." + last.lowercased(), domain)
  }

  /// `text` cut to the column's length
  private func fitted(_ text: String) -> String {
    guard let maxLength = type.maxLength else { return text }
    return String(text.prefix(maxLength))
  }

  /// `base` cut to the column's length with `-<count>` at the end, or the bare count when the
  /// dash does not fit. The digits after the last dash (or the whole text, which then has no
  /// dash) are the count, so two counts never give the same value.
  private func tagged(_ base: String) throws -> String {
    let tag = "-\(count)"
    guard let maxLength = type.maxLength else { return base + tag }
    if tag.count <= maxLength { return String(base.prefix(maxLength - tag.count)) + tag }
    let digits = String(count)
    guard digits.count <= maxLength else { throw Error.uniqueValuesExhausted(column: column) }
    return digits
  }

  private static func textKind(name: String, typeText: String) -> Kind {
    let words = nameWords(name)
    let joined = words.joined()
    func has(_ candidates: String...) -> Bool { candidates.contains { words.contains($0) } }
    if has("uuid", "guid"), UUIDGenerator.fits(columnType: typeText) { return .uuidV4 }
    if has("mail") || joined.contains("email") { return .email }
    if has("tel", "telephone", "mobile", "fax") || joined.contains("phone") { return .phone }
    if has("url", "uri", "website", "homepage", "link") { return .url }
    if has("fname") || joined.contains("firstname") || joined.contains("givenname") {
      return .firstName
    }
    if has("lname", "surname") || joined.contains("lastname") || joined.contains("familyname") {
      return .lastName
    }
    if has("city", "town") { return .city }
    if has("street", "addr") || joined.contains("address") { return .address }
    if has("name", "fullname") { return .fullName }
    return .text
  }

  /// `firstName`, `first_name` and `FIRST-NAME` all give ["first", "name"]
  private static func nameWords(_ name: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previousIsLower = false
    for character in name {
      guard character.isLetter || character.isNumber else {
        if !current.isEmpty { words.append(current) }
        current = ""
        previousIsLower = false
        continue
      }
      if character.isUppercase, previousIsLower {
        words.append(current)
        current = ""
      }
      current.append(character)
      previousIsLower = character.isLowercase || character.isNumber
    }
    if !current.isEmpty { words.append(current) }
    return words.map { $0.lowercased() }
  }

  // MARK: - Dates

  /// Generated dates fall in 2020-01-01...2025-12-31 (days since 1970-01-01); unique ones
  /// count up from the first day
  private static let firstDay = 18_262
  private static let lastDay = 20_453

  /// Days since 1970-01-01 as `yyyy-MM-dd`, proleptic Gregorian (civil-from-days)
  private static func dateText(day: Int) -> String {
    let shifted = day + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let dayOfMonth = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return "\(padded(year, 4))-\(padded(month, 2))-\(padded(dayOfMonth, 2))"
  }

  private static func timeText(second: Int) -> String {
    "\(padded(second / 3_600, 2)):\(padded(second / 60 % 60, 2)):\(padded(second % 60, 2))"
  }

  private static func padded(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
  }

  private static func power10(_ exponent: Int) -> Int {
    (0..<exponent).reduce(1) { value, _ in value * 10 }
  }
}

nonisolated extension ColumnValueGenerator {
  /// What a column's type text says about its values
  struct ColumnType: Sendable, Equatable {
    /// Lowercased name without parameters or sign words (`varchar`, `int`,
    /// `timestamp with time zone`)
    var base: String
    /// Numbers in the parentheses: `varchar(20)` [20], `numeric(10,2)` [10, 2]
    var parameters: [Int]
    var isUnsigned: Bool
    /// PostgreSQL `integer[]`
    var isArray: Bool
    /// MySQL `enum('a','b')` and `set(...)` labels
    var labels: [String]

    init(_ text: String) {
      let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
      isArray = lowered.hasSuffix("[]")
      var name = lowered
      var inside = ""
      if let open = lowered.firstIndex(of: "("), let close = lowered.lastIndex(of: ")"),
        open < close
      {
        inside = String(lowered[lowered.index(after: open)..<close])
        name = String(lowered[..<open]) + " " + String(lowered[lowered.index(after: close)...])
      }
      let words = name.split(separator: " ").map(String.init)
      isUnsigned = words.contains("unsigned")
      base = words.filter { !["unsigned", "signed", "zerofill"].contains($0) }.joined(
        separator: " ")
      let numbers = inside.split(separator: ",").map {
        Int($0.trimmingCharacters(in: .whitespaces))
      }
      parameters = numbers.contains(nil) ? [] : numbers.compactMap { $0 }
      // Labels keep their case, so they are read from the original text
      labels = base == "enum" || base == "set" ? Self.quotedLabels(text) : []
    }

    /// `char(n)`, `varchar(n)`, `character varying(n)` and the like. Nil for n < 1: SQLite keeps
    /// declared type text as written, so a file can declare `varchar(-5)`.
    var maxLength: Int? {
      base.contains("char") && parameters.count == 1 && parameters[0] > 0 ? parameters[0] : nil
    }

    /// `numeric(p,s)` / `decimal(p)`: p - s integer digits and s fraction digits
    var decimalDigits: (integer: Int, fraction: Int)? {
      guard ["numeric", "decimal", "dec", "number", "fixed"].contains(base),
        let precision = parameters.first
      else { return nil }
      let scale = parameters.count > 1 ? parameters[1] : 0
      return (max(precision - scale, 0), max(scale, 0))
    }

    /// The range an integer type holds. Nil for a type that is not an integer.
    var integerBounds: ClosedRange<Int>? {
      let signed: ClosedRange<Int>
      switch base {
      case "tinyint": signed = -128...127
      case "smallint", "int2", "smallserial": signed = Int(Int16.min)...Int(Int16.max)
      case "mediumint": signed = -8_388_608...8_388_607
      case "int", "integer", "int4", "serial": signed = Int(Int32.min)...Int(Int32.max)
      default:
        // SQLite reads any declared type with INT in it as an integer
        guard base.contains("int"), !base.contains("interval"), !base.contains("point"),
          !base.contains("range")
        else {
          return nil
        }
        signed = Int.min...Int.max
      }
      guard isUnsigned else { return signed }
      return 0...(signed.upperBound == .max ? .max : signed.upperBound * 2 + 1)
    }

    /// `enum('a','it''s')` gives ["a", "it's"]
    private static func quotedLabels(_ text: String) -> [String] {
      guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close
      else { return [] }
      var labels: [String] = []
      var current: String?
      var characters = text[text.index(after: open)..<close].makeIterator()
      var pending = characters.next()
      while let character = pending {
        pending = characters.next()
        guard character == "'" else {
          current?.append(character)
          continue
        }
        if current == nil {
          current = ""
        } else if pending == "'" {
          current?.append("'")
          pending = characters.next()
        } else {
          labels.append(current ?? "")
          current = nil
        }
      }
      return labels
    }
  }
}

/// Small word lists for generated text: fictional names, places and filler words
nonisolated private enum Words {
  static let firstNames = [
    "Alice", "Ben", "Clara", "Daniel", "Emma", "Felix", "Grace", "Henry", "Iris", "Jack", "Laura",
    "Liam", "Maya", "Noah", "Olivia", "Paul", "Quinn", "Rosa", "Sam", "Tara", "Victor", "Zoe",
  ]
  static let lastNames = [
    "Adams", "Baker", "Carter", "Diaz", "Evans", "Fisher", "Garcia", "Hughes", "Ito", "Jensen",
    "Kim", "Lopez", "Martin", "Nguyen", "Owens", "Patel", "Reed", "Silva", "Turner", "Walker",
  ]
  static let streets = [
    "Oak", "Maple", "Cedar", "Pine", "Elm", "Birch", "Willow", "Lake", "Hill", "River", "Park",
    "Sunset",
  ]
  static let streetSuffixes = ["Street", "Avenue", "Road", "Lane", "Drive", "Way"]
  static let cities = [
    "Springfield", "Riverton", "Lakeside", "Fairview", "Brookfield", "Greenville", "Oakdale",
    "Maplewood", "Hillcrest", "Westport", "Northfield", "Clearwater",
  ]
  /// Reserved for examples (RFC 2606)
  static let domains = ["example.com", "example.org", "example.net"]
  static let lorem = [
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
    "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua", "enim",
    "minim", "veniam", "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi",
  ]
}
