// SQLiteQueryParameterTests.swift
// Named parameters against a temporary SQLite file, including LIMIT bound as text.
// SQLite has no server cursor and coerces inconsistent binds, so those are not required.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite Query Parameters")
@MainActor
struct SQLiteQueryParameterTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  private static func sqliteConfig(path: String, protectedMode: Bool) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent,
      protectedMode: protectedMode
    )
  }

  private static func seed(_ url: URL, table: String, rows: [(Int, String)]) throws {
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT)")
    let values = rows.map { "(\($0.0), '\($0.1)')" }.joined(separator: ", ")
    try handle.execute("INSERT INTO \(table) (id, name) VALUES \(values)")
  }

  private static func removeDatabase(_ url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  /// Roll back a pending app transaction, then disconnect. The file is removed in `defer`.
  private static func finish(_ manager: DatabaseConnectionManager) async {
    if await !manager.transactionSnapshot().isIdle {
      try? await manager.rollbackAppTransaction()
    }
    await manager.disconnect()
  }

  private func withFile(
    protectedMode: Bool = false,
    rows: [(Int, String)] = [(1, "a"), (2, "b")],
    _ body: (DatabaseConnectionManager, String) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-qp-\(UUID().uuidString).sqlite")
    defer { Self.removeDatabase(url) }
    let table = "qp_p2_rows"
    try Self.seed(url, table: table, rows: rows)
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: Self.sqliteConfig(path: url.path, protectedMode: protectedMode))
    do {
      try await body(manager, table)
    } catch {
      await Self.finish(manager)
      throw error
    }
    await Self.finish(manager)
  }

  @Test("A bound id returns that row", .timeLimit(.minutes(1)))
  func whereBindReturnsTheMatchingRow() async throws {
    try await withFile { manager, table in
      let result = try await manager.execute(
        userSQL: "SELECT name FROM \(table) WHERE id = :id",
        parameters: ["id": .text("2")], policy: open)
      #expect(result.rows == [[.string("b")]])
    }
  }

  @Test("LIMIT :n bound as text returns the lowest id", .timeLimit(.minutes(1)))
  func limitBindReturnsTheLowestId() async throws {
    try await withFile { manager, table in
      let result = try await manager.execute(
        userSQL: "SELECT id FROM \(table) ORDER BY id LIMIT :n",
        parameters: ["n": .text("1")], policy: open)
      #expect(result.rows == [[.int(1)]])
    }
  }

  @Test("IN (:a, :b) returns exactly those two rows", .timeLimit(.minutes(1)))
  func inListReturnsTheBoundIds() async throws {
    try await withFile(rows: [(1, "a"), (2, "b"), (3, "c")]) { manager, table in
      let result = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE id IN (:a, :b) ORDER BY id",
        parameters: ["a": .text("1"), "b": .text("2")], policy: open)
      #expect(result.rows == [[.int(1)], [.int(2)]])
    }
  }

  @Test(
    "NULL equality matches nothing and IS NULL matches the seeded rows", .timeLimit(.minutes(1)))
  func nullBindMatchesOnlyIsNull() async throws {
    try await withFile { manager, table in
      let equal = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE name = :name ORDER BY id",
        parameters: ["name": .null], policy: open)
      #expect(equal.rows.isEmpty)

      let isNull = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE :name IS NULL ORDER BY id",
        parameters: ["name": .null], policy: open)
      #expect(isNull.rows == [[.int(1)], [.int(2)]])
    }
  }

  @Test("One reused name filters only when the value is present", .timeLimit(.minutes(1)))
  func optionalFilterReusesOneName() async throws {
    try await withFile { manager, table in
      let sql = "SELECT name FROM \(table) WHERE :name IS NULL OR name = :name ORDER BY id"
      let all = try await manager.execute(
        userSQL: sql, parameters: ["name": .null], policy: open)
      #expect(all.rows == [[.string("a")], [.string("b")]])

      let filtered = try await manager.execute(
        userSQL: sql, parameters: ["name": .text("a")], policy: open)
      #expect(filtered.rows == [[.string("a")]])
    }
  }

  @Test("A repeated name returns one row of two equal strings", .timeLimit(.minutes(1)))
  func repeatedNameReturnsTwoEqualStrings() async throws {
    try await withFile { manager, _ in
      let result = try await manager.execute(
        userSQL: "SELECT :n, :n", parameters: ["n": .text("z")], policy: open)
      #expect(result.rows == [[.string("z"), .string("z")]])
    }
  }

  @Test("Pending DML previews :name, and rollback restores the old name", .timeLimit(.minutes(1)))
  func pendingUpdatePreviewKeepsNamedSQL() async throws {
    try await withFile(protectedMode: true) { manager, table in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET name = :name WHERE id = :id",
        parameters: ["name": .text("z"), "id": .text("1")], policy: protected)
      let preview = try #require(
        await manager.transactionSnapshot().pending.first?.sqlPreview)
      #expect(preview.contains(":name"))
      #expect(!preview.contains("?"))

      try await manager.rollbackAppTransaction()
      let read = try await manager.execute(
        userSQL: "SELECT name FROM \(table) WHERE id = :id",
        parameters: ["id": .text("1")], policy: protected)
      #expect(read.rows == [[.string("a")]])
    }
  }

  @Test("EXPLAIN with a bind returns rows", .timeLimit(.minutes(1)))
  func explainWithBindReturnsRows() async throws {
    try await withFile { manager, table in
      let plan = try await manager.execute(
        userSQL: "EXPLAIN SELECT id FROM \(table) WHERE id = :id",
        parameters: ["id": .text("2")], policy: open)
      #expect(!plan.rows.isEmpty)
    }
  }
}
