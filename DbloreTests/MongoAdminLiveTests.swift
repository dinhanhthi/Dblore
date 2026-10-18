// MongoAdminLiveTests.swift
// Administration commands against the docker fixture (mongo:8.0 on 27018, users in `admin`)
// through a real DatabaseConnectionManager, sent as the admin action model sends them: the
// rendered mongosh text through `executeGatedSequentialBatch`, then checked with the catalog
// reads (`fetchMongoIndexes`, `fetchMongoCollectionInfo`). createIndex without a name gets the
// drivers' generated name, hide / unhide, a time-series createCollection, createView, a collMod
// validator, rename and drop. Hide / unhide and collMod need `dbAdmin` on `dblore_test`
// (docker/mongodb/init/01-users.js). Opt-in (`.requiresMongo`), serialized; every collection has
// a unique `admin_live_` name and is dropped before and after.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoAdminLiveTests {
  private typealias Field = MongoValue.Field

  /// A unique plain identifier, so `render()` writes `db.<name>` like the app does.
  private static func uniqueName() -> String {
    "admin_live_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
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

  private func indexes(
    _ manager: DatabaseConnectionManager, _ collection: String
  ) async throws -> [MongoIndexInfo] {
    let result = try await manager.fetchMongoIndexes(
      database: TestMongoDatabase.database, collection: collection)
    guard case .indexes(let list) = result else {
      Issue.record("Expected indexes on \(collection), got \(result)")
      return []
    }
    return list
  }

  private func info(
    _ manager: DatabaseConnectionManager, _ collection: String
  ) async throws -> MongoCollectionInfo {
    try await manager.fetchMongoCollectionInfo(
      database: TestMongoDatabase.database, collection: collection)
  }

  /// The value of `key` in a document, nil when absent or not a document.
  private func field(_ key: String, of value: MongoValue?) -> MongoValue? {
    guard case .document(let fields)? = value else { return nil }
    return fields.first { $0.key == key }?.value
  }

  @Test("createIndex without a name gets the generated name; hide then unhide", .requiresMongo)
  func indexHideUnhide() async throws {
    let name = Self.uniqueName()
    try await withManager([name]) { manager, epoch in
      let keys = MongoValue.document([Field("a", .int32(1)), Field("b", .int32(-1))])
      try await send(
        .createIndex(collection: name, keys: keys, options: nil), manager, epoch: epoch)
      let created = try await indexes(manager, name)
      #expect(created.map(\.name).contains("a_1_b_-1"), "\(created.map(\.name))")
      #expect(created.first { $0.name == "a_1_b_-1" }?.isHidden == false)

      try await send(
        .setIndexHidden(collection: name, name: "a_1_b_-1", hidden: true), manager, epoch: epoch)
      #expect(try await indexes(manager, name).first { $0.name == "a_1_b_-1" }?.isHidden == true)

      try await send(
        .setIndexHidden(collection: name, name: "a_1_b_-1", hidden: false), manager, epoch: epoch)
      #expect(try await indexes(manager, name).first { $0.name == "a_1_b_-1" }?.isHidden == false)
    }
  }

  @Test("createView on a collection is a view of it", .requiresMongo)
  func createView() async throws {
    let source = Self.uniqueName()
    let view = Self.uniqueName()
    try await withManager([view, source]) { manager, epoch in
      try await send(.createCollection(name: source, options: nil), manager, epoch: epoch)
      let pipeline = [MongoValue.document([Field("$match", .document([Field("a", .int32(1))]))])]
      try await send(
        .createView(name: view, source: source, pipeline: pipeline, options: nil), manager,
        epoch: epoch)
      let created = try await info(manager, view)
      #expect(created.type == "view")
      #expect(field("viewOn", of: created.options) == .string(source))
      #expect(field("pipeline", of: created.options) == .array(pipeline))
      #expect(
        try await manager.fetchMongoIndexes(database: TestMongoDatabase.database, collection: view)
          == .view)
    }
  }

  @Test(
    "Time-series createCollection, collMod validator, rename and drop reach the server",
    .requiresMongo)
  func collectionLifecycle() async throws {
    let series = Self.uniqueName()
    let name = Self.uniqueName()
    let renamed = Self.uniqueName()
    try await withManager([series, name, renamed]) { manager, epoch in
      // Time-series
      let timeseries = MongoValue.document([
        Field("timeseries", .document([Field("timeField", .string("ts"))]))
      ])
      try await send(.createCollection(name: series, options: timeseries), manager, epoch: epoch)
      let seriesInfo = try await info(manager, series)
      #expect(seriesInfo.type == "timeseries")
      #expect(
        field("timeField", of: field("timeseries", of: seriesInfo.options)) == .string("ts"))

      // collMod validator
      try await send(.createCollection(name: name, options: nil), manager, epoch: epoch)
      let validator = MongoValue.document([
        Field("$jsonSchema", .document([Field("required", .array([.string("name")]))]))
      ])
      try await send(
        .collMod(
          collection: name,
          options: .document([
            Field("validator", validator), Field("validationLevel", .string("moderate")),
          ])),
        manager, epoch: epoch)
      let modified = try await info(manager, name)
      #expect(modified.type == "collection")
      #expect(field("validator", of: modified.options) == validator)
      #expect(field("validationLevel", of: modified.options) == .string("moderate"))

      // Rename: the new name exists, the old one is gone
      try await send(.renameCollection(collection: name, to: renamed), manager, epoch: epoch)
      #expect(field("validator", of: try await info(manager, renamed).options) == validator)
      await #expect(throws: (any Error).self) { try await info(manager, name) }

      // Drop
      try await send(.drop(collection: renamed), manager, epoch: epoch)
      await #expect(throws: (any Error).self) { try await info(manager, renamed) }
      try await send(.drop(collection: series), manager, epoch: epoch)
      await #expect(throws: (any Error).self) { try await info(manager, series) }
    }
  }
}
