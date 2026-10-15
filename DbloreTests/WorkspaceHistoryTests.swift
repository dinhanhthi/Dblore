// WorkspaceHistoryTests.swift
// History list search, scope, paging, and the workspace actions that use a row.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Workspace history", .serialized)
@MainActor
struct WorkspaceHistoryTests {
  @Test("Scope uses the active connection and workspace, and a missing key searches all")
  func scopeFilters() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
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

    #expect(HistoryScope.all.selectedTitle == "All")
    #expect(HistoryScope.connection.menuTitle == "This Connection")
    #expect(HistoryScope.connection.selectedTitle == "This Conn")
    #expect(HistoryScope.workspace.menuTitle == "This Workspace")
    #expect(HistoryScope.workspace.selectedTitle == "This Wks")
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

  @Test("Each page holds 50 rows, and the next page is a separate load")
  func pagingLoadsOnePage() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<51 {
      try await store.record(
        Self.entry(sql: "SELECT \(index)", at: start.addingTimeInterval(Double(index) * 10)))
    }
    let manager = makeManager(store: store)

    await manager.historyList.searchNow()
    #expect(manager.historyList.results.count == 50)
    #expect(manager.historyList.totalCount == 51)
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.results.first?.sql == "SELECT 50")
    #expect(
      manager.historyList.pageLabel
        == HistoryListModel.pageLabel(page: 1, pageSize: HistoryListModel.pageSize, total: 51))

    await manager.historyList.goToPage(2)
    #expect(manager.historyList.page == 2)
    #expect(manager.historyList.results.map(\.sql) == ["SELECT 0"])

    await manager.historyList.goToPage(9)
    #expect(manager.historyList.page == 2)
    #expect(manager.historyList.results.map(\.sql) == ["SELECT 0"])

    let oldest = try #require(manager.historyList.results.first)
    await manager.deleteHistory(ids: [oldest.id])
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.totalCount == 50)
    #expect(manager.historyList.results.count == 50)
  }

  @Test("Changing status resets paging and updates matching rows")
  func statusResetsPaging() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<51 {
      try await store.record(
        Self.entry(
          sql: "SELECT \(index)", at: start.addingTimeInterval(Double(index) * 10),
          status: index == 0 ? .error : .success))
    }
    let manager = makeManager(store: store)
    await manager.historyList.searchNow()
    await manager.historyList.goToPage(2)
    #expect(manager.historyList.page == 2)

    manager.historyList.status = .error
    await manager.historyList.searchNow()
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.totalCount == 1)
    #expect(manager.historyList.results.map(\.sql) == ["SELECT 0"])
  }

  @Test("deleteHistory removes the row from the list and the store")
  func deleteHistoryRemovesRow() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
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

  @Test("insertHistory does not insert a transaction summary label")
  func insertHistorySkipsTransactionSummary() {
    let manager = makeManager()
    manager.newNotebook()
    let captured = CapturedInsertion()
    let token = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { note in
      captured.text = note.userInfo?["text"] as? String
    }
    defer { NotificationCenter.default.removeObserver(token) }

    #expect(QueryHistoryEntry.isTransactionSummary("COMMIT (2 statements)"))
    #expect(QueryHistoryEntry.isTransactionSummary("ROLLBACK (1 statements)"))
    #expect(!QueryHistoryEntry.isTransactionSummary("COMMIT"))
    #expect(!QueryHistoryEntry.isTransactionSummary("ROLLBACK TO SAVEPOINT s"))
    #expect(!QueryHistoryEntry.isTransactionSummary("SELECT 1"))

    manager.insertHistory(Self.entry(sql: "COMMIT (2 statements)", kind: .transaction))
    manager.insertHistory(Self.entry(sql: "ROLLBACK (1 statements)", kind: .transaction))
    #expect(captured.text == nil)

    manager.insertHistory(Self.entry(sql: "COMMIT"))
    #expect(captured.text == "COMMIT")
  }

  @Test("copyHistory does not copy a transaction summary label")
  func copyHistorySkipsTransactionSummary() {
    let manager = makeManager()
    #expect(manager.copyHistory(Self.entry(sql: "SELECT copy_me")))
    #expect(!manager.copyHistory(Self.entry(sql: "COMMIT (2 statements)", kind: .transaction)))
    #expect(NSPasteboard.general.string(forType: .string) == "SELECT copy_me")
    #expect(
      WorkspaceManager.historyClipboardText(Self.entry(sql: "ROLLBACK (1 statements)")) == nil)

    #expect(!manager.copyHistory(Self.entry(sql: "ROLLBACK (1 statements)", kind: .transaction)))
    #expect(NSPasteboard.general.string(forType: .string) == "SELECT copy_me")
  }

  @Test("Dump and restore rows are labels: Insert and Copy skip them by source or by text")
  func insertAndCopySkipDumpAndRestoreLabels() {
    #expect(QueryHistoryEntry.isLabelText("SQL dump of shop: 3 tables, 120 rows"))
    #expect(QueryHistoryEntry.isLabelText("SQL dump of app.sqlite: 1 table, 1 row"))
    #expect(QueryHistoryEntry.isLabelText("SQL dump of a: b: 0 tables, 0 rows"))
    #expect(QueryHistoryEntry.isLabelText("Restore SQL dump: 7 statements"))
    #expect(QueryHistoryEntry.isLabelText("Restore SQL dump: 1 statement"))
    #expect(QueryHistoryEntry.isLabelText("COMMIT (2 statements)"))
    #expect(!QueryHistoryEntry.isLabelText("SQL dump of shop"))
    #expect(!QueryHistoryEntry.isLabelText("SQL dump of shop: 3 tables"))
    #expect(!QueryHistoryEntry.isLabelText("SQL dump of shop: x tables, 1 rows"))
    #expect(!QueryHistoryEntry.isLabelText("SQL dump of shop: 3 tables, 1 rows; DROP TABLE t"))
    #expect(!QueryHistoryEntry.isLabelText("Restore SQL dump: statements"))
    #expect(!QueryHistoryEntry.isLabelText("Restore SQL dump: 7 statements; DROP TABLE t"))
    #expect(!QueryHistoryEntry.isLabelText("SELECT 'Restore SQL dump: 7 statements'"))
    #expect(!QueryHistoryEntry.isLabelText("SELECT 1"))

    // By source whatever the text, and by text for a transaction summary
    #expect(Self.entry(sql: "SELECT 1", source: .dump).isLabel)
    #expect(Self.entry(sql: "SELECT 1", source: .restore).isLabel)
    #expect(Self.entry(sql: "COMMIT (2 statements)", kind: .transaction).isLabel)
    #expect(!Self.entry(sql: "SELECT 1", source: .editor).isLabel)

    let manager = makeManager()
    manager.newNotebook()
    let captured = CapturedInsertion()
    let token = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { note in
      captured.text = note.userInfo?["text"] as? String
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let dump = Self.entry(sql: "SQL dump of shop: 3 tables, 120 rows", source: .dump, kind: .read)
    let restore = Self.entry(
      sql: "Restore SQL dump: 7 statements", source: .restore, kind: .schema)
    manager.insertHistory(dump)
    manager.insertHistory(restore)
    #expect(captured.text == nil)
    #expect(WorkspaceManager.historyClipboardText(dump) == nil)
    #expect(WorkspaceManager.historyClipboardText(restore) == nil)
    #expect(!manager.copyHistory(dump))
    #expect(!manager.copyHistory(restore))
  }

  @Test("A history data change reloads the first page and other categories do not")
  func localDataChangeReloadsHistory() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT old", at: start))
    let list = HistoryListModel()
    list.browser = { store }

    await list.searchNow()
    #expect(list.results.map(\.sql) == ["SELECT old"])

    try await store.record(Self.entry(sql: "SELECT new", at: start.addingTimeInterval(10)))
    postLocalDataChange(.logs)
    try await Task.sleep(for: .milliseconds(400))
    #expect(list.results.map(\.sql) == ["SELECT old"])

    postLocalDataChange(.queryHistory)
    await waitUntil { list.results.map(\.sql) == ["SELECT new", "SELECT old"] }
    #expect(list.results.map(\.sql) == ["SELECT new", "SELECT old"])

    try await store.record(Self.entry(sql: "SELECT all", at: start.addingTimeInterval(20)))
    postLocalDataChange(nil)
    await waitUntil {
      list.results.map(\.sql) == ["SELECT all", "SELECT new", "SELECT old"]
    }
    #expect(list.results.map(\.sql) == ["SELECT all", "SELECT new", "SELECT old"])
  }

  @Test("Recording a statement reloads an open history list")
  func recordingReloadsOpenHistoryList() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let manager = makeManager(store: store)
    manager.newNotebook()
    let viewModel = try #require(manager.activeViewModel)
    let suiteName = "WorkspaceHistoryTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    viewModel.historySettings = settings
    viewModel.historyRecorder = store

    await viewModel.recordExecution(
      [
        QueryHistoryOutcome(
          sql: "SELECT new", duration: 0.01, rowCount: 1, status: .success, errorMessage: nil)
      ],
      source: .cell)

    await waitUntil { manager.historyList.results.map(\.sql) == ["SELECT new"] }
    #expect(manager.historyList.results.map(\.sql) == ["SELECT new"])
  }

  private static let connectionKey = "PostgreSQL|localhost|5432|app|ana"

  private static func entry(
    sql: String,
    at executedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    connectionKey: String = connectionKey,
    workspaceID: UUID? = nil,
    status: QueryHistoryEntry.Status = .success,
    source: QueryHistoryEntry.Source = .cell,
    kind: QueryHistoryEntry.Kind? = nil
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0,
      sql: sql,
      executedAt: executedAt,
      durationMs: 1,
      rowCount: 1,
      status: status,
      errorMessage: nil,
      connectionKey: connectionKey,
      connectionLabel: "Prod",
      workspaceID: workspaceID,
      workspaceName: nil,
      source: source,
      kind: kind
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

  private func postLocalDataChange(_ category: LocalDataCategory?) {
    var userInfo: [AnyHashable: Any]?
    if let category {
      userInfo = [LocalDataCategory.userInfoKey: category.rawValue]
    }
    NotificationCenter.default.post(name: .localDataChanged, object: nil, userInfo: userInfo)
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(30)
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
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
