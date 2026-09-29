// WorkspaceTransactionResolveTests.swift
// Resolving the pending Protected transaction (review round 3) against the docker test
// database (TEST_DB_* env, port 5435 in CI/autopilot): the way out while COMMIT does not
// answer, queued cells cancelled before the answer is applied, re-prompts, the re-entry guard,
// quit while a tab runs, and the actor ending idle after a disconnect during a statement.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace Transaction - Resolve (Requires PostgreSQL)", .serialized)
@MainActor
struct WorkspaceTransactionResolveTests {
  private static func config(protectedMode: Bool = true) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      // Explicit, so the global Safe Mode of the test host never applies
      safeMode: .silent,
      protectedMode: protectedMode
    )
  }

  private struct Fixture {
    let workspace: WorkspaceManager
    let tabId: UUID
    let viewModel: NotebookViewModel
    let observer: DatabaseConnectionManager
    let table: String
  }

  /// `table (id int PRIMARY KEY, v int)` with row (1, 10), created by an unprotected observer;
  /// a workspace connected in Protected mode with one notebook tab.
  private func setUp(_ table: String) async throws -> Fixture {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")

    let workspace = WorkspaceManager(workspace: Workspace())
    // Never show an NSAlert from tests: an unexpected prompt cancels
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    let tabId = workspace.newNotebook()
    try await workspace.connect(config: Self.config(), globalSafeMode: .silent)
    guard let viewModel = workspace.viewModel(for: tabId) else {
      throw DatabaseError.notConnected
    }
    return Fixture(
      workspace: workspace, tabId: tabId, viewModel: viewModel, observer: observer, table: table)
  }

  private func tearDown(_ fixture: Fixture) async {
    await fixture.workspace.connectionManager.setTransactionEndHook(nil)
    try? await fixture.workspace.connectionManager.rollbackAppTransaction()
    await fixture.workspace.disconnect(resolution: .rollback)
    // A backend may still sleep holding the row lock after its client disconnected
    _ = try? await fixture.observer.executeInternal(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        + "WHERE pid <> pg_backend_pid() AND query LIKE '%\(fixture.table)%pg_sleep%'")
    _ = try? await fixture.observer.executeInternal("DROP TABLE IF EXISTS \(fixture.table)")
    await fixture.observer.disconnect()
  }

  @discardableResult
  private func run(_ sql: String, in fixture: Fixture) async -> CellResult? {
    let cell = NotebookCell(cellType: .sql, content: sql)
    fixture.viewModel.notebook.cells.append(cell)
    return await fixture.viewModel.executeTask(ExecutionTask(cellId: cell.id, query: sql))
  }

  private func committedValue(_ fixture: Fixture) async throws -> CellValue? {
    try await fixture.observer.executeInternal(
      "SELECT v FROM \(fixture.table) WHERE id = 1"
    ).rows.first?.first
  }

  private func isCancelled(_ state: ExecutionState?) -> Bool {
    if case .cancelled? = state { return true }
    return false
  }

  // MARK: - COMMIT does not answer

  private struct EndHold {
    let reached: AsyncStream<Void>
    let release: AsyncStream<Void>.Continuation
  }

  /// Commit / Rollback suspends right after the state became `.ending`, before it is sent
  private func holdTransactionEnd(_ manager: DatabaseConnectionManager) async -> EndHold {
    let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
    let (released, releaseContinuation) = AsyncStream<Void>.makeStream()
    await manager.setTransactionEndHook { _ in
      reachedContinuation.yield()
      for await _ in released { break }
    }
    return EndHold(reached: reached, release: releaseContinuation)
  }

  @Test(
    "COMMIT not answering: Disconnect (outcome unknown) returns promptly, nothing committed",
    .timeLimit(.minutes(1)))
  func disconnectWhileCommitHangs() async throws {
    let fixture = try await setUp("p3_ws_commit_hangs")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    let hold = await holdTransactionEnd(fixture.workspace.connectionManager)
    fixture.workspace.requestCommit()
    let committing = Task { await fixture.workspace.confirmCommit(globalSafeMode: .silent) }
    var reached = hold.reached.makeAsyncIterator()
    _ = await reached.next()
    #expect(fixture.workspace.pendingTransaction.endingKind == .commit)

    var offered: [PendingTransactionResolution] = []
    fixture.workspace.pendingTransactionPrompt = { _, _, options in
      offered = options
      return options.first ?? .cancel
    }
    let start = Date()
    #expect(await fixture.workspace.disconnect())
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(offered == [.disconnectUnknownOutcome, .cancel])
    #expect(fixture.workspace.connectionState == .disconnected)
    #expect(!(await fixture.workspace.connectionManager.isConnected))

    hold.release.yield()
    hold.release.finish()
    #expect(!(await committing.value))
    let toast = WorkspaceWindowManager.shared.toastState.currentToast
    #expect(toast?.message.contains("unknown whether") == true)
    #expect(fixture.workspace.pendingTransaction.isIdle)
    // The hook held COMMIT before it was sent: the server rolled the transaction back
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  // MARK: - Queued cells cancelled before the answer is applied

  @Test(
    "Discard while Run All's first cell runs: the queued cells never execute",
    .timeLimit(.minutes(1)))
  func discardCancelsQueuedCells() async throws {
    let fixture = try await setUp("p3_ws_discard_run_all")
    let table = fixture.table
    let cells = [
      NotebookCell(
        cellType: .sql,
        content: "UPDATE \(table) SET v = 20 WHERE id = 1 AND pg_sleep(20) IS NOT NULL"),
      NotebookCell(cellType: .sql, content: "UPDATE \(table) SET v = 30 WHERE id = 1"),
      NotebookCell(cellType: .sql, content: "UPDATE \(table) SET v = 40 WHERE id = 1"),
    ]
    fixture.viewModel.notebook.cells = cells
    guard let queue = fixture.viewModel.executionQueue else {
      Issue.record("No execution queue")
      await tearDown(fixture)
      return
    }
    await fixture.viewModel.runAllCells(bypass: true)
    #expect(await queue.waitForExecuting(cellId: cells[0].id))
    try await Task.sleep(for: .milliseconds(500))

    fixture.workspace.pendingTransactionPrompt = { _, _, options in
      options.contains(.discard) ? .discard : .cancel
    }
    let epoch = await fixture.workspace.connectionManager.connectionEpoch
    #expect(await fixture.workspace.disconnect())
    // Discard disconnected once; disconnect() does not close again
    #expect(await fixture.workspace.connectionManager.connectionEpoch == epoch &+ 1)
    #expect(fixture.workspace.connectionState == .disconnected)

    // Cell 1 fails once its connection closed; give a queued cell time to (wrongly) start
    try await Task.sleep(for: .seconds(1))
    for cell in cells.dropFirst() {
      #expect(isCancelled(queue.tasks.first { $0.cellId == cell.id }?.state))
      #expect(fixture.viewModel.notebook.cells.first { $0.id == cell.id }?.result == nil)
    }
    #expect(await fixture.workspace.connectionManager.transactionSnapshot().isIdle)
    _ = try? await fixture.observer.executeInternal(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        + "WHERE pid <> pg_backend_pid() AND query LIKE '%\(table)%pg_sleep%'")
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  // MARK: - Re-prompt, re-entry, quit

  @Test(
    "Prompted Commit / Rollback refused because a statement started: asked again with Discard",
    .timeLimit(.minutes(1)), arguments: [PendingTransactionResolution.commit, .rollback])
  func repromptAfterRefusedAnswer(first: PendingTransactionResolution) async throws {
    let fixture = try await setUp("p3_ws_reprompt_\(first == .commit ? "commit" : "rollback")")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    let viewModel = fixture.viewModel
    let slowSQL = "UPDATE \(fixture.table) SET v = 30 WHERE id = 1 AND pg_sleep(2) IS NOT NULL"

    var offered: [[PendingTransactionResolution]] = []
    var hung: Task<CellResult?, Never>?
    fixture.workspace.pendingTransactionPrompt = { _, _, options in
      offered.append(options)
      guard offered.count == 1 else { return .cancel }
      // A statement starts while the prompt is open: the chosen answer is refused
      let cell = NotebookCell(cellType: .sql, content: slowSQL)
      viewModel.notebook.cells.append(cell)
      hung = Task { await viewModel.executeTask(ExecutionTask(cellId: cell.id, query: slowSQL)) }
      try? await Task.sleep(for: .milliseconds(500))
      return first
    }
    #expect(!(await fixture.workspace.disconnect()))
    #expect(offered.count == 2)
    #expect(offered.first == [.commit, .rollback, .cancel])
    #expect(offered.last == [.discard, .cancel])
    #expect(fixture.workspace.connectionState == .connected)

    _ = await hung?.value
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  @Test(
    "Refused answer while another resolve prompt opened meanwhile: no second prompt at once",
    .timeLimit(.minutes(1)))
  func noRepromptWhileAnotherPromptIsOpen() async throws {
    let fixture = try await setUp("p3_ws_reprompt_overlap")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    let viewModel = fixture.viewModel
    let slowSQL = "UPDATE \(fixture.table) SET v = 30 WHERE id = 1 AND pg_sleep(2) IS NOT NULL"

    var prompts = 0
    var open = 0
    var maxOpen = 0
    var hung: Task<CellResult?, Never>?
    var other: Task<Bool, Never>?
    fixture.workspace.pendingTransactionPrompt = { [weak workspace = fixture.workspace] _, _, _ in
      prompts += 1
      open += 1
      maxOpen = max(maxOpen, open)
      defer { open -= 1 }
      guard prompts == 1, let workspace else {
        // Stays open while the first resolve handles its refused answer
        try? await Task.sleep(for: .seconds(1))
        return .cancel
      }
      // A statement starts while the prompt is open: the chosen Rollback is refused
      let cell = NotebookCell(cellType: .sql, content: slowSQL)
      viewModel.notebook.cells.append(cell)
      hung = Task { await viewModel.executeTask(ExecutionTask(cellId: cell.id, query: slowSQL)) }
      try? await Task.sleep(for: .milliseconds(500))
      // Starts once this prompt is closed: its own prompt opens while the answer is applied
      other = Task { await workspace.resolvePendingTransaction(action: .quit) }
      return .rollback
    }
    #expect(!(await fixture.workspace.resolvePendingTransaction(action: .closeWindow)))
    #expect(await other?.value == false)
    #expect(prompts == 2)
    #expect(maxOpen == 1)

    _ = await hung?.value
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  @Test(
    "A second resolve while the prompt is open is refused without a second prompt",
    .timeLimit(.minutes(1)))
  func resolveReentryRefused() async throws {
    let fixture = try await setUp("p3_ws_reentry")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)

    var prompts = 0
    var nested: Bool?
    var nestedCloseDeferred: Bool?
    let tabId = fixture.tabId
    fixture.workspace.pendingTransactionPrompt = { [weak workspace = fixture.workspace] _, _, _ in
      prompts += 1
      if prompts == 1, let workspace {
        nested = await workspace.resolvePendingTransaction(action: .quit)
        nestedCloseDeferred = workspace.deferCloseTabForPendingTransaction(id: tabId)
      }
      return .cancel
    }
    #expect(!(await fixture.workspace.resolvePendingTransaction(action: .closeWindow)))
    #expect(prompts == 1)
    #expect(nested == false)
    #expect(nestedCloseDeferred == true)
    #expect(fixture.workspace.pendingTransaction.pending.count == 1)
    await tearDown(fixture)
  }

  @Test(
    "Quit while a tab runs the statement that opened the transaction (mirror still idle)",
    .timeLimit(.minutes(1)))
  func quitWhileTabExecutingMirrorIdle() async throws {
    let fixture = try await setUp("p3_ws_quit_executing")
    let cell = NotebookCell(
      cellType: .sql,
      content: "UPDATE \(fixture.table) SET v = 20 WHERE id = 1 AND pg_sleep(2) IS NOT NULL")
    fixture.viewModel.notebook.cells = [cell]
    guard let queue = fixture.viewModel.executionQueue else {
      Issue.record("No execution queue")
      await tearDown(fixture)
      return
    }
    queue.enqueue(cellId: cell.id, query: cell.content)
    #expect(await queue.waitForExecuting(cellId: cell.id))
    try await Task.sleep(for: .milliseconds(500))
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(fixture.workspace.isAnyTabExecuting)

    var offered: [PendingTransactionResolution] = []
    fixture.workspace.pendingTransactionPrompt = { _, _, options in
      offered = options
      return .cancel
    }
    #expect(!(await fixture.workspace.resolvePendingTransaction(action: .quit)))
    #expect(offered == [.discard, .cancel])

    await queue.waitForIdle()
    #expect(fixture.workspace.pendingTransaction.pending.count == 1)
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  // MARK: - Actor disconnect during a statement

  @Test(
    "Disconnect while a statement of the transaction runs: the closed manager ends idle",
    .timeLimit(.minutes(1)))
  func disconnectDuringStatementEndsIdle() async throws {
    let fixture = try await setUp("p3_ws_in_flight_disconnect")
    let manager = fixture.workspace.connectionManager
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    let hung = Task {
      await run(
        "UPDATE \(fixture.table) SET v = 30 WHERE id = 1 AND pg_sleep(20) IS NOT NULL", in: fixture)
    }
    try await Task.sleep(for: .milliseconds(500))

    await manager.disconnect()
    #expect(!(await manager.isConnected))
    let result = await hung.value
    #expect(result?.error != nil)
    #expect(await manager.transactionSnapshot().isIdle)
    #expect(await manager.transactionStatus().owner == nil)
    _ = try? await fixture.observer.executeInternal(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        + "WHERE pid <> pg_backend_pid() AND query LIKE '%\(fixture.table)%pg_sleep%'")
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }
}
