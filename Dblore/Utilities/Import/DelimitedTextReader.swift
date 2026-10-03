// DelimitedTextReader.swift
// RFC 4180 text. Delimiter is comma, semicolon, tab, or pipe.
// Bytes are UTF-8, then Latin-1. Fields are not trimmed.

import Foundation

nonisolated enum DelimitedTextError: Error, Equatable, Sendable {
  case unclosedQuote
}

/// Preview table. Every row has one string per column. A missing field is empty.
nonisolated enum DelimitedTextReader {
  nonisolated struct Options: Sendable, Equatable {
    var delimiter: Character?
    var hasHeader: Bool
    var rowLimit: Int?

    init(delimiter: Character? = nil, hasHeader: Bool = true, rowLimit: Int? = nil) {
      self.delimiter = delimiter
      self.hasHeader = hasHeader
      self.rowLimit = rowLimit
    }
  }

  nonisolated struct Table: Sendable, Equatable {
    var delimiter: Character
    var columns: [String]
    var rows: [[String]]
  }

  static func read(_ data: Data, options: Options = Options()) throws -> Table {
    try PerfSignpost.interval("import.delimited") {
      try parse(data, options: options)
    }
  }

  private static let candidates: [Character] = [",", ";", "\t", "|"]
  private static let detectionRows = 20

  private static func parse(_ data: Data, options: Options) throws -> Table {
    let text = decodedText(data)
    let delimiter = options.delimiter ?? detectDelimiter(in: text)
    let scalar = delimiter.unicodeScalars[delimiter.unicodeScalars.startIndex]
    let parsed = try records(in: text, delimiter: scalar, maxRecords: recordCap(options))
    return makeTable(records: parsed, delimiter: delimiter, hasHeader: options.hasHeader)
  }

  /// Equal scores keep the earlier candidate: comma, semicolon, tab, pipe.
  private static func detectDelimiter(in text: String) -> Character {
    var best = candidates[0]
    var bestScore = -1
    for candidate in candidates {
      let scalar = candidate.unicodeScalars[candidate.unicodeScalars.startIndex]
      let sample = (try? records(in: text, delimiter: scalar, maxRecords: detectionRows)) ?? []
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
    return options.hasHeader ? rows + 1 : rows
  }

  private static func records(
    in text: String, delimiter: Unicode.Scalar, maxRecords: Int?
  ) throws -> [[String]] {
    if let maxRecords, maxRecords <= 0 { return [] }
    var records: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var quoted = false
    var sawContent = false
    let scalars = text.unicodeScalars
    var index = scalars.startIndex

    func finishRecord() {
      row.append(field)
      if sawContent { records.append(row) }
      row.removeAll(keepingCapacity: true)
      field = ""
      quoted = false
      sawContent = false
    }

    while index < scalars.endIndex {
      if let maxRecords, records.count >= maxRecords { break }
      let scalar = scalars[index]
      index = scalars.index(after: index)
      if inQuotes {
        if scalar == "\"" {
          if index < scalars.endIndex, scalars[index] == "\"" {
            field.append("\"")
            index = scalars.index(after: index)
          } else {
            inQuotes = false
          }
        } else {
          field.append(Character(scalar))
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
        row.append(field)
        field = ""
        quoted = false
        sawContent = true
        continue
      }
      if scalar == "\n" || scalar == "\r" {
        if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" {
          index = scalars.index(after: index)
        }
        finishRecord()
        continue
      }
      field.append(Character(scalar))
      sawContent = true
    }
    if inQuotes { throw DelimitedTextError.unclosedQuote }
    if sawContent || !row.isEmpty { finishRecord() }
    return records
  }

  private static func makeTable(
    records: [[String]], delimiter: Character, hasHeader: Bool
  ) -> Table {
    let width = records.map(\.count).max() ?? 0
    guard width > 0 else {
      return Table(delimiter: delimiter, columns: [], rows: [])
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

  private static func pad(_ row: [String], to width: Int) -> [String] {
    guard row.count < width else { return row }
    return row + Array(repeating: "", count: width - row.count)
  }

  private static func decodedText(_ data: Data) -> String {
    let payload: Data
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      payload = Data(data.dropFirst(3))
    } else {
      payload = data
    }
    if let text = String(data: payload, encoding: .utf8) { return text }
    return String(data: payload, encoding: .isoLatin1) ?? ""
  }
}
