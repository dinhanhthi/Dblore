// EditTargetConnectionIntegrationTests.swift
// Against the docker test database (TEST_DB_* env, port 5435 in autopilot):
// - an edit target resolved before a reconnect is refused by the actor; a re-run makes the
//   result editable again;
// - legacy inheritance parents are never editable; plain tables update with `UPDATE ONLY`;
//   partitioned parents stay editable with a plain UPDATE (partition routing).

import Foundation
import Testing

@testable import Dblore

@Suite("Edit target connection and relation kind - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct EditTargetConnectionIntegrationTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private func connect() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: InlineEditIntegrationTests.testConfig)
    return manager
  }

  private func scalar(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws
    -> CellValue?
  {
    try await manager.executeInternal(sql).rows.first?.first
  }

  private func run(_ manager: DatabaseConnectionManager, _ statements: [String]) async throws {
    for sql in statements {
      _ = try await manager.executeInternal(sql)
    }
  }

  private func target(
    _ query: String, _ manager: DatabaseConnectionManager
  ) async throws
    -> EditTarget?
  {
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(userSQL: query, policy: open)
    return await NotebookViewModel().editTarget(
      for: query, result: result, connectionManager: manager, epoch: epoch)
  }

  private func update(_ target: EditTarget, value: String, id: Int) throws -> CellUpdateStatement {
    try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "v", newValue: value,
      primaryKeyColumns: target.primaryKeyColumns, rowData: ["id": .int(id)],
      updateOnly: target.updateOnly)
  }

  // MARK: - Connection epoch

  @Test("SELECT, reconnect, edit is refused; re-run makes it editable again")
  func reconnectRefusesStaleTarget() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    try await run(
      manager,
      [
        "DROP TABLE IF EXISTS s2e_items",
        "CREATE TABLE s2e_items (id int PRIMARY KEY, v text)",
        "INSERT INTO s2e_items VALUES (1, 'a')",
      ])

    let stale = try #require(try await target("SELECT * FROM s2e_items", manager))
    try await manager.connect(config: InlineEditIntegrationTests.testConfig)
    #expect(await manager.connectionEpoch != stale.connectionEpoch)

    do {
      _ = try await manager.executeGatedUpdate(
        try update(stale, value: "stale", id: 1), policy: open,
        connectionEpoch: stale.connectionEpoch)
      Issue.record("Expected notEditable")
    } catch DatabaseError.notEditable {
      // expected
    }
    #expect(try await scalar(manager, "SELECT v FROM s2e_items WHERE id = 1") == .string("a"))

    let fresh = try #require(try await target("SELECT * FROM s2e_items", manager))
    #expect(fresh.connectionEpoch == (await manager.connectionEpoch))
    #expect(
      try await manager.executeGatedUpdate(
        try update(fresh, value: "fresh", id: 1), policy: open,
        connectionEpoch: fresh.connectionEpoch) == 1)
    #expect(try await scalar(manager, "SELECT v FROM s2e_items WHERE id = 1") == .string("fresh"))
    _ = try await manager.executeInternal("DROP TABLE s2e_items")
  }

  @Test("A target resolved with an epoch older than the connection is not created")
  func staleEpochAtResolveGivesNoTarget() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    try await run(
      manager,
      [
        "DROP TABLE IF EXISTS s2e_resolve",
        "CREATE TABLE s2e_resolve (id int PRIMARY KEY, v text)",
      ])
    let query = "SELECT * FROM s2e_resolve"
    let epochBefore = await manager.connectionEpoch
    let result = try await manager.execute(userSQL: query, policy: open)
    try await manager.connect(config: InlineEditIntegrationTests.testConfig)
    #expect(
      await NotebookViewModel().editTarget(
        for: query, result: result, connectionManager: manager, epoch: epochBefore) == nil)
    _ = try await manager.executeInternal("DROP TABLE s2e_resolve")
  }

  // MARK: - Relation kind

  @Test("Legacy inheritance parent with a child sharing an id is not editable")
  func inheritanceParentNotEditable() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    try await run(
      manager,
      [
        "DROP SCHEMA IF EXISTS s2i CASCADE", "CREATE SCHEMA s2i",
        "CREATE TABLE s2i.p (id int PRIMARY KEY, v text)",
        "CREATE TABLE s2i.c (extra text) INHERITS (s2i.p)",
        "INSERT INTO s2i.p VALUES (1, 'parent')",
        "INSERT INTO s2i.c (id, v) VALUES (1, 'child')",
      ])
    #expect(try await manager.fetchEditTable(tableName: "s2i.p") == nil)
    #expect(try await target("SELECT * FROM s2i.p", manager) == nil)
    _ = try await manager.executeInternal("DROP SCHEMA s2i CASCADE")
  }

  @Test("Plain table is editable and its UPDATE uses ONLY; the edit hits one row")
  func plainTableUsesOnly() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    try await run(
      manager,
      [
        "DROP SCHEMA IF EXISTS s2o CASCADE", "CREATE SCHEMA s2o",
        "CREATE TABLE s2o.t (id int PRIMARY KEY, v text)",
        "INSERT INTO s2o.t VALUES (1, 'a'), (2, 'b')",
      ])
    let resolved = try #require(try await target("SELECT * FROM s2o.t", manager))
    #expect(resolved.updateOnly)
    let statement = try update(resolved, value: "z", id: 1)
    #expect(statement.sql.hasPrefix("UPDATE ONLY s2o.t SET"))
    #expect(
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: resolved.connectionEpoch) == 1)
    #expect(try await scalar(manager, "SELECT v FROM s2o.t WHERE id = 1") == .string("z"))
    _ = try await manager.executeInternal("DROP SCHEMA s2o CASCADE")
  }

  @Test("Partitioned parent stays editable with a plain UPDATE routed to the partition")
  func partitionedParentPlainUpdate() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    try await run(
      manager,
      [
        "DROP SCHEMA IF EXISTS s2p CASCADE", "CREATE SCHEMA s2p",
        "CREATE TABLE s2p.m (id int PRIMARY KEY, v text) PARTITION BY RANGE (id)",
        "CREATE TABLE s2p.m1 PARTITION OF s2p.m FOR VALUES FROM (0) TO (100)",
        "INSERT INTO s2p.m VALUES (1, 'a')",
      ])
    let resolved = try #require(try await target("SELECT * FROM s2p.m", manager))
    #expect(!resolved.updateOnly)
    let statement = try update(resolved, value: "routed", id: 1)
    #expect(statement.sql.hasPrefix("UPDATE s2p.m SET"))
    #expect(
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: resolved.connectionEpoch) == 1)
    #expect(try await scalar(manager, "SELECT v FROM s2p.m1 WHERE id = 1") == .string("routed"))
    _ = try await manager.executeInternal("DROP SCHEMA s2p CASCADE")
  }
}
