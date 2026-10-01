// ExportOptions.swift
// Choices for the result download sheet. Each format shows only its own toggles.
// Clipboard copy does not use this.

import Foundation

/// Download target. The sheet opens with the format the user picked in the Download menu.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case csv
  case excel
  case json
  case markdown
  case pdf
  case sqlInsert

  var id: String { rawValue }

  var title: String {
    switch self {
    case .csv: "CSV"
    case .excel: "Excel"
    case .json: "JSON"
    case .markdown: "Markdown"
    case .pdf: "PDF"
    case .sqlInsert: "SQL INSERT"
    }
  }

  var blurb: String {
    switch self {
    case .csv:
      "Comma-separated values. Compatible with Excel and most tools."
    case .excel:
      "Excel workbook (.xlsx)."
    case .json:
      "A JSON array of objects, one per row."
    case .markdown:
      "A Markdown table."
    case .pdf:
      "A paginated PDF. Long text can wrap instead of being cut off."
    case .sqlInsert:
      "INSERT statements for the rows in this result."
    }
  }

  /// CSV and Markdown can omit the column-name row. SQL can omit the column list.
  var offersHeaderToggle: Bool {
    self == .csv || self == .markdown || self == .sqlInsert
  }

  var headerToggleTitle: String {
    self == .sqlInsert ? "Include column names" : "Put field names in the first row"
  }

  /// Formats that can write an empty field instead of NULL. JSON keeps a real null or omits the key.
  var offersNullAsEmpty: Bool {
    self == .csv || self == .excel || self == .markdown || self == .sqlInsert
  }

  var offersWrap: Bool {
    self == .pdf
  }

  /// Newlines inside a cell become a space. JSON keeps them escaped. PDF wrap keeps the lines.
  var offersLineBreakToSpace: Bool {
    self == .csv || self == .excel || self == .markdown || self == .sqlInsert
  }

  /// Spreadsheet formula injection. Other formats have no formula parser.
  var offersFormulaSanitize: Bool {
    self == .csv || self == .excel
  }

  /// Text files. Excel is OOXML and PDF has its own encoding.
  var offersEncoding: Bool {
    self == .csv || self == .json || self == .markdown || self == .sqlInsert
  }

  var offersQuote: Bool {
    self == .csv
  }

  /// Same files as encoding. Excel and PDF do not take a record separator.
  var offersLineBreak: Bool {
    offersEncoding
  }

  var offersJsonPretty: Bool { self == .json }
  var offersJsonIncludeNull: Bool { self == .json }
  var offersJsonValuesAsString: Bool { self == .json }
}

/// How the row count is drawn in the export sheet.
nonisolated enum ExportRowScale: Equatable, Sendable {
  /// Under 1,000 rows.
  case modest
  /// 1,000 through 9,999 rows.
  case large
  /// 10,000 rows or more.
  case huge

  static func level(for count: Int) -> ExportRowScale {
    if count >= 10_000 { return .huge }
    if count >= 1_000 { return .large }
    return .modest
  }
}

/// Text-file encoding. UTF-16 LE always starts with a byte order mark.
nonisolated enum ExportEncoding: String, CaseIterable, Identifiable, Sendable {
  case utf8
  case utf16LE
  case windows1252

  var id: String { rawValue }

  var title: String {
    switch self {
    case .utf8: "UTF-8"
    case .utf16LE: "UTF-16 LE"
    case .windows1252: "Windows-1252"
    }
  }

  func encode(_ text: String) -> Data {
    switch self {
    case .utf8:
      return Data(text.utf8)
    case .utf16LE:
      var data = Data([0xFF, 0xFE])
      if let payload = text.data(using: .utf16LittleEndian) {
        data.append(payload)
      }
      return data
    case .windows1252:
      return text.data(using: Self.windows1252Encoding, allowLossyConversion: true)
        ?? Data(text.utf8)
    }
  }

  /// `kCFStringEncodingWindowsLatin1` (code page 1252).
  private static let windows1252Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(0x0500))
}

/// CSV field quoting. Other formats quote with their own rules.
nonisolated enum ExportQuote: String, CaseIterable, Identifiable, Sendable {
  case ifNeeded
  case always
  case never

  var id: String { rawValue }

  var title: String {
    switch self {
    case .ifNeeded: "Quote if needed"
    case .always: "Always"
    case .never: "Never"
    }
  }
}

/// Record separator, also applied to line breaks that remain inside fields.
nonisolated enum ExportLineBreak: String, CaseIterable, Identifiable, Sendable {
  case lf
  case crlf
  case cr

  var id: String { rawValue }

  var title: String {
    switch self {
    case .lf: "\\n"
    case .crlf: "\\r\\n"
    case .cr: "\\r"
    }
  }

  var ending: String {
    switch self {
    case .lf: "\n"
    case .crlf: "\r\n"
    case .cr: "\r"
    }
  }

  func applied(to text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    if ending == "\n" { return normalized }
    return normalized.replacingOccurrences(of: "\n", with: ending)
  }
}

/// Options for one download. Toggles that the format does not offer stay stored and unused.
nonisolated struct ExportOptions: Equatable, Sendable {
  var format: ExportFormat
  /// Column indexes whose cells are written as `mask`, including nulls.
  var redactedColumns: Set<Int> = []
  /// PDF only. On by default so a long cell is not cut with an ellipsis.
  var wrapText: Bool = true
  /// CSV and Markdown. On matches the previous exporters, which always wrote a header.
  /// SQL uses the same flag for the column list.
  var includeHeader: Bool = true
  /// Off keeps NULL. CSV writes the letters NULL; SQL writes the keyword NULL.
  var nullAsEmpty: Bool = false
  /// Off keeps line breaks inside the cell.
  var convertLineBreaksToSpace: Bool = false
  /// On prefixes formula-like text. A numeric cell is never prefixed.
  var sanitizeFormulas: Bool = true
  var encoding: ExportEncoding = .utf8
  var quote: ExportQuote = .ifNeeded
  var lineBreak: ExportLineBreak = .lf
  var jsonPretty: Bool = true
  var jsonIncludeNull: Bool = true
  var jsonValuesAsString: Bool = false

  static let mask = "****"

  var emptiesNulls: Bool {
    nullAsEmpty && format.offersNullAsEmpty
  }
}

extension DataExporter {
  /// Sensitive columns, then nulls, then line breaks and formula prefixes when that format offers them.
  static func applying(_ options: ExportOptions, to result: CellResult) -> CellResult {
    let emptyNulls = options.emptiesNulls
    let flatten = options.convertLineBreaksToSpace && options.format.offersLineBreakToSpace
    let sanitize = options.sanitizeFormulas && options.format.offersFormulaSanitize
    if options.redactedColumns.isEmpty && !emptyNulls && !flatten && !sanitize {
      return result
    }
    let rows = result.rows.map { row in
      row.enumerated().map { index, value -> CellValue in
        if options.redactedColumns.contains(index) {
          return .string(ExportOptions.mask)
        }
        var next = value
        if emptyNulls && next.isNull {
          next = .string("")
        }
        if flatten {
          next = flatteningLineBreaks(next)
        }
        if sanitize {
          next = sanitizingFormula(next)
        }
        return next
      }
    }
    return CellResult(
      columns: result.columns,
      rows: rows,
      executionTime: result.executionTime,
      rowCount: rows.count,
      timestamp: result.timestamp,
      error: result.error,
      wasLimited: result.wasLimited,
      sourceQuery: result.sourceQuery,
      tableName: result.tableName,
      primaryKeyColumns: result.primaryKeyColumns,
      affectedRows: result.affectedRows,
      editTarget: result.editTarget)
  }

  /// Bytes for a text export. Encoding and the line ending apply only when the format offers them.
  static func fileData(text: String, options: ExportOptions) -> Data {
    let broken = options.format.offersLineBreak ? options.lineBreak.applied(to: text) : text
    let encoding = options.format.offersEncoding ? options.encoding : .utf8
    return encoding.encode(broken)
  }

  private static func flatteningLineBreaks(_ value: CellValue) -> CellValue {
    switch value {
    case .string(let text):
      return .string(spacesForLineBreaks(text))
    case .json(let text):
      return .json(spacesForLineBreaks(text))
    default:
      return value
    }
  }

  private static func spacesForLineBreaks(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  /// A leading `=`, `+`, `-`, `@`, tab, or CR marks a spreadsheet formula. Numbers stay numbers.
  private static func sanitizingFormula(_ value: CellValue) -> CellValue {
    switch value {
    case .string(let text):
      return .string(prefixedIfFormula(text))
    case .json(let text):
      return .json(prefixedIfFormula(text))
    default:
      return value
    }
  }

  private static let formulaStarters: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

  private static func prefixedIfFormula(_ text: String) -> String {
    guard let first = text.first, formulaStarters.contains(first) else { return text }
    return "'" + text
  }
}
