// MongoDataLiveTests.swift
// Many-document writes and streamed reads against the docker fixture (mongo:8.0 on 27018, users
// in `admin`) through a real DatabaseConnectionManager: a typed insertMany split by
// `MongoInsertBatcher` into two batches through `executeGatedMongoCommands` lands every
// document, and `streamMongoDocuments` reads them back across getMore pages. Opt-in
// (`.requiresMongo`), serialized; the collection has a unique `data_live_` name and is dropped
// before and after.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoDataLiveTests {
  /// The pages `onPage` received, in order.
  private actor Pages {
    var sizes: [Int] = []
    var ids: [MongoValue] = []

    func add(_ page: [MongoValue]) {
      sizes.append(page.count)
      for case .document(let fields) in page {
        ids.append(fields.first { $0.key == "_id" }?.value ?? .null)
      }
    }
  }

  private static func uniqueName() -> String {
    "data_live_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
  }

  @Test(
    "A typed insertMany of two batches lands 250 documents; a find streams them in pages",
    .requiresMongo)
  func insertThenStream() async throws {
    let name = Self.uniqueName()
    await MongoSessionTests.drop(name)
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: MongoSessionTests.config())
      let epoch = await manager.connectionEpoch
      let policy = ProtectionPolicy(protectionLevel: .none)

      // Batches of at most 200 documents: 200, then 50
      var batcher = MongoInsertBatcher(
        limits: MongoWriteLimits(
          maxBsonObjectSize: 16 * 1_048_576, maxMessageSizeBytes: 48_000_000,
          maxWriteBatchSize: 200))
      var batches: [[MongoValue]] = []
      for id in 0..<250 {
        let document = MongoValue.document([MongoValue.Field("_id", .int32(Int32(id)))])
        if let full = try batcher.append(document, record: id + 1) { batches.append(full) }
      }
      if let rest = batcher.finish() { batches.append(rest) }
      #expect(batches.map(\.count) == [200, 50])

      for batch in batches {
        let results = try await manager.executeGatedMongoCommands(
          [.insertMany(collection: name, documents: batch)], policy: policy,
          connectionEpoch: epoch, expectedRows: [batch.count])
        #expect(results.map(\.affectedRows) == [batch.count])
      }

      let pages = Pages()
      let delivered = try await manager.streamMongoDocuments(
        .find(
          collection: name, filter: nil, projection: nil,
          sort: .document([MongoValue.Field("_id", .int32(1))]), skip: nil, limit: nil),
        policy: policy, pageSize: 100
      ) { page in await pages.add(page) }
      #expect(delivered == 250)
      let sizes = await pages.sizes
      #expect(sizes.count >= 2, "\(sizes)")
      #expect(sizes.reduce(0, +) == 250)
      #expect(await pages.ids == (0..<250).map { MongoValue.int32(Int32($0)) })
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(name)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(name)
  }
}
