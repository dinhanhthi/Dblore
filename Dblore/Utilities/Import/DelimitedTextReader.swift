// DelimitedTextReader.swift
// RFC 4180 text. Delimiter is comma, semicolon, tab, or pipe.
// Bytes are UTF-8, then Latin-1. Fields are not trimmed.

import Foundation

nonisolated enum DelimitedTextError: Error, LocalizedError, Equatable, Sendable {
  case unclosedQuote
  case cellLimitExceeded
  case rowLimitExceeded
  case fieldLimitExceeded
  case encodingChanged
  case tooManyFields(row: Int)
  case recordLimitExceeded(row: Int)

  var errorDescription: String? {
    switch self {
    case .unclosedQuote: "A quoted field is not closed"
    case .cellLimitExceeded: "Import exceeds the 1,000,000-cell safety limit"
    case .rowLimitExceeded: "Import exceeds the 100,000-row safety limit"
    case .fieldLimitExceeded: "Import contains a field longer than the safety limit"
    case .encodingChanged:
      "The file is not valid UTF-8 after the preview. Save it as UTF-8 and import again."
    case .tooManyFields(let row):
      "Row \(row.formatted()) has more fields than the file has columns"
    case .recordLimitExceeded(let row):
      "Row \(row.formatted()) is longer than the 64 MiB safety limit"
    }
  }
}

/// Preview table. Every row has one string per column. A missing field is empty.
nonisolated enum DelimitedTextReader {
  /// Import limits shared by every import (SQL tables and MongoDB collections).
  static let maxImportFileBytes = 256 * 1_024 * 1_024
  static let maxImportRows = 100_000
  /// UTF-8 bytes one streamed record (or NDJSON line) may hold, its quotes and CSV line end
  /// included
  static let maxRecordBytes = 64 * 1_024 * 1_024

  nonisolated struct Options: Sendable, Equatable {
    var delimiter: Character?
    var hasHeader: Bool
    var rowLimit: Int?
    var maxCells: Int
    var maxRows: Int
    var maxFieldCharacters: Int
    /// nil = UTF-8, then Latin-1. UTF-8 = fail instead of falling back to Latin-1.
    var encoding: String.Encoding?
    /// Fills `Table.quoted`, so a quoted "NULL" can be told from a bare NULL (paste rows)
    var reportsQuotedFields: Bool

    init(
      delimiter: Character? = nil, hasHeader: Bool = true, rowLimit: Int? = nil,
      maxCells: Int = 1_000_000, maxRows: Int = DelimitedTextReader.maxImportRows,
      maxFieldCharacters: Int = 8 * 1_024 * 1_024, encoding: String.Encoding? = nil,
      reportsQuotedFields: Bool = false
    ) {
      self.delimiter = delimiter
      self.hasHeader = hasHeader
      self.rowLimit = rowLimit
      self.maxCells = max(maxCells, 0)
      self.maxRows = max(maxRows, 0)
      self.maxFieldCharacters = max(maxFieldCharacters, 0)
      self.encoding = encoding
      self.reportsQuotedFields = reportsQuotedFields
    }
  }

  nonisolated struct Table: Sendable, Equatable {
    var delimiter: Character
    var columns: [String]
    var rows: [[String]]
    var encoding: String.Encoding = .utf8
    /// With `reportsQuotedFields`: per row, one flag per field the record held (not padded,
    /// so a short record shows as a shorter list), true when that field was quoted. Else empty.
    var quoted: [[Bool]] = []
  }

  static func read(_ data: Data, options: Options = Options()) throws -> Table {
    let (text, encoding) = try decode(data, encoding: options.encoding)
    return try read(text: text, encoding: encoding, options: options)
  }

  /// `text` already decoded (`decode`), so a caller can free a file's bytes before the parse.
  /// `progress` gets the share of `text` parsed (0 to 1), about every 64K characters.
  static func read(
    text: String, encoding: String.Encoding, options: Options = Options(),
    progress: (Double) -> Void = { _ in }
  ) throws -> Table {
    try PerfSignpost.interval("import.delimited") {
      try parse(text, encoding: encoding, options: options, progress: progress)
    }
  }

  private static let candidates: [Character] = [",", ";", "\t", "|"]
  private static let detectionRows = 20

  private static func parse(
    _ text: String, encoding: String.Encoding, options: Options, progress: (Double) -> Void
  ) throws -> Table {
    try Task.checkCancellation()
    let delimiter = options.delimiter ?? detectDelimiter(in: text, options: options)
    let scalar = delimiter.unicodeScalars[delimiter.unicodeScalars.startIndex]
    let parsed = try records(
      in: text, delimiter: scalar, maxRecords: recordCap(options), options: options,
      progress: progress)
    var table = try makeTable(
      records: parsed.records, delimiter: delimiter, hasHeader: options.hasHeader,
      maxCells: options.maxCells)
    table.encoding = encoding
    if options.reportsQuotedFields {
      table.quoted = Array(parsed.quoted.dropFirst(options.hasHeader ? 1 : 0))
    }
    return table
  }

  /// Equal scores keep the earlier candidate: comma, semicolon, tab, pipe.
  private static func detectDelimiter(in text: String, options: Options) -> Character {
    var best = candidates[0]
    var bestScore = -1
    for candidate in candidates {
      let scalar = candidate.unicodeScalars[candidate.unicodeScalars.startIndex]
      let sample =
        (try? records(
          in: text, delimiter: scalar, maxRecords: detectionRows, options: options
        ).records) ?? []
      let scored = score(sample)
      if scored > bestScore {
        bestScore = scored
        best = candidate
      }
    }
    return best
  }

  private static func score(_ records: [[String]]) -> Int {
    guard !records.isEmpty else { return 0 }
    var histogram: [Int: Int] = [:]
    var occurrences = 0
    for record in records {
      histogram[record.count, default: 0] += 1
      if record.count > 1 { occurrences += record.count - 1 }
    }
    let mode = histogram.max { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key < rhs.key
    }!
    if mode.key <= 1 { return occurrences }
    return mode.value * 1_000 / records.count + mode.key * 10 + occurrences
  }

  private static func recordCap(_ options: Options) -> Int? {
    guard let rowLimit = options.rowLimit else { return nil }
    let rows = max(rowLimit, 0)
    return options.hasHeader && rows < Int.max ? rows + 1 : rows
  }

  private static func records(
    in text: String, delimiter: Unicode.Scalar, maxRecords: Int?, options: Options,
    progress: (Double) -> Void = { _ in }
  ) throws -> (records: [[String]], quoted: [[Bool]]) {
    if let maxRecords, maxRecords <= 0 { return ([], []) }
    var records: [[String]] = []
    var row: [String] = []
    // Filled only with `reportsQuotedFields`
    var quotedRecords: [[Bool]] = []
    var rowQuoted: [Bool] = []
    var field = ""
    var inQuotes = false
    var quoted = false
    var sawContent = false
    var fieldCharacters = 0
    var totalFields = 0
    var widestRecord = 0
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    var scalarCount = 0
    // UTF-8 bytes read so far, for `progress` (not counting a skipped second scalar)
    var bytesRead = 0
    let byteCount = Double(max(text.utf8.count, 1))

    func appendField() throws {
      guard row.count < options.maxCells - totalFields else {
        throw DelimitedTextError.cellLimitExceeded
      }
      row.append(field)
      if options.reportsQuotedFields { rowQuoted.append(quoted) }
      field = ""
      fieldCharacters = 0
      quoted = false
    }

    func finishRecord() throws {
      try appendField()
      if sawContent {
        let recordCap =
          options.hasHeader && options.maxRows < Int.max
          ? options.maxRows + 1 : options.maxRows
        guard records.count < recordCap else { throw DelimitedTextError.rowLimitExceeded }
        widestRecord = max(widestRecord, row.count)
        let dataRows = max(records.count + 1 - (options.hasHeader ? 1 : 0), 1)
        guard widestRecord <= options.maxCells / dataRows else {
          throw DelimitedTextError.cellLimitExceeded
        }
        totalFields += row.count
        records.append(row)
        if options.reportsQuotedFields { quotedRecords.append(rowQuoted) }
      }
      row.removeAll(keepingCapacity: true)
      rowQuoted.removeAll(keepingCapacity: true)
      sawContent = false
    }

    func appendCharacter(_ character: Character) throws {
      guard fieldCharacters < options.maxFieldCharacters else {
        throw DelimitedTextError.fieldLimitExceeded
      }
      field.append(character)
      fieldCharacters += 1
    }

    while index < scalars.endIndex {
      scalarCount += 1
      if scalarCount.isMultiple(of: 4_096) { try Task.checkCancellation() }
      if scalarCount.isMultiple(of: 65_536) { progress(Double(bytesRead) / byteCount) }
      if let maxRecords, records.count >= maxRecords { break }
      let scalar = scalars[index]
      index = scalars.index(after: index)
      bytesRead += UTF8.width(scalar)
      if inQuotes {
        if scalar == "\"" {
          if index < scalars.endIndex, scalars[index] == "\"" {
            try appendCharacter("\"")
            index = scalars.index(after: index)
          } else {
            inQuotes = false
          }
        } else {
          try appendCharacter(Character(scalar))
        }
        sawContent = true
        continue
      }
      if scalar == "\"", field.isEmpty, !quoted {
        inQuotes = true
        quoted = true
        sawContent = true
        continue
      }
      if scalar == delimiter {
        try appendField()
        sawContent = true
        continue
      }
      if scalar == "\n" || scalar == "\r" {
        if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" {
          index = scalars.index(after: index)
        }
        try finishRecord()
        continue
      }
      try appendCharacter(Character(scalar))
      sawContent = true
    }
    if inQuotes { throw DelimitedTextError.unclosedQuote }
    if sawContent || !row.isEmpty { try finishRecord() }
    progress(1)
    return (records, quotedRecords)
  }

  private static func makeTable(
    records: [[String]], delimiter: Character, hasHeader: Bool, maxCells: Int
  ) throws -> Table {
    let width = records.map(\.count).max() ?? 0
    guard width > 0 else {
      return Table(delimiter: delimiter, columns: [], rows: [])
    }
    let dataRows = hasHeader ? max(records.count - 1, 0) : records.count
    guard width <= maxCells / max(dataRows, 1) else {
      throw DelimitedTextError.cellLimitExceeded
    }
    let rows: [[String]]
    let columns: [String]
    if hasHeader {
      let header = records[0]
      columns = (0..<width).map { index in
        index < header.count ? header[index] : "column\(index + 1)"
      }
      rows = records.dropFirst().map { pad($0, to: width) }
    } else {
      columns = (1...width).map { "column\($0)" }
      rows = records.map { pad($0, to: width) }
    }
    return Table(delimiter: delimiter, columns: columns, rows: rows)
  }

  static func pad(_ row: [String], to width: Int) -> [String] {
    guard row.count < width else { return row }
    return row + Array(repeating: "", count: width - row.count)
  }

  /// RFC 4180 records of a text fed in pieces, as `read` parses them (blank lines skipped).
  /// The caller gives the delimiter and the column count (both from the preview): with
  /// `pads`, every record comes back padded to `columns` with empty fields, the header record
  /// included; a record with more fields is refused. "Row" in an error counts records from 1,
  /// header included, blank lines not.
  nonisolated struct RecordStream: Sendable {
    let delimiter: Unicode.Scalar
    let columns: Int
    let maxFieldCharacters: Int
    let maxRecordBytes: Int
    let pads: Bool
    private var row: [String] = []
    private var field = ""
    private var fieldCharacters = 0
    private var recordBytes = 0
    private var inQuotes = false
    private var quoted = false
    /// A quote that closed a quoted field, unless the next scalar is a second quote
    private var quotePending = false
    private var sawContent = false
    private var recordsRead = 0

    init(
      delimiter: Character, columns: Int, maxFieldCharacters: Int = 8 * 1_024 * 1_024,
      maxRecordBytes: Int = DelimitedTextReader.maxRecordBytes, pads: Bool = true
    ) {
      self.delimiter = delimiter.unicodeScalars[delimiter.unicodeScalars.startIndex]
      self.columns = max(columns, 1)
      self.maxFieldCharacters = max(maxFieldCharacters, 0)
      self.maxRecordBytes = max(maxRecordBytes, 0)
      self.pads = pads
    }

    /// The records `text` completes
    mutating func feed(_ text: Substring) throws -> [[String]] {
      var records: [[String]] = []
      var scalarCount = 0
      for scalar in text.unicodeScalars {
        scalarCount += 1
        if scalarCount.isMultiple(of: 4_096) { try Task.checkCancellation() }
        recordBytes += UTF8.width(scalar)
        guard recordBytes <= maxRecordBytes else {
          throw DelimitedTextError.recordLimitExceeded(row: recordsRead + 1)
        }
        if quotePending {
          quotePending = false
          if scalar == "\"" {
            try appendCharacter("\"")
            continue
          }
          inQuotes = false
        }
        if inQuotes {
          if scalar == "\"" {
            quotePending = true
          } else {
            try appendCharacter(Character(scalar))
          }
          sawContent = true
          continue
        }
        if scalar == "\"", field.isEmpty, !quoted {
          inQuotes = true
          quoted = true
          sawContent = true
          continue
        }
        if scalar == delimiter {
          try appendField()
          sawContent = true
          continue
        }
        // A CR LF pair ends one record and leaves a blank one, which is skipped
        if scalar == "\n" || scalar == "\r" {
          if let record = try finishRecord() { records.append(record) }
          continue
        }
        try appendCharacter(Character(scalar))
        sawContent = true
      }
      return records
    }

    /// The last record, when the text does not end with a line end
    mutating func finish() throws -> [[String]] {
      if quotePending {
        quotePending = false
        inQuotes = false
      }
      if inQuotes { throw DelimitedTextError.unclosedQuote }
      guard sawContent || !row.isEmpty, let record = try finishRecord() else { return [] }
      return [record]
    }

    private mutating func appendField() throws {
      guard row.count < columns else {
        throw DelimitedTextError.tooManyFields(row: recordsRead + 1)
      }
      row.append(field)
      field = ""
      fieldCharacters = 0
      quoted = false
    }

    private mutating func finishRecord() throws -> [String]? {
      try appendField()
      defer {
        // A new array, so a record returned unpadded holds only its own fields' capacity
        row = []
        recordBytes = 0
        sawContent = false
      }
      guard sawContent else { return nil }
      recordsRead += 1
      return pads ? DelimitedTextReader.pad(row, to: columns) : row
    }

    private mutating func appendCharacter(_ character: Character) throws {
      guard fieldCharacters < maxFieldCharacters else {
        throw DelimitedTextError.fieldLimitExceeded
      }
      field.append(character)
      fieldCharacters += 1
    }
  }

  /// `data` as text: UTF-8 (a leading BOM dropped), else Latin-1; `encoding` as in `Options`
  static func decode(
    _ data: Data, encoding: String.Encoding?
  ) throws -> (String, String.Encoding) {
    // A slice shares the bytes (no copy of the file)
    let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    if encoding != .isoLatin1, let text = String(data: payload, encoding: .utf8) {
      return (text, .utf8)
    }
    if encoding == .utf8 { throw DelimitedTextError.encodingChanged }
    return (String(data: payload, encoding: .isoLatin1) ?? "", .isoLatin1)
  }
}
