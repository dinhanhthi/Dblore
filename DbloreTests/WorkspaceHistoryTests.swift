// WorkspaceHistoryTests.swift
// History list search, scope, paging, and the workspace actions that use a row.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Workspace history", .serialized)
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

  @Test("writesOnly from page 2 resets, then reloads with and without the filter")
  func writesOnlyResetsPageAndFilters() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let older: [(sql: String, kind: QueryHistoryEntry.Kind?)] = [
      ("UPDATE older", .write),
      ("UPDATE newer", .write),
      ("CREATE TABLE t", .schema),
      ("SELECT unlabeled", nil),
    ]
    let rows = older + (0..<50).map { ("SELECT \($0)", QueryHistoryEntry.Kind.read) }
    for (index, row) in rows.enumerated() {
      try await store.record(
        Self.entry(
          sql: row.sql, at: start.addingTimeInterval(Double(index) * 10), kind: row.kind))
    }
    let manager = makeManager(store: store)
    let pageTwo = ["SELECT unlabeled", "CREATE TABLE t", "UPDATE newer", "UPDATE older"]

    await manager.historyList.goToPage(2)
    #expect(manager.historyList.page == 2)
    #expect(manager.historyList.results.map(\.sql) == pageTwo)
    #expect(manager.historyList.totalCount == 54)

    manager.historyList.writesOnly = true
    #expect(manager.historyList.page == 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.results.map(\.sql) == pageTwo)

    try await Task.sleep(for: .milliseconds(400))
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.totalCount == 2)
    #expect(manager.historyList.results.map(\.sql) == ["UPDATE newer", "UPDATE older"])

    manager.historyList.writesOnly = false
    try await Task.sleep(for: .milliseconds(100))
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.results.map(\.sql) == ["UPDATE newer", "UPDATE older"])

    try await Task.sleep(for: .milliseconds(400))
    #expect(manager.historyList.page == 1)
    #expect(manager.historyList.totalCount == 54)
    #expect(manager.historyList.results.count == 50)
    #expect(manager.historyList.results.first?.sql == "SELECT 49")
  }

  @Test("History badges name kind and source, and nil kind has no kind label")
  func historyBadgeLabels() {
    #expect(HistoryRowLabels.kindLabel(.read) == "Read")
    #expect(HistoryRowLabels.kindLabel(.write) == "Write")
    #expect(HistoryRowLabels.kindLabel(.schema) == "Schema")
    #expect(HistoryRowLabels.kindLabel(.transaction) == "Transaction")
    #expect(HistoryRowLabels.kindLabel(.other) == "Other")
    #expect(HistoryRowLabels.kindLabel(nil) == nil)
    #expect(HistoryRowLabels.sourceLabel(.cell) == "Cell")
    #expect(HistoryRowLabels.sourceLabel(.editor) == "Editor")
    #expect(HistoryRowLabels.sourceLabel(.dataViewerEdit) == "Data Viewer Edit")
  }

  @Test("History age is minute resolution and does not name seconds")
  func historyAgeStopsAtMinutes() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(HistoryRelativeTime.label(from: now.addingTimeInterval(-5), now: now) == "just now")
    #expect(HistoryRelativeTime.label(from: now.addingTimeInterval(-59), now: now) == "just now")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-60), now: now) == "1 minute ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-119), now: now) == "1 minute ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-120), now: now) == "2 minutes ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-3_600), now: now) == "1 hour ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-7_200), now: now) == "2 hours ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-86_400), now: now) == "1 day ago")
    #expect(
      HistoryRelativeTime.label(from: now.addingTimeInterval(-2 * 86_400), now: now)
        == "2 days ago")
    let week = HistoryRelativeTime.label(from: now.addingTimeInterval(-8 * 86_400), now: now)
    #expect(week.localizedCaseInsensitiveContains("second") == false)
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

  @Test("copyHistory copies the SQL")
  func copyHistoryCopiesSQL() {
    let manager = makeManager()
    manager.copyHistory(Self.entry(sql: "SELECT copy_me"))
    #expect(NSPasteboard.general.string(forType: .string) == "SELECT copy_me")
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
    workspaceID: UUID? = nil,
    kind: QueryHistoryEntry.Kind? = nil
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
      source: .cell,
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
    _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)
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
