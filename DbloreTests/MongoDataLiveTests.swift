// MongoDataLiveTests.swift
// Many-document writes and streamed reads against the docker fixture (mongo:8.0 on 27018, users
// in `admin`) through a real DatabaseConnectionManager: a typed insertMany split by
// `MongoInsertBatcher` into two batches through `executeGatedMongoCommands` lands every
// document, and `streamMongoDocuments` reads them back across getMore pages (a relock between
// pages stops the stream). A backup of two collections of `dblore_test` (one capped, one with a
// unique and a 2d index) restores into `dblore_test_other` with the same counts and indexes.
// Opt-in (`.requiresMongo`), serialized; collections have unique `data_live_` names and are
// dropped before and after, and `dblore_test_other` is dropped before and after.

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

  @Test("A relock while documents stream stops the stream before the next page", .requiresMongo)
  func relockStopsStream() async throws {
    let name = Self.uniqueName()
    await MongoSessionTests.drop(name)
    let config = MongoSessionTests.config()
    let registry = LockRegistry()
    registry.setLockedConnections([LockIdentity(config)])
    registry.grant(LockIdentity(config))
    let manager = DatabaseConnectionManager(lockSource: registry)
    do {
      try await manager.connect(config: config)
      let policy = ProtectionPolicy(protectionLevel: .none)
      let documents = (0..<3).map {
        MongoValue.document([MongoValue.Field("_id", .int32(Int32($0)))])
      }
      _ = try await manager.executeGatedMongoCommands(
        [.insertMany(collection: name, documents: documents)], policy: policy,
        connectionEpoch: await manager.connectionEpoch, expectedRows: [3])

      // Pages of one document; the lock comes back once the first is handed out
      let pages = Pages()
      do {
        _ = try await manager.streamMongoDocuments(
          .find(collection: name, filter: nil, projection: nil, sort: nil, skip: nil, limit: nil),
          policy: policy, pageSize: 1
        ) { page in
          await pages.add(page)
          registry.relockAll()
        }
        Issue.record("Expected the relocked stream to be refused")
      } catch DatabaseError.connectionLocked {}
      #expect(await pages.sizes == [1])
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(name)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(name)
  }

  @Test(
    "A backup of dblore_test restores into dblore_test_other with the same counts and indexes",
    .requiresMongo)
  func backupThenRestore() async throws {
    typealias Field = MongoValue.Field
    let (plain, capped) = (Self.uniqueName(), Self.uniqueName())
    let other = "dblore_test_other"
    let policy = ProtectionPolicy(protectionLevel: .none)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MongoDataLiveTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("backup.ndjson")
    for name in [plain, capped] { await MongoSessionTests.drop(name) }
    let source = DatabaseConnectionManager()
    let target = DatabaseConnectionManager()
    var sourceEpoch: UInt64?

    func cleanUp() async {
      if let sourceEpoch {
        _ = try? await source.executeGatedMongoCommands(
          [.admin(.dropDatabase(database: other))], policy: policy,
          connectionEpoch: sourceEpoch, expectedRows: nil)
      }
      await target.disconnect()
      await source.disconnect()
      for name in [plain, capped] { await MongoSessionTests.drop(name) }
      try? FileManager.default.removeItem(at: folder)
    }

    do {
      try await source.connect(config: MongoSessionTests.config())
      let epoch = await source.connectionEpoch
      sourceEpoch = epoch
      _ = try await source.executeGatedMongoCommands(
        [
          .admin(.dropDatabase(database: other)),
          .admin(
            .createCollection(
              name: capped,
              options: .document([Field("capped", .bool(true)), Field("size", .int64(1_048_576))])
            )),
          .insertMany(
            collection: capped,
            documents: (0..<30).map { .document([Field("_id", .int32(Int32($0)))]) }),
          .insertMany(
            collection: plain,
            documents: (0..<120).map {
              .document([Field("_id", .int32(Int32($0))), Field("a", .int32(Int32($0)))])
            }),
          .admin(
            .createIndex(
              collection: plain, keys: .document([Field("a", .int32(1))]),
              options: .document([Field("name", .string("a_1")), Field("unique", .bool(true))]))),
          .admin(
            .createIndex(
              collection: plain, keys: .document([Field("loc", .string("2d"))]),
              options: .document([Field("name", .string("loc_2d")), Field("bits", .int32(20))]))),
        ], policy: policy, connectionEpoch: epoch, expectedRows: nil)

      // Back up through the model, as the Back Up Database panel does
      let backup = MongoBackupModel(
        context: context(source, database: TestMongoDatabase.database),
        connectionEpoch: epoch,
        environment: MongoBackupModel.Environment(
          chooseSaveURL: { _ in url }, chooseOpenURL: { nil },
          existingNames: MongoBackupModel.Environment.live.existingNames))
      await backup.backUp(names: [plain, capped])
      guard case .done = backup.state else {
        Issue.record("Expected the backup done, got \(backup.state)")
        await cleanUp()
        return
      }

      // Restore into the other database on its own connection
      try await target.connect(
        config: MongoSessionTests.config(
          uri: "mongodb://\(TestMongoDatabase.host):\(TestMongoDatabase.port)/\(other)"
            + "?authSource=\(TestMongoDatabase.authSource)",
          database: other))
      let restore = MongoBackupModel(
        context: context(target, database: other),
        connectionEpoch: await target.connectionEpoch,
        environment: MongoBackupModel.Environment(
          chooseSaveURL: { _ in nil }, chooseOpenURL: { url },
          existingNames: MongoBackupModel.Environment.live.existingNames))
      await restore.loadRestore(url: url)
      #expect(restore.sourceDatabase == TestMongoDatabase.database)
      #expect(restore.collisions.isEmpty)
      await restore.requestRestore(dropExisting: false)
      guard case .done = restore.state else {
        Issue.record("Expected the restore done, got \(restore.state)")
        await cleanUp()
        return
      }

      for name in [plain, capped] {
        #expect(
          try await count(name, on: target) == (try await count(name, on: source)), "\(name)")
        let restored = try await indexes(name, database: other, on: target)
        let original = try await indexes(
          name, database: TestMongoDatabase.database, on: source)
        #expect(restored.map(\.name) == original.map(\.name), "\(name)")
        #expect(restored.map(\.keys) == original.map(\.keys), "\(name)")
      }
      #expect(try await count(plain, on: target) == 120)
      #expect(try await count(capped, on: target) == 30)
      let info = try await target.fetchMongoCollectionInfo(database: other, collection: capped)
      guard case .document(let options) = info.options else {
        Issue.record("Expected the options of \(capped), got \(info.options)")
        await cleanUp()
        return
      }
      #expect(options.first { $0.key == "capped" }?.value == .bool(true))
    } catch {
      await cleanUp()
      throw error
    }
    await cleanUp()
  }

  /// A backup or restore context on `manager` with no prompt (Immediate) and no History
  private func context(
    _ manager: DatabaseConnectionManager, database: String
  ) -> MongoBackupModel.Context {
    MongoBackupModel.Context(
      manager: manager, policy: ProtectionPolicy(protectionLevel: .none),
      commitStyle: { .immediate }, caller: nil, database: database,
      config: MongoSessionTests.config(database: database), recordHistory: { _ in },
      onRestored: {})
  }

  private func count(
    _ collection: String, on manager: DatabaseConnectionManager
  ) async throws
    -> Int
  {
    try await manager.streamMongoDocuments(
      .find(collection: collection, filter: nil, projection: nil, sort: nil, skip: nil, limit: nil),
      policy: ProtectionPolicy(protectionLevel: .none), pageSize: 100
    ) { _ in }
  }

  private func indexes(
    _ collection: String, database: String, on manager: DatabaseConnectionManager
  ) async throws -> [MongoIndexInfo] {
    let result = try await manager.fetchMongoIndexes(database: database, collection: collection)
    guard case .indexes(let list) = result else {
      Issue.record("Expected indexes on \(collection), got \(result)")
      return []
    }
    return list.sorted { $0.name < $1.name }
  }
}
