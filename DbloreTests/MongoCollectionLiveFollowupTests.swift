// MongoCollectionLiveFollowupTests.swift
// Collection-tab catalog reads against the docker fixture (mongo:8.0 on 27018, users in `admin`)
// through a real DatabaseConnectionManager, the same calls the collection tabs make: the Indexes
// tab on a view answers `.view` (listIndexes `CommandNotSupportedOnView`, 166, handled) instead
// of an error; an index created through the admin action path is listed with its generated name
// and a Ready status once createIndexes returns; the Schema tab's `$sample` read on a view
// returns the view's documents. Opt-in (`.requiresMongo`), serialized; every collection and view
// has a unique `followup_live_` name and is dropped before and after.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoCollectionLiveFollowupTests {
  private typealias Field = MongoValue.Field

  private static func uniqueName() -> String {
    "followup_live_"
      + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
  }

  /// Runs `body` with a connected manager and the epoch read right after connecting. Every name
  /// in `collections` is dropped before and after.
  private func withManager(
    _ collections: [String],
    _ body: (DatabaseConnectionManager, UInt64) async throws -> Void
  ) async throws {
    for name in collections { await MongoSessionTests.drop(name) }
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: MongoSessionTests.config())
      let epoch = await manager.connectionEpoch
      try await body(manager, epoch)
    } catch {
      await manager.disconnect()
      for name in collections { await MongoSessionTests.drop(name) }
      throw error
    }
    await manager.disconnect()
    for name in collections { await MongoSessionTests.drop(name) }
  }

  /// Sends `command` the way `MongoAdminActionModel` does.
  private func send(
    _ command: MongoAdminCommand, _ manager: DatabaseConnectionManager, epoch: UInt64
  ) async throws {
    _ = try await manager.executeGatedSequentialBatch(
      [command.render()], policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: epoch, expectedRows: nil)
  }

  /// Inserts documents `{_id: id, a: a}` into `collection` as one typed insertMany.
  private func seed(
    _ collection: String, _ rows: [(id: Int32, a: Int32)], _ manager: DatabaseConnectionManager,
    epoch: UInt64
  ) async throws {
    let documents = rows.map {
      MongoValue.document([Field("_id", .int32($0.id)), Field("a", .int32($0.a))])
    }
    let results = try await manager.executeGatedMongoCommands(
      [.insertMany(collection: collection, documents: documents)],
      policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: epoch,
      expectedRows: [documents.count])
    #expect(results.map(\.affectedRows) == [documents.count])
  }

  /// A view of `source` keeping the documents with `a: 1`.
  private func createView(
    _ view: String, on source: String, _ manager: DatabaseConnectionManager, epoch: UInt64
  ) async throws {
    let pipeline = [MongoValue.document([Field("$match", .document([Field("a", .int32(1))]))])]
    try await send(
      .createView(name: view, source: source, pipeline: pipeline, options: nil), manager,
      epoch: epoch)
  }

  /// The value of `key` in a document, nil when absent or not a document.
  private func field(_ key: String, of value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value else { return nil }
    return fields.first { $0.key == key }?.value
  }

  @Test("The indexes of a view answer .view, not an error", .requiresMongo)
  func viewIndexes() async throws {
    let source = Self.uniqueName()
    let view = Self.uniqueName()
    try await withManager([view, source]) { manager, epoch in
      try await send(.createCollection(name: source, options: nil), manager, epoch: epoch)
      try await createView(view, on: source, manager, epoch: epoch)

      let result = try await manager.fetchMongoIndexes(
        database: TestMongoDatabase.database, collection: view)
      #expect(result == .view)
      let specs = try await manager.fetchMongoIndexSpecs(
        database: TestMongoDatabase.database, collection: view)
      #expect(specs.isEmpty)
    }
  }

  @Test("A created index is listed with its generated name and is Ready", .requiresMongo)
  func createdIndexIsReady() async throws {
    let name = Self.uniqueName()
    try await withManager([name]) { manager, epoch in
      try await seed(name, (1...50).map { (id: $0, a: $0 % 5) }, manager, epoch: epoch)
      try await send(
        .createIndex(
          collection: name, keys: .document([Field("a", .int32(1))]), options: nil),
        manager, epoch: epoch)

      // createIndexes returns once the build has committed, so a Building state (read from
      // $indexStats `building: true`) can't be observed deterministically here: only the final
      // state is asserted. The fixture user's clusterMonitor role grants indexStats, so the
      // status is read, not left nil.
      let result = try await manager.fetchMongoIndexes(
        database: TestMongoDatabase.database, collection: name)
      guard case .indexes(let list) = result else {
        Issue.record("Expected indexes on \(name), got \(result)")
        return
      }
      #expect(list.map(\.name) == ["_id_", "a_1"], "\(list.map(\.name))")
      #expect(list.allSatisfy { $0.status == .ready }, "\(list.map(\.status))")
    }
  }

  @Test("The schema sample of a view returns the view's documents", .requiresMongo)
  func sampleOnView() async throws {
    let source = Self.uniqueName()
    let view = Self.uniqueName()
    try await withManager([view, source]) { manager, epoch in
      try await seed(
        source, [(1, 1), (2, 0), (3, 1), (4, 0), (5, 1)], manager, epoch: epoch)
      try await createView(view, on: source, manager, epoch: epoch)

      // An empty filter sends `$sample`; when the server refuses it on the view, the manager
      // falls back to `find({}).limit(size)`. Either way the view's documents come back, which
      // is what is asserted (the result does not say which read answered).
      let documents = try await manager.sampleMongoDocuments(
        database: TestMongoDatabase.database, collection: view, filterText: "", size: 10)
      let ids = documents.compactMap { document -> Int32? in
        guard case .int32(let id)? = field("_id", of: document) else { return nil }
        return id
      }
      #expect(ids.sorted() == [1, 3, 5], "\(documents)")
      #expect(documents.allSatisfy { field("a", of: $0) == .int32(1) })
    }
  }
}
