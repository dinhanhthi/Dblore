// ParquetExport.swift
// What a Parquet export sends to its in-memory DuckDB: one DuckDB type per result column, the
// CREATE TABLE and multi-row INSERT text (values are binds), the text each value binds as, and
// the COPY statement. COPY only writes the app-created temporary file
// `<temp root>/dblore-parquet-<uuid>/export.parquet`; any other path is refused.

import Foundation

nonisolated enum ParquetExport {
  /// The table the rows go into before COPY.
  static let tableName = "export"
  static let fileName = "export.parquet"
  static let directoryPrefix = "dblore-parquet-"
  /// Rows per INSERT statement (spike 2.3: 1,000 rows per statement, ~2.4 s per 100k rows).
  static let rowsPerStatement = 1_000
  /// DuckDB's widest DECIMAL.
  private static let maxDecimalPrecision = 38

  enum Failure: Error, Equatable, LocalizedError {
    /// A table needs at least one column.
    case noColumns
    /// The COPY target is not the app-created temporary file.
    case refusedTarget
    /// The DuckDB plugin is not installed.
    case pluginMissing

    var errorDescription: String? {
      switch self {
      case .noColumns: "This result has no columns to export."
      case .refusedTarget: "The Parquet file can only be written to its temporary folder."
      case .pluginMissing: "Parquet export requires the DuckDB plugin (Settings > Plugins)."
      }
    }
  }

  enum ColumnType: Equatable, Sendable {
    case bigint
    case double
    case boolean
    case timestamp
    case blob
    case json
    case varchar
    case decimal(precision: Int, scale: Int)

    var sql: String {
      switch self {
      case .bigint: "BIGINT"
      case .double: "DOUBLE"
      case .boolean: "BOOLEAN"
      case .timestamp: "TIMESTAMP"
      case .blob: "BLOB"
      case .json: "JSON"
      case .varchar: "VARCHAR"
      case .decimal(let precision, let scale): "DECIMAL(\(precision),\(scale))"
      }
    }
  }

  struct Column: Equatable, Sendable {
    let name: String
    let type: ColumnType
  }

  // MARK: - Columns

  /// One column per result column: unique names (empty becomes `column_<n>`, a repeat, compared
  /// case-insensitively like DuckDB, gets `_2`, `_3`, …) and the type its values agree on.
  static func columns(_ columns: [ColumnInfo], rows: [[CellValue]]) -> [Column] {
    var used: Set<String> = []
    return columns.enumerated().map { index, column in
      let base = column.name.isEmpty ? "column_\(index + 1)" : column.name
      var name = base
      var suffix = 1
      while used.contains(name.lowercased()) {
        suffix += 1
        name = "\(base)_\(suffix)"
      }
      used.insert(name.lowercased())
      let values = rows.lazy.map { index < $0.count ? $0[index] : .null }
      return Column(name: name, type: type(source: column.type, values: values))
    }
  }

  /// The kind every non-NULL value shares (ints and doubles together are DOUBLE). Text is
  /// DECIMAL only when the source type is NUMERIC or DECIMAL and every value is plain decimal
  /// text that fits; mixed kinds and all-NULL columns are VARCHAR.
  private static func type(source: String, values: some Sequence<CellValue>) -> ColumnType {
    var kind: ColumnType?
    var texts: [String] = []
    for value in values {
      let next: ColumnType
      switch value {
      case .null: continue
      case .int: next = .bigint
      case .double: next = .double
      case .bool: next = .boolean
      case .date: next = .timestamp
      case .data: next = .blob
      case .json: next = .json
      case .string(let text):
        next = .varchar
        texts.append(text)
      }
      switch (kind, next) {
      case (nil, _): kind = next
      case (.bigint?, .double), (.double?, .bigint): kind = .double
      case (let current?, _) where current == next: break
      default: return .varchar
      }
    }
    guard let kind else { return .varchar }
    if kind == .varchar, let decimal = decimalType(source: source, texts: texts) {
      return decimal
    }
    return kind
  }

  /// The declared precision and scale when the values fit, else precision 38 and the widest
  /// scale; nil when the source is not NUMERIC/DECIMAL or a value is not plain decimal text.
  private static func decimalType(source: String, texts: [String]) -> ColumnType? {
    guard let declared = declaredDecimal(source) else { return nil }
    var integerDigits = 0
    var scale = 0
    for text in texts {
      guard let digits = decimalDigits(text) else { return nil }
      integerDigits = max(integerDigits, digits.integer)
      scale = max(scale, digits.fraction)
    }
    if let declared, case (let precision, let declaredScale) = declared,
      precision <= maxDecimalPrecision,
      scale <= declaredScale, integerDigits <= precision - declaredScale
    {
      return .decimal(precision: precision, scale: declaredScale)
    }
    guard integerDigits + scale <= maxDecimalPrecision else { return nil }
    return .decimal(precision: maxDecimalPrecision, scale: scale)
  }

  /// `.some(nil)` for a bare NUMERIC/DECIMAL/DEC, `.some((p, s))` with a valid `(p)` or `(p,s)`
  /// (a malformed suffix counts as bare); nil for any other type.
  private static func declaredDecimal(_ source: String) -> (Int, Int)?? {
    let upper = source.trimmingCharacters(in: .whitespaces).uppercased()
    guard let name = ["NUMERIC", "DECIMAL", "DEC"].first(where: upper.hasPrefix) else {
      return nil
    }
    let rest = upper.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty { return .some(nil) }
    guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
    let parts = rest.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
      .map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard (1...2).contains(parts.count), let precision = parts[0], precision >= 1 else {
      return .some(nil)
    }
    let scale = parts.count == 2 ? parts[1] : 0
    guard let scale, scale >= 0, scale <= precision else { return .some(nil) }
    return .some((precision, scale))
  }

  /// Integer digits (leading zeros not counted) and fraction digits of `[+-]digits[.digits]`;
  /// nil for anything else (exponents, NaN, Infinity, empty).
  private static func decimalDigits(_ text: String) -> (integer: Int, fraction: Int)? {
    var body = Substring(text)
    if let first = body.first, first == "-" || first == "+" { body = body.dropFirst() }
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }) else {
      return nil
    }
    let integer = parts[0]
    let fraction = parts.count == 2 ? parts[1] : ""
    guard !integer.isEmpty || !fraction.isEmpty else { return nil }
    return (integer.drop(while: { $0 == "0" }).count, fraction.count)
  }

  // MARK: - Statements

  static func createTableSQL(_ columns: [Column]) throws -> String {
    guard !columns.isEmpty else { throw Failure.noColumns }
    let dialect = SQLDialect.duckdb
    let definitions = try columns.map { try dialect.quoteIdentifier($0.name) + " " + $0.type.sql }
    return "CREATE TABLE \(try dialect.quoteIdentifier(tableName)) ("
      + definitions.joined(separator: ", ") + ")"
  }

  /// `INSERT INTO "export" ("a", …) VALUES ($1, …), (…)`, `rowCount` rows of placeholders.
  static func insertSQL(columns: [Column], rowCount: Int) throws -> String {
    guard !columns.isEmpty else { throw Failure.noColumns }
    let dialect = SQLDialect.duckdb
    let names = try columns.map { try dialect.quoteIdentifier($0.name) }
    let width = columns.count
    let rows = (0..<rowCount).map { row in
      "(" + (1...width).map { dialect.placeholder(row * width + $0) }.joined(separator: ", ")
        + ")"
    }
    return "INSERT INTO \(try dialect.quoteIdentifier(tableName)) ("
      + names.joined(separator: ", ") + ") VALUES " + rows.joined(separator: ", ")
  }

  /// Row ranges of at most `rowsPerStatement` rows.
  static func batches(rowCount: Int) -> [Range<Int>] {
    stride(from: 0, to: rowCount, by: rowsPerStatement).map {
      $0..<min($0 + rowsPerStatement, rowCount)
    }
  }

  /// `COPY "export" TO '<path>' (FORMAT PARQUET)`. `outputPath` must be exactly
  /// `outputPath(temporaryRoot:id:)` for some id, and `temporaryRoot` an absolute path without
  /// `.`, `..` or empty components, a trailing slash, NUL or a line break.
  static func copySQL(outputPath: String, temporaryRoot: String) throws -> String {
    guard isPlainAbsolutePath(temporaryRoot) else { throw Failure.refusedTarget }
    let prefix = temporaryRoot + "/" + directoryPrefix
    let suffix = "/" + fileName
    guard outputPath.hasPrefix(prefix), outputPath.hasSuffix(suffix),
      outputPath.count > prefix.count + suffix.count
    else { throw Failure.refusedTarget }
    let id = outputPath.dropFirst(prefix.count).dropLast(suffix.count)
    guard let uuid = UUID(uuidString: String(id)), uuid.uuidString == id else {
      throw Failure.refusedTarget
    }
    let table = try SQLDialect.duckdb.quoteIdentifier(tableName)
    return "COPY \(table) TO \(SQLDialect.duckdb.literal(.string(outputPath))) (FORMAT PARQUET)"
  }

  static func outputPath(temporaryRoot: String, id: UUID) -> String {
    temporaryRoot + "/" + directoryPrefix + id.uuidString + "/" + fileName
  }

  private static func isPlainAbsolutePath(_ path: String) -> Bool {
    guard path.count > 1, path.hasPrefix("/"), !path.hasSuffix("/"),
      !path.contains(where: { $0 == "\0" || $0.isNewline })
    else { return false }
    return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  // MARK: - Binds

  static func binds(_ row: [CellValue], columns: [Column]) -> [SQLBindValue] {
    columns.indices.map { index in
      bind(index < row.count ? row[index] : .null, as: columns[index].type)
    }
  }

  /// Text DuckDB casts to `type`. VARCHAR columns take each value's full text.
  static func bind(_ value: CellValue, as type: ColumnType) -> SQLBindValue {
    switch (value, type) {
    case (.null, _): .null
    case (.double(let number), .double): .text(doubleText(number))
    case (.date(let date), .timestamp): .text(timestampText(date))
    case (.data(let data), .blob): .text(blobText(data))
    default: .text(value.fullString)
    }
  }

  private static func doubleText(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
    return String(number)
  }

  /// `\xHH` for every byte: DuckDB's VARCHAR to BLOB cast reads only ASCII and these escapes.
  private static func blobText(_ data: Data) -> String {
    let digits = Array("0123456789ABCDEF")
    var text = ""
    text.reserveCapacity(data.count * 4)
    for byte in data {
      text += "\\x"
      text.append(digits[Int(byte >> 4)])
      text.append(digits[Int(byte & 0x0F)])
    }
    return text
  }

  /// `yyyy-MM-dd HH:mm:ss.SSSSSS` in UTC on the proleptic Gregorian calendar (DuckDB's), so
  /// dates before 1582 are not shifted to the Julian calendar. A date beyond Int64 microseconds
  /// (PostgreSQL `infinity`) is DuckDB's `infinity` or `-infinity`.
  private static func timestampText(_ date: Date) -> String {
    let total = (date.timeIntervalSince1970 * 1_000_000).rounded()
    guard let micros = Int64(exactly: total), micros > -Int64.max, micros < Int64.max else {
      return total < 0 ? "-infinity" : "infinity"
    }
    var (seconds, fraction) = micros.quotientAndRemainder(dividingBy: 1_000_000)
    if fraction < 0 {
      seconds -= 1
      fraction += 1_000_000
    }
    let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
    let time = seconds - days * 86_400
    let (year, month, day) = civilDate(daysSince1970: days)
    return String(
      format: "%04lld-%02lld-%02lld %02lld:%02lld:%02lld.%06lld", year, month, day, time / 3_600,
      time % 3_600 / 60, time % 60, fraction)
  }

  /// Year, month, day of a day count from 1970-01-01 (H. Hinnant's `civil_from_days`).
  private static func civilDate(daysSince1970: Int64) -> (Int64, Int64, Int64) {
    let shifted = daysSince1970 + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }
}
