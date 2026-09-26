// InlineEditTargetIntegrationTests.swift
// Editability decided from the server's column origins (table OID + attnum) against the docker
// test database (TEST_DB_* env, port 5435 in autopilot).

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Inline Edit Target - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct InlineEditTargetIntegrationTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private func connect() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: InlineEditIntegrationTests.testConfig)
    for sql in [
      "DROP TABLE IF EXISTS s9_orders, s9_customers, s9_logs",
      "CREATE TABLE s9_customers (id int PRIMARY KEY, name text)",
      "CREATE TABLE s9_orders (id int PRIMARY KEY, customer_id int, total int)",
      "CREATE TABLE s9_logs (id int)",
      "INSERT INTO s9_customers VALUES (1, 'c1'), (2, 'c2')",
      "INSERT INTO s9_orders VALUES (10, 1, 100), (20, 2, 200)",
      "INSERT INTO s9_logs VALUES (99)",
    ] {
      _ = try await manager.executeInternal(sql)
    }
    return manager
  }

  private func target(
    _ query: String, _ manager: DatabaseConnectionManager
  ) async throws
    -> [String]
  {
    let viewModel = NotebookViewModel()
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(userSQL: query, policy: open)
    return await viewModel.editTarget(
      for: query, result: result, connectionManager: manager, epoch: epoch)?
      .primaryKeyColumns ?? []
  }

  @Test("Join results are not editable; a plain table is, and the edit hits exactly one row")
  func editability() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }

    #expect(try await target("SELECT * FROM s9_orders", manager) == ["id"])
    // Comma join: the FROM parser picks s9_orders, but "id" also comes from s9_customers
    #expect(
      try await target(
        "SELECT s9_orders.*, s9_customers.id FROM s9_orders, s9_customers", manager
      ).isEmpty)
    #expect(
      try await target(
        "SELECT * FROM s9_orders JOIN s9_customers ON s9_customers.id = s9_orders.customer_id",
        manager
      ).isEmpty)
    #expect(try await target("SELECT *, 5 AS id FROM s9_orders", manager).isEmpty)
    #expect(
      try await target(
        "SELECT (SELECT max(id) FROM s9_logs) AS id, total FROM s9_orders", manager
      ).isEmpty)

    let update = try CellUpdateStatement.make(
      qualifiedName: "public.s9_orders", columnName: "total", newValue: "150",
      primaryKeyColumns: ["id"], rowData: ["id": .int(10)])
    #expect(
      try await manager.executeGatedUpdate(
        update, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    #expect(
      try await manager.executeInternal("SELECT total FROM s9_orders WHERE id = 10").rows.first?
        .first == .int(150))

    // Composite key: key order, not column order
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s9_composite")
    _ = try await manager.executeInternal(
      "CREATE TABLE s9_composite (b int, a int, v text, PRIMARY KEY (a, b))")
    _ = try await manager.executeInternal("INSERT INTO s9_composite VALUES (1, 2, 'x')")
    #expect(try await target("SELECT * FROM s9_composite", manager) == ["a", "b"])

    _ = try await manager.executeInternal(
      "DROP TABLE s9_orders, s9_customers, s9_logs, s9_composite")
  }
}
