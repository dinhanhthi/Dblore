// QueryNotificationHookTests.swift
// Long-query notification hooks of the notebook view model, against a temporary SQLite file:
// one notification per cell run, editor run or Run All (cells of a Run All do not post their
// own), none for a short run, a cancel or an active app, and the text never carries SQL or
// server error text.

import Foundation
import Testing

@testable import Dblore

/// Records posted requests; always authorized.
private actor RecordingCenter: QueryNotificationCenter {
  private(set) var requests: [QueryNotificationRequest] = []

  func requestAuthorization() async -> Bool { true }
  func authorizationStatus() async -> QueryNotificationAuthorization { .granted }
  func add(_ request: QueryNotificationRequest) async { requests.append(request) }
}

@Suite("Query notification hooks")
@MainActor
struct QueryNotificationHookTests {
  private static let tabID = UUID()
  private static let tabName = "Orders"
  /// Every run counts as long
  private static let long = QueryNotificationSettings(
    enabled: true, thresholdSeconds: 0, onlyWhenInactive: true)
  /// SQLite never ends it on its own; only an interrupt stops it
  private static let endless =
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"

  private static func config(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
  }

  private static func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  /// A connected view model over a file with `items` (3 rows), posting into `center`
  private func withViewModel(
    cells: [String] = [], settings: QueryNotificationSettings = long, appActive: Bool = false,
    _ body: (NotebookViewModel, RecordingCenter) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-notify-\(UUID().uuidString).sqlite")
    defer { Self.removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    try handle.execute("INSERT INTO items (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')")

    let config = Self.config(path: url.path)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    let center = RecordingCenter()
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = cells.map { NotebookCell(cellType: .sql, content: $0) }
    viewModel.notebook.connectionConfig = config
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.toastPresenter = { _, _ in }
    viewModel.queryNotifier = QueryCompletionNotifier(center: center)
    viewModel.notificationTab = { (id: Self.tabID, name: Self.tabName) }
    viewModel.notificationSettings = { settings }
    viewModel.isAppActive = { appActive }
    do {
      try await body(viewModel, center)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  /// Runs one cell through the queue and waits for its notification, if any
  private func runCell(_ viewModel: NotebookViewModel, at index: Int = 0) async {
    await viewModel.runCell(id: viewModel.notebook.cells[index].id)
    await viewModel.executionQueue.waitForIdle()
    await viewModel.lastCompletionNotification?.value
  }

  /// Polls until the statement is running on the connection
  private func waitUntilInFlight(_ viewModel: NotebookViewModel) async throws {
    let manager = try #require(viewModel.connectionManager)
    for _ in 0..<500 {
      if await manager.runningStatementStatus().inFlight { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("statement never started")
  }

  @Test("A long cell run posts exactly one notification for its tab", .timeLimit(.minutes(1)))
  func longCellRunPostsOnce() async throws {
    try await withViewModel(cells: ["SELECT * FROM items"]) { viewModel, center in
      await runCell(viewModel)

      let requests = await center.requests
      #expect(requests.count == 1)
      let request = try #require(requests.first)
      #expect(request.identifier == QueryCompletionNotifier.identifier(for: Self.tabID))
      #expect(request.userInfo[QueryCompletionNotifier.tabIDKey] == Self.tabID.uuidString)
      #expect(request.title == "Query finished")
      #expect(request.body.hasPrefix("Orders · "))
      #expect(request.body.hasSuffix(" · 3 rows"))
    }
  }

  @Test("A DML cell run reports affected rows", .timeLimit(.minutes(1)))
  func dmlCellRunReportsAffectedRows() async throws {
    try await withViewModel(cells: ["UPDATE items SET name = 'z' WHERE id <= 2"]) {
      viewModel, center in
      await runCell(viewModel)

      let requests = await center.requests
      #expect(requests.count == 1)
      #expect(requests.first?.body.hasSuffix(" · 2 rows affected") == true)
    }
  }

  @Test("A run shorter than the threshold posts nothing", .timeLimit(.minutes(1)))
  func shortRunPostsNothing() async throws {
    let short = QueryNotificationSettings(
      enabled: true, thresholdSeconds: 3600, onlyWhenInactive: true)
    try await withViewModel(cells: ["SELECT * FROM items"], settings: short) {
      viewModel, center in
      await runCell(viewModel)

      #expect(await center.requests.isEmpty)
    }
  }

  @Test("A failed run says failed, never the SQL or the server error", .timeLimit(.minutes(1)))
  func failedRunHidesSQLAndError() async throws {
    try await withViewModel(cells: ["SELECT secret_col FROM missing_secret_tbl"]) {
      viewModel, center in
      await runCell(viewModel)

      let requests = await center.requests
      #expect(requests.count == 1)
      let request = try #require(requests.first)
      #expect(request.title == "Query failed")
      #expect(request.body.hasSuffix(" · failed"))
      for text in [request.title, request.body] {
        #expect(!text.contains("missing_secret_tbl"))
        #expect(!text.contains("secret_col"))
        #expect(!text.localizedCaseInsensitiveContains("no such table"))
      }
    }
  }

  @Test("A cancelled cell run posts nothing", .timeLimit(.minutes(2)))
  func cancelledCellRunPostsNothing() async throws {
    try await withViewModel(cells: [Self.endless]) { viewModel, center in
      viewModel.cancelQueryPrompt = { _ in true }
      let cellId = viewModel.notebook.cells[0].id
      await viewModel.runCell(id: cellId)
      try await waitUntilInFlight(viewModel)

      await viewModel.cancelRunningStatement(cancelQueue: true)
      // The cell gets its error result once the interrupted statement returns (up to 20s on a
      // loaded runner)
      for _ in 0..<2000 where viewModel.notebook.cells[0].result == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(viewModel.notebook.cells[0].result?.error != nil)
      await viewModel.lastCompletionNotification?.value

      #expect(await center.requests.isEmpty)
    }
  }

  @Test("A cancelled editor run posts nothing", .timeLimit(.minutes(1)))
  func cancelledEditorRunPostsNothing() async throws {
    try await withViewModel { viewModel, center in
      viewModel.viewMode = .editor
      viewModel.cancelQueryPrompt = { _ in true }
      let run = Task { await viewModel.executeEditorQuery(Self.endless) }
      try await waitUntilInFlight(viewModel)

      await viewModel.cancelRunningStatement(cancelQueue: false)
      await run.value
      await viewModel.lastCompletionNotification?.value

      #expect(viewModel.editorResult?.error != nil)
      #expect(await center.requests.isEmpty)
    }
  }

  @Test("Run All of three cells posts one notification, not three", .timeLimit(.minutes(1)))
  func runAllPostsOnce() async throws {
    try await withViewModel(
      cells: [
        "SELECT * FROM items", "SELECT id FROM items WHERE id = 1",
        "SELECT name FROM items WHERE id > 1",
      ]
    ) { viewModel, center in
      await viewModel.runAllCells(bypass: true)
      #expect(!viewModel.queryConfirmationState.showRunAllConfirmation)
      await viewModel.executionQueue.waitForIdle()
      await viewModel.lastCompletionNotification?.value

      let requests = await center.requests
      #expect(requests.count == 1)
      #expect(requests.first?.body.hasSuffix(" · 6 rows") == true)
    }
  }

  @Test("Run All with a failing cell posts one failed notification", .timeLimit(.minutes(1)))
  func runAllWithFailurePostsFailed() async throws {
    try await withViewModel(
      cells: ["SELECT * FROM items", "SELECT * FROM missing_tbl", "SELECT 1"]
    ) { viewModel, center in
      await viewModel.runAllCells(bypass: true)
      await viewModel.executionQueue.waitForIdle()
      await viewModel.lastCompletionNotification?.value

      let requests = await center.requests
      #expect(requests.count == 1)
      #expect(requests.first?.title == "Query failed")
    }
  }

  @Test("An editor run posts one notification", .timeLimit(.minutes(1)))
  func editorRunPostsOnce() async throws {
    try await withViewModel { viewModel, center in
      viewModel.viewMode = .editor
      await viewModel.executeEditorQuery("SELECT * FROM items; SELECT 1")
      await viewModel.lastCompletionNotification?.value

      let requests = await center.requests
      #expect(requests.count == 1)
      #expect(requests.first?.body.hasSuffix(" · 1 row") == true)
    }
  }

  @Test("An active app with only-when-inactive on posts nothing", .timeLimit(.minutes(1)))
  func activeAppPostsNothing() async throws {
    try await withViewModel(cells: ["SELECT * FROM items"], appActive: true) {
      viewModel, center in
      await runCell(viewModel)
      viewModel.viewMode = .editor
      await viewModel.executeEditorQuery("SELECT * FROM items")
      await viewModel.lastCompletionNotification?.value

      #expect(await center.requests.isEmpty)
    }
  }
}
