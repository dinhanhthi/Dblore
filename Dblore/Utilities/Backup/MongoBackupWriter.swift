// MongoBackupWriter.swift
// Writes a MongoDB backup file (`MongoBackupFormat`). The header is line 1 but its document
// counts are known only once every document is read, so the document lines go to a temporary
// body file first; `finish` writes the header to a second temporary file, copies the body after
// it in chunks (never the whole file in memory) and puts the result at the destination in one
// step (`SQLDumpWriter.replaceItem`; an existing file is replaced). Both temporary files sit in
// the container's temporary folder (the sandbox grants the save panel's file only), so the disk
// briefly holds the backup twice. Cancel or a failure deletes them: no partial file is left.
//
// `backUp` reads the chosen collections and views of the session's database: listCollections
// (`fetchMongoCollectionInfo`) and the raw listIndexes specs (`fetchMongoIndexSpecs`) of each
// for the header, then every document of each collection (`find {}`, natural order) through
// `streamMongoDocuments` under the read-only policy (a backup is a read). Views go in the header
// only. Names a restore could not create (system.*, `$`, NUL) are skipped, and so is a view on
// such a source.

import Foundation

actor MongoBackupWriter {
  nonisolated struct Progress: Equatable, Sendable {
    var collectionsDone: Int
    var collectionsTotal: Int
    var documentsWritten: Int
  }

  /// Documents per cursor batch of the backup read
  static let pageSize = 1000
  private static let copyChunkSize = 1_048_576

  let destination: URL
  private(set) var documentsWritten = 0
  private var counts: [String: Int64] = [:]
  private let maxLineBytes: Int
  /// The document lines
  private let body: URL
  /// The header followed by the body, moved to the destination
  private let assembled: URL
  /// The body's handle; nil once finished or cancelled
  private var output: FileHandle?

  /// Creates the body file (mode 0600) in `temporaryDirectory`. A document line may not exceed
  /// `MongoBackupFormat.maxDocumentLineBytes(maxBsonObjectSize:)`, the limit the reader applies.
  init(
    destination: URL, maxBsonObjectSize: Int,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws {
    let prefix = "Dblore-backup-\(UUID().uuidString)"
    let body = temporaryDirectory.appendingPathComponent("\(prefix).body.partial")
    self.destination = destination
    self.body = body
    assembled = temporaryDirectory.appendingPathComponent("\(prefix).partial")
    maxLineBytes = MongoBackupFormat.maxDocumentLineBytes(maxBsonObjectSize: maxBsonObjectSize)
    output = FileHandle(
      fileDescriptor: try SQLDumpWriter.createPrivateFile(at: body), closeOnDealloc: true)
  }

  /// Appends one page of `collection`'s documents; the caller writes one collection after the
  /// other. Returns the documents written so far in total. Throws `CancellationError` after
  /// `cancel()` or `finish()`.
  func write(collection: String, documents: [MongoValue]) throws -> Int {
    guard let output else { throw CancellationError() }
    var text = ""
    var written = counts[collection, default: 0]
    for document in documents {
      let line = MongoBackupFormat.documentLine(collection: collection, document: document)
      written += 1
      guard line.utf8.count <= maxLineBytes else {
        let limit = ByteCountFormatter.string(
          fromByteCount: Int64(maxLineBytes), countStyle: .memory)
        throw MongoBackupFormatError(
          line: nil,
          message: "Document \(written) of \(collection) is too large for a backup line (\(limit))."
        )
      }
      text += line + "\n"
    }
    if !text.isEmpty { try output.write(contentsOf: Data(text.utf8)) }
    counts[collection] = written
    documentsWritten += documents.count
    return documentsWritten
  }

  /// Writes `header` with each collection's count set to the documents written for it, then the
  /// documents, and puts the file at the destination. Returns the header written. On failure
  /// nothing is left behind.
  func finish(header: MongoBackupHeader) throws -> MongoBackupHeader {
    guard let bodyHandle = output else { throw CancellationError() }
    var header = header
    for index in header.collections.indices {
      header.collections[index].count = counts[header.collections[index].name, default: 0]
    }
    do {
      output = nil
      try bodyHandle.close()
      let line = MongoBackupFormat.headerLine(header)
      guard line.utf8.count <= MongoBackupFormat.maxHeaderBytes else {
        throw MongoBackupFormatError(
          line: nil,
          message: "The backup header is larger than "
            + ByteCountFormatter.string(
              fromByteCount: Int64(MongoBackupFormat.maxHeaderBytes), countStyle: .memory)
            + "; back up fewer collections at a time.")
      }
      let target = FileHandle(
        fileDescriptor: try SQLDumpWriter.createPrivateFile(at: assembled), closeOnDealloc: true)
      do {
        try target.write(contentsOf: Data((line + "\n").utf8))
        let source = try FileHandle(forReadingFrom: body)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
          try Task.checkCancellation()
          try target.write(contentsOf: chunk)
        }
        try target.close()
      } catch {
        try? target.close()
        throw error
      }
      try SQLDumpWriter.replaceItem(at: destination, withItemAt: assembled)
      try? FileManager.default.removeItem(at: body)
      return header
    } catch {
      discard()
      throw error
    }
  }

  /// Closes and deletes the temporary files. No-op once finished or cancelled.
  func cancel() {
    guard output != nil else { return }
    discard()
  }

  private func discard() {
    try? output?.close()
    output = nil
    try? FileManager.default.removeItem(at: body)
    try? FileManager.default.removeItem(at: assembled)
  }
}

// MARK: - Backup

extension MongoBackupWriter {
  /// Backs up `names` (collections and views, in this order) of `database`, which must be the
  /// session's database, to `destination`, and returns the header written. Reads go through
  /// `streamMongoDocuments` with `caller`, `expectedEpoch` (read before the caller listed the
  /// names) and `statementToken`: `interruptMongoStatement(token:)` with that token plus a Task
  /// cancel stop the backup. Every failure and a cancel leave no file.
  static func backUp(
    names: [String], database: String, to destination: URL,
    manager: DatabaseConnectionManager, caller: UUID?, expectedEpoch: UInt64?,
    statementToken: String, createdAt: Date = Date(),
    progress: @escaping @Sendable (Progress) async -> Void
  ) async throws -> MongoBackupHeader {
    try await PerfSignpost.interval("mongo.backup") {
      var header = try await readHeader(
        names: names, database: database, manager: manager, createdAt: createdAt)
      try Task.checkCancellation()
      let limits = await manager.mongoWriteLimits()
      let writer = try MongoBackupWriter(
        destination: destination, maxBsonObjectSize: limits.maxBsonObjectSize)
      let total = header.collections.count
      await progress(Progress(collectionsDone: 0, collectionsTotal: total, documentsWritten: 0))
      do {
        for (done, collection) in header.collections.enumerated() {
          try Task.checkCancellation()
          let name = collection.name
          _ = try await manager.streamMongoDocuments(
            .find(
              collection: name, filter: nil, projection: nil, sort: nil, skip: nil, limit: nil),
            policy: ProtectionPolicy(protectionLevel: .readOnly), pageSize: pageSize,
            caller: caller, expectedEpoch: expectedEpoch, statementToken: statementToken
          ) { page in
            try Task.checkCancellation()
            let written = try await writer.write(collection: name, documents: page)
            await progress(
              Progress(collectionsDone: done, collectionsTotal: total, documentsWritten: written))
          }
          await progress(
            Progress(
              collectionsDone: done + 1, collectionsTotal: total,
              documentsWritten: await writer.documentsWritten))
        }
        try Task.checkCancellation()
        header = try await writer.finish(header: header)
        return header
      } catch {
        await writer.cancel()
        throw error
      }
    }
  }

  /// The header of `names` with every count 0 (`finish` sets them).
  private static func readHeader(
    names: [String], database: String, manager: DatabaseConnectionManager, createdAt: Date
  ) async throws -> MongoBackupHeader {
    var header = MongoBackupHeader(
      database: database, createdAt: Int64((createdAt.timeIntervalSince1970 * 1000).rounded()),
      collections: [], views: [])
    var seen: Set<String> = []
    for name in names where MongoCollectionDraft.nameProblem(name) == nil {
      guard seen.insert(name).inserted else { continue }
      try Task.checkCancellation()
      let info = try await manager.fetchMongoCollectionInfo(database: database, collection: name)
      guard case .document(let options) = info.options else {
        throw MongoSessionError(message: "The options of \(name) are not a document.")
      }
      if info.isView {
        guard case .string(let source)? = options.first(where: { $0.key == "viewOn" })?.value,
          case .array(let pipeline)? = options.first(where: { $0.key == "pipeline" })?.value
        else { throw MongoSessionError(message: "The view \(name) has no source or pipeline.") }
        guard MongoCollectionDraft.nameProblem(source) == nil else { continue }
        header.views.append(
          MongoBackupHeader.View(
            name: name, viewOn: source, pipeline: pipeline,
            options: .document(options.filter { $0.key != "viewOn" && $0.key != "pipeline" })))
        continue
      }
      let validatorKeys: Set<String> = ["validator", "validationLevel", "validationAction"]
      let rules = options.filter { validatorKeys.contains($0.key) }
      let specs = try await manager.fetchMongoIndexSpecs(database: database, collection: name)
      header.collections.append(
        MongoBackupHeader.Collection(
          name: name, options: .document(options.filter { !validatorKeys.contains($0.key) }),
          validator: rules.isEmpty ? nil : .document(rules),
          indexes: specs.filter(isRestorableIndex), count: 0))
    }
    return header
  }

  /// Every listIndexes spec but `_id_` and a clustered collection's index (createCollection's
  /// `clusteredIndex` recreates it; createIndex refuses it).
  private static func isRestorableIndex(_ spec: MongoValue) -> Bool {
    guard case .document(let fields) = spec else { return false }
    let value = { (key: String) in fields.first { $0.key == key }?.value }
    guard case .string(let name)? = value("name"), name != "_id_",
      case .document(let key)? = value("key"), !key.isEmpty
    else { return false }
    if case .bool(true)? = value("clustered") { return false }
    return true
  }
}
