// DuckDBSafeModeGateTests.swift
// A real DuckDB session (dev plugin) behind the connection actor. A read-only protection
// level blocks INSTALL, ATTACH, COPY ... TO and CREATE TABLE at the gate on a read-write file
// and in memory, Safe Mode confirms them before anything is sent, and SELECT runs. Text
// EXPLAIN / EXPLAIN ANALYZE go through the app's explain path and render as a raw grid.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB Safe Mode gate", .requiresDuckDBPlugin, .serialized)
@MainActor
struct DuckDBSafeModeGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)

  @Test(
    "Read-only protection blocks INSTALL, ATTACH, COPY TO and CREATE TABLE; SELECT runs",
    arguments: [false, true])
  func readOnlyBlocksWrites(inMemory: Bool) async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = try await connect(path: inMemory ? DuckDBSession.inMemoryPath : dbPath(folder))
    defer { Task { await manager.disconnect() } }
    _ = try await manager.execute(
      userSQL: "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)", policy: open)

    for sql in writes(in: folder) {
      let error = await #expect(throws: DatabaseError.self, "\(sql)") {
        try await manager.execute(userSQL: sql, policy: readOnly)
      }
      guard case .blockedByProtection = error else {
        Issue.record("Expected \(sql) to be blocked, got \(String(describing: error))")
        continue
      }
    }
    try await expectNothingWritten(manager, folder: folder)

    let selected = try await manager.execute(userSQL: "SELECT a FROM t", policy: readOnly)
    #expect(selected.rows == [[.int(1)]])
  }

  @Test("Safe Mode confirms each write before sending it; a SELECT runs with no dialog")
  func safeModeConfirmsWrites() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var config = duckDBConfig(path: dbPath(folder), safeMode: .alertRead)
    config.applyCommitStyle(.confirm)
    let manager = try await connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.execute(
      userSQL: "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)", policy: open)

    for sql in writes(in: folder) {
      let viewModel = makeViewModel(manager: manager, config: config, sql: sql)
      viewModel.confirmAndRunCell(id: viewModel.notebook.cells[0].id)
      #expect(viewModel.queryConfirmationState.showDialog, "\(sql)")
      viewModel.cancelPendingQuery()
      await viewModel.executionQueue.waitForIdle()
    }
    try await expectNothingWritten(manager, folder: folder)

    let viewModel = makeViewModel(manager: manager, config: config, sql: "SELECT a FROM t")
    await run(viewModel) { viewModel.confirmAndRunCell(id: viewModel.notebook.cells[0].id) }
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.notebook.cells[0].result?.error == nil)
    #expect(viewModel.notebook.cells[0].result?.rows == [[.int(1)]])
  }

  @Test("EXPLAIN and EXPLAIN ANALYZE run through the explain path and show as text rows")
  func textExplain() async throws {
    let config = duckDBConfig(path: DuckDBSession.inMemoryPath, safeMode: .silent)
    let manager = try await connect(config: config)
    defer { Task { await manager.disconnect() } }
    _ = try await manager.execute(
      userSQL: "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1)", policy: open)

    for analyze in [false, true] {
      let viewModel = makeViewModel(manager: manager, config: config, sql: "SELECT a FROM t")
      let cellId = viewModel.notebook.cells[0].id
      viewModel.selectedCellId = cellId
      await run(viewModel) {
        Task { await viewModel.explainSelectedStatement(analyze: analyze) }
      }
      let result = try #require(viewModel.notebook.cells[0].result)
      #expect(result.error == nil, "analyze: \(analyze)")
      #expect(result.columns.map(\.name) == ["explain_key", "explain_value"])
      #expect(ExplainResultPlan.parse(result) == nil)
      guard case .string(let plan)? = result.rows.first?.last else {
        Issue.record("Expected a text plan, got \(String(describing: result.rows.first))")
        continue
      }
      #expect(plan.contains("SEQ_SCAN") || plan.contains("TABLE_SCAN"), "\(plan)")
    }

    // A data-changing ANALYZE is wrapped in BEGIN / ROLLBACK, so the row is not kept.
    let viewModel = makeViewModel(
      manager: manager, config: config, sql: "INSERT INTO t VALUES (2)")
    let cellId = viewModel.notebook.cells[0].id
    viewModel.selectedCellId = cellId
    await run(viewModel) { Task { await viewModel.explainSelectedStatement(analyze: true) } }
    #expect(viewModel.notebook.cells[0].result?.error == nil)
    let count = try await manager.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(1)]])
  }

  // MARK: - Helpers

  private func writes(in folder: URL) -> [String] {
    [
      "INSTALL httpfs",
      "ATTACH '\(folder.appendingPathComponent("other.duckdb").path)' AS other",
      "COPY (SELECT 1 AS a) TO '\(folder.appendingPathComponent("out.csv").path)'",
      "CREATE TABLE blocked (a INTEGER)",
    ]
  }

  private func expectNothingWritten(
    _ manager: DatabaseConnectionManager, folder: URL
  ) async throws {
    let tables = try await manager.execute(
      userSQL: "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'blocked'", policy: open)
    #expect(tables.rows == [[.int(0)]])
    let attached = try await manager.execute(
      userSQL: "SELECT count(*) FROM duckdb_databases() WHERE database_name = 'other'",
      policy: open)
    #expect(attached.rows == [[.int(0)]])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.csv").path))
    #expect(
      !FileManager.default.fileExists(atPath: folder.appendingPathComponent("other.duckdb").path))
  }

  /// The app's session factory with the dev plugin as the installed one.
  private func connect(
    path: String? = nil, config: ConnectionConfig? = nil
  ) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(duckDBLibraryLoader: {
        { try DuckDBTestPlugin.library() }
      }))
    try await manager.connect(
      config: config ?? duckDBConfig(path: path ?? DuckDBSession.inMemoryPath, safeMode: .silent))
    return manager
  }

  /// Read-write file (`readOnlyFile: false`): a refusal comes from the gate, not the file.
  private func duckDBConfig(path: String, safeMode: SafeMode) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: path, sslMode: .disable, protectionLevel: .none,
      safeMode: safeMode, protectedMode: false, statementTimeoutSeconds: 30,
      readOnlyFile: false)
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

  /// Starts a run and waits until its statements finished.
  private func run(_ viewModel: NotebookViewModel, _ start: () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      viewModel.onStatementsExecuted = {
        viewModel.onStatementsExecuted = nil
        continuation.resume()
      }
      start()
    }
    await viewModel.executionQueue.waitForIdle()
  }

  private func dbPath(_ folder: URL) -> String {
    folder.appendingPathComponent("gate.duckdb").path
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
