// SchemaSidebarRefreshTests.swift
// After a schema command (CREATE / ALTER / DROP / …) the Public sidebar reloads on its own.
// A Review transaction keeps the cached schema until Commit; Rollback leaves it unchanged.

import Foundation
import Testing

@testable import Dblore

@Suite("Schema sidebar refresh")
@MainActor
struct SchemaSidebarRefreshTests {
  @Test("A committed CREATE TABLE shows up in the sidebar without Refresh schema")
  func committedCreateRefreshesSidebar() async throws {
    try await withWorkspace(protected: false) { env in
      let created = try await env.run("CREATE TABLE extra (id INTEGER)")
      #expect(created.error == nil)
      await env.workspace.awaitSchemaLoad()
      #expect(env.tableNames.contains("extra"))
    }
  }

  @Test("CREATE TABLE inside BEGIN appears only after COMMIT")
  func userTransactionRefreshesOnCommit() async throws {
    try await withWorkspace(protected: false) { env in
      let begun = try await env.run("BEGIN")
      #expect(begun.error == nil)
      let created = try await env.run("CREATE TABLE extra (id INTEGER)")
      #expect(created.error == nil)
      await env.workspace.awaitSchemaLoad()
      #expect(!env.tableNames.contains("extra"))

      let committed = try await env.run("COMMIT")
      #expect(committed.error == nil)
      await env.workspace.awaitSchemaLoad()
      #expect(env.tableNames.contains("extra"))
    }
  }

  @Test("Review mode shows the new table after Commit, not while the transaction is open")
  func reviewCreateRefreshesOnCommit() async throws {
    try await withWorkspace(protected: true) { env in
      let created = try await env.run("CREATE TABLE extra (id INTEGER)")
      #expect(created.error == nil)
      #expect(env.workspace.isSchemaPaused)
      await env.workspace.awaitSchemaLoad()
      #expect(!env.tableNames.contains("extra"))

      env.workspace.requestCommit()
      #expect(await env.workspace.confirmCommit(defaultCommitStyle: .immediate))
      #expect(!env.workspace.isSchemaPaused)
      await env.workspace.awaitSchemaLoad()
      #expect(env.tableNames.contains("extra"))
    }
  }

  @Test("Rollback of a Review CREATE leaves the sidebar without that table")
  func reviewRollbackDoesNotAddTable() async throws {
    try await withWorkspace(protected: true) { env in
      let created = try await env.run("CREATE TABLE extra (id INTEGER)")
      #expect(created.error == nil)
      #expect(await env.workspace.rollback())
      #expect(!env.workspace.isSchemaPaused)
      await env.workspace.awaitSchemaLoad()
      #expect(!env.tableNames.contains("extra"))
      #expect(env.tableNames.contains("items"))
    }
  }

  @MainActor
  private struct Env {
    let workspace: WorkspaceManager
    let viewModel: NotebookViewModel
    let url: URL

    var tableNames: [String] { workspace.databaseTables.map(\.name) }

    func run(_ sql: String) async throws -> CellResult {
      let cell = NotebookCell(cellType: .sql, content: sql)
      viewModel.notebook.cells.append(cell)
      let result = await viewModel.executeTask(ExecutionTask(cellId: cell.id, query: sql))
      return try #require(result)
    }
  }

  private func withWorkspace(
    protected: Bool, _ body: @MainActor (Env) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-schema-refresh-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    let config = ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: url.path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent,
      protectedMode: protected
    )
    let workspace = WorkspaceManager(workspace: Workspace())
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    let tabId = workspace.newNotebook()
    let viewModel = try #require(workspace.viewModel(for: tabId))
    let env = Env(workspace: workspace, viewModel: viewModel, url: url)
    do {
      try await workspace.connect(config: config, defaultCommitStyle: .immediate)
      await workspace.awaitSchemaLoad()
      #expect(env.tableNames.contains("items"))
      try await body(env)
    } catch {
      await tearDown(env)
      throw error
    }
    await tearDown(env)
  }

  private func tearDown(_ env: Env) async {
    if await !env.workspace.connectionManager.transactionSnapshot().isIdle {
      _ = await env.workspace.rollback()
    }
    await env.workspace.disconnect(resolution: .rollback)
    try? FileManager.default.removeItem(at: env.url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: env.url.path + suffix))
    }
  }
}
