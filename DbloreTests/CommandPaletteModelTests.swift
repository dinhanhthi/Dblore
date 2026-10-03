// CommandPaletteModelTests.swift
// Snapshot rank, cancel on the next keystroke, and history scoped to this connection.

import Foundation
import Testing

@testable import Dblore

@Suite("Command palette model")
@MainActor
struct CommandPaletteModelTests {
  @Test("snapshot rows rank by score, keep ties in snapshot order, and stop at 50")
  func snapshotRanksByScoreAndStopsAtFifty() async {
    let favoriteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var snapshot = CommandPaletteSnapshot(
      tables: [
        .init(schema: "b", name: "users"),
        .init(schema: "a", name: "users"),
      ],
      views: [.init(schema: "public", name: "users_extra")],
      functions: [.init(schema: "public", name: "all_users", arguments: "id integer")],
      tabs: [.init(id: tabID, title: "zzusers")],
      favorites: [.init(id: favoriteID, name: "saved users", sql: "SELECT 1")],
      actions: [.init(id: "run", title: "usres")]
    )
    let model = CommandPaletteModel()
    model.query = "Users"
    model.open(snapshot)

    let expected: [CommandPaletteItem] = [
      .table(schema: "b", name: "users"),
      .table(schema: "a", name: "users"),
      .view(schema: "public", name: "users_extra"),
      .function(schema: "public", name: "all_users", arguments: "id integer"),
      .favorite(id: favoriteID, name: "saved users", sql: "SELECT 1"),
      .tab(id: tabID, title: "zzusers"),
      .action(id: "run", title: "usres"),
    ]
    #expect(await waitUntil { model.ranked == expected })
    #expect(model.ranked == expected)

    model.query = "saved users"
    #expect(
      await waitUntil {
        model.ranked == [.favorite(id: favoriteID, name: "saved users", sql: "SELECT 1")]
      })

    snapshot.tables.append(.init(schema: "public", name: "users"))
    model.query = "Users"
    #expect(await waitUntil { model.ranked == expected })
    #expect(model.ranked == expected)

    var crowded = CommandPaletteSnapshot()
    crowded.tables = (0..<48).map { .init(schema: "public", name: "t\($0)") }
    crowded.actions = (0..<5).map { .init(id: "act-\($0)", title: "Action \($0)") }
    let capped = CommandPaletteModel()
    capped.open(crowded)
    var cappedExpected: [CommandPaletteItem] = crowded.tables.map {
      .table(schema: $0.schema, name: $0.name)
    }
    cappedExpected.append(.action(id: "act-0", title: "Action 0"))
    cappedExpected.append(.action(id: "act-1", title: "Action 1"))
    #expect(await waitUntil { capped.ranked == cappedExpected })
    #expect(capped.ranked.count == 50)
    #expect(capped.ranked == cappedExpected)
  }

  @Test("a new keystroke cancels the previous rank")
  func newKeystrokeCancelsPreviousRank() async {
    let gate = PaletteRankGate()
    let model = CommandPaletteModel(rank: BlockingRank.make(gate))
    let snapshot = CommandPaletteSnapshot(
      tables: [
        .init(schema: "public", name: "orders"),
        .init(schema: "public", name: "customers"),
      ])
    model.open(snapshot)
    #expect(await waitUntil { model.ranked.count == 2 })

    model.query = "block"
    #expect(model.ranked.isEmpty)
    #expect(await gate.waitUntilStarted())
    #expect(model.ranked.isEmpty)

    model.query = "orders"
    #expect(await gate.waitUntilCancelled())
    let orders: [CommandPaletteItem] = [.table(schema: "public", name: "orders")]
    #expect(await waitUntil { model.ranked == orders })
    #expect(model.ranked == orders)
  }

  @Test("history search uses the injected store, this connection, and a 250 ms debounce")
  func historySearchUsesInjectedStoreAndConnection() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let connectionKey = "PostgreSQL|localhost|5432|palette|user"
    let otherKey = "PostgreSQL|localhost|5432|other|user"
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<52 {
      try await store.record(
        Self.entry(
          sql: "SELECT row \(index)", at: start.addingTimeInterval(TimeInterval(index)),
          connectionKey: connectionKey, kind: .read))
    }
    try await store.record(
      Self.entry(
        sql: "DELETE row write", at: start.addingTimeInterval(200), connectionKey: connectionKey,
        kind: .write))
    try await store.record(
      Self.entry(
        sql: "SELECT other_connection", at: start.addingTimeInterval(500), connectionKey: otherKey,
        kind: .read))

    let model = CommandPaletteModel(historyStore: store)
    var snapshot = CommandPaletteSnapshot()
    snapshot.connectionKey = connectionKey
    model.open(snapshot)
    #expect(model.history.isEmpty)

    #expect(await waitUntil { model.history.count == 50 })
    #expect(model.history.map(\.title).first == "DELETE row write")
    #expect(model.history.map(\.title).contains("SELECT row 51"))
    #expect(model.history.map(\.title).contains("SELECT row 3"))
    #expect(!model.history.map(\.title).contains("SELECT row 2"))
    #expect(!model.history.map(\.title).contains("SELECT other_connection"))
    #expect(Set(model.history.map(\.id)).count == model.history.count)

    model.query = "delete"
    #expect(model.history.isEmpty)
    #expect(await waitUntil { model.history.map(\.title) == ["DELETE row write"] })
    #expect(model.history.map(\.title) == ["DELETE row write"])

    try await store.record(
      Self.entry(
        sql: "COMMIT (2 statements)", at: start.addingTimeInterval(800),
        connectionKey: connectionKey, kind: .write))
    let stored = try await store.search(
      text: "commit", scope: .connection(connectionKey), limit: 10, offset: 0, writesOnly: false)
    #expect(stored.map(\.sql).contains("COMMIT (2 statements)"))
    model.query = "commit"
    #expect(model.history.isEmpty)
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.history.isEmpty)

    model.query = " \t "
    #expect(await waitUntil { model.history.count == 49 })
    #expect(model.history.map(\.title).first == "DELETE row write")
    #expect(!model.history.map(\.title).contains("COMMIT (2 statements)"))
    #expect(!model.history.map(\.title).contains("SELECT other_connection"))

    snapshot.connectionKey = otherKey
    snapshot.tables = [.init(schema: "public", name: "only")]
    model.open(snapshot)
    #expect(
      await waitUntil {
        model.history.map(\.title) == ["SELECT other_connection"]
          && model.ranked == [.table(schema: "public", name: "only")]
      })
    #expect(model.history.map(\.title) == ["SELECT other_connection"])
    #expect(model.ranked == [.table(schema: "public", name: "only")])
  }

  @Test("opening again replaces the snapshot instead of appending")
  func openingAgainReplacesSnapshot() async {
    let model = CommandPaletteModel()
    var first = CommandPaletteSnapshot(
      tables: [
        .init(schema: "public", name: "alpha"),
        .init(schema: "public", name: "beta"),
      ],
      actions: [.init(id: "settings", title: "Settings")]
    )
    model.open(first)
    #expect(
      await waitUntil { model.ranked.map(\.title) == ["alpha", "beta", "Settings"] })

    model.query = "beta"
    #expect(await waitUntil { model.ranked.map(\.title) == ["beta"] })

    first.tables.append(.init(schema: "public", name: "beta"))
    let second = CommandPaletteSnapshot(
      actions: [.init(id: "new-sql", title: "New SQL File")])
    model.open(second)
    #expect(await waitUntil { model.ranked.isEmpty })
    #expect(model.ranked.isEmpty)

    model.query = ""
    #expect(await waitUntil { model.ranked == [.action(id: "new-sql", title: "New SQL File")] })
    #expect(model.ranked == [.action(id: "new-sql", title: "New SQL File")])
  }

  @Test("perform selects the tab from the snapshot")
  func performSelectsTab() {
    let manager = makeWorkspace()
    let first = manager.newNotebook()
    let second = manager.newSQLFile()
    #expect(manager.activeTabId == second)

    let sources = manager.paletteSources()
    #expect(sources.connectionKey.isEmpty)
    #expect(sources.tabs.map(\.id) == [first, second])
    let tab = sources.tabs[0]
    manager.perform(.tab(id: tab.id, title: tab.title))
    #expect(manager.activeTabId == first)
  }

  @Test("perform inserts a favorite and a normal history row")
  func performInsertsFavoriteAndHistory() {
    let manager = makeWorkspace()
    manager.newNotebook()
    manager.activeViewModel?.selectedCellId = manager.activeViewModel?.notebook.cells.first?.id
    let favorite = FavoriteStatement(name: "saved", sql: "SELECT favorite")
    manager.saveFavorite(favorite)

    withInsertionCapture { captured in
      let row = manager.paletteSources().favorites.first { $0.id == favorite.id }
      #expect(row?.sql == "SELECT favorite")
      manager.perform(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql))
      #expect(captured.text == "SELECT favorite")

      captured.text = nil
      manager.perform(.history(id: 7, sql: "SELECT history_row"))
      #expect(captured.text == "SELECT history_row")
    }
  }

  @Test("perform refuses a transaction-summary history row")
  func performRefusesTransactionSummaryHistory() {
    let manager = makeWorkspace()
    manager.newNotebook()
    manager.activeViewModel?.selectedCellId = manager.activeViewModel?.notebook.cells.first?.id

    withInsertionCapture { captured in
      #expect(!manager.perform(.history(id: 1, sql: "COMMIT (2 statements)")))
      #expect(!manager.perform(.history(id: 2, sql: "ROLLBACK (1 statements)")))
      #expect(captured.text == nil)
    }
  }

  @Test("perform leaves the palette open when inserted text would be dropped")
  func performLeavesPaletteOpenWhenTextWouldBeDropped() {
    let manager = makeWorkspace()
    let favorite = FavoriteStatement(name: "saved", sql: "SELECT favorite")
    #expect(!manager.perform(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql)))
    #expect(!manager.perform(.history(id: 3, sql: "SELECT history_row")))
    #expect(!manager.perform(.function(schema: "public", name: "lower", arguments: "text")))

    manager.newNotebook()
    withInsertionCapture { captured in
      #expect(!manager.perform(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql)))
      #expect(captured.text == nil)
      manager.activeViewModel?.selectedCellId = manager.activeViewModel?.notebook.cells.first?.id
      #expect(manager.perform(.history(id: 4, sql: "SELECT history_row")))
      #expect(captured.text == "SELECT history_row")
    }

    manager.newSQLFile()
    manager.activeViewModel?.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: [])
    withInsertionCapture { captured in
      #expect(!manager.perform(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql)))
      #expect(!manager.perform(.history(id: 5, sql: "SELECT history_row")))
      #expect(!manager.perform(.function(schema: "public", name: "lower", arguments: "text")))
      #expect(captured.text == nil)
    }
  }

  @Test("perform stays open when commit, rollback, or the right sidebar would do nothing")
  func performStaysOpenWhenCommitRollbackOrSidebarWouldDoNothing() {
    let manager = makeWorkspace()
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.isCommitConfirmationVisible)
    #expect(!manager.perform(.action(id: "rollback", title: "Roll Back")))
    #expect(!manager.perform(.action(id: "toggle-right-sidebar", title: "Toggle Right Sidebar")))

    manager.pendingTransaction = .aborted(reason: "failed", pending: [])
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.isCommitConfirmationVisible)

    manager.pendingTransaction = .appTx(pending: [])
    #expect(manager.perform(.action(id: "commit", title: "Commit")))
    #expect(manager.isCommitConfirmationVisible)
    #expect(manager.perform(.action(id: "rollback", title: "Roll Back")))

    manager.newNotebook()
    #expect(manager.activeViewModel?.isRightSidebarVisible == false)
    #expect(manager.perform(.action(id: "toggle-right-sidebar", title: "Toggle Right Sidebar")))
    #expect(manager.activeViewModel?.isRightSidebarVisible == true)
  }

  @Test("perform run stays open while the schema visualizer covers the tab")
  func performRunStaysOpenWhileSchemaVisualizerCoversTheTab() {
    let notes = PaletteNoteCount()
    let center = NotificationCenter.default
    let tokens = [
      center.addObserver(forName: .runAllCells, object: nil, queue: nil) { _ in notes.runAll += 1 },
      center.addObserver(forName: .runEditorQuery, object: nil, queue: nil) { _ in
        notes.editor += 1
      },
    ]
    defer {
      for token in tokens {
        center.removeObserver(token)
      }
    }

    let manager = makeWorkspace()
    manager.newNotebook()
    manager.isSchemaVisualizerActive = true
    #expect(!manager.perform(.action(id: "run-all", title: "Run All Cells")))
    manager.newSQLFile()
    #expect(!manager.perform(.action(id: "run-cell", title: "Run Cell")))
    #expect(!manager.perform(.action(id: "run-all", title: "Run All Cells")))
    #expect(notes.runAll == 0)
    #expect(notes.editor == 0)
  }

  @Test("perform opens a data viewer for a table")
  func performOpensDataViewerForTable() throws {
    let config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ana")
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    manager.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users",
        columns: [
          DatabaseColumn(name: "id", type: "int", isPrimaryKey: true),
          DatabaseColumn(name: "email", type: "text"),
        ]),
      DatabaseTable(schema: "sales", name: "orders"),
    ]
    manager.databaseViews = [DatabaseView(schema: "public", name: "active_users")]
    manager.databaseFunctions = [
      DatabaseFunction(schema: "public", name: "lower", returnType: "text", arguments: "text")
    ]

    let sources = manager.paletteSources()
    #expect(sources.connectionKey == "PostgreSQL|db.example|5432|app|ana")
    #expect(sources.tables.map(\.name) == ["users", "orders"])
    #expect(sources.views == [.init(schema: "public", name: "active_users")])
    #expect(
      sources.functions == [.init(schema: "public", name: "lower", arguments: "text")])
    let table = try #require(sources.tables.first { $0.name == "users" })
    manager.perform(.table(schema: table.schema, name: table.name))

    let viewer = try #require(manager.activeViewModel?.dataViewer)
    #expect(viewer.schema == "public")
    #expect(viewer.name == "users")
    #expect(viewer.orderColumns == ["id"])
  }

  @Test("perform runs the new notebook action")
  func performRunsNewNotebookAction() throws {
    let manager = makeWorkspace()
    let actions = manager.paletteSources().actions
    #expect(
      actions.map(\.id) == [
        "new-notebook",
        "new-sql-file",
        "run-cell",
        "run-all",
        "toggle-left-sidebar",
        "toggle-right-sidebar",
        "toggle-ai-assistant",
        "settings",
        "schema-visualizer",
        "connect",
        "disconnect",
        "commit",
        "rollback",
      ])
    #expect(
      actions.map(\.title) == [
        "New Notebook",
        "New SQL File",
        "Run Cell",
        "Run All Cells",
        "Toggle Left Sidebar",
        "Toggle Right Sidebar",
        "Toggle AI Assistant",
        "Settings",
        "Visualize Schema Relationships",
        "Connect",
        "Disconnect",
        "Commit",
        "Roll Back",
      ])

    let notebook = try #require(actions.first { $0.id == "new-notebook" })
    manager.perform(.action(id: notebook.id, title: notebook.title))
    #expect(manager.tabs.count == 1)
    #expect(manager.tabs.first?.documentType == .notebook)
    #expect(manager.tabs.first?.title == "Untitled.dblore")
    #expect(manager.activeTabId == manager.tabs.first?.id)
  }

  @Test("perform run-all confirms on a notebook and runs the editor query on an editor")
  func performRunAllConfirmsAndEditorRunsQuery() {
    let notes = PaletteNoteCount()
    let center = NotificationCenter.default
    let tokens = [
      center.addObserver(forName: .runAllCells, object: nil, queue: nil) { _ in notes.runAll += 1 },
      center.addObserver(forName: .runEditorQuery, object: nil, queue: nil) { _ in
        notes.editor += 1
      },
      center.addObserver(forName: .unfocusEditor, object: nil, queue: nil) { _ in
        notes.unfocus += 1
      },
    ]
    defer {
      for token in tokens {
        center.removeObserver(token)
      }
    }

    let manager = makeWorkspace()
    #expect(!manager.perform(.action(id: "run-all", title: "Run All Cells")))
    #expect(!manager.perform(.action(id: "run-cell", title: "Run Cell")))
    #expect(notes.runAll == 0)
    #expect(notes.editor == 0)

    manager.newNotebook()
    manager.activeViewModel?.selectedCellId = nil
    #expect(!manager.perform(.action(id: "run-cell", title: "Run Cell")))
    #expect(manager.perform(.action(id: "run-all", title: "Run All Cells")))
    #expect(notes.runAll == 1)
    #expect(notes.unfocus == 0)
    #expect(notes.editor == 0)

    manager.newSQLFile()
    #expect(manager.perform(.action(id: "run-cell", title: "Run Cell")))
    #expect(manager.perform(.action(id: "run-all", title: "Run All Cells")))
    #expect(notes.editor == 2)
    #expect(notes.runAll == 1)
    #expect(notes.unfocus == 0)

    manager.activeViewModel?.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: [])
    #expect(manager.perform(.action(id: "run-all", title: "Run All Cells")))
    #expect(notes.editor == 3)
    #expect(notes.unfocus == 0)
  }

  private func makeWorkspace() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  private func withInsertionCapture(_ body: (PaletteInsertionCapture) -> Void) {
    let captured = PaletteInsertionCapture()
    let token = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { note in
      captured.text = note.userInfo?["text"] as? String
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body(captured)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(15))
    }
    return condition()
  }

  private static func entry(
    sql: String, at executedAt: Date, connectionKey: String, kind: QueryHistoryEntry.Kind
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0, sql: sql, executedAt: executedAt, durationMs: 1, rowCount: 1, status: .success,
      errorMessage: nil, connectionKey: connectionKey, connectionLabel: "palette",
      workspaceID: nil, workspaceName: nil, source: .cell, kind: kind)
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-palette-\(UUID().uuidString).sqlite")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
}

/// Holds text posted with `insertTextIntoCell`. The notification callback is sendable.
private final class PaletteInsertionCapture: @unchecked Sendable {
  var text: String?
}

/// Counts run notifications posted by palette actions. The observer is sendable.
private final class PaletteNoteCount: @unchecked Sendable {
  var runAll = 0
  var editor = 0
  var unfocus = 0
}

private actor PaletteRankGate {
  private var started = false
  private var cancelled = false

  func markStarted() { started = true }

  func markCancelled() { cancelled = true }

  func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !started {
      if clock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  func waitUntilCancelled(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !cancelled {
      if clock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }
}

private enum BlockingRank {
  static func make(
    _ gate: PaletteRankGate
  )
    -> @Sendable ([CommandPaletteItem], String) async ->
    [CommandPaletteItem]
  {
    { items, query in
      if query == "block" {
        await gate.markStarted()
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          await gate.markCancelled()
        }
        return []
      }
      return await CommandPaletteRanking.rank(items, query)
    }
  }
}
