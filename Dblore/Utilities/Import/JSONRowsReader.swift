// JSONRowsReader.swift
// An array of objects, or one object per line (NDJSON).
// Keys are unioned in first-seen order. Nested values stay source JSON text.

import Foundation

nonisolated enum JSONRowsError: Error, LocalizedError, Equatable, Sendable {
  case invalidJSON
  case expectedObject
  case cellLimitExceeded
  case rowLimitExceeded
  case fieldLimitExceeded

  var errorDescription: String? {
    switch self {
    case .invalidJSON: "Invalid JSON"
    case .expectedObject: "Expected a JSON object"
    case .cellLimitExceeded: "Import exceeds the 1,000,000-cell safety limit"
    case .rowLimitExceeded: "Import exceeds the 100,000-row safety limit"
    case .fieldLimitExceeded: "Import contains too many fields in one object"
    }
  }
}

/// Nil is JSON null or a key this row does not have.
nonisolated enum JSONRowsReader {
  nonisolated struct Options: Sendable, Equatable {
    var rowLimit: Int?
    var maxCells: Int
    var maxRows: Int
    var maxFieldsPerObject: Int

    init(
      rowLimit: Int? = nil, maxCells: Int = 1_000_000,
      maxRows: Int = 100_000, maxFieldsPerObject: Int = 10_000
    ) {
      self.rowLimit = rowLimit
      self.maxCells = max(maxCells, 0)
      self.maxRows = max(maxRows, 0)
      self.maxFieldsPerObject = max(maxFieldsPerObject, 0)
    }
  }

  nonisolated struct Table: Sendable, Equatable {
    var columns: [String]
    var rows: [[String?]]
  }

  static func read(_ data: Data, options: Options = Options()) throws -> Table {
    try PerfSignpost.interval("import.json") {
      try parse(data, options: options)
    }
  }

  private static func parse(_ data: Data, options: Options) throws -> Table {
    let text = decodedText(data)
    try Task.checkCancellation()
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    while index < scalars.endIndex {
      let scalar = scalars[index]
      if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
        index = scalars.index(after: index)
        continue
      }
      break
    }
    if index >= scalars.endIndex { return Table(columns: [], rows: []) }
    if scalars[index] == "[" {
      var scanner = Scanner(text, maxFieldsPerObject: options.maxFieldsPerObject)
      return try scanner.parseArray(options: options)
    }
    return try parseLines(text, options: options)
  }

  private static func parseLines(_ text: String, options: Options) throws -> Table {
    let rowLimit = options.rowLimit
    if let rowLimit, rowLimit <= 0 { return Table(columns: [], rows: []) }
    var builder = RowBuilder(maxCells: options.maxCells, maxRows: options.maxRows)
    let scalars = text.unicodeScalars
    var lineStart = scalars.startIndex
    var index = scalars.startIndex
    var scalarCount = 0

    func takeLine(upTo end: String.Index) throws {
      let line = String(scalars[lineStart..<end]).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return }
      var scanner = Scanner(line, maxFieldsPerObject: options.maxFieldsPerObject)
      try scanner.skipWhitespace()
      guard scanner.peek() == "{" else { throw JSONRowsError.expectedObject }
      try builder.append(scanner.parseObject())
      try scanner.skipWhitespace()
      guard scanner.isAtEnd else { throw JSONRowsError.invalidJSON }
    }

    while index < scalars.endIndex {
      scalarCount += 1
      if scalarCount.isMultiple(of: 4_096) { try Task.checkCancellation() }
      let scalar = scalars[index]
      if scalar == "\n" || scalar == "\r" {
        try takeLine(upTo: index)
        index = scalars.index(after: index)
        if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" {
          index = scalars.index(after: index)
        }
        lineStart = index
        if let rowLimit, builder.rows.count >= rowLimit { return builder.table() }
        continue
      }
      index = scalars.index(after: index)
    }
    try takeLine(upTo: scalars.endIndex)
    return builder.table()
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

  private nonisolated struct Field {
    var key: String
    var value: String?
  }

  private nonisolated struct RowBuilder {
    let maxCells: Int
    let maxRows: Int
    var columns: [String] = []
    private var indexByKey: [String: Int] = [:]
    var rows: [[String?]] = []

    mutating func append(_ fields: [Field]) throws {
      guard rows.count < maxRows else { throw JSONRowsError.rowLimitExceeded }
      var newKeys: Set<String> = []
      for field in fields where indexByKey[field.key] == nil {
        newKeys.insert(field.key)
      }
      guard columns.count + newKeys.count <= maxCells / (rows.count + 1) else {
        throw JSONRowsError.cellLimitExceeded
      }
      for field in fields where indexByKey[field.key] == nil {
        indexByKey[field.key] = columns.count
        columns.append(field.key)
      }
      if let last = rows.last, last.count < columns.count {
        let extra = columns.count - last.count
        for index in rows.indices {
          if index.isMultiple(of: 256) { try Task.checkCancellation() }
          rows[index].append(contentsOf: repeatElement(nil, count: extra))
        }
      }
      var row = [String?](repeating: nil, count: columns.count)
      for field in fields {
        if let column = indexByKey[field.key] { row[column] = field.value }
      }
      rows.append(row)
    }

    func table() -> Table {
      Table(columns: columns, rows: rows)
    }
  }

  private nonisolated struct Scanner {
    private static let maxNesting = 128
    let maxFieldsPerObject: Int
    let scalars: String.UnicodeScalarView
    var index: String.UnicodeScalarView.Index

    init(_ text: String, maxFieldsPerObject: Int) {
      self.maxFieldsPerObject = maxFieldsPerObject
      scalars = text.unicodeScalars
      index = scalars.startIndex
    }

    var isAtEnd: Bool { index >= scalars.endIndex }

    mutating func peek() -> Unicode.Scalar? {
      guard index < scalars.endIndex else { return nil }
      return scalars[index]
    }

    mutating func advance() -> Unicode.Scalar? {
      guard index < scalars.endIndex else { return nil }
      let value = scalars[index]
      index = scalars.index(after: index)
      return value
    }

    mutating func skipWhitespace() throws {
      var skipped = 0
      while let scalar = peek(),
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
      {
        skipped += 1
        if skipped.isMultiple(of: 4_096) { try Task.checkCancellation() }
        _ = advance()
      }
    }

    mutating func expect(_ literal: String) throws {
      for scalar in literal.unicodeScalars {
        guard advance() == scalar else { throw JSONRowsError.invalidJSON }
      }
    }

    mutating func parseArray(options: Options) throws -> Table {
      let rowLimit = options.rowLimit
      if let rowLimit, rowLimit <= 0 { return Table(columns: [], rows: []) }
      try skipWhitespace()
      guard advance() == "[" else { throw JSONRowsError.invalidJSON }
      try skipWhitespace()
      var builder = RowBuilder(maxCells: options.maxCells, maxRows: options.maxRows)
      if peek() == "]" {
        _ = advance()
        try endOfValue()
        return builder.table()
      }
      while true {
        try Task.checkCancellation()
        try skipWhitespace()
        if peek() == "]" || peek() == nil { throw JSONRowsError.invalidJSON }
        guard peek() == "{" else { throw JSONRowsError.expectedObject }
        try builder.append(parseObject())
        if let rowLimit, builder.rows.count >= rowLimit { return builder.table() }
        try skipWhitespace()
        if peek() == "," {
          _ = advance()
          continue
        }
        guard advance() == "]" else { throw JSONRowsError.invalidJSON }
        try endOfValue()
        return builder.table()
      }
    }

    mutating func parseObject() throws -> [Field] {
      guard advance() == "{" else { throw JSONRowsError.invalidJSON }
      try skipWhitespace()
      if peek() == "}" {
        _ = advance()
        return []
      }
      var fields: [Field] = []
      while true {
        try Task.checkCancellation()
        guard fields.count < maxFieldsPerObject else {
          throw JSONRowsError.fieldLimitExceeded
        }
        try skipWhitespace()
        guard peek() == "\"" else { throw JSONRowsError.invalidJSON }
        let key = try parseString()
        try skipWhitespace()
        guard advance() == ":" else { throw JSONRowsError.invalidJSON }
        fields.append(Field(key: key, value: try parseCell()))
        try skipWhitespace()
        if peek() == "," {
          _ = advance()
          continue
        }
        guard advance() == "}" else { throw JSONRowsError.invalidJSON }
        return fields
      }
    }

    mutating func endOfValue() throws {
      try skipWhitespace()
      guard isAtEnd else { throw JSONRowsError.invalidJSON }
    }

    mutating func parseCell() throws -> String? {
      try skipWhitespace()
      guard let scalar = peek() else { throw JSONRowsError.invalidJSON }
      if scalar == "{" || scalar == "[" { return try rawContainer() }
      if scalar == "\"" { return try parseString() }
      if scalar == "t" {
        try expect("true")
        return "true"
      }
      if scalar == "f" {
        try expect("false")
        return "false"
      }
      if scalar == "n" {
        try expect("null")
        return nil
      }
      if scalar == "-" || isDigit(scalar) { return try parseNumber() }
      throw JSONRowsError.invalidJSON
    }

    mutating func rawContainer() throws -> String {
      let start = index
      try skipValue()
      return String(scalars[start..<index])
    }

    mutating func skipValue(depth: Int = 0) throws {
      try skipWhitespace()
      guard let scalar = peek() else { throw JSONRowsError.invalidJSON }
      if scalar == "{" {
        guard depth < Self.maxNesting else { throw JSONRowsError.invalidJSON }
        try skipObject(depth: depth + 1)
      } else if scalar == "[" {
        guard depth < Self.maxNesting else { throw JSONRowsError.invalidJSON }
        try skipArray(depth: depth + 1)
      } else if scalar == "\"" {
        _ = try parseString()
      } else if scalar == "t" {
        try expect("true")
      } else if scalar == "f" {
        try expect("false")
      } else if scalar == "n" {
        try expect("null")
      } else if scalar == "-" || isDigit(scalar) {
        _ = try parseNumber()
      } else {
        throw JSONRowsError.invalidJSON
      }
    }

    mutating func skipObject(depth: Int) throws {
      guard advance() == "{" else { throw JSONRowsError.invalidJSON }
      try skipWhitespace()
      if peek() == "}" {
        _ = advance()
        return
      }
      while true {
        try Task.checkCancellation()
        try skipWhitespace()
        guard peek() == "\"" else { throw JSONRowsError.invalidJSON }
        _ = try parseString()
        try skipWhitespace()
        guard advance() == ":" else { throw JSONRowsError.invalidJSON }
        try skipValue(depth: depth)
        try skipWhitespace()
        if peek() == "," {
          _ = advance()
          continue
        }
        guard advance() == "}" else { throw JSONRowsError.invalidJSON }
        return
      }
    }

    mutating func skipArray(depth: Int) throws {
      guard advance() == "[" else { throw JSONRowsError.invalidJSON }
      try skipWhitespace()
      if peek() == "]" {
        _ = advance()
        return
      }
      while true {
        try Task.checkCancellation()
        try skipValue(depth: depth)
        try skipWhitespace()
        if peek() == "," {
          _ = advance()
          continue
        }
        guard advance() == "]" else { throw JSONRowsError.invalidJSON }
        return
      }
    }

    mutating func parseString() throws -> String {
      guard advance() == "\"" else { throw JSONRowsError.invalidJSON }
      var result = ""
      var scalarCount = 0
      while let scalar = advance() {
        scalarCount += 1
        if scalarCount.isMultiple(of: 4_096) { try Task.checkCancellation() }
        if scalar == "\"" { return result }
        if scalar == "\\" {
          guard let escaped = advance() else { throw JSONRowsError.invalidJSON }
          switch escaped {
          case "\"": result.append("\"")
          case "\\": result.append("\\")
          case "/": result.append("/")
          case "b": result.append("\u{08}")
          case "f": result.append("\u{0C}")
          case "n": result.append("\n")
          case "r": result.append("\r")
          case "t": result.append("\t")
          case "u": result.append(Character(try unicodeScalar()))
          default: throw JSONRowsError.invalidJSON
          }
          continue
        }
        if scalar.value < 0x20 { throw JSONRowsError.invalidJSON }
        result.append(Character(scalar))
      }
      throw JSONRowsError.invalidJSON
    }

    mutating func unicodeScalar() throws -> Unicode.Scalar {
      let unit = try hex4()
      if (0xD800...0xDBFF).contains(unit) {
        guard advance() == "\\", advance() == "u" else { throw JSONRowsError.invalidJSON }
        let low = try hex4()
        guard (0xDC00...0xDFFF).contains(low) else { throw JSONRowsError.invalidJSON }
        let value = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        guard let scalar = Unicode.Scalar(value) else { throw JSONRowsError.invalidJSON }
        return scalar
      }
      guard !(0xDC00...0xDFFF).contains(unit), let scalar = Unicode.Scalar(unit) else {
        throw JSONRowsError.invalidJSON
      }
      return scalar
    }

    mutating func hex4() throws -> UInt32 {
      var value: UInt32 = 0
      for _ in 0..<4 {
        guard let scalar = advance() else { throw JSONRowsError.invalidJSON }
        value <<= 4
        switch scalar {
        case "0"..."9": value += scalar.value - Unicode.Scalar("0").value
        case "a"..."f": value += scalar.value - Unicode.Scalar("a").value + 10
        case "A"..."F": value += scalar.value - Unicode.Scalar("A").value + 10
        default: throw JSONRowsError.invalidJSON
        }
      }
      return value
    }

    mutating func parseNumber() throws -> String {
      let start = index
      if peek() == "-" { _ = advance() }
      guard let first = peek(), isDigit(first) else { throw JSONRowsError.invalidJSON }
      if first == "0" {
        _ = advance()
      } else {
        try scanDigits()
      }
      if peek() == "." {
        _ = advance()
        guard let scalar = peek(), isDigit(scalar) else { throw JSONRowsError.invalidJSON }
        try scanDigits()
      }
      if peek() == "e" || peek() == "E" {
        _ = advance()
        if peek() == "+" || peek() == "-" { _ = advance() }
        guard let scalar = peek(), isDigit(scalar) else { throw JSONRowsError.invalidJSON }
        try scanDigits()
      }
      try Task.checkCancellation()
      return String(scalars[start..<index])
    }

    mutating func scanDigits() throws {
      var count = 0
      while let scalar = peek(), isDigit(scalar) {
        count += 1
        if count.isMultiple(of: 4_096) { try Task.checkCancellation() }
        _ = advance()
      }
    }

    func isDigit(_ scalar: Unicode.Scalar) -> Bool {
      scalar.value >= 48 && scalar.value <= 57
    }
  }
}
