// MongoHistoryTests.swift
// Query history of MongoDB cells through the real recording path (runCell → manager →
// recordResults): one entry per split piece with the original text (not the limit-rewritten
// text that is sent), kinds from `historyKind(StatementKind)` (reads → read, writes and
// `$merge` → write, `$out` → schema) and a `MongoDB|` connection key. Fake session, no database.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB query history")
@MainActor
struct MongoHistoryTests {
  /// Appends recorded entries in place of `QueryHistoryStore`.
  private actor Recorder: QueryHistoryRecording {
    private(set) var entries: [QueryHistoryEntry] = []

    func record(_ entry: QueryHistoryEntry) async {
      entries.append(entry)
    }
  }

  /// Runs `body` with a view model on a fake MongoDB session (Protected mode off, Immediate,
  /// so no confirmation stops the run) recording into `Recorder`.
  private func withViewModel(
    cell: String,
    _ body: (NotebookViewModel, FakeDatabaseSessionFactory, Recorder) async throws -> Void
  ) async throws {
    let suiteName = "MongoHistoryTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true

    var config = ConnectionConfig(
      databaseType: .mongodb, host: "mongo.local", port: 27017, database: "shop",
      username: "ana", password: "secret-db", sslMode: .disable)
    config.protectedMode = false
    config.applyCommitStyle(.immediate)
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities,
      columns: [ColumnInfo(name: "_id", type: "objectId")],
      rows: [[.string("0123456789abcdef01234567")]])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)

    let recorder = Recorder()
    let viewModel = NotebookViewModel()
    viewModel.historyRecorder = recorder
    viewModel.historySettings = settings
    viewModel.notebook.connectionConfig = config
    viewModel.notebook.cells = [NotebookCell(cellType: .sql, content: cell)]
    viewModel.toastPresenter = { _, _ in }
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected

    await viewModel.runCell(id: viewModel.notebook.cells[0].id)
    await viewModel.executionQueue.waitForIdle()
    #expect(viewModel.notebook.cells[0].result?.error == nil)
    try await body(viewModel, factory, recorder)
    await manager.disconnect()
  }

  /// History is written on a detached task after the run: waits until `count` entries arrived.
  private func entries(_ recorder: Recorder, count: Int) async throws -> [QueryHistoryEntry] {
    for _ in 0..<200 {
      let entries = await recorder.entries
      if entries.count >= count { return entries }
      try await Task.sleep(for: .milliseconds(10))
    }
    return await recorder.entries
  }

  @Test("Each piece of a cell is recorded with its original text and its kind")
  func kindsPerPiece() async throws {
    let pieces: [(text: String, kind: QueryHistoryEntry.Kind)] = [
      ("db.users.find({a: 1}).limit(50) // all", .read),
      ("db.users.countDocuments({a: 1})", .read),
      ("db.users.distinct(\"a\")", .read),
      ("db.users.aggregate([{$match: {a: 1}}])", .read),
      ("db.users.insertOne({a: 1})", .write),
      ("db.users.insertMany([{a: 2}, {a: 3}])", .write),
      ("db.users.updateMany({}, {$set: {b: 1}})", .write),
      ("db.users.replaceOne({_id: 1}, {a: 2})", .write),
      ("db.users.deleteOne({a: 1})", .write),
      ("db.users.deleteMany({})", .write),
      ("db.users.aggregate([{$match: {}}, {$merge: {into: \"other\"}}])", .write),
      ("db.users.aggregate([{$match: {}}, {$out: \"copy\"}])", .schema),
    ]
    let cell = pieces.map(\.text).joined(separator: "\n")
    try await withViewModel(cell: cell) { viewModel, factory, recorder in
      #expect(factory.statements.count == pieces.count)
      let entries = try await entries(recorder, count: pieces.count)
      #expect(entries.map(\.sql) == pieces.map(\.text))
      #expect(entries.map(\.kind) == pieces.map(\.kind))
      #expect(entries.allSatisfy { $0.source == .cell && $0.status == .success })
      #expect(entries.allSatisfy { $0.connectionKey == "MongoDB|mongo.local|27017|shop|ana" })
    }
  }

  @Test("A find is sent with the capped limit; history keeps the text the user wrote")
  func originalTextRecorded() async throws {
    let find = "db['users'].find({a: 1}).limit(5000) // newest"
    try await withViewModel(cell: find) { viewModel, factory, recorder in
      let sent = try MongoCommandRewriter.withLimit(
        text: find, maxRows: viewModel.effectiveRowCap)
      #expect(sent != find)
      #expect(factory.statements == [sent])
      let entries = try await entries(recorder, count: 1)
      #expect(entries.map(\.sql) == [find])
      #expect(entries.first?.kind == .read)
      #expect(entries.first?.connectionKey.hasPrefix("MongoDB|") == true)
    }
  }
}
