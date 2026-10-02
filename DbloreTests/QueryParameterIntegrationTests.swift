// QueryParameterIntegrationTests.swift
// Named parameters against the docker PostgreSQL: bound values change the rows the server
// returns, and Protected mode keeps the original :name text.

import Foundation
import Testing

@testable import Dblore

@Suite("Query Parameter Integration", .requiresPostgres, .serialized)
@MainActor
struct QueryParameterIntegrationTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  private static func config(protectedMode: Bool) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: protectedMode
    )
  }

  private static func tableName(_ suffix: String) -> String {
    let token = UUID().uuidString.prefix(8).lowercased()
    return "qp_p2_\(suffix)_\(token)"
  }

  private static func create(
    _ table: String, rows: [(Int, String)], on manager: DatabaseConnectionManager
  ) async throws {
    _ = try await manager.executeInternal(
      "CREATE TABLE \(table) (id int PRIMARY KEY, name text)")
    let values = rows.map { "(\($0.0), '\($0.1)')" }.joined(separator: ", ")
    _ = try await manager.executeInternal("INSERT INTO \(table) (id, name) VALUES \(values)")
  }

  /// Roll back a pending app transaction, then drop `table`. Disconnect stays in `defer`.
  private static func drop(_ table: String, on manager: DatabaseConnectionManager) async {
    if await !manager.transactionSnapshot().isIdle {
      try? await manager.rollbackAppTransaction()
    }
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
  }

  private func withTable(
    _ suffix: String,
    protectedMode: Bool = false,
    rows: [(Int, String)] = [(1, "a"), (2, "b")],
    _ body: (DatabaseConnectionManager, String) async throws -> Void
  ) async throws {
    let table = Self.tableName(suffix)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: protectedMode))
    defer { Task { await manager.disconnect() } }
    do {
      try await Self.create(table, rows: rows, on: manager)
      try await body(manager, table)
    } catch {
      await Self.drop(table, on: manager)
      throw error
    }
    await Self.drop(table, on: manager)
  }

  @Test("A bound id returns that row and queryText keeps :id", .timeLimit(.minutes(1)))
  func whereBindReturnsTheMatchingRow() async throws {
    try await withTable("where") { manager, table in
      let sql = "SELECT name FROM \(table) WHERE id = :id"
      let detailed = try await manager.executeDetailed(
        userSQL: sql, parameters: ["id": .text("2")], policy: open)
      #expect(detailed.results.first?.result.rows == [[.string("b")]])
      let queryText = try #require(detailed.results.first?.queryText)
      #expect(queryText.contains(":id"))
      #expect(!queryText.contains("$1"))
    }
  }

  @Test("LIMIT :n bound as text returns the lowest id", .timeLimit(.minutes(1)))
  func limitBindReturnsTheLowestId() async throws {
    try await withTable("limit") { manager, table in
      let result = try await manager.execute(
        userSQL: "SELECT id FROM \(table) ORDER BY id LIMIT :n",
        parameters: ["n": .text("1")], policy: open)
      #expect(result.rows == [[.int(1)]])
    }
  }

  @Test("IN (:a, :b) returns exactly those two rows", .timeLimit(.minutes(1)))
  func inListReturnsTheBoundIds() async throws {
    try await withTable("in", rows: [(1, "a"), (2, "b"), (3, "c")]) { manager, table in
      let result = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE id IN (:a, :b) ORDER BY id",
        parameters: ["a": .text("1"), "b": .text("2")], policy: open)
      #expect(result.rows == [[.int(1)], [.int(2)]])
    }
  }

  @Test("NULL equality matches nothing", .timeLimit(.minutes(1)))
  func nullBindMatchesOnlyIsNull() async throws {
    try await withTable("null") { manager, table in
      let equal = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE name = :name ORDER BY id",
        parameters: ["name": .null], policy: open)
      #expect(equal.rows.isEmpty)
    }
  }

  @Test("One reused name filters only when the value is present", .timeLimit(.minutes(1)))
  func optionalFilterReusesOneName() async throws {
    try await withTable("filter") { manager, table in
      let sql = "SELECT name FROM \(table) WHERE name = :name OR :name IS NULL ORDER BY id"
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
    try await withTable("reuse") { manager, _ in
      let result = try await manager.execute(
        userSQL: "SELECT :n, :n", parameters: ["n": .text("z")], policy: open)
      #expect(result.rows == [[.string("z"), .string("z")]])
    }
  }

  @Test("Inconsistent parameter types fail on the server", .timeLimit(.minutes(1)))
  func inconsistentTypesFailOnTheServer() async throws {
    try await withTable("types") { manager, _ in
      let sql = "SELECT :x::int, :x::uuid"
      do {
        _ = try await manager.execute(
          userSQL: sql, parameters: ["x": .text("1")], policy: open)
        Issue.record("Expected queryFailed")
      } catch let error as DatabaseError {
        switch error {
        case .queryFailed:
          break
        case .missingParameters, .mixedPlaceholders:
          Issue.record("Refused before send: \(error)")
        default:
          Issue.record("Expected queryFailed, got \(error)")
        }
      } catch {
        Issue.record("Expected queryFailed, got \(error)")
      }
    }
  }

  @Test(
    "A parameterized read inside a Protected transaction uses a server cursor",
    .timeLimit(.minutes(1)))
  func protectedReadUsesACursor() async throws {
    try await withTable("cursor", protectedMode: true) { manager, table in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET name = :name WHERE id = :id",
        parameters: ["name": .text("z"), "id": .text("1")], policy: protected)
      let before = await manager.cursorReadCount
      let read = try await manager.execute(
        userSQL: "SELECT id FROM \(table) WHERE id >= :lo ORDER BY id",
        parameters: ["lo": .text("1")], policy: protected, maxRows: 10)
      #expect(read.rows == [[.int(1)], [.int(2)]])
      #expect(await manager.cursorReadCount >= before + 1)
      #expect(await manager.transactionSnapshot().isIdle == false)
    }
  }

  @Test("Pending DML previews :name, and rollback restores the old name", .timeLimit(.minutes(1)))
  func pendingUpdatePreviewKeepsNamedSQL() async throws {
    try await withTable("pending", protectedMode: true) { manager, table in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET name = :name WHERE id = :id",
        parameters: ["name": .text("z"), "id": .text("1")], policy: protected)
      let pending = await manager.transactionSnapshot().pending
      let preview = try #require(pending.first?.sqlPreview)
      #expect(preview.contains(":name"))
      #expect(!preview.contains("$"))

      try await manager.rollbackAppTransaction()
      let read = try await manager.execute(
        userSQL: "SELECT name FROM \(table) WHERE id = :id",
        parameters: ["id": .text("1")], policy: protected)
      #expect(read.rows == [[.string("a")]])
    }
  }

  @Test("EXPLAIN with a bind returns a plan", .timeLimit(.minutes(1)))
  func explainWithBindReturnsRows() async throws {
    try await withTable("explain") { manager, table in
      let plan = try await manager.execute(
        userSQL: "EXPLAIN SELECT id FROM \(table) WHERE id = :id",
        parameters: ["id": .text("2")], policy: open)
      #expect(!plan.rows.isEmpty)
    }
  }
}
