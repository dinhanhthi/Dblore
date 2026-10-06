// SQLiteGateTests.swift
// A temporary SQLite file through the connection actor: read-only blocks file and PRAGMA
// writes, a SELECT runs, and a write waits for Safe Mode confirmation.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLiteGateTests")
@MainActor
struct SQLiteGateTests {
  private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("Read-only blocks ATTACH and a PRAGMA write")
  func readOnlyBlocksFileAndPragmaWrites() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path, protectionLevel: .readOnly))
    defer { Task { await manager.disconnect() } }

    let attached = await #expect(throws: DatabaseError.self) {
      try await manager.execute(
        userSQL: "ATTACH '\(url.deletingLastPathComponent().path)/dblore-other.sqlite' AS other",
        policy: readOnly)
    }
    guard case .blockedByProtection = attached else {
      Issue.record("Expected ATTACH to be blocked, got \(String(describing: attached))")
      return
    }

    let pragma = await #expect(throws: DatabaseError.self) {
      try await manager.execute(userSQL: "PRAGMA writable_schema = ON", policy: readOnly)
    }
    guard case .blockedByProtection = pragma else {
      Issue.record("Expected the PRAGMA write to be blocked, got \(String(describing: pragma))")
      return
    }

    let databases = try await manager.execute(userSQL: "PRAGMA database_list", policy: readOnly)
    let names = databases.rows.compactMap { row -> String? in
      guard row.count > 1, case .string(let name) = row[1] else { return nil }
      return name
    }
    #expect(names.contains("main"))
    #expect(!names.contains("other"))
    let schema = try await manager.execute(userSQL: "PRAGMA writable_schema", policy: readOnly)
    #expect(schema.rows == [[.int(0)]])
  }

  @Test("A SELECT runs, and EXPLAIN QUERY PLAN returns a grid")
  func selectRuns() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path, protectionLevel: .readOnly))
    defer { Task { await manager.disconnect() } }

    let selected = try await manager.execute(
      userSQL: "SELECT body FROM notes", policy: readOnly)
    #expect(selected.rows == [[.string("hello")]])

    let plan = try await manager.execute(
      userSQL: "EXPLAIN QUERY PLAN SELECT body FROM notes", policy: readOnly)
    #expect(!plan.columns.isEmpty)
    #expect(!plan.rows.isEmpty)
  }

  @Test("Review holds PRAGMA journal_mode = OFF with no confirm dialog until banner commit")
  func reviewHoldsJournalModeUntilBannerCommit() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    let config = sqliteConfig(path: url.path, safeMode: .safeAll, protectedMode: true)
    #expect(config.resolvedCommitStyle(fallback: .immediate) == .review)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }

    let viewModel = makeViewModel(
      manager: manager, config: config, sql: "PRAGMA journal_mode = OFF")
    let cellId = viewModel.notebook.cells[0].id
    await runWithoutDialog(viewModel, cellId: cellId)

    #expect(!viewModel.queryConfirmationState.showDialog)
    let held = try await manager.execute(
      userSQL: "PRAGMA journal_mode",
      policy: ProtectionPolicy(config: config),
      caller: viewModel.id)
    #expect(held.rows == [[.string("wal")]])
    #expect(viewModel.notebook.cells[0].result?.error == nil)

    let status = await manager.transactionStatus()
    #expect(!status.state.isIdle)
    try await manager.commitAppTransaction(expectedGeneration: status.generation)
    #expect(await manager.transactionSnapshot().isIdle)
    let committed = try await manager.execute(userSQL: "PRAGMA journal_mode", policy: open)
    // `journal_mode = OFF` does not leave WAL on the system SQLite, inside a transaction or
    // after COMMIT. Review's proof is the pending transaction, not a mode flip.
    #expect(committed.rows == [[.string("wal")]])
  }

  @Test("Confirm dialogs PRAGMA journal_mode = OFF, then autocommits with no pending transaction")
  func confirmDialogsJournalModeThenAutocommits() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    var config = sqliteConfig(path: url.path, protectedMode: false)
    config.applyCommitStyle(.confirm)
    #expect(config.resolvedCommitStyle(fallback: .review) == .confirm)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }

    let viewModel = makeViewModel(
      manager: manager, config: config, sql: "PRAGMA journal_mode = OFF")
    let cellId = viewModel.notebook.cells[0].id
    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.statements.first?.kindLabel == "Schema change")

    let before = try await manager.execute(userSQL: "PRAGMA journal_mode", policy: open)
    #expect(before.rows == [[.string("wal")]])

    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()

    #expect(viewModel.notebook.cells[0].result?.error == nil)
    #expect(await manager.transactionSnapshot().isIdle)
    let after = try await manager.execute(userSQL: "PRAGMA journal_mode", policy: open)
    // Autocommit does not leave a pending transaction. This SQLite also keeps WAL for
    // `journal_mode = OFF`, so the mode stays wal after the statement runs.
    #expect(after.rows == [[.string("wal")]])
  }

  private func makeViewModel(
    manager: DatabaseConnectionManager, config: ConnectionConfig, sql: String
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.notebook.connectionConfig = config
    viewModel.notebook.cells[0].content = sql
    return viewModel
  }

  /// Review runs the cell immediately. Wait until that run finishes.
  private func runWithoutDialog(_ viewModel: NotebookViewModel, cellId: UUID) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      viewModel.onStatementsExecuted = { continuation.resume() }
      viewModel.confirmAndRunCell(id: cellId)
    }
    await viewModel.executionQueue.waitForIdle()
  }

  private func sqliteConfig(
    path: String,
    protectionLevel: ConnectionProtectionLevel = .none,
    safeMode: SafeMode? = .silent,
    protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: path,
      username: "",
      rememberConnection: false,
      protectionLevel: protectionLevel,
      safeMode: safeMode,
      protectedMode: protectedMode
    )
  }

  private func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-gate-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
    try handle.execute("INSERT INTO notes (body) VALUES ('hello')")
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
