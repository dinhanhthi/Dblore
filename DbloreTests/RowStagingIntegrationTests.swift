// RowStagingIntegrationTests.swift
// Staged insert, edit, and delete against the docker test database (port 5435).

import Foundation
import Testing

@testable import Dblore

@Suite("Row Staging - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct RowStagingIntegrationTests {
  @Test("Insert, edit, and delete commit together and the table matches", .timeLimit(.minutes(1)))
  func commitAppliesTheWholeBatch() async throws {
    try await withViewer(
      table: "p74_commit", protectedMode: false,
      ddl: "CREATE TABLE p74_commit (id int PRIMARY KEY, name text)",
      seed: "INSERT INTO p74_commit VALUES (1, 'a'), (2, 'b')"
    ) { viewModel, manager, observer in
      let recorder = StagingHistoryRecorder()
      viewModel.historyRecorder = recorder
      viewModel.historySettings = try isolatedHistorySettings()

      let edited = try rowIndex(1, in: viewModel)
      let deleted = try rowIndex(2, in: viewModel)
      #expect(
        viewModel.stageInsert(values: ["id": .int(3), "name": .string("c")]) == nil)
      #expect(viewModel.stageEdit(row: edited, column: "name", value: .string("A")) == nil)
      #expect(viewModel.stageDelete(rows: [deleted]) == nil)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await rows(observer, "SELECT id, name FROM p74_commit ORDER BY id")
          == [[.int(1), .string("A")], [.int(3), .string("c")]])
      let entries = await recorder.entries
      let entry = try #require(entries.first { $0.source == .dataViewerEdit })
      #expect(entry.status == .success)
      #expect(entry.sql.contains("name"))
      #expect(!entry.sql.contains("$"))
      _ = manager
    }
  }

  @Test("A failing statement rolls the whole batch back", .timeLimit(.minutes(1)))
  func failingStatementRollsBackTheBatch() async throws {
    try await withViewer(
      table: "p74_rollback", protectedMode: false,
      ddl: "CREATE TABLE p74_rollback (id int PRIMARY KEY, n int CHECK (n > 0))",
      seed: "INSERT INTO p74_rollback VALUES (1, 1), (2, 2)"
    ) { viewModel, _, observer in
      let doomed = try rowIndex(1, in: viewModel)
      let invalid = try rowIndex(2, in: viewModel)
      #expect(viewModel.stageDelete(rows: [doomed]) == nil)
      #expect(viewModel.stageEdit(row: invalid, column: "n", value: .int(-1)) == nil)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
      #expect(
        try await rows(observer, "SELECT id, n FROM p74_rollback ORDER BY id")
          == [[.int(1), .int(1)], [.int(2), .int(2)]])
    }
  }

  @Test(
    "Protected mode leaves pending summaries and does not auto-commit", .timeLimit(.minutes(1)))
  func protectedModeLeavesPendingEntries() async throws {
    try await withViewer(
      table: "p74_protected", protectedMode: true,
      ddl: "CREATE TABLE p74_protected (id int PRIMARY KEY, name text)",
      seed: "INSERT INTO p74_protected VALUES (1, 'a')"
    ) { viewModel, manager, observer in
      let edited = try rowIndex(1, in: viewModel)
      #expect(viewModel.stageEdit(row: edited, column: "name", value: .string("z")) == nil)

      await viewModel.commitStaged()

      let snapshot = await manager.transactionSnapshot()
      #expect(!snapshot.pending.isEmpty)
      #expect(!snapshot.isIdle)
      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await rows(observer, "SELECT name FROM p74_protected WHERE id = 1")
          == [[.string("a")]])
    }
  }

  @Test("A table without a primary key does not stage", .timeLimit(.minutes(1)))
  func tableWithoutPrimaryKeyDoesNotStage() async throws {
    try await withViewer(
      table: "p74_nopk", protectedMode: false,
      ddl: "CREATE TABLE p74_nopk (id int, name text)",
      seed: "INSERT INTO p74_nopk VALUES (1, 'a')"
    ) { viewModel, _, observer in
      let result = try #require(viewModel.editorResult)
      #expect(result.error == nil)
      #expect(result.editTarget == nil)
      #expect(
        viewModel.stageEdit(row: 0, column: "name", value: .string("z"))?
          .contains("Table has no primary key") == true)
      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await rows(observer, "SELECT name FROM p74_nopk") == [[.string("a")]])
    }
  }

  @Test(
    "A stored generated column is read-only and left out of staged rows",
    .timeLimit(.minutes(1)))
  func generatedColumnIsNotWritten() async throws {
    try await withViewer(
      table: "p74_generated", protectedMode: false,
      ddl: """
        CREATE TABLE p74_generated (
          id int PRIMARY KEY, g int GENERATED ALWAYS AS (id * 2) STORED, name text)
        """,
      seed: "INSERT INTO p74_generated (id, name) VALUES (1, 'a')"
    ) { viewModel, _, observer in
      let result = try #require(viewModel.editorResult)
      #expect(result.editTarget?.generatedColumns == ["g"])
      let generated = try #require(result.columns.firstIndex { $0.name == "g" })
      #expect(viewModel.readOnlyColumnIndexes(result) == [generated])

      let row = try rowIndex(1, in: viewModel)
      #expect(viewModel.stageEdit(row: row, column: "name", value: .string("A")) == nil)
      #expect(await viewModel.stageDuplicate(rows: [row]) == nil)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await rows(observer, "SELECT id, g, name FROM p74_generated ORDER BY id")
          == [[.int(1), .int(2), .string("A")], [.int(2), .int(4), .string("A")]])
    }
  }

  @Test(
    "A loaded row follows commit style; an appended insert stays in the batch",
    .timeLimit(.minutes(1)),
    arguments: [CommitStyle.immediate, .review])
  func loadedRowFollowsCommitStyle(_ style: CommitStyle) async throws {
    try await withViewer(
      table: "p74_view_row", style: style,
      ddl: "CREATE TABLE p74_view_row (id int PRIMARY KEY, name text)",
      seed: "INSERT INTO p74_view_row VALUES (1, 'a')"
    ) { viewModel, manager, observer in
      let result = try #require(viewModel.editorResult)
      let column = try #require(result.columns.firstIndex { $0.name == "name" })
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        viewModel.onStatementsExecuted = {
          viewModel.onStatementsExecuted = nil
          continuation.resume()
        }
        viewModel.handleStagedGridCellEdit(
          row: 0, column: column, newValue: "edited", result: result)
        if viewModel.dataViewer?.changeSet != nil {
          viewModel.onStatementsExecuted = nil
          continuation.resume()
        }
      }

      let snapshot = await manager.transactionSnapshot()
      let stored = try await rows(observer, "SELECT name FROM p74_view_row WHERE id = 1")
      if style.opensReviewTransaction {
        #expect(stored == [[.string("a")]])
        #expect(snapshot.pending.count == 1)
        #expect(snapshot.pending.first?.kindLabel == "UPDATE")
      } else {
        #expect(stored == [[.string("edited")]])
        #expect(snapshot.isIdle)
      }
      try #require(viewModel.dataViewer?.changeSet == nil)

      #expect(viewModel.stageInsert(values: ["id": .int(2), "name": .string("c")]) == nil)
      let preview = viewModel.previewStagedSQL()
      #expect(preview.contains("INSERT"))
      #expect(!preview.contains("UPDATE"))
      await viewModel.commitStaged()

      let after = await manager.transactionSnapshot()
      let storedRows = try await rows(observer, "SELECT id, name FROM p74_view_row ORDER BY id")
      #expect(viewModel.dataViewer?.changeSet == nil)
      if style.opensReviewTransaction {
        #expect(storedRows == [[.int(1), .string("a")]])
        #expect(after.pending.count == 2)
        #expect(!after.isIdle)
      } else {
        #expect(storedRows == [[.int(1), .string("edited")], [.int(2), .string("c")]])
        #expect(after.isIdle)
      }
    }
  }

  @Test(
    "A timestamptz primary key with microseconds targets exactly its row",
    .timeLimit(.minutes(1)))
  func microsecondTimestampKey() async throws {
    try await withViewer(
      table: "p74_ts_key", protectedMode: false,
      ddl: "CREATE TABLE p74_ts_key (id timestamptz PRIMARY KEY, name text)",
      seed: """
        INSERT INTO p74_ts_key VALUES
          ('2024-01-02 03:04:05.123456+00', 'a'), ('2024-01-02 03:04:05.654321+00', 'b')
        """
    ) { viewModel, _, observer in
      let result = try #require(viewModel.editorResult)
      #expect(result.rows.count == 2)
      let name = try #require(result.columns.firstIndex { $0.name == "name" })
      let edited = try #require(result.rows.firstIndex { $0[name] == .string("a") })
      let deleted = try #require(result.rows.firstIndex { $0[name] == .string("b") })
      #expect(viewModel.stageEdit(row: edited, column: "name", value: .string("A")) == nil)
      #expect(viewModel.stageDelete(rows: [deleted]) == nil)

      await viewModel.commitStaged()

      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await rows(
          observer, "SELECT to_char(id AT TIME ZONE 'UTC', 'US'), name FROM p74_ts_key")
          == [[.string("123456"), .string("A")]])
    }
  }

  private func config(protectedMode: Bool) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, protectionLevel: .none, safeMode: .silent, protectedMode: protectedMode)
  }

  private func config(style: CommitStyle) -> ConnectionConfig {
    var config = config(protectedMode: false)
    config.applyCommitStyle(style)
    return config
  }

  private func withViewer(
    table: String, protectedMode: Bool, ddl: String, seed: String,
    _ body: (NotebookViewModel, DatabaseConnectionManager, DatabaseConnectionManager) async throws
      -> Void
  ) async throws {
    try await withViewer(
      table: table, connection: config(protectedMode: protectedMode), ddl: ddl, seed: seed, body)
  }

  private func withViewer(
    table: String, style: CommitStyle, ddl: String, seed: String,
    _ body: (NotebookViewModel, DatabaseConnectionManager, DatabaseConnectionManager) async throws
      -> Void
  ) async throws {
    try await withViewer(
      table: table, connection: config(style: style), ddl: ddl, seed: seed, body)
  }

  private func withViewer(
    table: String, connection: ConnectionConfig, ddl: String, seed: String,
    _ body: (NotebookViewModel, DatabaseConnectionManager, DatabaseConnectionManager) async throws
      -> Void
  ) async throws {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal(ddl)
    _ = try await observer.executeInternal(seed)

    let manager = DatabaseConnectionManager()
    try await manager.connect(config: connection)
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [], connectionConfig: connection))
    viewModel.viewMode = .editor
    viewModel.connectionState = .connected
    viewModel.connectionManager = manager
    viewModel.dataViewer = DataViewerState(schema: "public", name: table, orderColumns: ["id"])
    do {
      await viewModel.loadDataViewerPage()
      try await body(viewModel, manager, observer)
    } catch {
      Issue.record(error)
    }
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func rowIndex(_ id: Int, in viewModel: NotebookViewModel) throws -> Int {
    let result = try #require(viewModel.editorResult)
    #expect(result.error == nil)
    let column = try #require(result.columns.firstIndex { $0.name == "id" })
    return try #require(result.rows.firstIndex { $0[column] == .int(id) })
  }

  private func rows(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws -> [[CellValue]] {
    try await manager.executeInternal(sql).rows
  }

  private func isolatedHistorySettings() throws -> AppSettings {
    let suiteName = "RowStagingIntegrationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    return settings
  }
}

private actor StagingHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}
