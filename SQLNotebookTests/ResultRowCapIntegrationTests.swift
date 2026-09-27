// ResultRowCapIntegrationTests.swift
// C6: a notebook cell reads at most the effective row cap (connection override, else the
// global `AppSettings.resultRowCap`) against the docker test database (TEST_DB_* env, port
// 5435 in autopilot). The global value is pinned per view model (`globalRowCap`), never on
// `AppSettings.shared`: other suites reset the shared settings while tests run in parallel.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Result Row Cap - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct ResultRowCapIntegrationTests {
  private static let query = "SELECT * FROM generate_series(1, 1000)"

  /// Runs `query` in a one-cell notebook connected with `config` and global cap `globalCap`
  private func runCell(config: ConnectionConfig, globalCap: Int) async throws -> CellResult {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let cellId = UUID()
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = [
      NotebookCell(id: cellId, cellType: .sql, content: Self.query, executionCount: 0)
    ]
    viewModel.notebook.connectionConfig = config
    viewModel.connectionManager = manager
    viewModel.globalRowCap = { globalCap }
    _ = await viewModel.executeTask(ExecutionTask(cellId: cellId, query: Self.query))
    return try #require(viewModel.notebook.cells.first?.result)
  }

  @Test("Global cap 150: a cell returns 150 rows, truncated")
  func globalCap() async throws {
    let result = try await runCell(config: InlineEditIntegrationTests.testConfig, globalCap: 150)
    #expect(result.error == nil)
    #expect(result.rows.count == 150)
    #expect(result.wasLimited)
  }

  @Test("Connection override 120 beats the global cap: 120 rows, truncated")
  func connectionOverride() async throws {
    var config = InlineEditIntegrationTests.testConfig
    config.rowCapOverride = 120
    let result = try await runCell(config: config, globalCap: 150)
    #expect(result.error == nil)
    #expect(result.rows.count == 120)
    #expect(result.wasLimited)
  }
}
