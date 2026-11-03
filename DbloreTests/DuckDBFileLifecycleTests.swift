// DuckDBFileLifecycleTests.swift
// Picked DuckDB files over the connection lifecycle, with fake sessions (no plugin): which
// paths each new session gets, when the access tokens are released, and what the Query
// Parquet/CSV File action does when the connection changes while its panel is open, and how the
// first run after a connect waits for the connect's loads.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB picked files lifecycle")
@MainActor
struct DuckDBFileLifecycleTests {
  private static func duckDB(_ database: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: database, sslMode: .disable, rememberConnection: false,
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  private static let postgres = ConnectionConfig(
    databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
    password: "p", sslMode: .disable, rememberConnection: false, protectionLevel: .none,
    safeMode: .silent, protectedMode: false)

  private let first = Self.duckDB("/tmp/dblore-first.duckdb")
  private let second = Self.duckDB("/tmp/dblore-second.duckdb")

  private func makeManager(
    _ factory: AllowedPathsRecordingFactory, config: ConnectionConfig, counter: TokenCounter
  ) -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
    manager.accessHooks.startAccess = { url in
      SecurityScopedAccessToken(
        url: url,
        start: { _ in
          counter.started += 1
          return true
        },
        stop: { _ in counter.stopped += 1 })
    }
    return manager
  }

  // MARK: - Connection actor

  @Test("A disconnect clears the actor's paths; its internal reconnect keeps them")
  func actorClearsOnDisconnectOnly() async throws {
    let factory = AllowedPathsRecordingFactory()
    let connection = DatabaseConnectionManager(sessionFactory: factory)

    try await connection.connect(config: first, extraAllowedPaths: ["/data/a.csv"])
    // Cancel and the capped read reopen the session through this call
    try await connection.reconnectWithActiveCertificate(config: first, material: nil)
    #expect(factory.recorded.last == ["/data/a.csv"])
    #expect(await connection.duckDBAllowedPaths == ["/data/a.csv"])

    await connection.disconnect()
    #expect(await connection.duckDBAllowedPaths.isEmpty)
    try await connection.connect(config: first)
    #expect(factory.recorded.last == [])
    await connection.disconnect()
  }

  // MARK: - Workspace

  @Test(
    "Another DuckDB database or another engine opens with no files and releases them",
    arguments: [false, true])
  func otherConnectDropsFiles(switchesEngine: Bool) async throws {
    let factory = AllowedPathsRecordingFactory()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: first)
    manager.addDuckDBFileAccess(URL(fileURLWithPath: "/data/a.csv"), path: "/data/a.csv")

    try await manager.connect(config: first)
    #expect(factory.recorded.last == ["/data/a.csv"])
    #expect(counter.stopped == 0)

    try await manager.connect(config: switchesEngine ? Self.postgres : second)
    #expect(factory.recorded.last == [])
    #expect(await manager.connectionManager.duckDBAllowedPaths.isEmpty)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(counter.started == 1)
    #expect(counter.stopped == 1)
  }

  @Test("A failed reconnect for a picked file releases that file")
  func failedGrantReleasesFile() async throws {
    let folder = try DuckDBFileQueryTests.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("data.csv")
    try Data("a\n1\n".utf8).write(to: file)
    let factory = AllowedPathsRecordingFactory()
    factory.openError = FakeQueryError()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    manager.accessHooks.chooseDataFile = { _ in file }

    #expect(await manager.queryDuckDBFile() == nil)
    #expect(factory.recorded.last == [try DuckDBFileQuery.canonicalPath(of: file)])
    #expect(counter.started == 1)
    #expect(counter.stopped == 1)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(manager.connectionState == .disconnected)
  }

  enum DuringPick: CaseIterable {
    case connectsOtherDatabase, switchesEngine, disconnects
  }

  @Test(
    "A connection changed while the panel is open: nothing reconnects, no file is held",
    arguments: DuringPick.allCases)
  func connectionChangedDuringPick(change: DuringPick) async throws {
    let folder = try DuckDBFileQueryTests.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("data.csv")
    try Data("a\n1\n".utf8).write(to: file)
    let factory = AllowedPathsRecordingFactory()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: first)
    let other = change == .switchesEngine ? Self.postgres : second
    manager.accessHooks.chooseDataFile = { _ in
      switch change {
      case .connectsOtherDatabase, .switchesEngine: try? await manager.connect(config: other)
      case .disconnects: await manager.performDisconnect()
      }
      return file
    }
    let sessionsBefore = factory.recorded.count

    #expect(await manager.queryDuckDBFile() == nil)

    let expectedSessions = sessionsBefore + (change == .disconnects ? 0 : 1)
    #expect(factory.recorded.count == expectedSessions)
    #expect(
      manager.workspace.connectionConfig?.database
        == (change == .disconnects ? first : other).database)
    #expect(counter.started == 0)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(await manager.connectionManager.duckDBAllowedPaths.isEmpty)
  }

  // MARK: - First run after a connect

  /// A connected workspace on `first` whose connect's schema load is still running until
  /// `release` finishes, with a notebook cell ready to run `sql`
  private func connectedWithHeldSchemaLoad(
    _ factory: AllowedPathsRecordingFactory, sql: String, settleLimit: Duration
  ) async throws -> (
    WorkspaceManager, NotebookViewModel, UUID, release: AsyncStream<Void>.Continuation
  ) {
    let manager = makeManager(factory, config: first, counter: TokenCounter())
    manager.connectLoadsSettleLimit = settleLimit
    try await manager.connect(config: first)
    await manager.awaitSchemaLoad()
    let release = holdSchemaLoad(of: manager)
    manager.newNotebook()
    let viewModel = try #require(manager.activeViewModel)
    viewModel.notebook.cells[0].content = sql
    return (manager, viewModel, viewModel.notebook.cells[0].id, release)
  }

  /// Replaces the schema load with one that runs until the returned continuation finishes
  private func holdSchemaLoad(of manager: WorkspaceManager) -> AsyncStream<Void>.Continuation {
    let (held, release) = AsyncStream.makeStream(of: Void.self)
    manager.schemaLoadTask = Task { for await _ in held {} }
    return release
  }

  private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test("LN12: the first run after a DuckDB connect is running at once, sent once the load ends")
  func firstRunWaitsForConnectLoads() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }

    await viewModel.runCell(id: cellId)
    #expect(await waitUntil { viewModel.notebook.cells[0].isRunning })
    // The schema load still owns the one connection: nothing of the run is sent meanwhile
    try await Task.sleep(for: .milliseconds(200))
    #expect(!factory.statements.contains(sql))
    #expect(viewModel.notebook.cells[0].isRunning)

    release.finish()
    await viewModel.executionQueue.waitForIdle()
    #expect(factory.statements.filter { $0 == sql }.count == 1)
    #expect(viewModel.notebook.cells[0].result?.error == nil)
    #expect(!viewModel.notebook.cells[0].isRunning)

    // Later runs do not wait, even for another load (a Refresh)
    let refresh = holdSchemaLoad(of: manager)
    defer { refresh.finish() }
    let started = ContinuousClock.now
    await viewModel.runCell(id: cellId)
    await viewModel.executionQueue.waitForIdle()
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(factory.statements.filter { $0 == sql }.count == 2)
  }

  @Test("LN12: two tabs waiting for the connect's loads both send their run once they end")
  func twoTabsWaitForConnectLoads() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let otherSQL = "SELECT 43 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }
    manager.newNotebook()
    let other = try #require(manager.activeViewModel)
    #expect(other !== viewModel)
    other.notebook.cells[0].content = otherSQL

    await viewModel.runCell(id: cellId)
    await other.runCell(id: other.notebook.cells[0].id)
    #expect(await waitUntil { viewModel.connectLoadsWaitTaskId != nil })
    #expect(await waitUntil { other.connectLoadsWaitTaskId != nil })

    release.finish()
    await viewModel.executionQueue.waitForIdle()
    await other.executionQueue.waitForIdle()
    #expect(factory.statements.filter { $0 == sql }.count == 1)
    #expect(factory.statements.filter { $0 == otherSQL }.count == 1)
    #expect(viewModel.notebook.cells[0].result?.error == nil)
    #expect(other.notebook.cells[0].result?.error == nil)
  }

  @Test("LN12: a connect load still running after the cap no longer holds the first run")
  func firstRunWaitIsCapped() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .milliseconds(50))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }

    let started = ContinuousClock.now
    await viewModel.runCell(id: cellId)
    await viewModel.executionQueue.waitForIdle()
    // Sent with the load still running, after the cap and not after the load
    #expect(factory.statements.filter { $0 == sql }.count == 1)
    #expect(started.duration(to: .now) < .seconds(5))
  }

  @Test("LN12: Stop on a cell waiting for the connect's loads sends nothing, the loads keep on")
  func stopCellDuringWait() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }
    let load = try #require(manager.schemaLoadTask)

    await viewModel.runCell(id: cellId)
    #expect(await waitUntil { viewModel.connectLoadsWaitTaskId != nil })
    viewModel.cancelCell(id: cellId)
    #expect(!viewModel.notebook.cells[0].isRunning)
    await viewModel.executionQueue.waitForIdle()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!factory.statements.contains(sql))
    #expect(!load.isCancelled)
    // The loads have not settled: the next run still waits for them
    #expect(manager.duckDBConnectLoadsPending != nil)
    await viewModel.runCell(id: cellId)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!factory.statements.contains(sql))

    release.finish()
    await viewModel.executionQueue.waitForIdle()
    #expect(factory.statements.filter { $0 == sql }.count == 1)
  }

  @Test("LN12: Stop on an editor run waiting for the connect's loads ends it, nothing is sent")
  func stopEditorRunDuringWait() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, _, _, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }
    let load = try #require(manager.schemaLoadTask)
    let editor = try #require(manager.viewModel(for: manager.newSQLFile(content: sql)))

    let run = Task { await editor.runUserEditorQuery(sql) }
    #expect(await waitUntil { editor.editorConnectLoadsWait != nil })
    #expect(editor.isEditorQueryRunning)
    let stopped = ContinuousClock.now
    editor.cancelEditorQuery()
    await run.value
    #expect(stopped.duration(to: .now) < .seconds(5))
    #expect(!editor.isEditorQueryRunning)
    #expect(!factory.statements.contains(sql))
    #expect(!load.isCancelled)
    #expect(manager.duckDBConnectLoadsPending != nil)
  }

  @Test("LN12: a connection changed while the run waited sends nothing")
  func connectionChangedDuringWait() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }

    await viewModel.runCell(id: cellId)
    #expect(await waitUntil { viewModel.connectLoadsWaitTaskId != nil })
    // The session is reopened (a new connection epoch) while the run waits
    try await manager.connectionManager.reconnectWithActiveCertificate(config: first, material: nil)
    release.finish()
    await viewModel.executionQueue.waitForIdle()

    #expect(!factory.statements.contains(sql))
    #expect(!viewModel.notebook.cells[0].isRunning)
    #expect(
      viewModel.notebook.cells[0].result?.error
        == NotebookViewModel.connectionChangedWhileWaitingMessage)
  }

  @Test(
    "LN12: a connect started after the run was admitted, before its wait began, sends nothing",
    arguments: [false, true])
  func connectStartedBeforeWait(switchesEngine: Bool) async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }
    // The run is admitted (shown as running) on `first`; another connect then runs to the end
    // before the wait reads anything: a new DuckDB database (its own loads mark) or another
    // engine (no mark at all)
    let wait = viewModel.awaitConnectLoads
    viewModel.awaitConnectLoads = { admitted in
      try? await manager.connect(config: switchesEngine ? Self.postgres : second)
      return await wait(admitted)
    }

    await viewModel.runCell(id: cellId)
    await viewModel.executionQueue.waitForIdle()

    #expect(manager.connectionState == .connected)
    #expect(!factory.statements.contains(sql))
    #expect(!viewModel.notebook.cells[0].isRunning)
    #expect(
      viewModel.notebook.cells[0].result?.error
        == NotebookViewModel.connectionChangedWhileWaitingMessage)
  }

  @Test("LN12: a connect started once the run's wait ended, before the send, sends nothing")
  func connectStartedAfterWait() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, viewModel, cellId, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    release.finish()
    // The wait ends with the connection kept; a connect then starts before anything is sent
    let wait = viewModel.awaitConnectLoads
    viewModel.awaitConnectLoads = { admitted in
      let kept = await wait(admitted)
      let before = manager.connectGeneration
      Task { try? await manager.connect(config: second) }
      _ = await waitUntil { manager.connectGeneration != before }
      return kept
    }

    await viewModel.runCell(id: cellId)
    await viewModel.executionQueue.waitForIdle()
    _ = await waitUntil { manager.connectionState == .connected }

    #expect(!factory.statements.contains(sql))
    #expect(!viewModel.notebook.cells[0].isRunning)
    #expect(
      viewModel.notebook.cells[0].result?.error
        == NotebookViewModel.connectionChangedWhileWaitingMessage)
  }

  /// An editor tab on `manager`'s connection whose toasts are recorded in `toasts`
  private func editorRecordingToasts(
    _ manager: WorkspaceManager, sql: String
  ) throws -> (NotebookViewModel, ToastRecorder) {
    let editor = try #require(manager.viewModel(for: manager.newSQLFile(content: sql)))
    let toasts = ToastRecorder()
    editor.toastPresenter = { message, _ in toasts.messages.append(message) }
    return (editor, toasts)
  }

  @Test(
    "LN12: an editor run whose connection changed before its wait began sends nothing",
    arguments: [false, true])
  func editorConnectStartedBeforeWait(switchesEngine: Bool) async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, _, _, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    defer { release.finish() }
    let (editor, toasts) = try editorRecordingToasts(manager, sql: sql)
    let wait = editor.awaitConnectLoads
    editor.awaitConnectLoads = { admitted in
      try? await manager.connect(config: switchesEngine ? Self.postgres : second)
      return await wait(admitted)
    }

    await editor.runUserEditorQuery(sql)

    #expect(manager.connectionState == .connected)
    #expect(!factory.statements.contains(sql))
    #expect(!editor.isEditorQueryRunning)
    #expect(toasts.messages == [NotebookViewModel.connectionChangedWhileWaitingMessage])
  }

  @Test("LN12: an editor run whose connection changed once its wait ended sends nothing")
  func editorConnectStartedAfterWait() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "SELECT 42 AS ln12"
    let (manager, _, _, release) = try await connectedWithHeldSchemaLoad(
      factory, sql: sql, settleLimit: .seconds(30))
    defer { Task { await manager.performDisconnect() } }
    release.finish()
    let (editor, toasts) = try editorRecordingToasts(manager, sql: sql)
    // The wait ends with the connection kept; a connect then starts before anything is sent
    let wait = editor.awaitConnectLoads
    editor.awaitConnectLoads = { admitted in
      let kept = await wait(admitted)
      let before = manager.connectGeneration
      Task { try? await manager.connect(config: second) }
      _ = await waitUntil { manager.connectGeneration != before }
      return kept
    }

    await editor.runUserEditorQuery(sql)
    _ = await waitUntil { manager.connectionState == .connected }

    #expect(!factory.statements.contains(sql))
    #expect(!editor.isEditorQueryRunning)
    #expect(toasts.messages == [NotebookViewModel.connectionChangedWhileWaitingMessage])
  }

  @Test("A single statement the send refused for a changed connection reads as run it again")
  func refusedSingleStatementMessage() {
    let refused = DatabaseError.sessionChanged(skippedStatements: 1)
    #expect(
      NotebookViewModel.runErrorMessage(refused, multipleStatements: false)
        == NotebookViewModel.connectionChangedWhileWaitingMessage)
    // A script may have run its first statements: the skipped ones are named
    #expect(
      NotebookViewModel.runErrorMessage(refused, multipleStatements: true)
        == refused.localizedDescription)
  }

  // MARK: - Confirmation across a connect

  private static func confirming(_ config: ConnectionConfig) -> ConnectionConfig {
    var config = config
    config.commitStyle = .confirm
    config.readOnlyFile = false
    return config
  }

  @Test("A confirmation shown on one connection is dropped by a connect: nothing is sent")
  func confirmationDroppedByConnect() async throws {
    let factory = AllowedPathsRecordingFactory()
    let sql = "UPDATE t SET a = 1 WHERE id = 1"
    let manager = makeManager(factory, config: Self.confirming(first), counter: TokenCounter())
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: Self.confirming(first))
    await manager.awaitSchemaLoad()
    manager.newNotebook()
    let viewModel = try #require(manager.activeViewModel)
    viewModel.notebook.cells[0].content = sql
    viewModel.confirmAndRunCell(id: viewModel.notebook.cells[0].id)
    #expect(viewModel.queryConfirmationState.showDialog)

    try await manager.connect(config: Self.confirming(second))
    #expect(!viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()
    #expect(!factory.statements.contains(sql))
  }

  @Test("A confirmed cell queued behind a run is refused when a connect ends before it starts")
  func confirmedCellQueuedAcrossConnect() async throws {
    let factory = AllowedPathsRecordingFactory()
    let select = "SELECT 42 AS ln12"
    let update = "UPDATE t SET a = 1 WHERE id = 1"
    let manager = makeManager(factory, config: Self.confirming(first), counter: TokenCounter())
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: Self.confirming(first))
    await manager.awaitSchemaLoad()
    let release = holdSchemaLoad(of: manager)
    defer { release.finish() }
    manager.newNotebook()
    let viewModel = try #require(manager.activeViewModel)
    viewModel.notebook.cells[0].content = select
    viewModel.addCell(type: .sql, after: viewModel.notebook.cells[0].id)
    viewModel.notebook.cells[1].content = update
    let confirmedId = viewModel.notebook.cells[1].id

    // The first run waits for the connect's loads: the confirmed cell queues behind it
    await viewModel.runCell(id: viewModel.notebook.cells[0].id)
    #expect(await waitUntil { viewModel.connectLoadsWaitTaskId != nil })
    viewModel.confirmAndRunCell(id: confirmedId)
    #expect(viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()
    #expect(viewModel.executionQueue.isInQueue(cellId: confirmedId))

    try await manager.connect(config: Self.confirming(second))
    await viewModel.executionQueue.waitForIdle()

    #expect(!factory.statements.contains(update))
    let confirmed = try #require(viewModel.notebook.cells.first { $0.id == confirmedId })
    #expect(!confirmed.isRunning)
    #expect(confirmed.result?.error == NotebookViewModel.connectionChangedWhileWaitingMessage)
  }
}

@MainActor
private final class ToastRecorder {
  var messages: [String] = []
}

private nonisolated final class TokenCounter: @unchecked Sendable {
  var started = 0
  var stopped = 0
}

/// Fake sessions that record the `extraAllowedPaths` each one was made with.
private nonisolated final class AllowedPathsRecordingFactory: DatabaseSessionFactory,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var paths: [[String]] = []
  private var made: [FakeDatabaseSession] = []
  private var error: (any Error)?

  /// Every session made from now on fails to open.
  var openError: (any Error)? {
    get { lock.withLock { error } }
    set { lock.withLock { error = newValue } }
  }

  var recorded: [[String]] { lock.withLock { paths } }

  /// SQL that reached any session made so far, in order
  var statements: [String] { lock.withLock { made }.flatMap(\.statements) }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    try await makeSession(config: config, extraAllowedPaths: [])
  }

  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    lock.withLock { paths.append(extraAllowedPaths) }
    let session = FakeDatabaseSessionFactory(capabilities: .contract(), openError: openError)
      .makeSession(config: config)
    if let fake = session as? FakeDatabaseSession { lock.withLock { made.append(fake) } }
    return session
  }
}
