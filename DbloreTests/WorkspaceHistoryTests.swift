// WorkspaceHistoryTests.swift
// History list search, scope, paging, and the workspace actions that use a row.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Workspace history")
@MainActor
struct WorkspaceHistoryTests {
  @Test("A query change waits, then searches")
  func queryIsDebounced() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT apples", at: start))
    try await store.record(Self.entry(sql: "SELECT bananas", at: start.addingTimeInterval(10)))
    let manager = makeManager(store: store)

    manager.historyList.query = "apples"
    try await Task.sleep(for: .milliseconds(100))
    #expect(manager.historyList.results.isEmpty)

    try await Task.sleep(for: .milliseconds(400))
    #expect(manager.historyList.results.map(\.sql) == ["SELECT apples"])
  }

  @Test("Scope uses the active connection and workspace, and a missing key searches all")
  func scopeFilters() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let workspaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let otherID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      Self.entry(
        sql: "SELECT mine", at: start, connectionKey: Self.connectionKey, workspaceID: workspaceID)
    )
    try await store.record(
      Self.entry(
        sql: "SELECT other connection", at: start.addingTimeInterval(10),
        connectionKey: "PostgreSQL|other|5432|db|user", workspaceID: workspaceID)
    )
    try await store.record(
      Self.entry(
        sql: "SELECT other workspace", at: start.addingTimeInterval(20),
        connectionKey: Self.connectionKey, workspaceID: otherID)
    )
    let manager = makeManager(
      store: store, id: workspaceID,
      connection: ConnectionConfig(
        host: "localhost", port: 5432, database: "app", username: "ana", name: "Prod"))

    #expect(
      HistoryScope.connection.storeScope(connectionKey: nil, workspaceID: workspaceID) == .all)
    #expect(
      HistoryScope.connection.storeScope(connectionKey: "", workspaceID: workspaceID) == .all)
    #expect(
      HistoryScope.workspace.storeScope(connectionKey: Self.connectionKey, workspaceID: nil) == .all
    )

    manager.historyList.scope = .connection
    await manager.historyList.searchNow()
    #expect(manager.historyList.results.map(\.sql) == ["SELECT other workspace", "SELECT mine"])

    manager.historyList.scope = .workspace
    await manager.historyList.searchNow()
    #expect(manager.historyList.results.map(\.sql) == ["SELECT other connection", "SELECT mine"])

    manager.workspace.connectionConfig = nil
    manager.historyList.scope = .connection
    await manager.historyList.searchNow()
    #expect(
      manager.historyList.results.map(\.sql) == [
        "SELECT other workspace", "SELECT other connection", "SELECT mine",
      ])
  }

  @Test("loadMore appends the next page of 100")
  func pagingAppendsNextPage() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<101 {
      try await store.record(
        Self.entry(sql: "SELECT \(index)", at: start.addingTimeInterval(Double(index) * 10)))
    }
    let manager = makeManager(store: store)

    await manager.historyList.searchNow()
    #expect(manager.historyList.results.count == 100)
    #expect(manager.historyList.results.first?.sql == "SELECT 100")

    await manager.historyList.loadMore()
    #expect(manager.historyList.results.count == 101)
    #expect(manager.historyList.results.last?.sql == "SELECT 0")

    await manager.historyList.loadMore()
    #expect(manager.historyList.results.count == 101)
  }

  @Test("deleteHistory removes the row from the list and the store")
  func deleteHistoryRemovesRow() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT keep", at: start))
    try await store.record(Self.entry(sql: "SELECT drop", at: start.addingTimeInterval(10)))
    let manager = makeManager(store: store)
    await manager.refreshHistory()
    let victim = try #require(manager.historyList.results.first { $0.sql == "SELECT drop" })

    await manager.deleteHistory(ids: [victim.id])

    #expect(manager.historyList.results.map(\.sql) == ["SELECT keep"])
    let remaining = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(remaining.map(\.sql) == ["SELECT keep"])
  }

  @Test("insertHistory asks the active notebook to insert the SQL")
  func insertHistoryInsertsText() {
    let manager = makeManager()
    manager.newNotebook()
    let captured = CapturedInsertion()
    let token = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { note in
      captured.text = note.userInfo?["text"] as? String
    }
    defer { NotificationCenter.default.removeObserver(token) }

    manager.insertHistory(Self.entry(sql: "SELECT from_history"))

    #expect(captured.text == "SELECT from_history")
  }

  @Test("runHistoryInNewCell adds a SQL cell after the selection and does not execute it")
  func runHistoryInNewCellDoesNotExecute() throws {
    let manager = makeManager()
    manager.newNotebook()
    let viewModel = try #require(manager.activeViewModel)
    let original = try #require(viewModel.notebook.cells.first)
    viewModel.notebook.cells.append(NotebookCell(cellType: .sql, content: "SELECT existing"))
    viewModel.selectedCellId = original.id

    manager.runHistoryInNewCell(Self.entry(sql: "SELECT history_sql"))

    #expect(
      viewModel.notebook.cells.map(\.content) == ["", "SELECT history_sql", "SELECT existing"])
    let inserted = viewModel.notebook.cells[1]
    #expect(inserted.cellType == .sql)
    #expect(inserted.isRunning == false)
    #expect(inserted.executionCount == nil)
    #expect(inserted.result == nil)
  }

  @Test("copyHistory copies the SQL")
  func copyHistoryCopiesSQL() {
    let manager = makeManager()
    manager.copyHistory(Self.entry(sql: "SELECT copy_me"))
    #expect(NSPasteboard.general.string(forType: .string) == "SELECT copy_me")
  }

  @Test("refreshHistory reloads the first page")
  func refreshHistoryReloadsFirstPage() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT old", at: start))
    let manager = makeManager(store: store)

    await manager.refreshHistory()
    #expect(manager.historyList.results.map(\.sql) == ["SELECT old"])

    try await store.record(Self.entry(sql: "SELECT new", at: start.addingTimeInterval(10)))
    #expect(manager.historyList.results.map(\.sql) == ["SELECT old"])

    await manager.refreshHistory()
    #expect(manager.historyList.results.map(\.sql) == ["SELECT new", "SELECT old"])
  }

  private static let connectionKey = "PostgreSQL|localhost|5432|app|ana"

  private static func entry(
    sql: String,
    at executedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    connectionKey: String = connectionKey,
    workspaceID: UUID? = nil
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0,
      sql: sql,
      executedAt: executedAt,
      durationMs: 1,
      rowCount: 1,
      status: .success,
      errorMessage: nil,
      connectionKey: connectionKey,
      connectionLabel: "Prod",
      workspaceID: workspaceID,
      workspaceName: nil,
      source: .cell
    )
  }

  private func makeManager(
    store: QueryHistoryStore? = nil,
    id: UUID = UUID(),
    connection: ConnectionConfig? = nil
  ) -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(id: id, connectionConfig: connection), restoreTabs: false)
    manager.historyBrowser = store
    return manager
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-workspace-history-\(UUID().uuidString).sqlite")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
}

/// Holds text posted with `insertTextIntoCell`. The notification callback is sendable.
private final class CapturedInsertion: @unchecked Sendable {
  var text: String?
}
