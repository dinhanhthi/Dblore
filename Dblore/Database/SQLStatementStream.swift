// SQLStatementStream.swift
// A SQL dump file read in chunks and split statement by statement

import CryptoKit
import Foundation

/// The statements of a SQL dump file, read through `FileHandle` in chunks and split as the
/// whole-text restore read does (`readScript`, then `SQLRestorePlan.init`): the same text, one
/// statement at a time, so memory follows the largest statement, not the file. On MySQL
/// mariadb-dump's sandbox first line is dropped before the split, as there. Each statement
/// comes with a byte range in the file and the SHA-256 of its UTF-8, so a second read can check
/// it is the statement the first read saw.
nonisolated struct SQLStatementStream {
  struct Statement: Sendable, Equatable {
    let text: String
    /// File bytes equal to `text`'s UTF-8: the first such bytes after the previous statement's
    /// range. The text skipped between statements (whitespace, delimiters, `DELIMITER` lines)
    /// can repeat the start of the next statement's text (a custom MySQL delimiter can), so the
    /// range can start before the statement's own bytes. A second read binds a statement to the
    /// first read's by `digest`, never by its offset.
    let byteRange: Range<Int>
    let digest: SHA256Digest
  }

  /// The file's size when it was opened
  let byteCount: Int
  /// Bytes read so far
  private(set) var bytesRead = 0

  // `FileHandle(forReadingFrom:)` closes the file when released
  private let handle: FileHandle
  private let engine: DatabaseType
  private let tokenizer: SQLTokenizer
  private let chunkSize: Int
  private let maxStatementBytes: Int
  /// Text not split yet, from a statement boundary; `bufferOffset` is the file offset of its
  /// first scalar, `bufferBytes` its UTF-8 size
  private var buffer: [Unicode.Scalar] = []
  private var bufferOffset = 0
  private var bufferBytes = 0
  /// The start of a code point cut by the last chunk's end
  private var cutBytes: [UInt8] = []
  private var split = SQLTokenizer.SplitState()
  /// Statements split and not yet returned, last first
  private var ready: [Statement] = []
  /// Statements split so far: the index of the next one
  private var splitCount = 0
  /// A refusal met after `ready`'s statements, thrown once they are returned
  private var failure: SQLRestoreError?
  private var startsFile = true
  private var atEnd = false
  private var finished = false
  private var line: String?

  /// - Throws: `SQLRestoreError.unsupportedEngine` for MongoDB; the file's open error
  init(
    url: URL, engine: DatabaseType, chunkSize: Int = 1_048_576,
    maxStatementBytes: Int = SQLRestorePlan.maxStatementBytes
  ) throws {
    switch engine {
    case .postgresql, .mysql, .sqlite, .duckdb: break
    case .mongodb: throw SQLRestoreError.unsupportedEngine(engine.rawValue)
    }
    handle = try FileHandle(forReadingFrom: url)
    byteCount = Int(clamping: try handle.seekToEnd())
    try handle.seek(toOffset: 0)
    self.engine = engine
    tokenizer = SQLTokenizer(dialect: engine.dialect)
    self.chunkSize = chunkSize
    self.maxStatementBytes = maxStatementBytes
  }

  /// The first line (after mariadb-dump's sandbox line on MySQL), without its line end: what
  /// `checkHeader` reads
  mutating func firstLine() throws -> String {
    if let line { return line }
    // The sandbox line, an optional space and CRLF must be read whole before the strip
    let sandbox = SQLRestorePlan.mariaDBSandboxLine.unicodeScalars.count + 3
    while !atEnd, buffer.count < sandbox { atEnd = try !readChunk() }
    if engine == .mysql {
      let prefix = String(String.UnicodeScalarView(buffer.prefix(sandbox)))
      consume(SQLRestorePlan.mariaDBSandboxPrefix(prefix))
    }
    var searched = 0
    while true {
      if let end = buffer[searched...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
        line = SQLTokenizer.text(buffer, 0..<end)
        break
      }
      searched = buffer.count
      if atEnd {
        line = SQLTokenizer.text(buffer, 0..<buffer.count)
        break
      }
      if let failure = openStatementTooLarge() { throw failure }
      atEnd = try !readChunk()
    }
    return line ?? ""
  }

  /// The next statement, nil after the last.
  /// - Throws: `DatabaseBackupError.notUTF8`; `SQLRestoreError.containsNUL` (SQLite, DuckDB),
  ///   `.statementTooLarge` or `.statementNotLocated`; `CancellationError`; the file's read
  ///   error
  mutating func next() throws -> Statement? {
    _ = try firstLine()
    while ready.isEmpty {
      if let failure { throw failure }
      if finished { return nil }
      if !atEnd { atEnd = try !readChunk() }
      splitBuffer()
    }
    return ready.popLast()
  }

  // MARK: - Reading

  /// Reads and decodes the next chunk; false at the end of the file
  private mutating func readChunk() throws -> Bool {
    try Task.checkCancellation()
    // `read` returns each chunk autoreleased: freed here, not when the whole read ends
    return try autoreleasepool {
      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      guard !chunk.isEmpty else {
        guard cutBytes.isEmpty else { throw DatabaseBackupError.notUTF8 }
        return false
      }
      bytesRead += chunk.count
      try decode(chunk)
      return true
    }
  }

  /// Appends `chunk`'s code points to `buffer`; a code point cut by its end waits in `cutBytes`
  private mutating func decode(_ chunk: Data) throws {
    var bytes = cutBytes
    bytes.append(contentsOf: chunk)
    let end = Self.wholeCodePointsEnd(bytes)
    cutBytes = Array(bytes[end...])
    let first = buffer.count
    var parser = Unicode.UTF8.ForwardParser()
    var iterator = bytes[..<end].makeIterator()
    decoding: while true {
      switch parser.parseScalar(from: &iterator) {
      case .valid(let encoded): buffer.append(Unicode.UTF8.decode(encoded))
      case .emptyInput: break decoding
      case .error: throw DatabaseBackupError.notUTF8
      }
    }
    bufferBytes += end
    // Both read statements as C strings: a NUL would cut the statement the whitelist approved
    if engine == .sqlite || engine == .duckdb, buffer[first...].contains("\0") {
      throw SQLRestoreError.containsNUL
    }
    // The whole-file read (`String(data:encoding:)`) drops a byte order mark at the start
    if startsFile, let scalar = buffer.first {
      startsFile = false
      if scalar == "\u{FEFF}" { consume(1) }
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

  /// Drops the first `count` scalars of `buffer`
  private mutating func consume(_ count: Int) {
    let bytes = buffer[..<count].reduce(0) { $0 + Unicode.UTF8.width($1) }
    bufferOffset += bytes
    bufferBytes -= bytes
    buffer.removeFirst(count)
  }

  // MARK: - Splitting

  /// Splits `buffer`'s complete statements into `ready`. Each is an exact substring of the
  /// buffer, in order, after whitespace, delimiters or a `DELIMITER` line: found by its first
  /// match after the previous one. One not found there fails the read after the ones before.
  private mutating func splitBuffer() {
    let (statements, consumed) = tokenizer.splitStatements(
      scalars: buffer, isFinal: atEnd, state: &split)
    let ranges = Self.locate(statements, in: buffer, before: consumed, offset: bufferOffset)
    var located: [Statement] = []
    located.reserveCapacity(statements.count)
    for (text, range) in zip(statements, ranges) {
      let bytes = text.utf8.count
      guard bytes <= maxStatementBytes else {
        failure = .statementTooLarge(index: splitCount, bytes: bytes)
        break
      }
      located.append(
        Statement(text: text, byteRange: range, digest: SHA256.hash(data: Data(text.utf8))))
      splitCount += 1
    }
    if failure == nil, ranges.count < statements.count {
      failure = .statementNotLocated(index: splitCount)
    }
    ready = located.reversed()
    guard failure == nil else { return }
    consume(consumed)
    if atEnd {
      finished = true
    } else {
      failure = openStatementTooLarge()
    }
  }

  /// The file bytes of `statements` in `buffer[..<consumed]`, whose first scalar is at file
  /// offset `offset`: each the first occurrence of its text at or after the previous one's end.
  /// Stops at the first statement not found there, so a range never drifts.
  static func locate(
    _ statements: [String], in buffer: [Unicode.Scalar], before consumed: Int, offset: Int
  ) -> [Range<Int>] {
    var position = 0
    var offset = offset
    var ranges: [Range<Int>] = []
    ranges.reserveCapacity(statements.count)
    for text in statements {
      let count = text.unicodeScalars.count
      while !buffer[position..<consumed].starts(with: text.unicodeScalars) {
        guard position + count < consumed else { return ranges }
        offset += Unicode.UTF8.width(buffer[position])
        position += 1
      }
      let bytes = text.utf8.count
      ranges.append(offset..<(offset + bytes))
      position += count
      offset += bytes
    }
    return ranges
  }

  /// The open statement (the buffer after a split) once it passes the cap. Whitespace around
  /// it and a delimiter at its end (the split may return it one call late) do not count, but
  /// the buffer never grows more than a chunk past the cap.
  private func openStatementTooLarge() -> SQLRestoreError? {
    guard bufferBytes > maxStatementBytes else { return nil }
    // Whitespace scalars are ASCII: one byte each
    let lead = buffer.prefix(while: SQLTokenizer.isWhitespace).count
    let trail = buffer[lead...].reversed().prefix(while: SQLTokenizer.isWhitespace).count
    let bytes = bufferBytes - lead - trail
    let delimiter = split.delimiter.reduce(0) { $0 + Unicode.UTF8.width($1) }
    guard bytes > maxStatementBytes + delimiter || bufferBytes > maxStatementBytes + chunkSize
    else { return nil }
    return .statementTooLarge(index: splitCount, bytes: bytes)
  }
}
