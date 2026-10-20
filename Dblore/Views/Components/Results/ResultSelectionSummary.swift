//
//  ResultSelectionSummary.swift
//  Dblore
//
//  Summary of the selected result cells. The grid selects whole rows, so the cells are the
//  selected rows in the last clicked column; without a clicked column only the rows are counted.
//  Numbers are summed in Decimal: `.int` and `.double` cells, and text cells of a numeric column
//  type (an exact DECIMAL read as text). A column with other values summarizes its numeric
//  cells only and says so. Above `detachedThreshold` cells the work runs in a detached task.
//

import Foundation

nonisolated struct ResultSelectionSummary: Equatable, Sendable {
  /// Selected rows (one cell each when a column is summarized)
  let count: Int
  /// Summarized column. Nil when no column was clicked: the row count only.
  let columnName: String?
  let nonNullCount: Int
  /// Non-null cells read as numbers; the statistics cover only these
  let numericCount: Int
  let sum: Decimal?
  let average: Decimal?
  let minimum: Decimal?
  let maximum: Decimal?

  /// More cells than this are summarized in a detached task
  static let detachedThreshold = 10_000

  /// Rows without a clicked column
  init(rowCount: Int) {
    count = rowCount
    columnName = nil
    nonNullCount = 0
    numericCount = 0
    sum = nil
    average = nil
    minimum = nil
    maximum = nil
  }

  private init(
    count: Int, columnName: String, nonNullCount: Int, numericCount: Int, sum: Decimal?,
    minimum: Decimal?, maximum: Decimal?
  ) {
    self.count = count
    self.columnName = columnName
    self.nonNullCount = nonNullCount
    self.numericCount = numericCount
    self.sum = sum
    average = sum.map { $0 / Decimal(numericCount) }
    self.minimum = minimum
    self.maximum = maximum
  }

  /// Some non-null cells are not numbers: the statistics leave them out
  var isMixed: Bool { numericCount > 0 && numericCount < nonNullCount }

  /// Summary of the cells of one column. Throws `CancellationError` when the task is cancelled.
  static func compute(
    values: [CellValue], columnName: String, columnType: String
  ) throws -> ResultSelectionSummary {
    let numericColumn = isNumericType(columnType)
    var nonNull = 0
    var numeric = 0
    var sum = Decimal.zero
    var minimum: Decimal?
    var maximum: Decimal?
    for (index, value) in values.enumerated() {
      if index % 1024 == 0 { try Task.checkCancellation() }
      if value.isNull { continue }
      nonNull += 1
      guard let number = decimal(value, numericColumn: numericColumn) else { continue }
      numeric += 1
      sum += number
      if minimum.map({ number < $0 }) ?? true { minimum = number }
      if maximum.map({ number > $0 }) ?? true { maximum = number }
    }
    return ResultSelectionSummary(
      count: values.count, columnName: columnName, nonNullCount: nonNull, numericCount: numeric,
      sum: numeric > 0 && !sum.isNaN ? sum : nil, minimum: minimum, maximum: maximum)
  }

  /// `compute`, in a detached task above `detachedThreshold` cells. Cancelling the caller's task
  /// cancels that work.
  static func summarize(
    values: [CellValue], columnName: String, columnType: String
  ) async throws -> ResultSelectionSummary {
    guard values.count > detachedThreshold else {
      return try compute(values: values, columnName: columnName, columnType: columnType)
    }
    let task = Task.detached(priority: .userInitiated) {
      try compute(values: values, columnName: columnName, columnType: columnType)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  // MARK: - Numbers

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// Integer, decimal and floating-point type names of the supported engines, without length,
  /// precision or `unsigned`
  private static let numericTypes: Set<String> = [
    "int", "int2", "int4", "int8", "integer", "smallint", "bigint", "tinyint", "mediumint",
    "hugeint", "uhugeint", "ubigint", "uinteger", "usmallint", "utinyint", "numeric", "decimal",
    "real", "float", "float4", "float8", "double", "double precision",
  ]

  /// Whether text cells of `type` are numbers (MySQL DECIMAL arrives as exact text)
  static func isNumericType(_ type: String) -> Bool {
    var head = type.lowercased()
    if let paren = head.firstIndex(of: "(") { head = String(head[..<paren]) }
    head = head.replacingOccurrences(of: "unsigned", with: "")
    return numericTypes.contains(head.trimmingCharacters(in: .whitespaces))
  }

  /// Exact value of a numeric cell. A double goes through its shortest text, so 0.1 stays 0.1.
  static func decimal(_ value: CellValue, numericColumn: Bool) -> Decimal? {
    switch value {
    case .int(let number):
      return Decimal(number)
    case .double(let number):
      guard number.isFinite else { return nil }
      return Decimal(string: String(number), locale: posix)
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      guard numericColumn, isPlainNumber(trimmed) else { return nil }
      return Decimal(string: trimmed, locale: posix)
    default:
      return nil
    }
  }

  /// Optional sign, digits with an optional fraction, optional exponent; nothing else
  private static func isPlainNumber(_ text: String) -> Bool {
    var bytes = Substring(text).utf8[...]
    if let first = bytes.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
      bytes = bytes.dropFirst()
    }
    let isDigit = { (byte: UInt8) in (0x30...0x39).contains(byte) }
    let whole = bytes.prefix(while: isDigit)
    bytes = bytes.dropFirst(whole.count)
    var fraction = bytes.prefix(0)
    if bytes.first == UInt8(ascii: ".") {
      bytes = bytes.dropFirst()
      fraction = bytes.prefix(while: isDigit)
      bytes = bytes.dropFirst(fraction.count)
    }
    guard !whole.isEmpty || !fraction.isEmpty else { return false }
    guard let marker = bytes.first else { return true }
    guard marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") else { return false }
    bytes = bytes.dropFirst()
    if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
      bytes = bytes.dropFirst()
    }
    return !bytes.isEmpty && bytes.allSatisfy(isDigit)
  }

  // MARK: - Text

  static func format(_ value: Decimal, locale: Locale = .current) -> String {
    value.formatted(.number.locale(locale))
  }

  /// Status bar text: "Count n · Sum … · Avg …", "Count n" for a column with no numbers, or
  /// "n rows" without a clicked column
  func statusText(locale: Locale = .current) -> String {
    let rows = count.formatted(.number.locale(locale))
    guard columnName != nil else { return "\(rows) \(count == 1 ? "row" : "rows")" }
    guard let sum, let average else { return "Count \(rows)" }
    return
      "Count \(rows) · Sum \(Self.format(sum, locale: locale)) · Avg \(Self.format(average, locale: locale))"
  }

  /// Label and value of each statistic, in popover and copy order
  func lines(locale: Locale = .current) -> [(label: String, value: String)] {
    var lines: [(label: String, value: String)] = [
      ("Count", count.formatted(.number.locale(locale))),
      ("Non-null", nonNullCount.formatted(.number.locale(locale))),
    ]
    let stats: [(String, Decimal?)] = [
      ("Sum", sum), ("Avg", average), ("Min", minimum), ("Max", maximum),
    ]
    for (label, value) in stats {
      if let value { lines.append((label, Self.format(value, locale: locale))) }
    }
    return lines
  }

  /// "Numeric cells only (n of m)" for a mixed column, else nil
  func mixedNote(locale: Locale = .current) -> String? {
    guard isMixed else { return nil }
    let numeric = numericCount.formatted(.number.locale(locale))
    let nonNull = nonNullCount.formatted(.number.locale(locale))
    return "Numeric cells only (\(numeric) of \(nonNull))"
  }

  /// Copied text: the column, one "Label: value" line per statistic, and the mixed note
  func copyText(locale: Locale = .current) -> String {
    var text = columnName.map { [$0] } ?? []
    text += lines(locale: locale).map { "\($0.label): \($0.value)" }
    if let note = mixedNote(locale: locale) { text.append(note) }
    return text.joined(separator: "\n")
  }
}
