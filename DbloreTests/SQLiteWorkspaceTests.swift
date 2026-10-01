// SQLiteWorkspaceTests.swift
// A temporary SQLite file: the sidebar schema model loads its tables, a capped read keeps
// a temp table, and inline edit follows the column-origin table identity.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLiteWorkspaceTests")
@MainActor
struct SQLiteWorkspaceTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("A temp-file connection loads tables into the sidebar schema model")
  func loadsTablesIntoSidebarSchema() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.connectionState = .connected
    workspace.workspace.connectionConfig = config

    await workspace.loadDatabaseSchema()

    let items = try #require(workspace.databaseTables.first { $0.name == "items" })
    #expect(items.schema == "main")
    #expect(items.columns.contains { $0.name == "id" && $0.isPrimaryKey })
    #expect(items.columns.contains { $0.name == "label" })
    #expect(workspace.databaseFunctions.isEmpty)
    #expect(workspace.databaseRoles.isEmpty)
  }

  @Test("A capped read does not drop a temp table")
  func cappedReadKeepsTempTable() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }

    _ = try await manager.execute(userSQL: "CREATE TEMP TABLE scratch (n INTEGER)", policy: open)
    _ = try await manager.execute(userSQL: "INSERT INTO scratch VALUES (7)", policy: open)

    let capped = try await manager.execute(
      userSQL: "SELECT id FROM items", policy: open, maxRows: 1)
    #expect(capped.truncated)
    #expect(!capped.sessionReset)

    let kept = try await manager.execute(userSQL: "SELECT n FROM scratch", policy: open)
    #expect(kept.rows == [[.int(7)]])
  }

  @Test("Inline edit resolves a keyed table by column origin and skips a table with no key")
  func editTargetUsesColumnOrigin() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionEpoch
    let viewModel = NotebookViewModel(notebook: .newDocument())

    let keyed = try await manager.execute(
      userSQL: "SELECT id, label FROM items", policy: open)
    let target = await viewModel.editTarget(
      for: "SELECT id, label FROM items", result: keyed, connectionManager: manager, epoch: epoch)
    let resolved = try #require(target)
    #expect(resolved.tableID == TableRef.sqlite(schema: "main", table: "items"))
    #expect(resolved.primaryKeyColumns == ["id"])

    let heap = try await manager.execute(userSQL: "SELECT id, note FROM heap", policy: open)
    let heapTarget = await viewModel.editTarget(
      for: "SELECT id, note FROM heap", result: heap, connectionManager: manager, epoch: epoch)
    #expect(heapTarget == nil)
  }

  private func sqliteConfig(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent,
      protectedMode: false
    )
  }

  private func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-workspace-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("INSERT INTO items (label) VALUES ('a'), ('b'), ('c')")
    try handle.execute("CREATE TABLE heap (id INTEGER, note TEXT)")
    try handle.execute("INSERT INTO heap (id, note) VALUES (1, 'loose')")
    return url
  }

  private func removeDatabase(_ url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
