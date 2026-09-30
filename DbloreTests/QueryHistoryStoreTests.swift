// QueryHistoryStoreTests.swift
// Query history persists in SQLite, searches with FTS5, and round-trips as JSON.

import Foundation
import Testing

@testable import Dblore

@Suite("Query history store", .serialized)
struct QueryHistoryStoreTests {
  @Test("FTS prefix and multi-term search, and blank text is newest first")
  func ftsPrefixAndMultiTermSearch() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      Self.entry(sql: "SELECT * FROM customers WHERE city = 'Paris'", at: start))
    try await store.record(
      Self.entry(sql: "DELETE FROM customers", at: start.addingTimeInterval(10)))
    try await store.record(
      Self.entry(sql: "SELECT name FROM customers", at: start.addingTimeInterval(20)))

    let prefix = try await store.search(text: "cust", scope: .all, limit: 10, offset: 0)
    #expect(prefix.map(\.sql).sorted() == [
      "DELETE FROM customers",
      "SELECT * FROM customers WHERE city = 'Paris'",
      "SELECT name FROM customers",
    ])

    let terms = try await store.search(text: "select name", scope: .all, limit: 10, offset: 0)
    #expect(terms.map(\.sql) == ["SELECT name FROM customers"])

    let recent = try await store.search(text: "   ", scope: .all, limit: 10, offset: 0)
    #expect(recent.map(\.sql) == [
      "SELECT name FROM customers",
      "DELETE FROM customers",
      "SELECT * FROM customers WHERE city = 'Paris'",
    ])

    let page = try await store.search(text: "", scope: .all, limit: 1, offset: 1)
    #expect(page.map(\.sql) == ["DELETE FROM customers"])
  }

  @Test("MATCH-syntax characters do not throw and do not match unrelated rows")
  func matchSyntaxCharactersStayLiteral() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    try await store.record(Self.entry(sql: "SELECT 1"))
    try await store.record(Self.entry(sql: "SELECT NEAR thing", at: Date(timeIntervalSince1970: 2)))

    for query in ["\"", "*", "NEAR", "-", "\" * NEAR -"] {
      let unrelated = try await store.search(text: query, scope: .all, limit: 10, offset: 0)
      #expect(!unrelated.contains { $0.sql == "SELECT 1" })
    }

    let near = try await store.search(text: "NEAR", scope: .all, limit: 10, offset: 0)
    #expect(near.map(\.sql) == ["SELECT NEAR thing"])
    let star = try await store.search(text: "*", scope: .all, limit: 10, offset: 0)
    #expect(star.isEmpty)
    let quote = try await store.search(text: "\"", scope: .all, limit: 10, offset: 0)
    #expect(quote.isEmpty)
    let dash = try await store.search(text: "-", scope: .all, limit: 10, offset: 0)
    #expect(dash.isEmpty)
  }

  @Test("Scope filters by connection and workspace")
  func scopeFilters() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let workspace = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let other = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      Self.entry(
        sql: "SELECT a", at: start, connectionKey: "c1", workspaceID: workspace,
        workspaceName: "One"))
    try await store.record(
      Self.entry(
        sql: "SELECT b", at: start.addingTimeInterval(1), connectionKey: "c2",
        workspaceID: workspace, workspaceName: "One"))
    try await store.record(
      Self.entry(
        sql: "SELECT c", at: start.addingTimeInterval(2), connectionKey: "c1",
        workspaceID: other, workspaceName: "Two"))

    let byConnection = try await store.search(
      text: "", scope: .connection("c1"), limit: 10, offset: 0)
    #expect(byConnection.map(\.sql) == ["SELECT c", "SELECT a"])

    let byWorkspace = try await store.search(
      text: "", scope: .workspace(workspace), limit: 10, offset: 0)
    #expect(byWorkspace.map(\.sql) == ["SELECT b", "SELECT a"])

    let filtered = try await store.search(
      text: "select", scope: .connection("c2"), limit: 10, offset: 0)
    #expect(filtered.map(\.sql) == ["SELECT b"])
  }

  @Test("Prune drops rows older than a date, then trims to a maximum count")
  func pruneByAgeAndCount() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    try await store.record(Self.entry(sql: "old", at: Date(timeIntervalSince1970: 1_000)))
    try await store.record(Self.entry(sql: "cutoff", at: Date(timeIntervalSince1970: 1_500)))
    try await store.record(Self.entry(sql: "mid", at: Date(timeIntervalSince1970: 2_000)))
    try await store.record(Self.entry(sql: "recent", at: Date(timeIntervalSince1970: 3_000)))

    try await store.prune(olderThan: Date(timeIntervalSince1970: 1_500), maxEntries: nil)
    #expect(try await store.count() == 3)
    let aged = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(aged.map(\.sql) == ["recent", "mid", "cutoff"])

    try await store.prune(olderThan: nil, maxEntries: 2)
    let trimmed = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(trimmed.map(\.sql) == ["recent", "mid"])
    #expect(try await store.count() == 2)
  }

  @Test("Same SQL and connection within 2 seconds collapses; outside 2 seconds inserts")
  func dedupeWindow() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 50_000)
    try await store.record(
      Self.entry(
        sql: "SELECT 1", at: start, durationMs: 5, rowCount: nil, status: .error,
        errorMessage: "nope", connectionKey: "c1"))
    try await store.record(
      Self.entry(
        sql: "SELECT 1", at: start.addingTimeInterval(2), durationMs: 9, rowCount: 4,
        status: .success, errorMessage: nil, connectionKey: "c1"))

    #expect(try await store.count() == 1)
    let collapsed = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(collapsed.count == 1)
    #expect(collapsed[0].id != 0)
    #expect(collapsed[0].durationMs == 9)
    #expect(collapsed[0].rowCount == 4)
    #expect(collapsed[0].status == .success)
    #expect(collapsed[0].errorMessage == nil)
    #expect(collapsed[0].executedAt == start.addingTimeInterval(2))

    try await store.record(
      Self.entry(
        sql: "SELECT 1", at: start.addingTimeInterval(4.001), connectionKey: "c1"))
    #expect(try await store.count() == 2)

    try await store.record(
      Self.entry(
        sql: "SELECT 1", at: start.addingTimeInterval(4.001), connectionKey: "c2"))
    #expect(try await store.count() == 3)
  }

  @Test("SQL longer than 100000 characters is stored with a truncation marker")
  func truncatesLongSQL() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let sql = String(repeating: "a", count: 100_001)
    try await store.record(Self.entry(sql: sql))
    let rows = try await store.search(text: "", scope: .all, limit: 1, offset: 0)
    let stored = try #require(rows.first)
    #expect(stored.sql.hasPrefix(String(repeating: "a", count: 100_000)))
    #expect(stored.sql.hasSuffix("\n-- truncated"))
    #expect(stored.sql.count == 100_000 + "\n-- truncated".count)
  }

  @Test("An empty v0 file migrates to userVersion 1 and a second open stays at 1")
  func migrationFromEmptyV0() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    do {
      let empty = try SQLiteHandle(url: url)
      #expect(empty.userVersion == 0)
    }
    let store = try QueryHistoryStore(url: url)
    #expect(try SQLiteHandle(url: url).userVersion == 1)
    #expect(try await store.fileSize() > 0)
    #expect(try await store.count() == 0)
    let reopened = try QueryHistoryStore(url: url)
    #expect(try SQLiteHandle(url: url).userVersion == 1)
    #expect(try await reopened.count() == 0)
  }

  @Test("200 concurrent records of distinct SQL insert 200 rows")
  func concurrentRecords() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<200 {
        group.addTask {
          try await store.record(Self.entry(sql: "SELECT \(index)", at: at))
        }
      }
      try await group.waitForAll()
    }
    #expect(try await store.count() == 200)
  }

  @Test("Export and import round-trip, and replace clears existing rows")
  func exportImportRoundTrip() async throws {
    let url = temporaryDatabaseURL()
    let copyURL = temporaryDatabaseURL()
    let jsonURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-history-\(UUID().uuidString).json")
    defer {
      removeDatabase(at: url)
      removeDatabase(at: copyURL)
      try? FileManager.default.removeItem(at: jsonURL)
    }
    let store = try QueryHistoryStore(url: url)
    let workspace = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      Self.entry(
        sql: "SELECT 1", at: start, durationMs: 12, rowCount: 1, status: .success,
        connectionKey: "k", connectionLabel: "label", workspaceID: workspace,
        workspaceName: "Work", source: .editor))
    try await store.record(
      Self.entry(
        sql: "SELECT bad", at: start.addingTimeInterval(100), durationMs: 4, rowCount: nil,
        status: .error, errorMessage: "syntax", connectionKey: "k", connectionLabel: "label",
        source: .cell))
    try await store.record(
      Self.entry(
        sql: "SELECT cancel", at: start.addingTimeInterval(200), durationMs: 1, rowCount: nil,
        status: .cancelled, connectionKey: "k", connectionLabel: "label",
        source: .dataViewerEdit))
    let original = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    try await store.exportJSON(to: jsonURL)

    let other = try QueryHistoryStore(url: copyURL)
    try await other.record(Self.entry(sql: "SHOULD BE CLEARED", at: start))
    try await other.importJSON(from: jsonURL, replace: true)
    let imported = try await other.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(imported == original)
  }

  @Test("Delete removes chosen ids and clear removes every row from search")
  func deleteAndClear() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT keep", at: start))
    try await store.record(Self.entry(sql: "SELECT drop", at: start.addingTimeInterval(1)))
    let rows = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    try await store.delete(ids: [rows[0].id])
    #expect(try await store.search(text: "drop", scope: .all, limit: 10, offset: 0).isEmpty)
    #expect(try await store.count() == 1)
    try await store.clear()
    #expect(try await store.count() == 0)
    #expect(try await store.search(text: "keep", scope: .all, limit: 10, offset: 0).isEmpty)
  }

  private static func entry(
    sql: String,
    at executedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    durationMs: Int = 1,
    rowCount: Int? = 1,
    status: QueryHistoryEntry.Status = .success,
    errorMessage: String? = nil,
    connectionKey: String = "PostgreSQL|localhost|5432|app|user",
    connectionLabel: String = "localhost/app",
    workspaceID: UUID? = nil,
    workspaceName: String? = nil,
    source: QueryHistoryEntry.Source = .cell
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0,
      sql: sql,
      executedAt: executedAt,
      durationMs: durationMs,
      rowCount: rowCount,
      status: status,
      errorMessage: errorMessage,
      connectionKey: connectionKey,
      connectionLabel: connectionLabel,
      workspaceID: workspaceID,
      workspaceName: workspaceName,
      source: source
    )
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-history-\(UUID().uuidString).sqlite")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
}
