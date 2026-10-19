// MongoImportReader.swift
// Reads an import file into MongoDB documents: a JSON array, NDJSON or CSV. The file is
// untrusted: its size and document count are capped (the SQL import limits) and the first bad
// record stops the read with its line or document number, before anything is sent.

import Foundation

/// The reason a read stopped. `message` names the record: "line N" for NDJSON and CSV (1-based
/// physical line; the CSV header is line 1), "document N" for a JSON array element (1-based).
nonisolated struct MongoImportError: Error, Equatable, Sendable, LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// Off the main actor: every entry point reads the whole file synchronously and checks
/// cooperative cancellation while it parses.
nonisolated enum MongoImportReader {
  nonisolated enum Format: Sendable, Equatable {
    /// One JSON array of documents; elements go through `MongoRelaxedJSON.parseValue`.
    case jsonArray
    /// One document per non-empty line, or a whole file holding a single (possibly indented)
    /// document.
    case ndjson
    /// Delimited text with a header row; the delimiter is detected.
    case csv
  }

  /// A CSV column type. An empty or whitespace-only cell is null under every type; `skip`
  /// leaves the column out of every document.
  nonisolated enum FieldType: String, Sendable, Equatable, CaseIterable {
    case int32, int64, double, bool, date, null, string, objectId, skip
  }

  nonisolated struct Column: Sendable, Equatable {
    /// The header. Dots nest: "a.b" is field `b` of the subdocument `a`.
    var path: String
    var inferred: FieldType
    var override: FieldType?

    var effective: FieldType { override ?? inferred }
  }

  nonisolated struct Output: Sendable {
    /// Every element is a `.document`.
    var documents: [MongoValue]
    /// CSV only: the columns the documents were built with.
    var columns: [Column]
  }

  /// `.csv` / `.tsv` / `.txt` are CSV and `.ndjson` / `.jsonl` NDJSON. Anything else is sniffed:
  /// a first character `[` is a JSON array, `{` (or any `.json`) NDJSON, otherwise CSV.
  static func detect(url: URL) throws -> Format {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "csv", "tsv", "txt": return .csv
    case "ndjson", "jsonl": return .ndjson
    default: break
    }
    let prefix = try prefix(of: url, count: 64 * 1_024)
    let bytes = Array(prefix.starts(with: utf8BOM) ? prefix.dropFirst(3) : prefix[...])
    let first = skipWhitespace(bytes, from: 0)
    if first < bytes.count, bytes[first] == UInt8(ascii: "[") { return .jsonArray }
    if ext == "json" || (first < bytes.count && bytes[first] == UInt8(ascii: "{")) {
      return .ndjson
    }
    return .csv
  }

  /// All documents of the file, or the first error. `columns` (CSV only) are the columns of an
  /// earlier read (`Output.columns`) with the user's overrides; nil infers them. Their paths must
  /// still match the file's header.
  static func read(
    url: URL, format: Format, columns: [Column]? = nil,
    maxBsonObjectSize: Int = MongoWriteLimits.fallback.maxBsonObjectSize,
    maxDocuments: Int = DelimitedTextReader.maxImportRows,
    maxFileBytes: Int = DelimitedTextReader.maxImportFileBytes
  ) throws -> Output {
    try PerfSignpost.interval("import.mongo.read") {
      switch format {
      case .jsonArray, .ndjson:
        let bytes = try utf8Bytes(url: url, maxFileBytes: maxFileBytes)
        let documents: [MongoValue]
        if format == .jsonArray {
          documents = try readArray(
            bytes, maxBsonObjectSize: maxBsonObjectSize, maxDocuments: maxDocuments)
        } else {
          documents = try readLines(
            bytes, maxBsonObjectSize: maxBsonObjectSize, maxDocuments: maxDocuments)
        }
        return Output(documents: documents, columns: [])
      case .csv:
        let table = try csvTable(url: url, maxDocuments: maxDocuments, maxFileBytes: maxFileBytes)
        let used: [Column]
        if let columns {
          guard columns.map(\.path) == table.columns else {
            throw MongoImportError(
              message: "The file's columns changed since it was read. Choose the file again.")
          }
          used = columns
        } else {
          used = try inferColumns(table)
        }
        return Output(documents: try csvDocuments(table, columns: used), columns: used)
      }
    }
  }

  // MARK: - File

  private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
  private static let cancellationStride = 256

  /// The whole file, refused when larger than `maxFileBytes` (also when it grows while read).
  private static func contents(of url: URL, maxFileBytes: Int) throws -> Data {
    try Task.checkCancellation()
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard try handle.seekToEnd() <= UInt64(maxFileBytes) else { throw fileTooLarge(maxFileBytes) }
    try handle.seek(toOffset: 0)
    var data = Data()
    while true {
      try Task.checkCancellation()
      let chunk =
        try handle.read(upToCount: min(1_024 * 1_024, maxFileBytes + 1 - data.count)) ?? Data()
      if chunk.isEmpty { break }
      data.append(chunk)
      guard data.count <= maxFileBytes else { throw fileTooLarge(maxFileBytes) }
    }
    return data
  }

  private static func prefix(of url: URL, count: Int) throws -> Data {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: count) ?? Data()
  }

  /// JSON text must be UTF-8 (a BOM is dropped); there is no Latin-1 fallback.
  private static func utf8Bytes(url: URL, maxFileBytes: Int) throws -> [UInt8] {
    let data = try contents(of: url, maxFileBytes: maxFileBytes)
    let payload = data.starts(with: utf8BOM) ? data.dropFirst(3) : data[...]
    guard let text = String(data: payload, encoding: .utf8) else {
      throw MongoImportError(
        message: "The file is not valid UTF-8. Save it as UTF-8 and try again.")
    }
    return Array(text.utf8)
  }

  private static func fileTooLarge(_ limit: Int) -> MongoImportError {
    MongoImportError(
      message:
        "The file is larger than the \(size(limit)) import limit. Split it into smaller parts.")
  }

  private static func tooManyDocuments(_ limit: Int) -> MongoImportError {
    MongoImportError(
      message:
        "The file has more than \(limit.formatted()) documents, the import limit. "
        + "Split it into smaller parts.")
  }

  private static func stopped(_ record: String, _ reason: String) -> MongoImportError {
    MongoImportError(message: "Stopped at \(record): \(reason)")
  }

  /// Binary units, as MongoDB states its 16 MB document limit.
  private static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
    var index = start
    while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
    return index
  }

  // MARK: - JSON

  private static func readArray(
    _ bytes: [UInt8], maxBsonObjectSize: Int, maxDocuments: Int
  ) throws -> [MongoValue] {
    var index = skipWhitespace(bytes, from: 0)
    guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else {
      throw MongoImportError(message: "The file is not a JSON array")
    }
    index = skipWhitespace(bytes, from: index + 1)
    var documents: [MongoValue] = []
    while index < bytes.count, bytes[index] != UInt8(ascii: "]") {
      let record = "document \(documents.count + 1)"
      if documents.count.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
      guard documents.count < maxDocuments else { throw tooManyDocuments(maxDocuments) }
      let parsed: (value: MongoValue, end: Int)
      do {
        parsed = try MongoRelaxedJSON.parseValue(in: bytes, from: index)
      } catch {
        throw stopped(record, error.message)
      }
      guard parsed.end - index <= maxBsonObjectSize else {
        throw stopped(record, "it is larger than \(size(maxBsonObjectSize))")
      }
      guard case .document = parsed.value else { throw stopped(record, "it is not a document") }
      documents.append(parsed.value)
      index = skipWhitespace(bytes, from: parsed.end)
      guard index < bytes.count, bytes[index] == UInt8(ascii: ",") else { break }
      // A trailing comma is accepted, as in the shell
      index = skipWhitespace(bytes, from: index + 1)
    }
    guard index < bytes.count, bytes[index] == UInt8(ascii: "]") else {
      throw stopped("document \(documents.count + 1)", "expected \",\" or \"]\"")
    }
    guard skipWhitespace(bytes, from: index + 1) == bytes.count else {
      throw MongoImportError(message: "Unexpected text after the JSON array")
    }
    return documents
  }

  /// A file that is exactly one document (on one line or indented over many) is that document;
  /// otherwise every non-empty line is one document. Blank lines still count for line numbers.
  private static func readLines(
    _ bytes: [UInt8], maxBsonObjectSize: Int, maxDocuments: Int
  ) throws -> [MongoValue] {
    let first = skipWhitespace(bytes, from: 0)
    if first < bytes.count, bytes[first] == UInt8(ascii: "{"),
      let single = try? MongoRelaxedJSON.parseValue(in: bytes, from: first),
      skipWhitespace(bytes, from: single.end) == bytes.count
    {
      guard single.end - first <= maxBsonObjectSize else {
        throw stopped("line 1", "the document is larger than \(size(maxBsonObjectSize))")
      }
      guard case .document = single.value else { throw stopped("line 1", "it is not a document") }
      guard maxDocuments >= 1 else { throw tooManyDocuments(maxDocuments) }
      return [single.value]
    }
    var documents: [MongoValue] = []
    var line = 0
    var start = 0
    while start < bytes.count {
      line += 1
      if line.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
      let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
      defer { start = end + 1 }
      let content = bytes[start..<end]
      guard !content.allSatisfy(isWhitespace) else { continue }
      guard documents.count < maxDocuments else { throw tooManyDocuments(maxDocuments) }
      let value: MongoValue
      do {
        value = try MongoRelaxedJSON.parse(
          String(decoding: content, as: UTF8.self), maxBytes: maxBsonObjectSize)
      } catch {
        throw stopped("line \(line)", error.message)
      }
      guard case .document = value else { throw stopped("line \(line)", "it is not a document") }
      documents.append(value)
    }
    return documents
  }

  // MARK: - CSV

  private static func csvTable(
    url: URL, maxDocuments: Int, maxFileBytes: Int
  ) throws -> DelimitedTextReader.Table {
    let data = try contents(of: url, maxFileBytes: maxFileBytes)
    do {
      return try DelimitedTextReader.read(data, options: .init(maxRows: maxDocuments))
    } catch DelimitedTextError.rowLimitExceeded {
      throw tooManyDocuments(maxDocuments)
    } catch let error as DelimitedTextError {
      throw MongoImportError(message: error.localizedDescription)
    }
  }

  /// The CSV header with a type inferred per column from every value: int32 when every number
  /// is an integer that fits, else int64, else double; bool for true/false in any case; date
  /// for ISO 8601 (date only, or date and time with or without fraction and zone; no zone is
  /// UTC); null when every cell is empty; string otherwise. Integers with leading zeros or
  /// beyond Int64 stay strings so no digit is lost.
  private static func inferColumns(_ table: DelimitedTextReader.Table) throws -> [Column] {
    var columns: [Column] = []
    for (index, path) in table.columns.enumerated() {
      try Task.checkCancellation()
      var type = FieldType.null
      for (row, cells) in table.rows.enumerated() where type != .string {
        if row.isMultiple(of: 4_096) { try Task.checkCancellation() }
        let cell = cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cell.isEmpty else { continue }
        type = joined(type, inferredType(cell))
      }
      columns.append(Column(path: path, inferred: type))
    }
    return columns
  }

  private static func inferredType(_ cell: String) -> FieldType {
    let bytes = Array(cell.utf8)
    if let number = MongoRelaxedJSON.Lexer.number(in: bytes, from: 0), number.end == bytes.count {
      if number.isInteger {
        if Int32(cell) != nil { return .int32 }
        return Int64(cell) != nil ? .int64 : .string
      }
      return Double(cell)?.isFinite == true ? .double : .string
    }
    if bool(cell) != nil { return .bool }
    if MongoDateText.millis(from: cell) != nil { return .date }
    return .string
  }

  /// The narrowest type that holds both: numbers widen int32 < int64 < double; any other mix
  /// is a string.
  private static func joined(_ lhs: FieldType, _ rhs: FieldType) -> FieldType {
    if lhs == .null || lhs == rhs { return rhs }
    let numeric: [FieldType] = [.int32, .int64, .double]
    guard let left = numeric.firstIndex(of: lhs), let right = numeric.firstIndex(of: rhs) else {
      return .string
    }
    return numeric[max(left, right)]
  }

  private static func bool(_ cell: String) -> Bool? {
    if cell.caseInsensitiveCompare("true") == .orderedSame { return true }
    if cell.caseInsensitiveCompare("false") == .orderedSame { return false }
    return nil
  }

  private static func csvDocuments(
    _ table: DelimitedTextReader.Table, columns: [Column]
  ) throws -> [MongoValue] {
    var tree = PathTree()
    for (index, column) in columns.enumerated() where column.effective != .skip {
      let segments = column.path.split(separator: ".", omittingEmptySubsequences: false)
      guard !segments.contains(where: \.isEmpty) else {
        throw MongoImportError(
          message:
            "The header \"\(shown(column.path))\" has an empty field name. Rename it or skip it.")
      }
      // Deeper nesting is refused by the server and would recurse without bound here
      guard segments.count <= MongoRelaxedJSON.maxDepth else {
        throw MongoImportError(
          message:
            "The header \"\(shown(column.path))\" nests deeper than "
            + "\(MongoRelaxedJSON.maxDepth) levels. Rename it or skip it.")
      }
      try tree.insert(segments.map(String.init)[...], column: index, header: column.path)
    }
    var documents: [MongoValue] = []
    documents.reserveCapacity(table.rows.count)
    for (row, cells) in table.rows.enumerated() {
      if row.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
      // The header is line 1. A quoted line break inside an earlier field is not counted.
      let line = row + 2
      let document = try tree.document { index in
        try value(cells[index], column: columns[index], line: line)
      }
      documents.append(document)
    }
    return documents
  }

  private static func value(_ cell: String, column: Column, line: Int) throws -> MongoValue {
    let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .null }
    let type = column.effective
    let converted: MongoValue? =
      switch type {
      case .int32: Int32(trimmed).map(MongoValue.int32)
      case .int64: Int64(trimmed).map(MongoValue.int64)
      case .double: decimalDouble(trimmed).map(MongoValue.double)
      case .bool: bool(trimmed).map(MongoValue.bool)
      case .date: MongoDateText.millis(from: trimmed).map(MongoValue.date)
      case .objectId: MongoObjectId(hex: trimmed).map(MongoValue.objectId)
      case .string: .string(cell)
      case .null, .skip: .null
      }
    guard let converted else {
      throw stopped(
        "line \(line)",
        "\"\(shown(trimmed))\" in column \"\(shown(column.path))\" is not a valid \(type.rawValue)")
    }
    return converted
  }

  /// File text echoed in a message, cut to 40 characters.
  private static func shown(_ text: String) -> String {
    text.count > 40 ? String(text.prefix(40)) + "..." : text
  }

  private static let decimalBytes = Set("0123456789+-.eE".utf8)

  /// A finite decimal number; `Double(_:)` alone also takes hex, "inf" and "nan".
  private static func decimalDouble(_ text: String) -> Double? {
    guard text.utf8.allSatisfy(decimalBytes.contains), let value = Double(text), value.isFinite
    else {
      return nil
    }
    return value
  }

  /// The nesting of the dotted headers: each key is a column value or a subdocument.
  private nonisolated struct PathTree {
    private nonisolated enum Node {
      case column(Int, header: String)
      case document(PathTree, header: String)

      var header: String {
        switch self {
        case .column(_, let header), .document(_, let header): header
        }
      }
    }

    private var keys: [String] = []
    private var nodes: [Node] = []
    private var indexByKey: [String: Int] = [:]

    mutating func insert(_ segments: ArraySlice<String>, column: Int, header: String) throws {
      guard let key = segments.first else { return }
      let rest = segments.dropFirst()
      guard let index = indexByKey[key] else {
        var node = Node.column(column, header: header)
        if !rest.isEmpty {
          var child = PathTree()
          try child.insert(rest, column: column, header: header)
          node = .document(child, header: header)
        }
        indexByKey[key] = keys.count
        keys.append(key)
        nodes.append(node)
        return
      }
      guard !rest.isEmpty, case .document(var child, let first) = nodes[index] else {
        throw MongoImportError(
          message:
            "The headers \"\(MongoImportReader.shown(nodes[index].header))\" and "
            + "\"\(MongoImportReader.shown(header))\" both set the field "
            + "\"\(MongoImportReader.shown(key))\". Rename or skip one of them.")
      }
      try child.insert(rest, column: column, header: header)
      nodes[index] = .document(child, header: first)
    }

    func document(_ value: (Int) throws -> MongoValue) rethrows -> MongoValue {
      var fields: [MongoValue.Field] = []
      fields.reserveCapacity(keys.count)
      for (key, node) in zip(keys, nodes) {
        switch node {
        case .column(let index, _): try fields.append(.init(key, value(index)))
        case .document(let child, _): try fields.append(.init(key, child.document(value)))
        }
      }
      return .document(fields)
    }
  }
}
