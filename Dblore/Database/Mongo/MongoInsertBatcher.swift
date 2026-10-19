// MongoInsertBatcher.swift
// Splits a stream of documents (restore, import) into insert batches the server accepts:
// at most min(1,000, maxWriteBatchSize) documents and min(8 MiB, maxMessageSizeBytes / 2)
// encoded BSON bytes per batch, leaving room for the command around the documents. A document
// larger than that byte budget (but within maxBsonObjectSize) goes in a batch of its own; a
// document larger than maxBsonObjectSize is refused with its record number.

import BSON
import Foundation
import NIOCore

nonisolated struct MongoInsertBatcher: Sendable {
  /// A document the server would refuse: larger than its `maxBsonObjectSize`.
  nonisolated struct OversizeDocument: Error, Equatable, Sendable, LocalizedError {
    let record: Int
    let bytes: Int
    let limit: Int

    var errorDescription: String? {
      "Record \(record) is \(Self.size(bytes)), larger than the server limit of \(Self.size(limit))"
    }

    /// Binary units, as MongoDB states its 16 MB document limit.
    private static func size(_ bytes: Int) -> String {
      ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
  }

  private let maxDocuments: Int
  private let maxBatchBytes: Int
  private let maxDocumentBytes: Int
  private var batch: [MongoValue] = []
  private var batchBytes = 0

  init(limits: MongoWriteLimits) {
    maxDocuments = max(1, min(1_000, limits.maxWriteBatchSize))
    maxBatchBytes = min(8 * 1_048_576, limits.maxMessageSizeBytes / 2)
    maxDocumentBytes = limits.maxBsonObjectSize
  }

  /// Adds one document. Returns the batch built so far when this document would overflow it;
  /// the document then starts the next batch. Throws `OversizeDocument` (nothing is added) or the
  /// encoder's `MappingError`.
  mutating func append(_ document: MongoValue, record: Int) throws -> [MongoValue]? {
    let size = try MongoBSONMapping.bsonDocument(document).makeByteBuffer().readableBytes
    guard size <= maxDocumentBytes else {
      throw OversizeDocument(record: record, bytes: size, limit: maxDocumentBytes)
    }
    var full: [MongoValue]?
    if !batch.isEmpty, batch.count == maxDocuments || batchBytes + size > maxBatchBytes {
      full = finish()
    }
    batch.append(document)
    batchBytes += size
    return full
  }

  /// The last, partial batch; nil when nothing is left.
  mutating func finish() -> [MongoValue]? {
    guard !batch.isEmpty else { return nil }
    defer {
      batch = []
      batchBytes = 0
    }
    return batch
  }
}
