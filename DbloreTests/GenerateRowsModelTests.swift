// GenerateRowsModelTests.swift
// The Generate Rows model on a connected SQLite tab (real file in the temporary folder, no
// server): one Safe Mode decision per run, followed to its end or its decline, a Read-only
// connection refused before anything is planned, and the same seed giving the same preview.

import Foundation
import Testing

@testable import Dblore

@Suite("Generate Rows model")
@MainActor
struct GenerateRowsModelTests {
  @Test("A run asks Safe Mode once over its summary, then sends every chunk")
  func oneSafeModeDecision() async throws {
    let (manager, viewModel, database) = try await sqliteTab(safeMode: .alertAll)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    let model = GenerateRowsModel(schema: "main", table: "people")
    await model.load(for: viewModel)
    #expect(model.errorMessage == nil)
    // Loading and the preview ask nothing
    #expect(!viewModel.queryConfirmationState.showDialog)
    model.rowCount = 2_500
    model.seed = 7

    #expect(await model.generate(in: viewModel))
    #expect(viewModel.queryConfirmationState.showDialog)
    let pending = try #require(viewModel.pendingStagedBatch)
    #expect(pending.streamed != nil)
    #expect(pending.statements.isEmpty)
    #expect(pending.preview.contains("-- 2500 generated rows, seed 7"))
    #expect(model.chunkTotal == 3)
    // The run stays the model's while Safe Mode holds it, so the sheet keeps progress and Cancel
    #expect(model.isGenerating)
    #expect(model.awaitsConfirmation)
    #expect(try await rowCount(manager) == 0)

    await viewModel.executePendingQuery()
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(try await rowCount(manager) == 2_500)
    #expect(!model.isGenerating)
    #expect(!model.awaitsConfirmation)
    #expect(model.errorMessage == nil)
    // Progress lands through main-actor tasks
    for _ in 0..<100 where model.chunksDone < 3 { await Task.yield() }
    #expect(model.chunksDone == 3)
  }

  @Test("Declining in Safe Mode ends the run unsent")
  func declinedInSafeMode() async throws {
    let (manager, viewModel, database) = try await sqliteTab(safeMode: .alertAll)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    let model = GenerateRowsModel(schema: "main", table: "people")
    await model.load(for: viewModel)

    #expect(await model.generate(in: viewModel))
    #expect(model.awaitsConfirmation)
    viewModel.cancelPendingQuery()
    #expect(!model.isGenerating)
    #expect(!model.awaitsConfirmation)
    #expect(model.errorMessage == nil)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(try await rowCount(manager) == 0)
  }

  @Test("A Read-only connection is refused before the run is planned or Safe Mode asks")
  func readOnlyRefusedFirst() async throws {
    let (manager, viewModel, database) = try await sqliteTab(
      safeMode: .alertAll, protectionLevel: .readOnly)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    let model = GenerateRowsModel(schema: "main", table: "people")
    await model.load(for: viewModel)

    #expect(await model.generate(in: viewModel) == false)
    #expect(model.errorMessage == NotebookViewModel.connectionIsReadOnly)
    // No plan: the chunk count is set only once the run is planned
    #expect(model.chunkTotal == 0)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(try await rowCount(manager) == 0)
  }

  @Test("The same seed gives the same preview; another seed gives other rows")
  func sameSeedSamePreview() async throws {
    let (manager, viewModel, database) = try await sqliteTab(safeMode: .silent)
    defer { removeDatabase(database) }
    defer { Task { await manager.disconnect() } }
    let model = GenerateRowsModel(schema: "main", table: "people")
    model.seed = 42
    await model.load(for: viewModel)
    let first = model.previewRows
    #expect(first.count == GenerateRowsModel.previewRowCount)
    #expect(model.previewColumns == ["id", "name", "email", "age"])

    model.seed = 43
    await model.refreshPreview(for: viewModel)
    #expect(model.previewRows != first)
    model.seed = 42
    await model.refreshPreview(for: viewModel)
    #expect(model.previewRows == first)
  }

  // MARK: - Helpers

  /// A connected SQLite tab on a new database file with an empty `people` table
  private func sqliteTab(
    safeMode: SafeMode, protectionLevel: ConnectionProtectionLevel = .none
  ) async throws -> (DatabaseConnectionManager, NotebookViewModel, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-generate-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: safeMode, protectedMode: false)
    let manager = DatabaseConnectionManager(lockSource: LockRegistry())
    try await manager.connect(config: config)
    _ = try await manager.executeInternal(
      """
      CREATE TABLE people (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE, age INTEGER)
      """)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    notebook.connectionConfig?.protectionLevel = protectionLevel
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = manager
    return (manager, viewModel, url)
  }

  private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private func rowCount(_ manager: DatabaseConnectionManager) async throws -> Int {
    let result = try await manager.executeInternal("SELECT count(*) FROM people")
    guard case .int(let count) = result.rows.first?.first else { return -1 }
    return count
  }
}
