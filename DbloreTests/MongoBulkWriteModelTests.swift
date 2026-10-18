// MongoBulkWriteModelTests.swift
// MongoBulkWriteModel on a fake MongoDB session: the preview counts through the gated read, the
// run always asks a second step (the typed name when the filter is empty or the count is
// unknown or >= 1,000, the Safe Mode panel or the inline Confirm step), then sends updateMany /
// deleteMany through the sequential gate and reports the counts of the reply.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MongoBulkWriteModelTests")
struct MongoBulkWriteModelTests {
  private final class Log {
    var outcomes: [QueryHistoryOutcome] = []
    var reloads = 0
    var staged = false
  }

  private static func config(level: ConnectionProtectionLevel = .none) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent, protectedMode: false)
  }

  /// A model on collection `items` whose preview counts `count` documents (a failing count
  /// when nil) and whose writes match `matched` and modify `modified` documents.
  private func makeModel(
    commitStyle: CommitStyle, count: Int? = 12, matched: Int = 12, modified: Int? = nil,
    level: ConnectionProtectionLevel = .none, filter: String = "{a: 1}", log: Log
  ) async throws -> (MongoBulkWriteModel, FakeDatabaseSessionFactory, DatabaseConnectionManager) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities,
      columns: [ColumnInfo(name: "count", type: "int")], rows: [[.int(count ?? 0)]],
      failingQuery: count == nil ? "countDocuments" : nil,
      commandRows: { _ in matched }, commandModifiedRows: { _ in modified })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.config(level: level)
    try await manager.connect(config: config)
    let model = MongoBulkWriteModel(
      context: MongoAdminContext(
        manager: manager, policy: ProtectionPolicy(config: config),
        commitStyle: { commitStyle }, caller: nil,
        recordHistory: { log.outcomes += $0 }),
      collection: "items", filterText: filter,
      hasStagedEdits: { log.staged },
      onStatementsExecuted: { log.reloads += 1 })
    return (model, factory, manager)
  }

  /// Statements other than the preview count
  private func writes(_ factory: FakeDatabaseSessionFactory) -> [String] {
    factory.statements.filter { !$0.contains("countDocuments") }
  }

  private func confirmation(_ model: MongoBulkWriteModel) -> MongoBulkWriteModel.Confirmation? {
    if case .confirming(let pending) = model.state { return pending }
    Issue.record("Expected confirming, got \(model.state)")
    return nil
  }

  @Test("Under Immediate a narrow filter still shows the Confirm step; the run reports counts")
  func immediateShowsConfirmStep() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(
      commitStyle: .immediate, matched: 12, modified: 10, log: log)
    model.updateText = "{$set: {b: 2}}"
    await model.preview()
    #expect(model.state == .ready(count: 12))
    #expect(factory.statements == [#"db.items.countDocuments({ a: 1 }, { maxTimeMS: 30000 })"#])

    await model.run()
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == nil)
    #expect(!pending.needsSafeModePanel)
    #expect(pending.question == "Update 12 documents?")
    #expect(writes(factory).isEmpty)

    await model.confirm(pending)
    let text = #"db.items.updateMany({ a: 1 }, { $set: { b: 2 } })"#
    #expect(writes(factory) == [text])
    #expect(
      model.state
        == .done(.init(mode: .update, matched: 12, modified: 10, previewCount: 12)))
    #expect(log.outcomes.map(\.sql) == [text])
    #expect(log.outcomes.map(\.status) == [.success])
    #expect(log.reloads == 1)
  }

  @Test("An empty filter asks for the typed name and sends nothing before it matches")
  func emptyFilterNeedsTypedName() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(
      commitStyle: .confirm, filter: "{}", log: log)
    model.mode = .delete
    await model.preview()
    await model.run()
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == "items")
    #expect(writes(factory).isEmpty)
    #expect(pending.needsSafeModePanel)
    // The existing all-rows warning of an empty filter stays
    #expect(pending.affectsAllRows)

    await model.confirm(pending, typedName: "Items")
    #expect(writes(factory).isEmpty)
    #expect(model.isPending(pending))

    await model.confirm(pending, typedName: "items")
    #expect(writes(factory) == ["db.items.deleteMany({})"])
    #expect(
      model.state == .done(.init(mode: .delete, matched: 12, modified: nil, previewCount: 12)))
  }

  @Test("An unknown count (failed, cancelled, stale or no preview) requires the typed name")
  func unknownCountNeedsTypedName() async throws {
    let log = Log()
    let (failed, _, _) = try await makeModel(commitStyle: .immediate, count: nil, log: log)
    failed.mode = .delete
    await failed.preview()
    #expect(failed.state == .ready(count: nil))
    await failed.run()
    #expect(confirmation(failed)?.typedName == "items")

    let (unpreviewed, _, _) = try await makeModel(commitStyle: .immediate, log: log)
    unpreviewed.mode = .delete
    await unpreviewed.run()
    #expect(confirmation(unpreviewed)?.typedName == "items")

    let (stale, _, _) = try await makeModel(commitStyle: .immediate, log: log)
    stale.mode = .delete
    await stale.preview()
    stale.filterText = "{a: 2}"
    await stale.run()
    #expect(confirmation(stale)?.typedName == "items")

    let (large, _, _) = try await makeModel(commitStyle: .immediate, count: 1000, log: log)
    large.mode = .delete
    await large.preview()
    await large.run()
    #expect(confirmation(large)?.typedName == "items")
  }

  @Test("Cancelling the preview leaves the count unknown; its late answer is dropped")
  func cancelPreview() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(commitStyle: .immediate, log: log)
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    let (started, didStart) = AsyncStream.makeStream(of: Void.self)
    factory.sessions.last?.onNextQuery { _ in
      didStart.yield()
      for await _ in gate {}
    }
    let preview = Task { await model.preview() }
    for await _ in started { break }
    #expect(model.state == .previewing)
    model.cancel()
    #expect(model.state == .ready(count: nil))
    release.finish()
    await preview.value
    #expect(model.state == .ready(count: nil))
  }

  @Test("A read-only connection refuses the run before any prompt")
  func readOnlyRefuses() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(
      commitStyle: .confirm, level: .readOnly, log: log)
    model.mode = .delete
    await model.run()
    #expect(model.state == .failed("Data modification is not allowed on a read-only connection"))
    #expect(writes(factory).isEmpty)
  }

  @Test("A replacement-style update is refused with the parser's message")
  func replacementRefused() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(commitStyle: .immediate, log: log)
    model.updateText = "{b: 2}"
    await model.run()
    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(message.contains("update operators"))
    #expect(factory.statements.isEmpty)
  }

  @Test("Staged document edits refuse the run")
  func stagedEditsRefuse() async throws {
    let log = Log()
    log.staged = true
    let (model, factory, _) = try await makeModel(commitStyle: .immediate, log: log)
    model.mode = .delete
    await model.run()
    #expect(model.state == .failed(MongoBulkWriteModel.stagedEditsRefusal))
    #expect(factory.statements.isEmpty)
  }

  @Test("A reconnect since the preview refuses the run; the next run asks the typed name and sends")
  func reconnectRefuses() async throws {
    let log = Log()
    let (model, factory, manager) = try await makeModel(commitStyle: .immediate, log: log)
    model.mode = .delete
    await model.preview()
    try await manager.connect(config: Self.config())
    await model.run()
    let pending = try #require(confirmation(model))
    await model.confirm(pending)
    #expect(
      model.state
        == .failed(
          "The connection changed since the preview; nothing was sent. Preview again to count."))
    #expect(writes(factory).isEmpty)
    #expect(log.outcomes.map(\.status) == [.error])

    // Dismissed: the stale count is gone, so the next run reads the current epoch and, the
    // count being unknown, asks for the typed name
    model.cancel()
    await model.run()
    let retry = try #require(confirmation(model))
    #expect(retry.count == nil)
    #expect(retry.typedName == "items")
    await model.confirm(retry, typedName: "items")
    #expect(writes(factory) == [#"db.items.deleteMany({ a: 1 })"#])
    #expect(log.outcomes.map(\.status) == [.error, .success])
  }

  @Test("A cancelled or replaced confirmation never sends, even with the right typed name")
  func lateConfirmationSendsNothing() async throws {
    let log = Log()
    let (model, factory, _) = try await makeModel(commitStyle: .immediate, log: log)
    model.mode = .delete
    await model.preview()
    await model.run()
    let first = try #require(confirmation(model))
    model.cancel()
    await model.confirm(first, typedName: "items")
    #expect(writes(factory).isEmpty)
    #expect(model.state == .ready(count: 12))

    await model.run()
    let second = try #require(confirmation(model))
    await model.confirm(first, typedName: "items")
    #expect(writes(factory).isEmpty)
    #expect(model.isPending(second))
    #expect(log.outcomes.isEmpty)
  }

  @Test("A count that changed since the preview is noted with the result")
  func countChangedNote() async throws {
    let log = Log()
    let (model, _, _) = try await makeModel(commitStyle: .immediate, matched: 15, log: log)
    model.mode = .delete
    await model.preview()
    await model.run()
    let pending = try #require(confirmation(model))
    await model.confirm(pending)
    guard case .done(let result) = model.state else {
      Issue.record("Expected done, got \(model.state)")
      return
    }
    #expect(result.note == "The preview counted 12 documents; the run deleted 15.")
    #expect(
      MongoBulkWriteModel.BulkWriteResult(
        mode: .delete, matched: 12, modified: nil, previewCount: 12
      ).note == nil)
  }
}
