// ImportFileStream.swift
// A CSV, TSV or NDJSON import file read in chunks, its data rows in blocks with a digest each

import CryptoKit
import Foundation

/// The data rows of an import file, read through `FileHandle` in chunks and parsed as the
/// whole read does (`DelimitedTextReader.RecordStream`, `JSONRowsReader.LineStream`), so memory
/// follows a chunk and a block, not the file. Text decodes with the preview's encoding: Latin-1
/// byte for byte, else UTF-8 (`DelimitedTextError.encodingChanged` when a byte is not); a
/// leading byte order mark is dropped as the whole read drops it. Rows come in blocks of
/// `rowsPerBlock`, each with the SHA-256 of its rows, so a second read can check it is the
/// block the first read saw. Callers read off the main actor and keep the file's
/// security-scoped access while they read.
nonisolated struct ImportFileStream {
  /// Data rows per block: the rows pass 1 digests together and pass 2 sends as one chunk
  static let rowsPerBlock = 1_000
  static let chunkSize = 1_048_576
  /// Unicode scalars of decoded text parsed at a time
  static let sliceScalars = 65_536

  enum Layout: Sendable, Equatable {
    /// CSV or TSV with the preview's delimiter
    case delimited(Character, hasHeader: Bool)
    /// One JSON object per line
    case ndjson
  }

  struct Block: Sendable, Equatable {
    /// The file's data-row number of the first row, from 1 (a header is not counted)
    let firstRow: Int
    /// One value per column, in `columns` order; nil is an NDJSON null or missing key
    let rows: [[String?]]
    /// `ImportFileStream.digest(rows)`
    let digest: SHA256Digest
  }

  /// The file's size when it was opened
  let byteCount: Int
  /// Bytes read so far
  private(set) var bytesRead = 0

  // `FileHandle(forReadingFrom:)` closes the file when released
  private let handle: FileHandle
  private let chunkSize: Int
  private let latin1: Bool
  private let columns: [String]
  private let hasHeader: Bool
  private var records: DelimitedTextReader.RecordStream?
  private var lines: JSONRowsReader.LineStream?
  /// NDJSON: the column of each key, and how many keys the file has named so far
  private let indexByKey: [String: Int]
  private var seenKeys = 0
  /// The start of a UTF-8 code point cut by the last chunk's end
  private var cutBytes: [UInt8] = []
  private var sawRecord = false
  private var atEnd = false
  /// Decoded text not yet parsed, parsed `sliceScalars` at a time while a block lacks rows
  private var unparsed: Substring = ""
  /// Rows parsed and not yet returned in a block, from `pendingStart`; padded or placed in
  /// `columns` only when their block is made
  private var pending: [Parsed] = []
  private var pendingStart = 0
  private var pendingCells = 0
  private var rowsReturned = 0
  /// The most row cells (allocated, not just used) waiting for a block at once
  private(set) var maxPendingCells = 0

  /// A parsed row: a CSV / TSV record's fields, or an NDJSON object's
  private enum Parsed {
    case record([String])
    case object([JSONRowsReader.Field])

    var cells: Int {
      switch self {
      case .record(let fields): fields.capacity
      case .object(let fields): fields.capacity
      }
    }
  }

  /// `columns` are the preview's (the mappings' source names, every one): a CSV / TSV header
  /// must name them as the whole read does, an NDJSON file must name exactly these keys in this
  /// first-seen order; else `TableImportError.columnsChanged`. `encoding` is the preview's
  /// (`.isoLatin1`, else UTF-8).
  /// - Throws: the file's open error
  init(
    url: URL, layout: Layout, encoding: String.Encoding, columns: [String],
    chunkSize: Int = ImportFileStream.chunkSize,
    maxRecordBytes: Int = DelimitedTextReader.maxRecordBytes
  ) throws {
    handle = try FileHandle(forReadingFrom: url)
    byteCount = Int(clamping: try handle.seekToEnd())
    // The whole read drops a UTF-8 byte order mark before it decodes, Latin-1 too
    try handle.seek(toOffset: 0)
    if try handle.read(upToCount: 3) == Data([0xEF, 0xBB, 0xBF]) {
      bytesRead = 3
    } else {
      try handle.seek(toOffset: 0)
    }
    self.chunkSize = max(chunkSize, 1)
    latin1 = encoding == .isoLatin1
    self.columns = columns
    indexByKey = Dictionary(
      columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    switch layout {
    case .delimited(let delimiter, let hasHeader):
      self.hasHeader = hasHeader
      records = DelimitedTextReader.RecordStream(
        delimiter: delimiter, columns: columns.count, maxRecordBytes: maxRecordBytes,
        pads: false)
    case .ndjson:
      hasHeader = false
      lines = JSONRowsReader.LineStream(maxRecordBytes: maxRecordBytes)
    }
  }

  /// The next block of up to `rowsPerBlock` rows, nil after the last.
  /// - Throws: `TableImportError.columnsChanged`; `DelimitedTextError` (`.encodingChanged`,
  ///   `.tooManyFields` naming the file record, `.recordLimitExceeded`, `.unclosedQuote`, …);
  ///   `JSONRowsError`; `CancellationError`; the file's read error
  mutating func nextBlock() throws -> Block? {
    while pending.count - pendingStart < Self.rowsPerBlock, !atEnd {
      if unparsed.isEmpty { try readChunk() } else { try parseSlice() }
    }
    let count = min(Self.rowsPerBlock, pending.count - pendingStart)
    guard count > 0 else { return nil }
    let parsed = pending[pendingStart..<pendingStart + count]
    pendingStart += count
    pendingCells -= parsed.reduce(0) { $0 + $1.cells }
    let rows = parsed.map(row)
    defer { rowsReturned += count }
    return Block(firstRow: rowsReturned + 1, rows: rows, digest: Self.digest(rows))
  }

  /// SHA-256 of `rows` in a canonical form: per row its field count, then per field a 0 byte
  /// for nil, or a 1 byte, its UTF-8 byte count and its UTF-8 (counts as big-endian UInt64)
  static func digest(_ rows: [[String?]]) -> SHA256Digest {
    var hasher = SHA256()
    func update(count: Int) {
      withUnsafeBytes(of: UInt64(count).bigEndian) { hasher.update(bufferPointer: $0) }
    }
    for row in rows {
      update(count: row.count)
      for field in row {
        guard var value = field else {
          withUnsafeBytes(of: UInt8(0)) { hasher.update(bufferPointer: $0) }
          continue
        }
        withUnsafeBytes(of: UInt8(1)) { hasher.update(bufferPointer: $0) }
        update(count: value.utf8.count)
        value.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
      }
    }
    return hasher.finalize()
  }

  // MARK: - Reading

  /// Reads and decodes the next chunk into `unparsed`; at the end of the file, the last record
  private mutating func readChunk() throws {
    try Task.checkCancellation()
    // `read` returns each chunk autoreleased: freed here, not when the whole read ends
    let text: String? = try autoreleasepool {
      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      guard !chunk.isEmpty else {
        guard cutBytes.isEmpty else { throw DelimitedTextError.encodingChanged }
        return nil
      }
      bytesRead += chunk.count
      return try decode(chunk)
    }
    guard let text else {
      atEnd = true
      try parse(nil)
      // An empty file, or NDJSON without every preview key, is not the file the preview read
      guard sawRecord, records != nil || seenKeys == columns.count else {
        throw TableImportError.columnsChanged
      }
      return
    }
    unparsed = text[...]
  }

  /// Parses the next `sliceScalars` of `unparsed`
  private mutating func parseSlice() throws {
    let scalars = unparsed.unicodeScalars
    let end =
      scalars.index(scalars.startIndex, offsetBy: Self.sliceScalars, limitedBy: scalars.endIndex)
      ?? scalars.endIndex
    let slice = Substring(scalars[..<end])
    unparsed = Substring(scalars[end...])
    try parse(slice)
  }

  /// `chunk`'s text; a UTF-8 code point cut by its end waits in `cutBytes`
  private mutating func decode(_ chunk: Data) throws -> String {
    if latin1 { return String(data: chunk, encoding: .isoLatin1) ?? "" }
    var bytes = cutBytes
    bytes.append(contentsOf: chunk)
    let end = Self.wholeCodePointsEnd(bytes)
    cutBytes = Array(bytes[end...])
    let whole = bytes[..<end]
    var parser = Unicode.UTF8.ForwardParser()
    var iterator = whole.makeIterator()
    while true {
      switch parser.parseScalar(from: &iterator) {
      case .valid: continue
      case .emptyInput: return String(decoding: whole, as: UTF8.self)
      case .error: throw DelimitedTextError.encodingChanged
      }
    }
  }

  /// `bytes.count`, or the start of a last code point whose bytes run past the end
  private static func wholeCodePointsEnd(_ bytes: [UInt8]) -> Int {
    for back in 1...min(3, bytes.count) {
      let byte = bytes[bytes.count - back]
      guard byte & 0xC0 == 0x80 else {
        let width = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        return width > back ? bytes.count - back : bytes.count
      }
    }
    return bytes.count
  }

  /// Parses `text` into `pending`; nil is the end of the file
  private mutating func parse(_ text: Substring?) throws {
    // Fewer than a block of rows wait here: drop the returned ones before adding more
    pending.removeFirst(pendingStart)
    pendingStart = 0
    if records != nil {
      let parsed: [[String]]
      do {
        parsed = try text.map { try records!.feed($0) } ?? records!.finish()
      } catch DelimitedTextError.tooManyFields(let row) where hasHeader && row == 1 {
        throw TableImportError.columnsChanged
      }
      for record in parsed {
        if hasHeader, !sawRecord {
          sawRecord = true
          try checkHeader(DelimitedTextReader.pad(record, to: columns.count))
          continue
        }
        sawRecord = true
        append(.record(record))
      }
    } else {
      let objects = try text.map { try lines!.feed($0) } ?? lines!.finish()
      for object in objects {
        sawRecord = true
        try checkKeys(object)
        append(.object(object))
      }
    }
    maxPendingCells = max(maxPendingCells, pendingCells)
  }

  private mutating func append(_ parsed: Parsed) {
    pending.append(parsed)
    pendingCells += parsed.cells
  }

  /// The whole read names a header field the record lacks `column<N>`; the stream pads it
  /// with an empty field, as it pads a header field the file leaves empty
  private func checkHeader(_ header: [String]) throws {
    for (index, name) in header.enumerated() {
      guard name == columns[index] || (name.isEmpty && columns[index] == "column\(index + 1)")
      else { throw TableImportError.columnsChanged }
    }
  }

  /// A key the preview did not see, or one seen first in another order, changes the columns
  /// the whole read would build
  private mutating func checkKeys(_ object: [JSONRowsReader.Field]) throws {
    for field in object {
      guard let index = indexByKey[field.key], index <= seenKeys else {
        throw TableImportError.columnsChanged
      }
      if index == seenKeys { seenKeys += 1 }
    }
  }

  /// `parsed`'s values in `columns` order: a record padded with empty fields, an NDJSON object
  /// with nil for a missing key
  private func row(_ parsed: Parsed) -> [String?] {
    switch parsed {
    case .record(let fields):
      return DelimitedTextReader.pad(fields, to: columns.count).map(Optional.some)
    case .object(let fields):
      var row = [String?](repeating: nil, count: columns.count)
      for field in fields {
        if let index = indexByKey[field.key] { row[index] = field.value }
      }
      return row
    }
  }
}

/// Pass 1 of a streamed import: the whole file read once (`ImportFileStream`), checking its
/// columns against the mappings and its fields, and keeping only the row count, one digest per
/// block and, with `measuresDecimals` (DuckDB), the decimal digits of every row. Column kinds
/// are the mappings' (inferred from the preview, maybe edited), never read again. No file,
/// row or cell cap.
nonisolated struct ImportFileSummary: Sendable, Equatable {
  /// Data rows in the file
  let rowCount: Int
  /// One per block of `ImportFileStream.rowsPerBlock` rows, in file order
  let digests: [SHA256Digest]
  /// One per included mapping, in mapping order: a decimal column's digits over every row
  /// (`ImportTypeInference.Accumulator`), else nil; empty without `measuresDecimals`
  let decimalDigits: [ImportTypeInference.PrecisionScale?]

  /// `progress` gets the share of the file's bytes read after each block.
  /// - Throws: as `ImportFileStream.nextBlock()`; the file's open error
  init(
    url: URL, layout: ImportFileStream.Layout, encoding: String.Encoding,
    mappings: [TableImportColumnMapping], measuresDecimals: Bool,
    chunkSize: Int = ImportFileStream.chunkSize,
    maxRecordBytes: Int = DelimitedTextReader.maxRecordBytes,
    progress: (Double) -> Void = { _ in }
  ) throws {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    var stream = try ImportFileStream(
      url: url, layout: layout, encoding: encoding, columns: mappings.map(\.sourceName),
      chunkSize: chunkSize, maxRecordBytes: maxRecordBytes)
    let included = mappings.indices.filter { mappings[$0].included }
    let decimals =
      measuresDecimals ? included.indices.filter { mappings[included[$0]].kind == .decimal } : []
    var accumulators = included.map { _ in ImportTypeInference.Accumulator() }
    var rowCount = 0
    var digests: [SHA256Digest] = []
    while let block = try stream.nextBlock() {
      rowCount += block.rows.count
      digests.append(block.digest)
      for position in decimals {
        let column = included[position]
        for row in block.rows { accumulators[position].add(row[column]) }
      }
      progress(Double(stream.bytesRead) / Double(max(stream.byteCount, 1)))
    }
    self.rowCount = rowCount
    self.digests = digests
    decimalDigits =
      measuresDecimals
      ? included.indices.map { decimals.contains($0) ? accumulators[$0].digits : nil } : []
  }

  /// The included columns (`importColumns` order) with each decimal column's digits, as
  /// `TableImportModel.withDecimalDigits` gives them over every row
  func withDecimalDigits(_ columns: [ImportSQLBuilder.Column]) -> [ImportSQLBuilder.Column] {
    columns.enumerated().map { index, column in
      guard column.kind == .decimal else { return column }
      var column = column
      column.precisionScale = decimalDigits.indices.contains(index) ? decimalDigits[index] : nil
      return column
    }
  }
}
