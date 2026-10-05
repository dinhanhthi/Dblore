// ViewModelHistoryRecordingTests.swift
// Query history recording: one entry per user statement, never internal queries,
// password statements, or a disabled history setting. Kind follows the SQL text.

import Foundation
import Testing

@testable import Dblore

@Suite("View model history recording")
@MainActor
struct ViewModelHistoryRecordingTests {
  @Test("A cell run records one entry")
  func cellRunRecordsOneEntry() async throws {
    try await withViewModel(connectionName: "Prod") { viewModel, recorder in
      await viewModel.recordExecution(
        [outcome("SELECT 1", duration: 0.012, rowCount: 1)],
        source: .cell)

      let entries = await recorder.entries
      #expect(entries.count == 1)
      let entry = try #require(entries.first)
      #expect(entry.sql == "SELECT 1")
      #expect(entry.source == .cell)
      #expect(entry.status == .success)
      #expect(entry.rowCount == 1)
      #expect(entry.durationMs == 12)
      #expect(entry.errorMessage == nil)
      #expect(entry.connectionKey == "PostgreSQL|localhost|5432|app|ana")
      #expect(!entry.connectionKey.contains("secret-db"))
      #expect(entry.connectionLabel == "Prod")
      #expect(entry.workspaceID == Self.workspaceID)
      #expect(entry.workspaceName == "Analytics")
    }
  }

  @Test("A multi-statement run records one entry per statement")
  func multiStatementRunRecordsEachStatement() async throws {
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [
          outcome("SELECT a", rowCount: 2),
          outcome("UPDATE t SET n = 1", rowCount: 4),
        ],
        source: .cell)

      let entries = await recorder.entries
      #expect(entries.map(\.sql) == ["SELECT a", "UPDATE t SET n = 1"])
      #expect(entries.map(\.rowCount) == [2, 4])
      #expect(entries.allSatisfy { $0.source == .cell && $0.status == .success })
    }
  }

  @Test("An editor run records the editor source")
  func editorRunRecordsEditorSource() async throws {
    try await withViewModel(connectionName: "") { viewModel, recorder in
      await viewModel.recordExecution(
        [outcome("SELECT * FROM events")],
        source: .editor)

      let entries = await recorder.entries
      let entry = try #require(entries.first)
      #expect(entries.count == 1)
      #expect(entry.source == .editor)
      #expect(entry.sql == "SELECT * FROM events")
      #expect(entry.connectionLabel == "localhost/app")
    }
  }

  @Test("A data viewer page load is not recorded")
  func dataViewerPageLoadIsNotRecorded() async throws {
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [outcome("SELECT * FROM public.events LIMIT 100")],
        source: .internal)
      await viewModel.recordExecution(
        [outcome("SELECT COUNT(*) FROM public.events")],
        source: .internal)

      #expect(await recorder.entries.isEmpty)
    }
  }

  @Test("A password statement is not recorded")
  func passwordStatementIsSkipped() async throws {
    let secret = "CREATE ROLE analyst WITH ENCRYPTED PASSWORD 'hunter2-do-not-store'"
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [
          outcome("SELECT 1", rowCount: 1),
          outcome(secret, rowCount: 0),
        ],
        source: .cell)

      let entries = await recorder.entries
      #expect(entries.map(\.sql) == ["SELECT 1"])
      #expect(entries.allSatisfy { !$0.sql.localizedCaseInsensitiveContains("hunter2") })
      #expect(entries.allSatisfy { !$0.sql.localizedCaseInsensitiveContains("PASSWORD") })
    }
  }

  @Test("Disabled history records nothing")
  func historyDisabledRecordsNothing() async throws {
    try await withViewModel(enabled: false) { viewModel, recorder in
      await viewModel.recordExecution(
        [outcome("SELECT 1")],
        source: .cell)

      #expect(await recorder.entries.isEmpty)
    }
  }

  @Test("SELECT, UPDATE, CREATE, and a write-then-read script get read, write, schema, write")
  func statementKindFollowsClassification() async throws {
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [
          outcome("SELECT 1"),
          outcome("UPDATE t SET n = 1"),
          outcome("CREATE TABLE t (id int)"),
          outcome("UPDATE t SET n = 1; SELECT a"),
        ],
        source: .cell)

      let entries = await recorder.entries
      #expect(entries.map(\.kind) == [.read, .write, .schema, .write])
      #expect(entries.count == 4)
    }
  }

  @Test("Blank and comment-only SQL is stored with no kind")
  func blankAndCommentStayUnclassified() async throws {
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [outcome("   "), outcome("-- only")],
        source: .editor)

      let entries = await recorder.entries
      #expect(entries.map(\.sql) == ["   ", "-- only"])
      #expect(entries.allSatisfy { $0.kind == nil })
    }
  }

  @Test("PRAGMA kind follows the connection dialect")
  func pragmaKindFollowsDialect() async throws {
    try await withViewModel { viewModel, recorder in
      var config = try #require(viewModel.notebook.connectionConfig)
      config.databaseType = .sqlite
      viewModel.notebook.connectionConfig = config
      await viewModel.recordExecution([outcome("PRAGMA foreign_keys")], source: .editor)

      #expect(await recorder.entries.first?.kind == .read)
    }
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution([outcome("PRAGMA foreign_keys")], source: .editor)

      #expect(await recorder.entries.first?.kind == .other)
    }
  }

  @Test("A failed statement records an error status")
  func failedStatementRecordsError() async throws {
    try await withViewModel { viewModel, recorder in
      await viewModel.recordExecution(
        [
          outcome(
            "SELECT * FROM missing",
            duration: 0.004,
            rowCount: nil,
            status: .error,
            errorMessage: "relation \"missing\" does not exist")
        ],
        source: .cell)

      let entries = await recorder.entries
      let entry = try #require(entries.first)
      #expect(entries.count == 1)
      #expect(entry.status == .error)
      #expect(entry.errorMessage == "relation \"missing\" does not exist")
      #expect(entry.rowCount == nil)
      #expect(entry.sql == "SELECT * FROM missing")
      #expect(entry.durationMs == 4)
    }
  }

  private static let workspaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  private func outcome(
    _ sql: String,
    duration: TimeInterval = 0.01,
    rowCount: Int? = 1,
    status: QueryHistoryEntry.Status = .success,
    errorMessage: String? = nil
  ) -> QueryHistoryOutcome {
    QueryHistoryOutcome(
      sql: sql, duration: duration, rowCount: rowCount, status: status,
      errorMessage: errorMessage)
  }

  private func withViewModel(
    enabled: Bool = true,
    connectionName: String = "Prod",
    _ body: @MainActor (NotebookViewModel, FakeQueryHistoryRecorder) async throws -> Void
  ) async throws {
    let suiteName = "ViewModelHistoryRecordingTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    defer { suite.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = enabled
    let recorder = FakeQueryHistoryRecorder()
    let viewModel = NotebookViewModel()
    viewModel.historyRecorder = recorder
    viewModel.historySettings = settings
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "secret-db",
      name: connectionName)
    viewModel.historyWorkspace = { (id: Self.workspaceID, name: "Analytics") }
    try await body(viewModel, recorder)
  }
}

/// Appends recorded entries. The view-model tests inject this instead of `QueryHistoryStore`.
private actor FakeQueryHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}
