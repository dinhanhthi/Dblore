// MongoInsertBatcherTests.swift
// Insert batches split by document count and by encoded BSON bytes, and an oversize document
// refused with its record number

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo insert batcher")
struct MongoInsertBatcherTests {

  /// A document of exactly `bytes` encoded BSON bytes: `{a: "<x * n>"}` encodes to 13 + n.
  private func doc(bytes: Int) -> MongoValue {
    .document([MongoValue.Field("a", .string(String(repeating: "x", count: bytes - 13)))])
  }

  private func limits(
    object: Int = 1_000, message: Int = 1_000, batch: Int = 100_000
  ) -> MongoWriteLimits {
    MongoWriteLimits(
      maxBsonObjectSize: object, maxMessageSizeBytes: message, maxWriteBatchSize: batch)
  }

  @Test("A batch holds at most min(1,000, maxWriteBatchSize) documents; finish returns the rest")
  func splitsByCount() throws {
    var batcher = MongoInsertBatcher(limits: .fallback)
    #expect(batcher.finish() == nil)
    for record in 1...1_000 {
      #expect(try batcher.append(.document([]), record: record) == nil)
    }
    #expect(try batcher.append(.document([]), record: 1_001)?.count == 1_000)
    #expect(batcher.finish()?.count == 1)
    #expect(batcher.finish() == nil)

    var small = MongoInsertBatcher(limits: limits(batch: 2))
    #expect(try small.append(.document([]), record: 1) == nil)
    #expect(try small.append(.document([]), record: 2) == nil)
    #expect(try small.append(.document([]), record: 3)?.count == 2)
  }

  @Test("A batch holds at most maxMessageSizeBytes / 2 bytes; a larger document goes alone")
  func splitsByBytes() throws {
    // Batch budget 50 bytes.
    var batcher = MongoInsertBatcher(limits: limits(object: 64, message: 100))
    let first = doc(bytes: 20)
    let second = doc(bytes: 21)
    let big = doc(bytes: 60)
    #expect(try batcher.append(first, record: 1) == nil)
    #expect(try batcher.append(second, record: 2) == nil)
    #expect(try batcher.append(first, record: 3) == [first, second])
    #expect(try batcher.append(big, record: 4) == [first])
    #expect(try batcher.append(second, record: 5) == [big])
    #expect(batcher.finish() == [second])
  }

  @Test("A document larger than maxBsonObjectSize fails with its record number")
  func oversizeDocumentFails() throws {
    var batcher = MongoInsertBatcher(limits: limits(object: 64))
    let kept = doc(bytes: 20)
    #expect(try batcher.append(kept, record: 41) == nil)
    do {
      _ = try batcher.append(doc(bytes: 65), record: 42)
      Issue.record("The oversize document was accepted")
    } catch let error as MongoInsertBatcher.OversizeDocument {
      #expect(error.record == 42)
      #expect(error.localizedDescription.contains("Record 42"))
    }
    #expect(batcher.finish() == [kept])
  }
}
