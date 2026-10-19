// MongoBackupModelTests.swift
// MongoBackupModel's restore on a fake MongoDB session: a bad line anywhere stops the restore
// before anything is sent, a collision needs Drop existing first and the typed database name,
// the typed commands go out in restore order (drops, create, documents, indexes, validator,
// views after their sources), a read-only connection refuses before the open panel, and a
// header that runs server-side JavaScript or a file changed after the check sends nothing.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MongoBackupModelTests")
struct MongoBackupModelTests {
  typealias Field = MongoValue.Field

  private final class Log {
    var entries: [QueryHistoryEntry] = []
    var openPanels = 0
  }

  private func makeModel(
    level: ConnectionProtectionLevel = .none, commitStyle: CommitStyle = .immediate,
    existing: Set<String> = [], openURL: URL? = nil, log: Log
  ) async throws -> (MongoBackupModel, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent)
    try await manager.connect(config: config)
    let environment = MongoBackupModel.Environment(
      chooseSaveURL: { _ in nil },
      chooseOpenURL: {
        log.openPanels += 1
        return openURL
      },
      existingNames: { _, names, _ in existing.intersection(names) })
    let model = MongoBackupModel(
      context: MongoBackupModel.Context(
        manager: manager, policy: ProtectionPolicy(config: config),
        commitStyle: { commitStyle }, caller: nil, database: "db", config: config,
        recordHistory: { log.entries.append($0) }, onRestored: {}),
      connectionEpoch: await manager.connectionEpoch, environment: environment)
    return (model, factory)
  }

  private func header(
    count: Int64, options: MongoValue = .document([]), validator: MongoValue? = nil,
    indexes: [MongoValue] = [], views: [MongoBackupHeader.View] = []
  ) -> MongoBackupHeader {
    MongoBackupHeader(
      database: "db", createdAt: 0,
      collections: [
        MongoBackupHeader.Collection(
          name: "items", options: options, validator: validator, indexes: indexes, count: count)
      ],
      views: views)
  }

  /// A backup of `header` with `count` documents `{_id: i}` of items; `badLine` replaces that
  /// line of the file
  private func backupFile(
    _ header: MongoBackupHeader, badLine: Int? = nil, at existing: URL? = nil
  ) throws -> URL {
    let url: URL
    if let existing {
      url = existing
    } else {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MongoBackupModelTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      url = folder.appendingPathComponent("db.ndjson")
    }
    var lines = [MongoBackupFormat.headerLine(header)]
    for index in 0..<header.collections[0].count {
      lines.append(
        MongoBackupFormat.documentLine(
          collection: "items", document: .document([Field("_id", .int64(index))])))
    }
    if let badLine { lines[badLine - 1] = "{oops" }
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    return url
  }

  private func removeFolder(of url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("A bad line 40 stops the restore before anything is sent")
  func badLineSendsNothing() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(log: log)
    let url = try backupFile(header(count: 50), badLine: 40)
    defer { removeFolder(of: url) }
    await model.loadRestore(url: url)

    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(message.contains("Line 40"))
    await model.requestRestore(dropExisting: true)
    #expect(factory.typedCommands.isEmpty)
    #expect(log.entries.isEmpty)
  }

  @Test(
    "A header that runs server-side JavaScript, or a view that writes or reads outside, sends nothing"
  )
  func unsafeHeaderSendsNothing() async throws {
    func view(_ stage: MongoValue) -> [MongoBackupHeader.View] {
      [
        MongoBackupHeader.View(
          name: "v", viewOn: "items", pipeline: [stage], options: .document([]))
      ]
    }
    let function = MongoValue.document([
      Field(
        "$addFields",
        .document([
          Field(
            "x",
            .document([
              Field(
                "$function",
                .document([
                  Field("body", .string("function() { return 1 }")), Field("args", .array([])),
                  Field("lang", .string("js")),
                ]))
            ]))
        ]))
    ])
    let headers = [
      header(count: 1, views: view(function)),
      header(
        count: 1,
        validator: .document([
          Field("validator", .document([Field("$where", .string("this.a > 1"))]))
        ])),
      header(count: 1, views: view(.document([Field("$out", .string("copy"))]))),
      header(
        count: 1,
        views: view(
          .document([
            Field(
              "$lookup",
              .document([
                Field(
                  "from",
                  .document([Field("db", .string("other")), Field("coll", .string("x"))])),
                Field("as", .string("y")), Field("pipeline", .array([])),
              ]))
          ]))),
      header(
        count: 1,
        views: view(
          .document([
            Field(
              "$facet",
              .document([
                Field("a", .array([.document([Field("$unionWith", .string("system.users"))])]))
              ]))
          ]))),
      header(
        count: 1,
        views: view(
          .document([
            Field(
              "$lookup",
              .document([
                Field("from", .string("items")), Field("from", .string("system.profile")),
                Field("as", .string("y")), Field("pipeline", .array([])),
              ]))
          ]))),
    ]
    for header in headers {
      let log = Log()
      let (model, factory) = try await makeModel(log: log)
      let url = try backupFile(header)
      defer { removeFolder(of: url) }
      await model.loadRestore(url: url)

      guard case .failed(let message) = model.state else {
        Issue.record("Expected failed, got \(model.state)")
        continue
      }
      #expect(message.hasPrefix("Line 1: "))
      #expect(message.contains("Dblore does not restore it"))
      await model.requestRestore(dropExisting: true)
      #expect(factory.typedCommands.isEmpty)
      #expect(log.entries.isEmpty)
    }
  }

  @Test("A file changed after it was checked is refused before the drops")
  func changedFileSendsNothing() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(existing: ["items"], log: log)
    let url = try backupFile(header(count: 2))
    defer { removeFolder(of: url) }
    await model.loadRestore(url: url)
    await model.requestRestore(dropExisting: true)
    guard case .confirming(let confirmation) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    _ = try backupFile(header(count: 3), at: url)

    await model.confirm(confirmation, typedName: "db")

    #expect(factory.typedCommands.isEmpty)
    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(message.contains("changed since it was checked"))
  }

  @Test("A colliding target needs Drop existing first and the typed database name")
  func collisionNeedsTypedDatabaseName() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(existing: ["items"], log: log)
    let url = try backupFile(header(count: 2))
    defer { removeFolder(of: url) }
    await model.loadRestore(url: url)
    #expect(model.collisions == ["items"])

    await model.requestRestore(dropExisting: false)
    guard case .failed = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(factory.typedCommands.isEmpty)

    await model.requestRestore(dropExisting: true)
    guard case .confirming(let confirmation) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    #expect(confirmation.typedName == "db")
    await model.confirm(confirmation, typedName: "")
    #expect(factory.typedCommands.isEmpty)
    #expect(model.isPending(confirmation))

    await model.confirm(confirmation, typedName: "db")
    #expect(factory.typedCommands.first == .admin(.drop(collection: "items")))
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
  }

  @Test("Typed commands go out as drops, create, inserts, indexes, collMod, views")
  func commandOrder() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(existing: ["items"], log: log)
    let rules = MongoValue.document([
      Field("validator", .document([Field("a", .document([Field("$exists", .bool(true))]))])),
      Field("validationLevel", .string("strict")),
    ])
    let index = MongoValue.document([
      Field("v", .int32(2)), Field("key", .document([Field("a", .int32(1))])),
      Field("name", .string("a_1")), Field("unique", .bool(true)), Field("bits", .int32(26)),
      Field("ns", .string("db.items")),
    ])
    // The dependent view comes first: it must be created after its source
    let views = [
      MongoBackupHeader.View(
        name: "recent", viewOn: "active", pipeline: [], options: .document([])),
      MongoBackupHeader.View(
        name: "active", viewOn: "items", pipeline: [], options: .document([])),
    ]
    let url = try backupFile(
      header(
        count: 3,
        options: .document([
          Field("capped", .bool(true)), Field("size", .int64(4096)),
          Field("storageEngine", .document([])),
        ]),
        validator: rules, indexes: [index], views: views))
    defer { removeFolder(of: url) }
    await model.loadRestore(url: url)
    await model.requestRestore(dropExisting: true)
    guard case .confirming(let confirmation) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    await model.confirm(confirmation, typedName: "db")

    let documents = (0..<3).map { MongoValue.document([Field("_id", .int64(Int64($0)))]) }
    #expect(
      factory.typedCommands == [
        .admin(.drop(collection: "items")),
        .admin(
          .createCollection(
            name: "items",
            options: .document([Field("capped", .bool(true)), Field("size", .int64(4096))]))),
        .insertMany(collection: "items", documents: documents),
        .admin(
          .createIndex(
            collection: "items", keys: .document([Field("a", .int32(1))]),
            options: .document([
              Field("name", .string("a_1")), Field("unique", .bool(true)),
              Field("bits", .int32(26)),
            ]))),
        .admin(.collMod(collection: "items", options: rules)),
        .admin(.createView(name: "active", source: "items", pipeline: [], options: nil)),
        .admin(.createView(name: "recent", source: "active", pipeline: [], options: nil)),
      ])
    #expect(log.entries.map(\.sql) == ["Restore MongoDB backup: 1 collection, 3 documents"])
    #expect(log.entries.first?.source == .restore)
  }

  @Test("Safe Mode holds the restore until confirmed, and a finished restore never runs again")
  func safeModeHoldsAndNoRerun() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .confirm, log: log)
    let url = try backupFile(header(count: 2))
    defer { removeFolder(of: url) }
    await model.loadRestore(url: url)

    await model.requestRestore(dropExisting: false)
    guard case .confirming(let first) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    #expect(first.typedName == nil)
    model.cancel()
    #expect(model.state == .idle)
    await model.confirm(first)
    #expect(factory.typedCommands.isEmpty)

    await model.requestRestore(dropExisting: false)
    guard case .confirming(let second) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    await model.confirm(second)
    let sent = factory.typedCommands.count
    #expect(sent == 2)
    await model.requestRestore(dropExisting: false)
    #expect(factory.typedCommands.count == sent)
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
  }

  @Test("Read-only refuses before the open panel and sends nothing")
  func readOnlyRefusesBeforeAnyPrompt() async throws {
    let log = Log()
    let url = try backupFile(header(count: 1))
    defer { removeFolder(of: url) }
    let (model, factory) = try await makeModel(
      level: .readOnly, commitStyle: .confirm, openURL: url, log: log)
    await model.chooseRestoreFile()

    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(!message.isEmpty)
    #expect(log.openPanels == 0)
    #expect(factory.typedCommands.isEmpty)
    #expect(log.entries.isEmpty)
  }
}
