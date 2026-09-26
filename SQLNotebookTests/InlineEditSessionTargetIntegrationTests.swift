// InlineEditSessionTargetIntegrationTests.swift
// Session-only, server-validated inline edit targets against the docker test database
// (TEST_DB_* env, port 5435 in autopilot): live re-run makes a decoded result editable, the
// UPDATE is pinned to the server-resolved schema-qualified table across `SET search_path`,
// quoted dotted names work, and a comma self-join is never editable.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Inline Edit Session Target - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct InlineEditSessionTargetIntegrationTests {
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

  @Test("search_path change after the SELECT: the edit hits only the table the rows came from")
  func searchPathPinned() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    for sql in [
      "DROP SCHEMA IF EXISTS s6a CASCADE", "DROP SCHEMA IF EXISTS s6b CASCADE",
      "CREATE SCHEMA s6a", "CREATE SCHEMA s6b",
      "CREATE TABLE s6a.t (id int PRIMARY KEY, v text)",
      "CREATE TABLE s6b.t (id int PRIMARY KEY, v text)",
      "INSERT INTO s6a.t VALUES (1, 'a')", "INSERT INTO s6b.t VALUES (1, 'b')",
      "SET search_path = s6a",
    ] {
      _ = try await manager.executeInternal(sql)
    }

    let resolved = try #require(try await target("SELECT * FROM t", manager))
    #expect(resolved.qualifiedName == "s6a.t")
    #expect(resolved.primaryKeyColumns == ["id"])

    _ = try await manager.executeInternal("SET search_path = s6b")
    let update = try CellUpdateStatement.make(
      qualifiedName: resolved.qualifiedName, columnName: "v", newValue: "edited",
      primaryKeyColumns: resolved.primaryKeyColumns, rowData: ["id": .int(1)])
    #expect(
      try await manager.executeGatedUpdate(
        update, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)

    #expect(try await scalar(manager, "SELECT v FROM s6a.t WHERE id = 1") == .string("edited"))
    #expect(try await scalar(manager, "SELECT v FROM s6b.t WHERE id = 1") == .string("b"))

    _ = try await manager.executeInternal("RESET search_path")
    _ = try await manager.executeInternal("DROP SCHEMA s6a, s6b CASCADE")
  }

  @Test("A quoted dotted table name resolves and edits")
  func quotedDottedName() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(#"DROP TABLE IF EXISTS "s6_my.table""#)
    _ = try await manager.executeInternal(
      #"CREATE TABLE "s6_my.table" (id int PRIMARY KEY, v text)"#)
    _ = try await manager.executeInternal(#"INSERT INTO "s6_my.table" VALUES (1, 'a')"#)

    let resolved = try #require(try await target(#"SELECT * FROM "s6_my.table" x"#, manager))
    #expect(resolved.qualifiedName.hasSuffix(#"."s6_my.table""#))
    let update = try CellUpdateStatement.make(
      qualifiedName: resolved.qualifiedName, columnName: "v", newValue: "z",
      primaryKeyColumns: resolved.primaryKeyColumns, rowData: ["id": .int(1)])
    #expect(
      try await manager.executeGatedUpdate(
        update, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    #expect(try await scalar(manager, #"SELECT v FROM "s6_my.table""#) == .string("z"))
    _ = try await manager.executeInternal(#"DROP TABLE "s6_my.table""#)
  }

  @Test("Comma self-join is not editable; a single aliased relation is")
  func commaSelfJoin() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_accounts")
    _ = try await manager.executeInternal(
      "CREATE TABLE s6_accounts (id int PRIMARY KEY, name text)")
    _ = try await manager.executeInternal("INSERT INTO s6_accounts VALUES (1, 'a'), (2, 'b')")

    #expect(
      try await target("SELECT a.id, b.name FROM s6_accounts a, s6_accounts b", manager) == nil)
    #expect(try await target("SELECT * FROM s6_accounts AS x", manager) != nil)
    _ = try await manager.executeInternal("DROP TABLE s6_accounts")
  }

  @Test("Decoded result is read-only; a live re-run of the cell makes it editable")
  func liveRerunEditable() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_rerun")
    _ = try await manager.executeInternal("CREATE TABLE s6_rerun (id int PRIMARY KEY, v text)")
    _ = try await manager.executeInternal("INSERT INTO s6_rerun VALUES (1, 'a')")

    let cellId = UUID()
    let stored = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "v", type: "text")],
      rows: [[.int(1), .string("a")]], rowCount: 1, sourceQuery: "SELECT * FROM s6_rerun",
      tableName: "s6_rerun", primaryKeyColumns: ["id"])
    let notebook = SQLNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM s6_rerun", executionCount: 1,
          result: stored)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Rerun"),
      connectionConfig: ConnectionConfig(protectionLevel: .none, safeMode: .silent),
      settings: NotebookSettings())
    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: true)
    let viewModel = NotebookViewModel(notebook: try DocumentCoder.decode(from: data))
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: .none, safeMode: .silent)
    viewModel.connectionManager = manager
    let decoded = try #require(viewModel.notebook.cells.first?.result)
    #expect(viewModel.canEdit(decoded) == false)

    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: "SELECT * FROM s6_rerun"))
    let rerun = try #require(viewModel.notebook.cells.first?.result)
    #expect(rerun.editTarget?.qualifiedName == "public.s6_rerun")
    #expect(viewModel.canEdit(rerun))
    _ = try await manager.executeInternal("DROP TABLE s6_rerun")
  }
}
