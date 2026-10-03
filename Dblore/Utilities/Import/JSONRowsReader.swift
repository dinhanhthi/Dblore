// JSONRowsReader.swift
// An array of objects, or one object per line (NDJSON).
// Keys are unioned in first-seen order. Nested values stay source JSON text.

import Foundation

nonisolated enum JSONRowsError: Error, Equatable, Sendable {
  case invalidJSON
  case expectedObject
}

/// Nil is JSON null or a key this row does not have.
nonisolated enum JSONRowsReader {
  nonisolated struct Options: Sendable, Equatable {
    var rowLimit: Int?

    init(rowLimit: Int? = nil) {
      self.rowLimit = rowLimit
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
      var scanner = Scanner(text)
      return try scanner.parseArray(rowLimit: options.rowLimit)
    }
    return try parseLines(text, rowLimit: options.rowLimit)
  }

  private static func parseLines(_ text: String, rowLimit: Int?) throws -> Table {
    if let rowLimit, rowLimit <= 0 { return Table(columns: [], rows: []) }
    var builder = RowBuilder()
    let scalars = text.unicodeScalars
    var lineStart = scalars.startIndex
    var index = scalars.startIndex

    func takeLine(upTo end: String.Index) throws {
      let line = String(scalars[lineStart..<end]).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return }
      var scanner = Scanner(line)
      scanner.skipWhitespace()
      guard scanner.peek() == "{" else { throw JSONRowsError.expectedObject }
      builder.append(try scanner.parseObject())
      scanner.skipWhitespace()
      guard scanner.isAtEnd else { throw JSONRowsError.invalidJSON }
    }

    while index < scalars.endIndex {
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
    var columns: [String] = []
    private var indexByKey: [String: Int] = [:]
    var rows: [[String?]] = []

    mutating func append(_ fields: [Field]) {
      for field in fields where indexByKey[field.key] == nil {
        indexByKey[field.key] = columns.count
        columns.append(field.key)
      }
      if let last = rows.last, last.count < columns.count {
        let extra = columns.count - last.count
        for index in rows.indices {
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
    let scalars: String.UnicodeScalarView
    var index: String.UnicodeScalarView.Index

    init(_ text: String) {
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

    mutating func skipWhitespace() {
      while let scalar = peek(),
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
      {
        _ = advance()
      }
    }

    mutating func expect(_ literal: String) throws {
      for scalar in literal.unicodeScalars {
        guard advance() == scalar else { throw JSONRowsError.invalidJSON }
      }
    }

    mutating func parseArray(rowLimit: Int?) throws -> Table {
      if let rowLimit, rowLimit <= 0 { return Table(columns: [], rows: []) }
      skipWhitespace()
      guard advance() == "[" else { throw JSONRowsError.invalidJSON }
      skipWhitespace()
      var builder = RowBuilder()
      if peek() == "]" {
        _ = advance()
        try endOfValue()
        return builder.table()
      }
      while true {
        skipWhitespace()
        if peek() == "]" || peek() == nil { throw JSONRowsError.invalidJSON }
        guard peek() == "{" else { throw JSONRowsError.expectedObject }
        builder.append(try parseObject())
        if let rowLimit, builder.rows.count >= rowLimit { return builder.table() }
        skipWhitespace()
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
      skipWhitespace()
      if peek() == "}" {
        _ = advance()
        return []
      }
      var fields: [Field] = []
      while true {
        skipWhitespace()
        guard peek() == "\"" else { throw JSONRowsError.invalidJSON }
        let key = try parseString()
        skipWhitespace()
        guard advance() == ":" else { throw JSONRowsError.invalidJSON }
        fields.append(Field(key: key, value: try parseCell()))
        skipWhitespace()
        if peek() == "," {
          _ = advance()
          continue
        }
        guard advance() == "}" else { throw JSONRowsError.invalidJSON }
        return fields
      }
    }

    mutating func endOfValue() throws {
      skipWhitespace()
      guard isAtEnd else { throw JSONRowsError.invalidJSON }
    }

    mutating func parseCell() throws -> String? {
      skipWhitespace()
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
      skipWhitespace()
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
      skipWhitespace()
      if peek() == "}" {
        _ = advance()
        return
      }
      while true {
        skipWhitespace()
        guard peek() == "\"" else { throw JSONRowsError.invalidJSON }
        _ = try parseString()
        skipWhitespace()
        guard advance() == ":" else { throw JSONRowsError.invalidJSON }
        try skipValue(depth: depth)
        skipWhitespace()
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
      skipWhitespace()
      if peek() == "]" {
        _ = advance()
        return
      }
      while true {
        try skipValue(depth: depth)
        skipWhitespace()
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
      while let scalar = advance() {
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
        while let scalar = peek(), isDigit(scalar) { _ = advance() }
      }
      if peek() == "." {
        _ = advance()
        guard let scalar = peek(), isDigit(scalar) else { throw JSONRowsError.invalidJSON }
        while let next = peek(), isDigit(next) { _ = advance() }
      }
      if peek() == "e" || peek() == "E" {
        _ = advance()
        if peek() == "+" || peek() == "-" { _ = advance() }
        guard let scalar = peek(), isDigit(scalar) else { throw JSONRowsError.invalidJSON }
        while let next = peek(), isDigit(next) { _ = advance() }
      }
      return String(scalars[start..<index])
    }

    func isDigit(_ scalar: Unicode.Scalar) -> Bool {
      scalar.value >= 48 && scalar.value <= 57
    }
  }
}
