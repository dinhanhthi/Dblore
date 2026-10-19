// MongoBackupFormat.swift
// The MongoDB backup file: UTF-8 NDJSON of canonical Extended JSON (.ndjson), one value per line.
//
// Line 1, the header:
//   {"format": "dblore-mongodb-backup", "version": 1, "database": <name>, "createdAt": <date>,
//    "collections": [{"name", "type": "collection", "options", "validator", "indexes", "count"}],
//    "views": [{"name", "viewOn", "pipeline", "options"}]}
//   `options` are the collection's createCollection options as listCollections reports them
//   (capped, size, max, timeseries, clusteredIndex, collation, ...) without the validator keys;
//   `validator` holds `validator` / `validationLevel` / `validationAction` (only those set) or is
//   null; `indexes` are listIndexes specs without `_id_` (and the clustered index, which
//   `clusteredIndex` recreates); `count` is the number of document lines of the collection. A
//   view's `options` are its options without `viewOn` and `pipeline` (its collation).
// Then one line per document: {"c": <collection>, "d": <document>}. The documents of one
// collection are contiguous. system.* collections are never written.
//
// Reading (the file is untrusted): the header must be line 1 with this exact `format` and version
// 1 (a newer version is refused); names must be valid collection names, unique across collections
// and views. Nothing in the header may run JavaScript on the server (`$where`, `$function`,
// `$accumulator`, `$code` at any depth of a view, an option, a validator or an index), and a
// view may not write (`$out`, `$merge`) nor read another database or a system collection
// (`$lookup` / `$graphLookup` `from`, `$unionWith`): a restored view runs on every read. No
// document of the header may repeat a key (the server keeps the last one).
// Every other line holds exactly `c` (a collection of the header) and `d` (a
// document), keeps its collection's documents together, and the counts must match the header.
// The first problem stops the read with its line number. Lines end with "\n" or "\r\n"; the file
// may end without one; an empty line is refused. The file is read in chunks, never whole.
//
// Line limits bound the memory of one line, not the document: canonical Extended JSON spells a
// small value as a wrapper (`{"$minKey": 1}` for 3 BSON bytes, `\u0001` for a 1-byte control
// character), so a document within maxBsonObjectSize can take several times that in text. A
// document line may take `textExpansion` times maxBsonObjectSize plus the wrapper; the restore
// checks the BSON size itself (`MongoInsertBatcher`). The writer refuses a line over the same
// limits, so every backup it writes can be read back.

import Foundation

/// The header line of a backup.
nonisolated struct MongoBackupHeader: Equatable, Sendable {
  nonisolated struct Collection: Equatable, Sendable {
    var name: String
    /// createCollection options as read, without `validator` / `validationLevel` /
    /// `validationAction`; always a document
    var options: MongoValue
    /// A document of `validator` / `validationLevel` / `validationAction` (the ones set), sent as
    /// `collMod` after the documents; nil when none is set
    var validator: MongoValue?
    /// listIndexes specs (`v`, `key`, `name` and the index options), without `_id_`
    var indexes: [MongoValue]
    /// Document lines of this collection in the file
    var count: Int64
  }

  nonisolated struct View: Equatable, Sendable {
    var name: String
    var viewOn: String
    var pipeline: [MongoValue]
    /// The view's options without `viewOn` and `pipeline` (its collation); always a document
    var options: MongoValue
  }

  /// The database the backup was read from
  var database: String
  /// Milliseconds since the Unix epoch (UTC)
  var createdAt: Int64
  var collections: [Collection]
  var views: [View]
}

/// One line handed out by `MongoBackupFormat.forEachLine`: the header first, then the documents.
nonisolated enum MongoBackupLine: Equatable, Sendable {
  case header(MongoBackupHeader)
  /// `line` is the 1-based line of the file
  case document(line: Int, collection: String, document: MongoValue)
}

/// Why a backup file was refused. `line` is 1-based; nil for a whole-file problem (a collection
/// with fewer documents than the header lists).
nonisolated struct MongoBackupFormatError: Error, Equatable, Sendable, LocalizedError {
  let line: Int?
  let message: String

  var errorDescription: String? { line.map { "Line \($0): \(message)" } ?? message }
}

nonisolated enum MongoBackupFormat {
  typealias Field = MongoValue.Field

  static let format = "dblore-mongodb-backup"
  static let version: Int32 = 1
  static let fileExtension = "ndjson"
  /// The header line limit in UTF-8 bytes
  static let maxHeaderBytes = 64 * 1_048_576
  /// Canonical Extended JSON text per BSON byte, at most (see the file header)
  static let textExpansion = 8
  /// The `{"c": …, "d": …}` wrapper with an escaped collection name, at most
  static let wrapperBytes = 64 * 1_024

  private static let validatorKeys: Set<String> = [
    "validator", "validationLevel", "validationAction",
  ]
  private static let cancellationStride = 256

  /// The document line limit in UTF-8 bytes for a server whose largest document is
  /// `maxBsonObjectSize` bytes.
  static func maxDocumentLineBytes(maxBsonObjectSize: Int) -> Int {
    maxBsonObjectSize * textExpansion + wrapperBytes
  }

  // MARK: - Writing

  /// Line 1 of the file, without its "\n".
  static func headerLine(_ header: MongoBackupHeader) -> String {
    let collections = header.collections.map { collection -> MongoValue in
      .document([
        Field("name", .string(collection.name)), Field("type", .string("collection")),
        Field("options", collection.options), Field("validator", collection.validator ?? .null),
        Field("indexes", .array(collection.indexes)), Field("count", .int64(collection.count)),
      ])
    }
    let views = header.views.map { view -> MongoValue in
      .document([
        Field("name", .string(view.name)), Field("viewOn", .string(view.viewOn)),
        Field("pipeline", .array(view.pipeline)), Field("options", view.options),
      ])
    }
    let value = MongoValue.document([
      Field("format", .string(format)), Field("version", .int32(version)),
      Field("database", .string(header.database)), Field("createdAt", .date(header.createdAt)),
      Field("collections", .array(collections)), Field("views", .array(views)),
    ])
    return MongoRelaxedJSON.render(value, as: .canonicalExtendedJSON)
  }

  /// One document line, without its "\n".
  static func documentLine(collection: String, document: MongoValue) -> String {
    MongoRelaxedJSON.render(
      .document([Field("c", .string(collection)), Field("d", document)]),
      as: .canonicalExtendedJSON)
  }

  // MARK: - Reading

  /// Reads the backup at `url` line by line and hands each line to `body`: the header, then every
  /// document. Throws `MongoBackupFormatError` at the first bad line (nothing after it reaches
  /// `body`), a file error, `CancellationError`, or `body`'s error; returns the header once every
  /// line was read and the counts matched. Validation alone passes a `body` that ignores its
  /// lines. Reads the file synchronously: call it off the main actor.
  @discardableResult
  static func forEachLine(
    url: URL, maxBsonObjectSize: Int, _ body: (MongoBackupLine) async throws -> Void
  ) async throws -> MongoBackupHeader {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var reader = LineReader(handle: handle)

    guard let first = try reader.next(maxBytes: maxHeaderBytes) else {
      throw MongoBackupFormatError(line: 1, message: "The file is empty.")
    }
    let header = try parseHeader(first)
    try await body(.header(header))

    let expected = Dictionary(
      header.collections.map { ($0.name, $0.count) }, uniquingKeysWith: { first, _ in first })
    let maxLineBytes = maxDocumentLineBytes(maxBsonObjectSize: maxBsonObjectSize)
    var counts: [String: Int64] = [:]
    var current: String?
    while let text = try reader.next(maxBytes: maxLineBytes) {
      let line = reader.lineNumber
      if line.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
      let (collection, document) = try parseDocumentLine(text, line: line, maxBytes: maxLineBytes)
      guard let limit = expected[collection] else {
        throw MongoBackupFormatError(
          line: line, message: "The collection \(label(collection)) is not in the backup header.")
      }
      if collection != current {
        guard counts[collection] == nil else {
          throw MongoBackupFormatError(
            line: line,
            message: "The documents of \(label(collection)) are not together; another collection's "
              + "documents come between them.")
        }
        current = collection
      }
      let count = counts[collection, default: 0] + 1
      guard count <= limit else {
        throw MongoBackupFormatError(
          line: line,
          message: "The collection \(label(collection)) has more documents than the header lists "
            + "(\(limit)).")
      }
      counts[collection] = count
      try await body(.document(line: line, collection: collection, document: document))
    }
    for collection in header.collections
    where counts[collection.name, default: 0] != collection.count {
      throw MongoBackupFormatError(
        line: nil,
        message: "The backup ends early: the collection \(label(collection.name)) has "
          + "\(counts[collection.name, default: 0]) of its \(collection.count) documents.")
    }
    return header
  }

  /// Reads and checks line 1 of `url` only (the restore's last look before it drops anything).
  static func readHeader(url: URL) throws -> MongoBackupHeader {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var reader = LineReader(handle: handle)
    guard let first = try reader.next(maxBytes: maxHeaderBytes) else {
      throw MongoBackupFormatError(line: 1, message: "The file is empty.")
    }
    return try parseHeader(first)
  }

  /// The size and modification date of a file: a restore refuses a file whose stamp changed
  /// since it was checked
  nonisolated struct FileStamp: Equatable, Sendable {
    let size: UInt64?
    let modified: Date?
  }

  static func stamp(of url: URL) throws -> FileStamp {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return FileStamp(
      size: (attributes[.size] as? NSNumber)?.uint64Value,
      modified: attributes[.modificationDate] as? Date)
  }

  /// A name from the file as UI and History text: one line without format characters (bidi
  /// overrides and the like), at most 120 characters
  static func label(_ name: String) -> String {
    let visible = String(
      String.UnicodeScalarView(
        name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    let line = visible.components(separatedBy: .newlines.union(.controlCharacters))
      .joined(separator: " ")
    return line.count > 120 ? String(line.prefix(120)) + "…" : line
  }

  // MARK: - Header

  private static func parseHeader(
    _ text: String
  ) throws(MongoBackupFormatError) -> MongoBackupHeader {
    func fail(_ message: String) -> MongoBackupFormatError {
      MongoBackupFormatError(line: 1, message: message)
    }
    let value: MongoValue
    do {
      value = try MongoRelaxedJSON.parse(text, maxBytes: maxHeaderBytes)
    } catch {
      throw fail("This file is not a Dblore MongoDB backup: \(error.message).")
    }
    guard case .document(let fields) = value,
      case .string(format)? = Self.value("format", in: fields)
    else { throw fail("This file is not a Dblore MongoDB backup.") }
    if let key = repeatedKey(in: value) {
      throw fail(
        "The backup header repeats the key \"\(label(key))\"; Dblore does not restore it.")
    }
    switch Self.value("version", in: fields) {
    case .int32(1)?, .int64(1)?: break
    case .int32(let number)? where number > 1:
      throw fail(newerVersion(Int64(number)))
    case .int64(let number)? where number > 1:
      throw fail(newerVersion(number))
    case nil: throw fail("The backup header has no version.")
    default: throw fail("The backup header has an invalid version.")
    }
    guard case .string(let database)? = Self.value("database", in: fields) else {
      throw fail("The backup header has no database name.")
    }
    guard case .date(let createdAt)? = Self.value("createdAt", in: fields) else {
      throw fail("The backup header has no creation date.")
    }
    guard case .array(let collectionEntries)? = Self.value("collections", in: fields),
      case .array(let viewEntries)? = Self.value("views", in: fields)
    else { throw fail("The backup header has no collections or views list.") }

    var names: Set<String> = []
    func unique(_ name: String, kind: String) throws(MongoBackupFormatError) {
      if let problem = MongoCollectionDraft.nameProblem(name) {
        throw fail("The \(kind) name \"\(label(name))\" is not valid: \(problem).")
      }
      guard names.insert(name).inserted else {
        throw fail("The name \(label(name)) appears twice in the backup header.")
      }
    }
    var collections: [MongoBackupHeader.Collection] = []
    for entry in collectionEntries {
      let collection = try parseCollection(entry, fail: fail)
      try unique(collection.name, kind: "collection")
      collections.append(collection)
    }
    var views: [MongoBackupHeader.View] = []
    for entry in viewEntries {
      let view = try parseView(entry, fail: fail)
      try unique(view.name, kind: "view")
      views.append(view)
    }
    return MongoBackupHeader(
      database: database, createdAt: createdAt, collections: collections, views: views)
  }

  /// A key that one document repeats at any depth of `value` (a written header never does; the
  /// server keeps the last of them, a check here may read another). The parser's depth limit
  /// bounds the recursion.
  private static func repeatedKey(in value: MongoValue) -> String? {
    switch value {
    case .document(let fields):
      var keys: Set<String> = []
      for field in fields {
        guard keys.insert(field.key).inserted else { return field.key }
        if let key = repeatedKey(in: field.value) { return key }
      }
      return nil
    case .array(let items):
      for item in items {
        if let key = repeatedKey(in: item) { return key }
      }
      return nil
    default: return nil
    }
  }

  private static func newerVersion(_ number: Int64) -> String {
    "The backup uses format version \(number); this version of Dblore reads version \(version) "
      + "only."
  }

  private static func parseCollection(
    _ entry: MongoValue, fail: (String) -> MongoBackupFormatError
  ) throws(MongoBackupFormatError) -> MongoBackupHeader.Collection {
    guard case .document(let fields) = entry, case .string(let name)? = value("name", in: fields)
    else { throw fail("A collection of the backup header has no name.") }
    let shown = label(name)
    guard case .string("collection")? = value("type", in: fields) else {
      throw fail("The collection \(shown) has an unknown type.")
    }
    guard let options = value("options", in: fields), case .document(let optionFields) = options,
      !optionFields.contains(where: {
        $0.key == "viewOn" || $0.key == "pipeline" || validatorKeys.contains($0.key)
      })
    else {
      throw fail(
        "The options of the collection \(shown) are not a document without view or validator "
          + "keys.")
    }
    var validator: MongoValue?
    switch value("validator", in: fields) {
    case .null?: break
    case .document(let rules)?
    where !rules.isEmpty && rules.allSatisfy({ validatorKeys.contains($0.key) }):
      validator = .document(rules)
    default:
      throw fail(
        "The validator of the collection \(shown) must be null or a document of validator, "
          + "validationLevel and validationAction.")
    }
    guard case .array(let indexes)? = value("indexes", in: fields),
      indexes.allSatisfy(isIndexSpec)
    else {
      throw fail(
        "The indexes of the collection \(shown) must be index specs with a name (not _id_) and "
          + "a key.")
    }
    let count: Int64
    switch value("count", in: fields) {
    case .int32(let number)? where number >= 0: count = Int64(number)
    case .int64(let number)? where number >= 0: count = number
    default: throw fail("The collection \(shown) has no valid document count.")
    }
    guard
      !([options] + [validator].compactMap { $0 } + indexes).contains(where: {
        MongoCommandClassifier.usesServerSideJavaScript($0)
      })
    else {
      throw fail(
        "The collection \"\(shown)\" runs server-side JavaScript (in its options, validator or "
          + "an index); Dblore does not restore it.")
    }
    return MongoBackupHeader.Collection(
      name: name, options: options, validator: validator, indexes: indexes, count: count)
  }

  private static func isIndexSpec(_ spec: MongoValue) -> Bool {
    guard case .document(let fields) = spec, case .string(let name)? = value("name", in: fields),
      name != "_id_", case .document(let key)? = value("key", in: fields), !key.isEmpty
    else { return false }
    return true
  }

  private static func parseView(
    _ entry: MongoValue, fail: (String) -> MongoBackupFormatError
  ) throws(MongoBackupFormatError) -> MongoBackupHeader.View {
    guard case .document(let fields) = entry, case .string(let name)? = value("name", in: fields)
    else { throw fail("A view of the backup header has no name.") }
    let shown = label(name)
    guard case .string(let viewOn)? = value("viewOn", in: fields),
      MongoCollectionDraft.nameProblem(viewOn) == nil
    else { throw fail("The view \(shown) has no valid source collection.") }
    guard case .array(let pipeline)? = value("pipeline", in: fields),
      pipeline.allSatisfy({ if case .document = $0 { true } else { false } })
    else { throw fail("The pipeline of the view \(shown) is not a list of stages.") }
    guard let options = value("options", in: fields), case .document = options else {
      throw fail("The options of the view \(shown) are not a document.")
    }
    if MongoCommandClassifier.usesServerSideJavaScript(.array(pipeline))
      || MongoCommandClassifier.usesServerSideJavaScript(options)
    {
      throw fail(
        "The view \"\(shown)\" runs server-side JavaScript; Dblore does not restore it.")
    }
    let read = MongoCommand.aggregate(collection: viewOn, pipeline: pipeline)
    guard MongoCommandClassifier.classify(read, summary: "").kind == .read else {
      throw fail(
        "The view \"\(shown)\" writes data ($out or $merge); Dblore does not restore it.")
    }
    guard !readsOutside(.array(pipeline)) else {
      throw fail(
        "The view \"\(shown)\" reads another database or a system collection; Dblore does not "
          + "restore it.")
    }
    return MongoBackupHeader.View(name: name, viewOn: viewOn, pipeline: pipeline, options: options)
  }

  /// Any `$lookup` / `$graphLookup` `from` or `$unionWith` collection at any depth of `value`
  /// that is not a plain collection name of this database: a document (another database) or a
  /// name `MongoCollectionDraft.nameProblem` refuses (`system.` included). The parser's depth
  /// limit bounds the recursion.
  private static func readsOutside(_ value: MongoValue) -> Bool {
    func foreign(_ source: MongoValue?) -> Bool {
      switch source {
      case nil: false
      case .string(let name)?: MongoCollectionDraft.nameProblem(name) != nil
      default: true
      }
    }
    switch value {
    case .document(let fields):
      return fields.contains { field in
        switch (field.key, field.value) {
        case ("$lookup", .document(let spec)), ("$graphLookup", .document(let spec)):
          if spec.contains(where: { $0.key == "from" && foreign($0.value) }) { return true }
        case ("$unionWith", .document(let spec)):
          if spec.contains(where: { $0.key == "coll" && foreign($0.value) }) { return true }
        case ("$unionWith", let source):
          if foreign(source) { return true }
        default: break
        }
        return readsOutside(field.value)
      }
    case .array(let items): return items.contains(where: readsOutside)
    default: return false
    }
  }

  // MARK: - Documents

  private static func parseDocumentLine(
    _ text: String, line: Int, maxBytes: Int
  ) throws(MongoBackupFormatError) -> (collection: String, document: MongoValue) {
    let value: MongoValue
    do {
      value = try MongoRelaxedJSON.parse(text, maxBytes: maxBytes)
    } catch {
      throw MongoBackupFormatError(line: line, message: error.message)
    }
    guard case .document(let fields) = value, fields.count == 2,
      case .string(let collection)? = Self.value("c", in: fields),
      case .document? = Self.value("d", in: fields), let document = Self.value("d", in: fields)
    else {
      throw MongoBackupFormatError(
        line: line,
        message: "A document line holds exactly \"c\" (the collection) and \"d\" (the document).")
    }
    return (collection, document)
  }

  /// The first field named `key`
  private static func value(_ key: String, in fields: [Field]) -> MongoValue? {
    fields.first { $0.key == key }?.value
  }
}

// MARK: - Line reader

/// Reads a file line by line in 1 MiB chunks. A line longer than the caller's limit is refused
/// before the rest of it is read.
nonisolated private struct LineReader {
  private static let chunkSize = 1_048_576

  let handle: FileHandle
  /// The 1-based number of the last line returned
  private(set) var lineNumber = 0
  private var buffer: [UInt8] = []
  /// First byte of the current line in `buffer`
  private var start = 0
  /// Bytes of the current line already searched for "\n"
  private var scanned = 0
  private var atEnd = false

  init(handle: FileHandle) {
    self.handle = handle
  }

  /// The next line without "\n" and one "\r" before it, as strict UTF-8; nil after the last
  /// line. `maxBytes` limits the line without its line break.
  mutating func next(maxBytes: Int) throws -> String? {
    while true {
      if let newline = buffer[(start + scanned)...].firstIndex(of: 0x0A) {
        let line = buffer[start..<newline]
        start = newline + 1
        scanned = 0
        return try text(of: line, maxBytes: maxBytes)
      }
      scanned = buffer.count - start
      // One more byte may be the "\r" of a "\r\n"
      guard scanned <= maxBytes + 1 else { throw tooLong(maxBytes) }
      if atEnd {
        guard scanned > 0 else { return nil }
        let line = buffer[start...]
        start = buffer.count
        scanned = 0
        return try text(of: line, maxBytes: maxBytes)
      }
      if start > 0 {
        buffer.removeFirst(start)
        start = 0
      }
      if let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
        buffer.append(contentsOf: chunk)
      } else {
        atEnd = true
      }
    }
  }

  private mutating func text(of line: ArraySlice<UInt8>, maxBytes: Int) throws -> String {
    lineNumber += 1
    let content = line.last == 0x0D ? line.dropLast() : line
    guard content.count <= maxBytes else {
      throw MongoBackupFormatError(line: lineNumber, message: limitMessage(maxBytes))
    }
    guard !content.isEmpty else {
      throw MongoBackupFormatError(line: lineNumber, message: "The line is empty.")
    }
    let text = String(decoding: content, as: UTF8.self)
    guard text.utf8.elementsEqual(content) else {
      throw MongoBackupFormatError(line: lineNumber, message: "The line is not valid UTF-8.")
    }
    return text
  }

  private func tooLong(_ maxBytes: Int) -> MongoBackupFormatError {
    MongoBackupFormatError(line: lineNumber + 1, message: limitMessage(maxBytes))
  }

  private func limitMessage(_ maxBytes: Int) -> String {
    "The line is longer than "
      + ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .memory) + "."
  }
}
