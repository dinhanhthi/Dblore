// RunAllSessionResetTests.swift
// Run All never continues on a different session than the one it started on (Protected mode
// off, against the docker test database, see `TestDatabase`):
// - a capped read that resets the session cancels the queued cells after it and says so;
// - a capped read inside the user's own BEGIN drains instead: the transaction is kept;
// - any other reset / reconnect between two cells (the batch's connection epoch changed)
//   refuses the next cell and cancels the rest.

import Foundation
import Testing

@testable import Dblore

/// Lock-protected flag shared with the script checkpoint hook
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false

  /// true the first time only
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !stored else { return false }
    stored = true
    return true
  }
}

@Suite("Run All Session Reset - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct RunAllSessionResetTests {
  private static let cap = 100

  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: false,
      statementTimeoutSeconds: 45
    )
  }

  /// Connects an observer that runs `setup` (app SQL), and a manager for the notebook
  private func connect(
    setup: [String]
  ) async throws -> (manager: DatabaseConnectionManager, observer: DatabaseConnectionManager) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config())
    for sql in setup {
      _ = try await observer.executeInternal(sql)
    }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    return (manager, observer)
  }

  private func tearDown(
    _ cleanup: [String], _ manager: DatabaseConnectionManager,
    _ observer: DatabaseConnectionManager
  ) async {
    await manager.disconnect()
    for sql in cleanup {
      _ = try? await observer.executeInternal(sql)
    }
    await observer.disconnect()
  }

  /// A notebook of `queries` (one SQL cell each) on `manager`, row cap `cap`
  private func notebook(
    _ queries: [String], manager: DatabaseConnectionManager
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = queries.map { NotebookCell(cellType: .sql, content: $0) }
    viewModel.notebook.connectionConfig = Self.config()
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.globalRowCap = { Self.cap }
    return viewModel
  }

  /// Run All (bypass on, confirmed if a dialog is still shown) and wait for the queue
  private func runAll(_ viewModel: NotebookViewModel) async {
    await viewModel.runAllCells(bypass: true)
    if viewModel.queryConfirmationState.showRunAllConfirmation {
      await viewModel.executeRunAllCellsWithDestructive()
    }
    await viewModel.executionQueue.waitForIdle()
  }

  private func count(
    _ sql: String, _ observer: DatabaseConnectionManager
  ) async throws -> CellValue? {
    try await observer.executeInternal(sql).rows.first?.first
  }

  // MARK: - Capped read resets: the rest of the batch is not run

  @Test(
    "SET search_path / capped read / DELETE: the reset stops Run All, DELETE never runs",
    .timeLimit(.minutes(1)))
  func searchPathResetStopsRunAll() async throws {
    let setup = [
      "DROP SCHEMA IF EXISTS runall_staging CASCADE",
      "DROP TABLE IF EXISTS public.runall_orders",
      "CREATE SCHEMA runall_staging",
      "CREATE TABLE runall_staging.runall_big (id int PRIMARY KEY, v int)",
      "INSERT INTO runall_staging.runall_big SELECT g, g FROM generate_series(1, 5000) g",
      "CREATE TABLE runall_staging.runall_orders (id int PRIMARY KEY)",
      "INSERT INTO runall_staging.runall_orders VALUES (1)",
      "CREATE TABLE public.runall_orders (id int PRIMARY KEY)",
      "INSERT INTO public.runall_orders VALUES (1)",
    ]
    let cleanup = [
      "DROP SCHEMA IF EXISTS runall_staging CASCADE", "DROP TABLE IF EXISTS public.runall_orders",
    ]
    let (manager, observer) = try await connect(setup: setup)
    do {
      let viewModel = notebook(
        [
          "SET search_path = runall_staging", "SELECT * FROM runall_big",
          "DELETE FROM runall_orders WHERE id = 1", "SELECT 1",
        ], manager: manager)
      await runAll(viewModel)

      let cells = viewModel.notebook.cells
      let read = try #require(cells[1].result)
      #expect(read.sessionReset)
      #expect(
        read.capNotice?.contains("2 queued cells were not run because the connection was reset")
          == true, "notice: \(read.capNotice ?? "nil")")
      #expect(cells[2].result == nil)
      #expect(cells[3].result == nil)
      #expect(await viewModel.executionQueue.waitForTask(cellId: cells[2].id) == .cancelled)
      #expect(await viewModel.executionQueue.waitForTask(cellId: cells[3].id) == .cancelled)
      #expect(try await count("SELECT count(*) FROM public.runall_orders", observer) == .int(1))
      #expect(
        try await count("SELECT count(*) FROM runall_staging.runall_orders", observer) == .int(1))
    } catch {
      Issue.record(error)
    }
    await tearDown(cleanup, manager, observer)
  }

  // MARK: - Capped read inside the user's BEGIN: drained, transaction kept

  @Test(
    "BEGIN / capped read / UPDATE / ROLLBACK: the read drains, the UPDATE is rolled back",
    .timeLimit(.minutes(1)))
  func userTransactionIsKept() async throws {
    let table = "runall_usertx"
    let setup = [
      "DROP TABLE IF EXISTS \(table)",
      "CREATE TABLE \(table) (id int PRIMARY KEY, v int)",
      "INSERT INTO \(table) SELECT g, g FROM generate_series(1, 5000) g",
    ]
    let (manager, observer) = try await connect(setup: setup)
    do {
      let viewModel = notebook(
        [
          "BEGIN", "SELECT * FROM \(table)", "UPDATE \(table) SET v = 99 WHERE id = 1",
          "ROLLBACK",
        ], manager: manager)
      await runAll(viewModel)

      let cells = viewModel.notebook.cells
      let read = try #require(cells[1].result)
      #expect(read.error == nil)
      #expect(read.rows.count == Self.cap)
      #expect(read.wasLimited)
      #expect(!read.sessionReset)
      #expect(cells[2].result?.error == nil)
      #expect(cells[2].result?.affectedRows == 1)
      #expect(cells[3].result?.error == nil)
      #expect(await manager.userTxOpen == false)
      #expect(try await count("SELECT v FROM \(table) WHERE id = 1", observer) == .int(1))
    } catch {
      Issue.record(error)
    }
    await tearDown(["DROP TABLE IF EXISTS \(table)"], manager, observer)
  }

  // MARK: - Any other reset / reconnect stops the batch

  @Test(
    "Reconnect during cell 1: the next queued cell is refused, the rest cancelled",
    .timeLimit(.minutes(1)))
  func reconnectStopsRunAll() async throws {
    let (manager, observer) = try await connect(setup: [])
    let viewModel = notebook(["SELECT 1", "SELECT 2", "SELECT 3"], manager: manager)
    let caller = viewModel.id
    let config = Self.config()
    let once = Flag()
    await manager.setScriptCheckpointHook { checkpoint in
      guard checkpoint == .beforeStatement(caller: caller, index: 0), once.claim() else {
        return
      }
      try? await manager.connect(config: config)
    }
    await runAll(viewModel)

    let cells = viewModel.notebook.cells
    #expect(cells[0].result?.error?.contains("connection was reset") == true)
    #expect(
      cells[1].result?.error?.contains(
        "2 queued cells were not run because the connection was reset") == true,
      "cell 2: \(cells[1].result?.error ?? "no error")")
    #expect(cells[1].result?.rows.isEmpty != false)
    #expect(cells[2].result == nil)
    #expect(await viewModel.executionQueue.waitForTask(cellId: cells[2].id) == .cancelled)
    await manager.setScriptCheckpointHook(nil)
    await tearDown([], manager, observer)
  }
}
