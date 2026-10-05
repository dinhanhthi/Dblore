// QueryHistoryStoreTests.swift
// Query history persists in SQLite, searches with FTS5, and round-trips as JSON.

import Foundation
import SQLite3
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
    #expect(
      prefix.map(\.sql).sorted() == [
        "DELETE FROM customers",
        "SELECT * FROM customers WHERE city = 'Paris'",
        "SELECT name FROM customers",
      ])

    let terms = try await store.search(text: "select name", scope: .all, limit: 10, offset: 0)
    #expect(terms.map(\.sql) == ["SELECT name FROM customers"])

    let recent = try await store.search(text: "   ", scope: .all, limit: 10, offset: 0)
    #expect(
      recent.map(\.sql) == [
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

  @Test("Status combines with search and scope before paging and counting")
  func statusFilters() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(Self.entry(sql: "SELECT ok", at: start, connectionKey: "c1"))
    try await store.record(
      Self.entry(
        sql: "SELECT failed", at: start.addingTimeInterval(10), status: .error,
        connectionKey: "c1"))
    try await store.record(
      Self.entry(
        sql: "SELECT cancelled", at: start.addingTimeInterval(20), status: .cancelled,
        connectionKey: "c1"))
    try await store.record(
      Self.entry(
        sql: "SELECT other", at: start.addingTimeInterval(30), status: .error,
        connectionKey: "c2"))

    #expect(try await store.count(text: "select", scope: .connection("c1"), status: .error) == 1)
    let failed = try await store.search(
      text: "select", scope: .connection("c1"), status: .error, limit: 1, offset: 0)
    #expect(failed.map(\.sql) == ["SELECT failed"])
    let next = try await store.search(
      text: "select", scope: .connection("c1"), status: .error, limit: 1, offset: 1)
    #expect(next.isEmpty)
    let cancelled = try await store.search(
      text: "", scope: .all, status: .cancelled, limit: 10, offset: 0)
    #expect(cancelled.map(\.sql) == ["SELECT cancelled"])
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

  @Test("An empty v0 file migrates to userVersion 2 and a second open stays at 2")
  func migrationFromEmptyV0() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    do {
      let empty = try SQLiteHandle(url: url)
      #expect(empty.userVersion == 0)
    }
    let store = try QueryHistoryStore(url: url)
    #expect(try SQLiteHandle(url: url).userVersion == 2)
    #expect(try await store.fileSize() > 0)
    #expect(try await store.count() == 0)
    let reopened = try QueryHistoryStore(url: url)
    #expect(try SQLiteHandle(url: url).userVersion == 2)
    #expect(try await reopened.count() == 0)
  }

  @Test("A v1 file gains kind, backfills from the connection dialect, and leaves NULL")
  func version1MigratesAndBackfillsKind() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let postgres = "PostgreSQL|localhost|5432|app|user"
    let sqlite = "SQLite|/tmp/app.sqlite|0|app|user"
    let rows: [(sql: String, key: String, kind: QueryHistoryEntry.Kind?)] = [
      ("SELECT 1", postgres, .read),
      ("UPDATE t SET a = 1", postgres, .write),
      ("CREATE TABLE t (a int)", postgres, .schema),
      ("COMMIT", postgres, .transaction),
      ("VACUUM", postgres, .other),
      ("-- comment only", postgres, nil),
      ("PRAGMA foreign_keys", sqlite, .read),
      ("PRAGMA foreign_keys", postgres, .other),
      ("REPLACE INTO t VALUES (1)", sqlite, .write),
      ("REPLACE INTO t VALUES (1)", postgres, .other),
      ("SELECT 1; DELETE FROM t", postgres, .write),
      ("DROP TABLE t; INSERT INTO t VALUES (1)", postgres, .write),
      ("EXPLAIN SELECT 1", postgres, .read),
      ("EXPLAIN ANALYZE DELETE FROM t", postgres, .write),
    ]
    try seedVersion1(at: url, rows: rows.map { (sql: $0.sql, key: $0.key) })
    #expect(try SQLiteHandle(url: url).userVersion == 1)

    let store = try QueryHistoryStore(url: url)
    let loaded = try await store.search(text: "", scope: .all, limit: 50, offset: 0)
    #expect(try SQLiteHandle(url: url).userVersion == 2)
    let info = try SQLiteHandle(url: url)
    let tables = try info.prepare(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'history'")
    #expect(try tables.step())
    #expect(tables.columnInt(0) == 1)
    let columns = try info.prepare(
      "SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = 'kind'")
    #expect(try columns.step())
    #expect(columns.columnInt(0) == 1)
    let trigger = try info.prepare(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'history_au'")
    #expect(try trigger.step())
    #expect(trigger.columnInt(0) == 1)

    let actual = loaded.map { row in
      "\(row.connectionKey)|\(row.sql)|\(row.kind?.rawValue ?? "nil")"
    }.sorted()
    let wanted = rows.map { row in
      "\(row.key)|\(row.sql)|\(row.kind?.rawValue ?? "nil")"
    }.sorted()
    #expect(actual == wanted)
    let matched = try await store.search(text: "UPDATE", scope: .all, limit: 20, offset: 0)
    #expect(matched.contains { $0.sql == "UPDATE t SET a = 1" })

    let reopened = try QueryHistoryStore(url: url)
    let again = try await reopened.search(text: "", scope: .all, limit: 50, offset: 0)
    #expect(again == loaded)
  }

  @Test("A failed v1 migration rolls back, stays on v1, and later calls throw the same error")
  func failedVersion1MigrationRollsBackAndRethrows() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    try seedVersion1(at: url, rows: [(sql: "UPDATE t SET a = 1", key: "PostgreSQL|h|5432|d|u")])
    // A v1 file that already has `kind` makes `ALTER TABLE ... ADD COLUMN kind` fail.
    try SQLiteHandle(url: url).execute("ALTER TABLE history ADD COLUMN kind TEXT")

    let store = try QueryHistoryStore(url: url)
    let first = await #expect(throws: (any Error).self) {
      try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    }
    do {
      let info = try SQLiteHandle(url: url)
      #expect(info.userVersion == 1)
      let trigger = try info.prepare(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'history_au'")
      #expect(try trigger.step())
      #expect(trigger.columnInt(0) == 1)
      let kinds = try info.prepare("SELECT COUNT(*) FROM history WHERE kind IS NOT NULL")
      #expect(try kinds.step())
      #expect(kinds.columnInt(0) == 0)
    }

    // The store keeps its schema cache, so the only signal is the stored error coming back.
    let second = await #expect(throws: (any Error).self) {
      try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    }
    #expect(second as? SQLiteError == first as? SQLiteError)
    #expect((first as? SQLiteError)?.message.contains("duplicate column name: kind") == true)
    #expect(try SQLiteHandle(url: url).userVersion == 1)
  }

  @Test("A busy file fails the migration without latching, and a later call migrates")
  func busyMigrationRetriesOnNextCall() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    try seedVersion1(at: url, rows: [(sql: "UPDATE t SET a = 1", key: "PostgreSQL|h|5432|d|u")])
    let store = try QueryHistoryStore(url: url)

    // Another connection holds the write lock past the 2 s busy timeout.
    let holder = try SQLiteHandle(url: url)
    try holder.execute("BEGIN EXCLUSIVE")
    let first = await #expect(throws: (any Error).self) {
      try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    }
    #expect((first as? SQLiteError)?.code == SQLITE_BUSY)
    try holder.execute("ROLLBACK")

    let entries = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(entries.map(\.kind) == [.write])
    #expect(try SQLiteHandle(url: url).userVersion == 2)
  }

  @Test("writesOnly keeps kind write in search and count, and NULL is not a write")
  func writesOnlyFiltersSearchAndCount() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    try await store.record(Self.entry(sql: "SELECT plain", kind: .read))
    try await store.record(Self.entry(sql: "UPDATE t SET a = 1", kind: .write))
    try await store.record(
      Self.entry(sql: "DELETE FROM other", connectionKey: "other", kind: .write))
    try await store.record(Self.entry(sql: "CREATE TABLE t (a int)", kind: .schema))
    try await store.record(Self.entry(sql: "COMMIT", kind: .transaction))
    try await store.record(Self.entry(sql: "VACUUM", kind: .other))
    try await store.record(Self.entry(sql: "UPDATE unclassified SET a = 1"))
    try await store.record(Self.entry(sql: "SELECT labeled", kind: .write))

    let writes = try await store.search(
      text: "", scope: .all, limit: 20, offset: 0, writesOnly: true)
    #expect(
      writes.map(\.sql).sorted() == [
        "DELETE FROM other", "SELECT labeled", "UPDATE t SET a = 1",
      ])
    #expect(try await store.count(text: "", scope: .all, writesOnly: true) == 3)
    #expect(try await store.count(text: "", scope: .all) == 8)
    #expect(try await store.count() == 8)

    let scoped = try await store.search(
      text: "", scope: .connection("other"), limit: 10, offset: 0, writesOnly: true)
    #expect(scoped.map(\.sql) == ["DELETE FROM other"])
    #expect(
      try await store.count(text: "", scope: .connection("other"), writesOnly: true) == 1)

    let matched = try await store.search(
      text: "update", scope: .all, limit: 10, offset: 0, writesOnly: true)
    #expect(matched.map(\.sql) == ["UPDATE t SET a = 1"])
    #expect(try await store.count(text: "update", scope: .all, writesOnly: true) == 1)
    #expect(try await store.count(text: "update", scope: .all) == 2)

    let reads = try await store.search(
      text: "select", scope: .all, limit: 10, offset: 0, writesOnly: true)
    #expect(reads.map(\.sql) == ["SELECT labeled"])
    #expect(try await store.count(text: "select", scope: .all, writesOnly: true) == 1)
  }

  @Test("Status and writesOnly combine, and NULL kind stays out")
  func statusAndWritesOnlyCombine() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let rows: [(sql: String, status: QueryHistoryEntry.Status, kind: QueryHistoryEntry.Kind?)] = [
      ("UPDATE failed one", .error, .write),
      ("UPDATE failed two", .error, .write),
      ("UPDATE ok", .success, .write),
      ("SELECT failed", .error, .read),
      ("UPDATE failed unlabeled", .error, nil),
      ("DELETE cancelled", .cancelled, .write),
    ]
    for (index, row) in rows.enumerated() {
      try await store.record(
        Self.entry(
          sql: row.sql, at: start.addingTimeInterval(Double(index) * 10), status: row.status,
          kind: row.kind))
    }

    #expect(try await store.count(text: "", scope: .all, status: .error, writesOnly: true) == 2)
    let firstPage = try await store.search(
      text: "", scope: .all, status: .error, limit: 1, offset: 0, writesOnly: true)
    #expect(firstPage.map(\.sql) == ["UPDATE failed two"])
    let secondPage = try await store.search(
      text: "", scope: .all, status: .error, limit: 1, offset: 1, writesOnly: true)
    #expect(secondPage.map(\.sql) == ["UPDATE failed one"])

    #expect(try await store.count(text: "", scope: .all, status: .error) == 4)
    #expect(try await store.count(text: "", scope: .all, writesOnly: true) == 4)
    #expect(
      try await store.count(text: "update", scope: .all, status: .success, writesOnly: true) == 1)
  }

  @Test("Old JSON without kind imports, and a present kind is stored as written")
  func oldJSONImportDecodesMissingKind() async throws {
    let url = temporaryDatabaseURL()
    let jsonURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-history-\(UUID().uuidString).json")
    defer {
      removeDatabase(at: url)
      try? FileManager.default.removeItem(at: jsonURL)
    }
    let json = """
      [
        {
          "connectionKey": "k",
          "connectionLabel": "label",
          "durationMs": 4,
          "executedAt": 1700000000,
          "id": 4,
          "rowCount": 1,
          "source": "cell",
          "sql": "DELETE FROM old",
          "status": "success"
        },
        {
          "connectionKey": "k",
          "connectionLabel": "label",
          "durationMs": 4,
          "executedAt": 1700000100,
          "id": 9,
          "kind": "write",
          "rowCount": 1,
          "source": "editor",
          "sql": "SELECT kept",
          "status": "success"
        },
        {
          "connectionKey": "k",
          "connectionLabel": "label",
          "durationMs": 4,
          "executedAt": 1700000200,
          "id": 10,
          "kind": null,
          "source": "dataViewerEdit",
          "sql": "SELECT present",
          "status": "cancelled"
        }
      ]
      """
    try json.write(to: jsonURL, atomically: true, encoding: .utf8)
    let store = try QueryHistoryStore(url: url)
    try await store.record(Self.entry(sql: "SHOULD BE CLEARED"))
    try await store.importJSON(from: jsonURL, replace: true)

    let imported = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(imported.map(\.sql) == ["SELECT present", "SELECT kept", "DELETE FROM old"])
    #expect(imported.map(\.id) == [10, 9, 4])
    #expect(imported.map(\.kind) == [nil, .write, nil])
    #expect(imported.map(\.source) == [.dataViewerEdit, .editor, .cell])
    #expect(imported[0].status == .cancelled)
    #expect(imported[2].status == .success)
  }

  @Test("An unknown source raw value is read as editor")
  func unknownSourceReadsAsEditor() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try QueryHistoryStore(url: url)
    try await store.record(Self.entry(sql: "SELECT cell", source: .cell))
    let database = try SQLiteHandle(url: url)
    let statement = try database.prepare(
      """
      INSERT INTO history (
        sql, executed_at, duration_ms, row_count, status,
        connection_key, connection_label, source, kind
      ) VALUES ('SELECT kept', 1700000000, 1, 1, 'success', 'k', 'label', 'futureSource', 'read')
      """
    )
    while try statement.step() {}

    let rows = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    let unknown = try #require(rows.first { $0.sql == "SELECT kept" })
    #expect(unknown.source == .editor)
    #expect(unknown.kind == .read)
    let known = try #require(rows.first { $0.sql == "SELECT cell" })
    #expect(known.source == .cell)
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
    source: QueryHistoryEntry.Source = .cell,
    kind: QueryHistoryEntry.Kind? = nil
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
      source: source,
      kind: kind
    )
  }

  /// Frozen version-1 schema: no `kind` column, `user_version` 1.
  private func seedVersion1(at url: URL, rows: [(sql: String, key: String)]) throws {
    let database = try SQLiteHandle(url: url)
    try database.transaction {
      try database.execute(
        """
        CREATE TABLE history (
          id INTEGER PRIMARY KEY,
          sql TEXT NOT NULL,
          executed_at REAL NOT NULL,
          duration_ms INTEGER NOT NULL,
          row_count INTEGER,
          status TEXT NOT NULL,
          error_message TEXT,
          connection_key TEXT NOT NULL,
          connection_label TEXT NOT NULL,
          workspace_id TEXT,
          workspace_name TEXT,
          source TEXT NOT NULL
        )
        """
      )
      try database.execute(
        """
        CREATE VIRTUAL TABLE history_fts USING fts5(
          sql,
          error_message,
          connection_label,
          workspace_name,
          content='history',
          content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        )
        """
      )
      try database.execute(
        """
        CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
          INSERT INTO history_fts(rowid, sql, error_message, connection_label, workspace_name)
          VALUES (new.id, new.sql, new.error_message, new.connection_label, new.workspace_name);
        END
        """
      )
      try database.execute(
        """
        CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
          INSERT INTO history_fts(
            history_fts, rowid, sql, error_message, connection_label, workspace_name
          )
          VALUES (
            'delete', old.id, old.sql, old.error_message, old.connection_label, old.workspace_name
          );
        END
        """
      )
      try database.execute(
        """
        CREATE TRIGGER history_au AFTER UPDATE ON history BEGIN
          INSERT INTO history_fts(
            history_fts, rowid, sql, error_message, connection_label, workspace_name
          )
          VALUES (
            'delete', old.id, old.sql, old.error_message, old.connection_label, old.workspace_name
          );
          INSERT INTO history_fts(rowid, sql, error_message, connection_label, workspace_name)
          VALUES (new.id, new.sql, new.error_message, new.connection_label, new.workspace_name);
        END
        """
      )
      try database.execute("CREATE INDEX history_executed_at ON history(executed_at)")
      try database.execute("CREATE INDEX history_connection_key ON history(connection_key)")
      try database.execute("PRAGMA user_version = 1")
    }
    for (offset, row) in rows.enumerated() {
      let statement = try database.prepare(
        """
        INSERT INTO history (
          sql, executed_at, duration_ms, row_count, status,
          connection_key, connection_label, source
        ) VALUES (?, ?, 1, 1, 'success', ?, 'label', 'cell')
        """
      )
      try statement.bind(1, .string(row.sql))
      try statement.bind(2, .double(Double(1_700_000_000 + offset)))
      try statement.bind(3, .string(row.key))
      while try statement.step() {}
    }
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
