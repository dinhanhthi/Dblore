// AffectedRowsTests.swift
// Affected rows come from the server command tag (DML without RETURNING) or from the rows read
// (DML with RETURNING); the statement text is sent unchanged. Runs against the docker test
// database (TEST_DB_* env, port 5435 in CI/autopilot).

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Affected Rows - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct AffectedRowsTests {
  private static func config(protectedMode: Bool) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      protectedMode: protectedMode
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Connects a manager and creates `table (id int PRIMARY KEY, v int, note text)` with ids 1...5.
  private func setUp(
    _ table: String, protectedMode: Bool = false
  ) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: protectedMode))
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await manager.executeInternal(
      "CREATE TABLE \(table) (id int PRIMARY KEY, v int, note text)")
    _ = try await manager.executeInternal(
      "INSERT INTO \(table) (id, v) SELECT g, g * 10 FROM generate_series(1, 5) g")
    return manager
  }

  private func tearDown(_ manager: DatabaseConnectionManager, dropping tables: [String]) async {
    try? await manager.rollbackAppTransaction()
    for table in tables {
      _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
    }
    await manager.disconnect()
  }

  /// Runs `body` on a fresh table and always tears down (a connection left open when a test
  /// throws would crash the test process).
  private func withTable(
    _ table: String, protectedMode: Bool = false, alsoDrop extra: [String] = [],
    _ body: (DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let manager = try await setUp(table, protectedMode: protectedMode)
    for other in extra {
      _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(other)")
    }
    do {
      try await body(manager)
    } catch {
      await tearDown(manager, dropping: [table] + extra)
      throw error
    }
    await tearDown(manager, dropping: [table] + extra)
  }

  private func run(_ manager: DatabaseConnectionManager, _ sql: String) async throws -> QueryResult
  {
    try await manager.execute(userSQL: sql, policy: open)
  }

  // MARK: - DML without RETURNING (command tag)

  @Test("UPDATE ... WHERE id <= 3 reports 3")
  func updateReportsTagCount() async throws {
    let table = "p2_rows_update"
    try await withTable(table) { manager in
      let result = try await run(manager, "UPDATE \(table) SET v = v WHERE id <= 3")
      #expect(result.affectedRows == 3)
      #expect(result.rows.isEmpty)
    }
  }

  @Test("DELETE ... WHERE false reports 0")
  func deleteNothingReportsZero() async throws {
    let table = "p2_rows_delete_none"
    try await withTable(table) { manager in
      let result = try await run(manager, "DELETE FROM \(table) WHERE false")
      #expect(result.affectedRows == 0)
    }
  }

  @Test("INSERT ... VALUES (6), (7) reports 2")
  func insertReportsTagCount() async throws {
    let table = "p2_rows_insert"
    try await withTable(table) { manager in
      let result = try await run(manager, "INSERT INTO \(table) (id) VALUES (6), (7)")
      #expect(result.affectedRows == 2)
    }
  }

  @Test("MERGE reports the MERGE command tag count")
  func mergeReportsTagCount() async throws {
    let table = "p2_rows_merge"
    try await withTable(table) { manager in
      let result = try await run(
        manager,
        """
        MERGE INTO \(table) t USING (VALUES (1), (2), (9)) s(id) ON t.id = s.id
        WHEN MATCHED THEN UPDATE SET v = 0
        WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, 0)
        """)
      #expect(result.affectedRows == 3)
    }
  }

  @Test("RETURNING inside a string literal is not RETURNING: tag count, no rows")
  func returningInLiteralUsesTag() async throws {
    let table = "p2_rows_literal"
    try await withTable(table) { manager in
      let result = try await run(
        manager, "INSERT INTO \(table) (id, note) VALUES (6, 'x RETURNING id')")
      #expect(result.affectedRows == 1)
      #expect(result.rows.isEmpty)
    }
  }

  @Test("DML with a trailing line comment and no semicolon is sent unchanged")
  func trailingCommentUnchanged() async throws {
    let table = "p2_rows_comment"
    try await withTable(table) { manager in
      let result = try await run(manager, "UPDATE \(table) SET v = 1 WHERE id = 1 -- note")
      #expect(result.affectedRows == 1)
      let withSemicolon = try await run(
        manager, "DELETE FROM \(table) WHERE id IN (2, 3) /* two */; -- note")
      #expect(withSemicolon.affectedRows == 2)
    }
  }

  // MARK: - DML with RETURNING (rows read)

  @Test("UPDATE ... RETURNING returns the rows and counts them (old wrapper broke it)")
  func updateReturningRowsAndCount() async throws {
    let table = "p2_rows_update_returning"
    try await withTable(table) { manager in
      let result = try await run(manager, "UPDATE \(table) SET v = 1 RETURNING v")
      #expect(result.affectedRows == 5)
      #expect(result.rows.count == 5)
      #expect(result.columns.map(\.name) == ["v"])
    }
  }

  @Test("DELETE ... RETURNING id returns the rows and counts them")
  func deleteReturningRowsAndCount() async throws {
    let table = "p2_rows_delete_returning"
    try await withTable(table) { manager in
      let result = try await run(manager, "DELETE FROM \(table) WHERE id <= 2 RETURNING id")
      #expect(result.affectedRows == 2)
      #expect(result.rows.compactMap(\.first).sorted() == [.int(1), .int(2)])
    }
  }

  @Test("WITH d AS (DELETE ... RETURNING *) SELECT * FROM d returns the row, affected unknown")
  func dataModifyingCTE() async throws {
    let table = "p2_rows_cte"
    try await withTable(table) { manager in
      let result = try await run(
        manager, "WITH d AS (DELETE FROM \(table) WHERE id = 1 RETURNING *) SELECT * FROM d")
      #expect(result.affectedRows == nil)
      #expect(result.rows.count == 1)
      #expect(result.rows.first?.first == .int(1))
      let left = try await manager.executeInternal("SELECT count(*) FROM \(table)")
      #expect(left.rows.first?.first == .int(4))
    }
  }

  @Test(
    "(a) WITH d AS (DELETE ...) SELECT ... FROM other returns the outer rows and deletes",
    .timeLimit(.minutes(1)))
  func dataModifyingCTEReturnsOuterRows() async throws {
    let table = "p3_rows_cte_outer"
    try await withTable(table) { manager in
      let result = try await run(
        manager,
        "WITH d AS (DELETE FROM \(table) WHERE id <= 2) SELECT g FROM generate_series(1, 3) g")
      #expect(result.rows.count == 3)
      #expect(result.rows.first?.first == .int(1))
      #expect(result.affectedRows == nil)
      let left = try await manager.executeInternal("SELECT count(*) FROM \(table)")
      #expect(left.rows.first?.first == .int(3))
    }
  }

  @Test(
    "(b) A read-only CTE with a column named update returns its rows", .timeLimit(.minutes(1)))
  func cteWithUpdateColumnReturnsRows() async throws {
    let table = "p3_rows_cte_update_col"
    try await withTable(table) { manager in
      _ = try await manager.executeInternal("ALTER TABLE \(table) ADD COLUMN update int")
      let result = try await run(
        manager, "WITH c AS (SELECT id, update FROM \(table)) SELECT id FROM c ORDER BY id")
      #expect(result.rows.count == 5)
      #expect(result.affectedRows == nil)
    }
  }

  @Test(
    "(c) Protected ON: WITH d AS (DELETE ... RETURNING id) SELECT count(*) pending, rows unknown",
    .timeLimit(.minutes(1)))
  func cteCountPendingRowsUnknown() async throws {
    let table = "p3_rows_cte_count"
    try await withTable(table, protectedMode: true) { manager in
      let result = try await run(
        manager,
        "WITH d AS (DELETE FROM \(table) WHERE id <= 4 RETURNING id) SELECT count(*) FROM d")
      #expect(result.rows.first?.first == .int(4))
      #expect(result.affectedRows == nil)

      let state = await manager.transactionSnapshot()
      #expect(state.pending.map(\.affectedRows) == [nil])
      #expect(state.pending.first?.rowsUnknown == true)
      let summary = PendingTransactionSummary(state: state)
      #expect(summary.hasUnknownRows)
      #expect(summary.headline.contains("unknown"))
      #expect(summary.commitPrompt.contains("unknown"))
      #expect(!summary.commitPrompt.contains("1 row"))
      #expect(!summary.headline.contains("0 rows"))
      try await manager.rollbackAppTransaction()
    }
  }

  // MARK: - DDL / SELECT INTO

  @Test("CREATE TABLE AS reports the SELECT tag count (5)")
  func createTableAsReportsCount() async throws {
    let target = "p2_rows_ctas"
    try await withTable("p2_rows_ctas_src", alsoDrop: [target]) { manager in
      let result = try await run(
        manager, "CREATE TABLE \(target) AS SELECT generate_series(1, 5)")
      #expect(result.affectedRows == 5)
    }
  }

  @Test("SELECT * INTO is sent unchanged and reports the SELECT tag count")
  func selectIntoReportsCount() async throws {
    let table = "p2_rows_into_src"
    let target = "p2_rows_into"
    try await withTable(table, alsoDrop: [target]) { manager in
      let result = try await run(manager, "SELECT * INTO \(target) FROM \(table)")
      #expect(result.affectedRows == 5)
      // Unchanged text: no ctid column was added to the new table
      let columns = try await manager.executeInternal(
        "SELECT count(*) FROM information_schema.columns WHERE table_name = '\(target)'")
      #expect(columns.rows.first?.first == .int(3))
    }
  }

  @Test("DDL without a row count reports nil affected rows")
  func plainDDLReportsNil() async throws {
    let table = "p2_rows_ddl"
    try await withTable(table) { manager in
      let result = try await run(manager, "CREATE INDEX p2_rows_ddl_v ON \(table) (v)")
      #expect(result.affectedRows == nil)
    }
  }

  // MARK: - Protected mode pending list

  @Test("Protected ON: pending statements carry the correct affected rows")
  func protectedPendingCounts() async throws {
    let table = "p2_rows_protected"
    try await withTable(table, protectedMode: true) { manager in
      _ = try await run(manager, "UPDATE \(table) SET v = v WHERE id <= 3")
      _ = try await run(
        manager,
        """
        MERGE INTO \(table) t USING (VALUES (4), (8)) s(id) ON t.id = s.id
        WHEN MATCHED THEN DELETE
        WHEN NOT MATCHED THEN INSERT (id) VALUES (s.id)
        """)
      _ = try await run(
        manager, "WITH d AS (DELETE FROM \(table) WHERE id = 1 RETURNING *) SELECT * FROM d")
      _ = try await run(manager, "DELETE FROM \(table) WHERE id >= 2 RETURNING id")

      let pending = await manager.transactionSnapshot().pending
      #expect(pending.map(\.affectedRows) == [3, 2, nil, 4])
      try await manager.rollbackAppTransaction()
      let count = try await manager.executeInternal("SELECT count(*) FROM \(table)")
      #expect(count.rows.first?.first == .int(5))
    }
  }
}

@Suite("Statement route (unit)")
struct StatementRouteTests {
  private func route(_ sql: String) -> StatementRoute {
    StatementRoute.route(for: SQLStatementClassifier.classifyStatement(sql))
  }

  @Test("Routes by classified kind and RETURNING")
  func routes() {
    #expect(route("SELECT * FROM t") == .read)
    #expect(route("EXPLAIN ANALYZE UPDATE t SET a = 1") == .read)
    #expect(route("UPDATE t SET a = 1") == .command)
    #expect(route("insert into t values ('RETURNING')") == .command)
    #expect(route("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE") == .command)
    #expect(route("SELECT * INTO t2 FROM t") == .command)
    #expect(route("CREATE TABLE t2 AS SELECT 1") == .command)
    #expect(route("SET search_path = public") == .command)
    #expect(route("UPDATE t SET a = 1 RETURNING a") == .returningRows)
    #expect(route("CALL p()") == .unwrappedRows)
    #expect(route("-- only a comment") == .read)
  }

  @Test("A data-modifying WITH is read as rows, text unchanged, affected rows unknown")
  func dataModifyingWithRoutes() {
    // (a) the outer SELECT rows must be returned, not discarded as a command
    #expect(route("WITH d AS (DELETE FROM t WHERE id = 1) SELECT * FROM x") == .unwrappedRows)
    // (b) a read-only CTE with a column named `update` (classified DML, fail closed)
    #expect(route("WITH c AS (SELECT update FROM t) SELECT * FROM c") == .unwrappedRows)
    // (c) RETURNING inside the CTE: the rows read are not the affected rows
    #expect(
      route("WITH d AS (DELETE FROM t RETURNING id) SELECT count(*) FROM d") == .unwrappedRows)
    #expect(route("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d") == .unwrappedRows)
    // A read-only WITH keeps the read path (row cap)
    #expect(route("WITH c AS (SELECT 1 AS a) SELECT * FROM c") == .read)
  }

  @Test("Only top-level RETURNING of INSERT / UPDATE / DELETE / MERGE counts rows")
  func topLevelReturningRoutes() {
    #expect(route("DELETE FROM t WHERE id = 1 RETURNING id") == .returningRows)
    #expect(route("INSERT INTO t VALUES (1) RETURNING *") == .returningRows)
    #expect(
      route("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE RETURNING t.id")
        == .returningRows)
    // RETURNING nested in parentheses is not the statement's own
    #expect(
      route("INSERT INTO t WITH d AS (DELETE FROM u RETURNING *) SELECT * FROM d") == .command)
  }

  @Test("Affected rows from the command tag, including MERGE")
  func tagCounts() {
    #expect(StatementRoute.affectedRowCount(rows: 3, command: "UPDATE") == 3)
    #expect(StatementRoute.affectedRowCount(rows: nil, command: "MERGE 7") == 7)
    #expect(StatementRoute.affectedRowCount(rows: nil, command: "CREATE TABLE") == nil)
    #expect(StatementRoute.affectedRowCount(rows: nil, command: "CREATE INDEX") == nil)
  }
}
