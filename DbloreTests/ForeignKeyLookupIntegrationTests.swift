// ForeignKeyLookupIntegrationTests.swift
// Referenced-row lookup against the docker test database. The SELECT is the one
// lookupReferencedRow sends, through the protection gate, and history does not store it.
// A NULL component sends nothing.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Foreign key lookup integration", .requiresPostgres, .serialized)
@MainActor
struct ForeignKeyLookupIntegrationTests {
  @Test("The referenced row comes back and is not recorded", .timeLimit(.minutes(2)))
  func lookupReturnsTheReferencedRow() async throws {
    try await withPair { viewModel, recorder, parent, child in
      let result = try await viewModel.lookupReferencedRow(
        column: "parent_id", schema: "public", table: child, rowColumns: ["id", "parent_id"],
        values: ["id": .int(1), "parent_id": .int(7)])
      let row = try #require(result?.rows.first)
      #expect(result?.rows.count == 1)
      #expect(row.contains(.int(7)))
      #expect(row.contains(.string("ada's")))
      #expect(await settledSQL(recorder).isEmpty)
    }
  }

  @Test(
    "An aliased key column offers its reference and finds the row; a fake alias offers none",
    .timeLimit(.minutes(2)))
  func aliasedColumnFollowsItsBaseColumn() async throws {
    try await withPair { viewModel, recorder, _, child in
      let manager = try #require(viewModel.connectionManager)
      let epoch = await manager.connectionEpoch
      let policy = ProtectionPolicy(protectionLevel: .readOnly)
      @MainActor func offered(
        _ sql: String, column: Int
      ) async throws -> (request: ReferencedRowRequest?, targets: ResultTargets) {
        let result = try await manager.execute(userSQL: sql, policy: policy)
        let targets = await viewModel.resultTargets(
          for: sql, result: result, connectionManager: manager, epoch: epoch)
        let coordinator = ResultGridCoordinator()
        let cellResult = CellResult(
          columns: result.columns, rows: result.rows, rowCount: result.rowCount,
          editTarget: targets.editTarget, lookupRelation: targets.lookupRelation)
        coordinator.update(NSTableView(), result: cellResult, sortColumn: nil, ascending: true)
        let relation = referencedRelation(
          dataViewer: nil, editTarget: targets.editTarget, lookupRelation: targets.lookupRelation)
        coordinator.relationSchema = relation?.schema
        coordinator.relationTable = relation?.table
        coordinator.baseColumnNames = relation?.baseColumns
        coordinator.foreignKeys = viewModel.databaseForeignKeys
        return (coordinator.referencedRowRequest(row: 0, column: column), targets)
      }

      let fake = try await offered("SELECT id, id AS parent_id FROM \(child)", column: 1)
      #expect(fake.request == nil)
      #expect(fake.targets.editTarget == nil)
      #expect(try await offered("SELECT id, parent_id FROM \(child)", column: 1).request != nil)

      let renamed = try await offered(
        "SELECT id, parent_id AS p, 1 AS one FROM \(child)", column: 1)
      #expect(renamed.targets.editTarget == nil)
      #expect(renamed.targets.lookupRelation?.baseColumns == ["id", "parent_id", nil])
      let aliased = try #require(renamed.request)
      #expect(aliased.column == "parent_id")
      #expect(aliased.values["parent_id"] == .int(7))
      let handlers = referencedRowHandlers(
        viewModel, editTarget: nil, lookupRelation: renamed.targets.lookupRelation)
      let found = try await handlers.lookup(
        aliased.column, aliased.schema, aliased.table, aliased.rowColumns, aliased.values)
      #expect(found?.rows.count == 1)
      #expect(found?.rows.first?.contains(.string("ada's")) == true)
      #expect(await settledSQL(recorder).isEmpty)
    }
  }

  @Test("A NULL component sends nothing; a value does", .timeLimit(.minutes(2)))
  func nullComponentSendsNothing() async throws {
    try await withPair { viewModel, recorder, _, child in
      let token = String(UUID().uuidString.prefix(8)).lowercased()
      viewModel.databaseForeignKeys = [
        ForeignKey(
          constraintName: "missing", sourceSchema: "public", sourceTable: child,
          sourceColumns: ["parent_id"], targetSchema: "public", targetTable: "fk_missing_\(token)",
          targetColumns: ["id"])
      ]
      let row = ["id", "parent_id"]

      let skipped = try await viewModel.lookupReferencedRow(
        column: "parent_id", schema: "public", table: child, rowColumns: row,
        values: ["id": .int(1), "parent_id": .null])
      #expect(skipped == nil)

      await #expect(throws: DatabaseError.self) {
        try await viewModel.lookupReferencedRow(
          column: "parent_id", schema: "public", table: child, rowColumns: row,
          values: ["id": .int(1), "parent_id": .int(7)])
      }
      #expect(await settledSQL(recorder).isEmpty)
    }
  }

  @Test(
    "A key to a partitioned table is listed once, targeting the parent", .timeLimit(.minutes(2)))
  func partitionedTargetIsListedOnce() async throws {
    let token = String(UUID().uuidString.prefix(8)).lowercased()
    let parent = "fk_part_parent_\(token)"
    let child = "fk_part_child_\(token)"
    let config = ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    do {
      _ = try await manager.executeInternal(
        "CREATE TABLE \(parent) (id int PRIMARY KEY) PARTITION BY RANGE (id)")
      _ = try await manager.executeInternal(
        "CREATE TABLE \(parent)_a PARTITION OF \(parent) FOR VALUES FROM (0) TO (10)")
      _ = try await manager.executeInternal(
        "CREATE TABLE \(parent)_b PARTITION OF \(parent) FOR VALUES FROM (10) TO (20)")
      _ = try await manager.executeInternal(
        "CREATE TABLE \(child) (id int PRIMARY KEY, parent_id int REFERENCES \(parent) (id))")

      let keys = try await manager.fetchForeignKeys().filter { $0.sourceTable == child }
      #expect(keys.count == 1)
      #expect(keys.first?.targetTable == parent)
      #expect(keys.first?.targetColumns == ["id"])
    } catch {
      await dropPair(parent: parent, child: child, on: manager)
      throw error
    }
    await dropPair(parent: parent, child: child, on: manager)
  }

  @Test("A timestamptz target key with microseconds finds its row", .timeLimit(.minutes(2)))
  func microsecondTimestampTargetMatches() async throws {
    let table = "fk_ts_\(String(UUID().uuidString.prefix(8)).lowercased())"
    let config = ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, protectionLevel: .readOnly, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    do {
      _ = try await manager.executeInternal(
        "CREATE TABLE \(table) (at timestamptz PRIMARY KEY, name text)")
      _ = try await manager.executeInternal(
        "INSERT INTO \(table) VALUES ('2024-01-02 03:04:05.123456+00', 'micro')")
      let decoded = try #require(
        try await manager.executeInternal("SELECT at FROM \(table)").rows.first?.first)
      let key = ForeignKey(
        constraintName: "ts", sourceSchema: "public", sourceTable: "src",
        sourceColumns: ["at"], targetSchema: "public", targetTable: table,
        targetColumns: ["at"])
      let query = try #require(
        ForeignKeyLookup.lookupSQL(for: key, values: ["at": decoded], dialect: .postgresql))
      let result = try await manager.execute(
        userSQL: query.sql, parameters: query.parameters,
        policy: ProtectionPolicy(protectionLevel: .readOnly))
      #expect(result.rows.count == 1)
      #expect(result.rows.first?.contains(.string("micro")) == true)
    } catch {
      _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
      throw error
    }
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(table)")
  }

  private func withPair(
    _ body: (
      NotebookViewModel, LookupHistoryRecorder, String, String
    ) async throws -> Void
  ) async throws {
    let token = String(UUID().uuidString.prefix(8)).lowercased()
    let parent = "fk_parent_\(token)"
    let child = "fk_child_\(token)"
    let config = ConnectionConfig(
      host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
      username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
      timeoutSeconds: 30, protectionLevel: .readOnly, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    do {
      try await createPair(parent: parent, child: child, on: manager)
      let key = try await referencedKey(parent: parent, child: child, on: manager)

      let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config))
      viewModel.connectionManager = manager
      viewModel.connectionState = .connected
      viewModel.databaseForeignKeys = [key]
      let recorder = LookupHistoryRecorder()
      viewModel.historyRecorder = recorder
      let suiteName = "ForeignKeyLookupIntegrationTests.\(UUID().uuidString)"
      let suite = try #require(UserDefaults(suiteName: suiteName))
      suite.removePersistentDomain(forName: suiteName)
      let settings = AppSettings(defaults: suite)
      settings.historyEnabled = true
      viewModel.historySettings = settings
      try await body(viewModel, recorder, parent, child)
    } catch {
      await dropPair(parent: parent, child: child, on: manager)
      throw error
    }
    await dropPair(parent: parent, child: child, on: manager)
  }

  private func createPair(
    parent: String, child: String, on manager: DatabaseConnectionManager
  ) async throws {
    _ = try await manager.executeInternal(
      "CREATE TABLE \(parent) (id int PRIMARY KEY, name text)")
    _ = try await manager.executeInternal(
      "INSERT INTO \(parent) (id, name) VALUES (7, 'ada''s')")
    _ = try await manager.executeInternal(
      "CREATE TABLE \(child) (id int PRIMARY KEY, parent_id int REFERENCES \(parent) (id))")
    _ = try await manager.executeInternal(
      "INSERT INTO \(child) (id, parent_id) VALUES (1, 7)")
  }

  /// The catalog key for `child.parent_id`. The app's list must contain it: that is what the
  /// grid menu reads.
  private func referencedKey(
    parent: String, child: String, on manager: DatabaseConnectionManager
  ) async throws -> ForeignKey {
    let all = try await manager.fetchForeignKeys()
    let fetched = all.filter { $0.sourceTable == child }
    if fetched.isEmpty {
      let tables = try await manager.executeInternal(
        """
        SELECT n.nspname::text, c.relname::text
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname IN ('\(parent)', '\(child)')
        """)
      let constraints = try await manager.executeInternal(
        "SELECT count(*)::int4 FROM pg_constraint WHERE contype = 'f'")
      Issue.record(
        "no key for \(child); tables=\(tables.rows) fkCount=\(constraints.rows) fetched=\(all.count)"
      )
    }
    let key = try #require(fetched.first)
    #expect(key.sourceSchema == "public")
    #expect(key.sourceColumns == ["parent_id"])
    #expect(key.targetSchema == "public")
    #expect(key.targetTable == parent)
    #expect(key.targetColumns == ["id"])
    return key
  }

  private func dropPair(
    parent: String, child: String, on manager: DatabaseConnectionManager
  ) async {
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(child)")
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS \(parent)")
  }

  private func settledSQL(_ recorder: LookupHistoryRecorder) async -> [String] {
    for _ in 0..<50 {
      await Task.yield()
    }
    return await recorder.sql
  }
}

private actor LookupHistoryRecorder: QueryHistoryRecording {
  private(set) var sql: [String] = []

  func record(_ entry: QueryHistoryEntry) async {
    sql.append(entry.sql)
  }
}
