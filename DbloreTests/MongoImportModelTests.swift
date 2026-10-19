// MongoImportModelTests.swift
// MongoImportModel on a fake MongoDB session: refuses up front on protected connections and on
// an empty file, creates a new target collection first, then sends the documents in insert
// batches through the typed write gate and stops at the first failing batch with the exact
// number of documents imported. Safe Mode holds every send until confirmed, and an import that
// ran is never sent again before the file is loaded again.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MongoImportModelTests")
struct MongoImportModelTests {
  private final class Log {
    var outcomes: [QueryHistoryOutcome] = []
    var finished = 0
  }

  private func makeModel(
    level: ConnectionProtectionLevel = .none, commitStyle: CommitStyle = .immediate,
    failTypedAt: Int? = nil, typedError: any Error = FakeQueryError(), log: Log
  ) async throws -> (MongoImportModel, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, failTypedAt: failTypedAt,
      typedError: typedError)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent)
    try await manager.connect(config: config)
    let model = MongoImportModel(
      context: MongoAdminContext(
        manager: manager, policy: ProtectionPolicy(config: config),
        commitStyle: { commitStyle }, caller: nil,
        recordHistory: { log.outcomes += $0 }, database: config.database),
      connectionEpoch: await manager.connectionEpoch,
      onFinished: { log.finished += 1 })
    return (model, factory)
  }

  /// An NDJSON file of `count` documents `{"_id": i}` in a fresh temporary folder
  private func ndjsonFile(count: Int) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MongoImportModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("data.ndjson")
    let text = (0..<count).map { "{\"_id\": \($0)}" }.joined(separator: "\n")
    try Data(text.utf8).write(to: url)
    return url
  }

  private func removeFolder(of url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("A failing second batch reports the exact count and the third batch is never sent")
  func failingBatchStops() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(failTypedAt: 1, log: log)
    let url = try ndjsonFile(count: 2500)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .existing("items"))

    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(message.hasPrefix("Imported 1000 of 2500 documents; batch 2 failed: "))
    #expect(factory.typedCommands.count == 2)
    #expect(log.outcomes.count == 1)
    #expect(log.outcomes.first?.sql == "// Imported 1000 documents into items from data.ndjson")
    #expect(log.outcomes.first?.status == .error)
    #expect(log.finished == 1)
  }

  @Test("A failing batch counts the documents the server wrote before its error")
  func failingBatchCountsWrittenDocuments() async throws {
    let log = Log()
    let (model, _) = try await makeModel(
      failTypedAt: 1,
      typedError: MongoSessionError(
        code: 11000, codeName: "DuplicateKey", message: "E11000 duplicate key", written: 499),
      log: log)
    let url = try ndjsonFile(count: 2500)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .existing("items"))

    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(message.hasPrefix("Imported 1499 of 2500 documents; batch 2 failed: "))
    #expect(log.outcomes.first?.sql == "// Imported 1499 documents into items from data.ndjson")
    #expect(log.outcomes.first?.rowCount == 1499)
  }

  @Test("Read-only refuses before any prompt and sends nothing")
  func readOnlyRefusesUpFront() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(level: .readOnly, commitStyle: .confirm, log: log)
    let url = try ndjsonFile(count: 3)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .existing("items"))

    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(!message.isEmpty)
    #expect(factory.typedCommands.isEmpty)
    #expect(log.outcomes.isEmpty)
  }

  @Test("A new collection is created first, then the documents are inserted")
  func newCollectionCreatedFirst() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(log: log)
    let url = try ndjsonFile(count: 3)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .new("fresh"))

    let sent = factory.typedCommands
    #expect(sent.count == 2)
    #expect(sent.first == .admin(.createCollection(name: "fresh", options: nil)))
    guard case .insertMany(let collection, let documents)? = sent.last else {
      Issue.record("Expected an insertMany, got \(String(describing: sent.last))")
      return
    }
    #expect(collection == "fresh")
    #expect(documents.count == 3)
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
  }

  @Test("A second Import after a finished one sends nothing until the file is loaded again")
  func secondRequestAfterDoneSendsNothing() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(log: log)
    let url = try ndjsonFile(count: 3)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .existing("items"))
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
    await model.request(target: .existing("items"))

    #expect(factory.typedCommands.count == 1)
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
  }

  @Test("Safe Mode holds the import until confirmed; cancel or a stale confirmation sends nothing")
  func safeModeConfirmationHolds() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .confirm, log: log)
    let url = try ndjsonFile(count: 3)
    defer { removeFolder(of: url) }
    await model.load(url: url)

    await model.request(target: .existing("items"))
    guard case .confirming(let first) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    model.cancel()
    #expect(model.state == .idle)
    await model.confirm(first)
    #expect(factory.typedCommands.isEmpty)

    await model.request(target: .existing("items"))
    guard case .confirming(let second) = model.state else {
      Issue.record("Expected confirming, got \(model.state)")
      return
    }
    await model.confirm(first)
    #expect(factory.typedCommands.isEmpty)
    #expect(model.isPending(second))
    await model.confirm(second)
    #expect(factory.typedCommands.count == 1)
    guard case .done = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
  }

  @Test("An empty file is refused and nothing is sent")
  func emptyImportRefused() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(log: log)
    let url = try ndjsonFile(count: 0)
    defer { removeFolder(of: url) }
    await model.load(url: url)
    await model.request(target: .existing("items"))

    guard case .failed = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(factory.typedCommands.isEmpty)
  }
}
