// RunningWorkTransactionTests.swift
// The running-work prompt and a Protected transaction a running tab opened (a temporary
// SQLite file through the connection actor): a quit names its rollback and asks about it after
// Stop; Stop asks again before it cancels a statement whose transaction opened after the
// prompt, and "Keep running" there cancels the close or quit; a second close or disconnect
// while the first asks about running work is ignored, and a ROLLBACK that hangs after a close
// chose it stays escapable from the banner.

import Foundation
import Testing

@testable import Dblore

@Suite("Running work and pending transactions")
@MainActor
struct RunningWorkTransactionTests {
  private let update = "UPDATE notes SET body = 'changed' WHERE id = 1"

  @Test(
    "A quit refreshes a running tab's transaction before asking, and asks about it after Stop",
    .timeLimit(.minutes(1)))
  func quitNamesAndResolvesRunningTransaction() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let manager = WorkspaceManager.createNew(connection: config)
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    let registry = RunningWorkRegistry()
    registry.stopLimit = .seconds(30)
    var prompts: [RunningWorkRegistry.Prompt] = []
    registry.presentPrompt = { prompt in
      prompts.append(prompt)
      return false
    }
    var resolutions: [PendingTransactionAction] = []
    manager.pendingTransactionPrompt = { action, _, _ in
      resolutions.append(action)
      return .cancel
    }
    func quit() async -> Bool {
      await WorkspaceManager.answerQuitQuestions(
        [manager], runningWork: registry, confirmBeforeQuit: false, confirmQuit: { true })
    }

    // The running cell's first statement opened the transaction: the mirror still shows none
    _ = try await manager.connectionManager.execute(
      userSQL: update, policy: ProtectionPolicy(config: config), caller: viewModel.id)
    viewModel.isEditorQueryRunning = true
    #expect(manager.pendingTransaction.isIdle)
    #expect(await quit() == false)
    let line = try #require(prompts.last?.lines.first)
    #expect(line.hasPrefix("Query in "))
    #expect(line.contains(" will be stopped; this "))
    #expect(line.hasSuffix(" 1 pending change"))
    #expect(resolutions.isEmpty)

    // The cell opens it while the prompt is open, and ends before Stop's wait does
    await manager.connectionManager.disconnect()
    try await manager.connectionManager.connect(config: config)
    manager.applyTransactionState(.idle, originTabId: nil)
    let copy = registry.begin(workspaceID: manager.id, label: "Copy", kind: .copyObjects) {}
    registry.presentPrompt = { prompt in
      prompts.append(prompt)
      viewModel.isEditorQueryRunning = false
      Task {
        _ = try? await manager.connectionManager.execute(
          userSQL: update, policy: ProtectionPolicy(config: config), caller: viewModel.id)
        registry.end(copy)
      }
      return true
    }
    #expect(await quit() == false)
    #expect(prompts.count == 2)
    // Never dropped silently: the quit asks about the transaction Stop left behind
    #expect(resolutions == [.quit])
    #expect(!manager.pendingTransaction.isIdle)
    await manager.connectionManager.disconnect()
  }

  @Test(
    "A second close or disconnect while a close asks about running work or stops it is ignored",
    .timeLimit(.minutes(1)))
  func secondCloseWhileAsking() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let windows = WorkspaceWindowManager()
    windows.findWorkspaceWindow = { _ in nil }
    windows.hasWelcomeHandler = { false }
    windows.openWorkspaceWindow = { _ in }
    let manager = windows.newWorkspace(connection: config)
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    _ = try await manager.connectionManager.execute(
      userSQL: update, policy: ProtectionPolicy(config: config), caller: viewModel.id)
    let registry = RunningWorkRegistry()
    manager.runningWork = registry
    // A cancel that hangs: Stop waits until the user's second clicks are done
    let copy = registry.begin(
      workspaceID: manager.id, label: "Copy Objects to shop", kind: .copyObjects
    ) {}
    registry.stopLimit = .seconds(30)
    var prompts = 0
    var second: Bool?
    var secondDisconnect: Bool?
    registry.presentPrompt = { _ in
      prompts += 1
      // While Stop waits, the user clicks Close and Disconnect again
      Task {
        second = await windows.closeWorkspace(id: manager.id)
        secondDisconnect = await manager.disconnect(asksForRunningWork: true)
        registry.end(copy)
      }
      return true
    }
    var transactionPrompts = 0
    manager.pendingTransactionPrompt = { _, _, _ in
      transactionPrompts += 1
      return .cancel
    }

    #expect(await windows.closeWorkspace(id: manager.id) == false)
    #expect(second == false)
    #expect(secondDisconnect == false)
    #expect(prompts == 1)
    #expect(transactionPrompts == 1)
    #expect(windows.workspaces[manager.id] === manager)
    #expect(manager.connectionState == .connected)

    _ = await windows.closeWorkspace(id: manager.id, force: true)
  }

  @Test(
    "A ROLLBACK that hangs after a close or disconnect chose it: the banner's Disconnect still works",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func disconnectWhileChosenRollbackHangs(startsWithClose: Bool) async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let windows = WorkspaceWindowManager()
    windows.findWorkspaceWindow = { _ in nil }
    windows.hasWelcomeHandler = { false }
    windows.openWorkspaceWindow = { _ in }
    let manager = windows.newWorkspace(connection: config)
    manager.runningWork = RunningWorkRegistry()
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    _ = try await manager.connectionManager.execute(
      userSQL: update, policy: ProtectionPolicy(config: config), caller: viewModel.id)
    // ROLLBACK is held right after the state became `.ending`, before it is sent
    let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
    let (released, releaseContinuation) = AsyncStream<Void>.makeStream()
    await manager.connectionManager.setTransactionEndHook { _ in
      reachedContinuation.yield()
      for await _ in released { break }
    }
    var offered: [[PendingTransactionResolution]] = []
    manager.pendingTransactionPrompt = { _, _, options in
      offered.append(options)
      return options.contains(.rollback) ? .rollback : options.first ?? .cancel
    }

    let first = Task {
      if startsWithClose { return await windows.closeWorkspace(id: manager.id) }
      return await manager.disconnect(asksForRunningWork: true)
    }
    var iterator = reached.makeAsyncIterator()
    _ = await iterator.next()
    #expect(manager.pendingTransaction.endingKind == .rollback)

    // The banner's "Rollback is taking long — Disconnect…"
    #expect(await manager.disconnect(asksForRunningWork: true))
    #expect(offered.last == [.disconnect, .cancel])
    #expect(manager.connectionState == .disconnected)
    #expect(!(await manager.connectionManager.isConnected))

    releaseContinuation.yield()
    releaseContinuation.finish()
    _ = await first.value
    await manager.connectionManager.setTransactionEndHook(nil)
    _ = await windows.closeWorkspace(id: manager.id, force: true)
  }

  @Test(
    "Stop skips a running statement's cancel warning only for the transaction its line named",
    .timeLimit(.minutes(1)))
  func stopAsksAgainForTransactionOpenedAfterPrompt() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let manager = WorkspaceManager.createNew(connection: config)
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    let connection = manager.connectionManager
    let registry = RunningWorkRegistry()
    registry.stopLimit = .seconds(30)
    manager.runningWork = registry
    var lines: [String] = []
    var warnings: [QueryCancelWarning] = []
    viewModel.cancelQueryPrompt = { warning in
      warnings.append(warning)
      return false
    }
    var resolutions: [PendingTransactionAction] = []
    manager.pendingTransactionPrompt = { action, _, _ in
      resolutions.append(action)
      return .cancel
    }
    func quit() async -> Bool {
      await WorkspaceManager.answerQuitQuestions(
        [manager], runningWork: registry, confirmBeforeQuit: false, confirmQuit: { true })
    }
    /// The change then a write that runs until it is interrupted, as the tab's script
    func runScript() -> Task<QueryResult, any Error> {
      Task {
        return try await connection.execute(
          userSQL: "\(update); \(Self.longWrite)", policy: ProtectionPolicy(config: config),
          caller: viewModel.id)
      }
    }
    func waitForPendingWrite() async throws {
      while true {
        let status = await connection.runningStatementStatus()
        if status.inFlight, status.state.pending.count == 1 { return }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    // The line named the pending change: Stop interrupts the write without asking again
    viewModel.isEditorQueryRunning = true
    let named = runScript()
    Task {
      _ = try? await named.value
      viewModel.isEditorQueryRunning = false
    }
    try await waitForPendingWrite()
    registry.presentPrompt = { prompt in
      lines += prompt.lines
      return true
    }
    #expect(await quit())
    #expect(lines.count == 1)
    #expect(lines.first?.hasSuffix(" 1 pending change") == true)
    #expect(warnings.isEmpty)
    #expect(resolutions.isEmpty)
    await #expect(throws: DatabaseError.self) { try await named.value }

    // The prompt named no transaction; the script opens one while Stop waits: its cancel asks
    lines = []
    viewModel.isEditorQueryRunning = true
    let copy = registry.begin(workspaceID: manager.id, label: "Copy", kind: .copyObjects) {}
    var opened: Task<QueryResult, any Error>?
    registry.presentPrompt = { prompt in
      lines += prompt.lines
      opened = runScript()
      // The script opens the transaction while the prompt is open. Stop's own cancel of the
      // tab is held back (the tab no longer shows as running) so the test's cancel below reads
      // the status only once the change is pending, as it would after a click on Stop.
      viewModel.isEditorQueryRunning = false
      Task {
        try? await waitForPendingWrite()
        // A cancel clicked in the tab while Stop waits (not one Stop started, whose "Keep
        // running" would cancel the quit before the transaction prompt)
        await viewModel.cancelRunningStatement(cancelQueue: true)
        registry.end(copy)
      }
      return true
    }
    #expect(await quit() == false)
    #expect(lines.count == 2)
    #expect(lines.first?.hasPrefix("Query in ") == true)
    #expect(lines.first?.contains(" will be stopped") == false)
    #expect(warnings.count == 1)
    #expect(warnings.first?.title.hasSuffix("1 pending change") == true)
    // Kept running: the change is asked about, never dropped silently
    #expect(resolutions == [.quit])
    #expect(!manager.pendingTransaction.isIdle)

    let status = await connection.runningStatementStatus()
    _ = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    _ = try? await opened?.value
    await connection.disconnect()
  }

  @Test(
    "Keep running in a cancel warning during Stop cancels the close or quit; the BEGIN stays open",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func keepRunningCancelsCloseOrQuit(closes: Bool) async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path, protectedMode: false)
    let windows = WorkspaceWindowManager()
    windows.findWorkspaceWindow = { _ in nil }
    windows.hasWelcomeHandler = { false }
    windows.openWorkspaceWindow = { _ in }
    let manager = windows.newWorkspace(connection: config)
    let connection = manager.connectionManager
    try await connection.connect(config: config)
    manager.connectionState = .connected
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    let registry = RunningWorkRegistry()
    registry.stopLimit = .milliseconds(200)
    manager.runningWork = registry
    var warnings: [QueryCancelWarning] = []
    viewModel.cancelQueryPrompt = { warning in
      warnings.append(warning)
      return false
    }
    var resolutions: [PendingTransactionAction] = []
    manager.pendingTransactionPrompt = { action, _, _ in
      resolutions.append(action)
      return .cancel
    }
    var copyCancels = 0
    let copy = registry.begin(workspaceID: manager.id, label: "Copy", kind: .copyObjects) {
      copyCancels += 1
    }

    // The user's BEGIN (Protected off) and a write in it, both after the mirror was last read
    let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open, caller: viewModel.id)
    let script = Task {
      try await connection.execute(userSQL: Self.longWrite, policy: open, caller: viewModel.id)
    }
    while true {
      let status = await connection.runningStatementStatus()
      if status.inFlight, status.userTxOpen { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!manager.isUserTransactionOpen)
    var lines: [String] = []
    registry.presentPrompt = { prompt in
      lines += prompt.lines
      // The tab shows as running once the prompt is drawn: Stop's cancel finds its BEGIN
      viewModel.isEditorQueryRunning = true
      return true
    }

    if closes {
      #expect(await windows.closeWorkspace(id: manager.id) == false)
      #expect(windows.workspaces[manager.id] === manager)
    } else {
      #expect(
        await WorkspaceManager.answerQuitQuestions(
          [manager], runningWork: registry, confirmBeforeQuit: false, confirmQuit: { true })
          == false)
    }
    #expect(lines == ["Copy"])
    #expect(warnings.count == 1)
    #expect(resolutions.isEmpty)
    // Kept running: nothing else was stopped, and the connection and its BEGIN stay open
    #expect(copyCancels == 0)
    #expect(manager.connectionState == .connected)
    let status = await connection.runningStatementStatus()
    #expect(status.inFlight)
    #expect(status.userTxOpen)

    _ = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    _ = try? await script.value
    viewModel.isEditorQueryRunning = false
    registry.end(copy)
    await connection.disconnect()
    _ = await windows.closeWorkspace(id: manager.id, force: true)
  }

  /// Runs far longer than any test waits (an interrupt stops it)
  private static let longWrite = """
    INSERT INTO notes (body) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c \
    LIMIT 1000000000) SELECT 'row' FROM c
    """

  private func sqliteConfig(path: String, protectedMode: Bool = true) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: protectedMode)
  }

  private func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-running-work-\(UUID().uuidString).sqlite")
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
