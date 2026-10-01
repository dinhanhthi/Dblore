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

  @Test("Protected mode does not send the write before confirmation")
  func protectedModeHoldsWriteUntilConfirmation() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    let config = sqliteConfig(path: url.path, safeMode: .alertRead, protectedMode: true)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }

    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.notebook.connectionConfig = config
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "PRAGMA journal_mode = OFF"

    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.statements.first?.kindLabel == "Schema change")

    let mode = try await manager.execute(userSQL: "PRAGMA journal_mode", policy: open)
    #expect(mode.rows == [[.string("wal")]])
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
