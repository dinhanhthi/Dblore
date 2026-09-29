// ClosedConnectionTests.swift
// C0: a session the server closed (idle-in-transaction timeout, pg_terminate_backend) never
// hangs a caller; the manager forgets the session, emits a session-lost event, and the
// workspace shows it as disconnected. Against the docker test database (TEST_DB_* env, port
// 5435 in CI/autopilot). A second, unprotected manager observes and terminates backends.

import Foundation
import Testing

@testable import Dblore

/// The outcome of an operation bounded by a deadline. The operation runs on its own task, so a
/// call that never completes is reported as `timedOut` instead of hanging the test.
enum BoundedOutcome {
  case returned
  case threw(Error)
  case timedOut

  var didThrow: Bool {
    if case .threw = self { return true }
    return false
  }
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}

func bounded(
  _ duration: Duration, _ operation: @escaping @Sendable () async throws -> Void
) async -> BoundedOutcome {
  await withCheckedContinuation { continuation in
    let once = ResumeOnce()
    let work = Task {
      do {
        try await operation()
        if once.claim() { continuation.resume(returning: .returned) }
      } catch {
        if once.claim() { continuation.resume(returning: .threw(error)) }
      }
    }
    Task {
      try? await Task.sleep(for: duration)
      if once.claim() {
        work.cancel()
        continuation.resume(returning: .timedOut)
      }
    }
  }
}

@Suite("Closed Connection - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct ClosedConnectionTests {
  private static func config(protectedMode: Bool, idleTimeout: Int = 600) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: protectedMode,
      idleInTransactionTimeoutSeconds: idleTimeout
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Connects an unprotected observer that creates `table (id int PRIMARY KEY, v int)` with
  /// row (1, 10), and `manager` with the given settings.
  private func setUp(
    _ table: String, protectedMode: Bool, idleTimeout: Int = 600
  ) async throws -> (manager: DatabaseConnectionManager, observer: DatabaseConnectionManager) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: Self.config(protectedMode: protectedMode, idleTimeout: idleTimeout))
    return (manager, observer)
  }

  private func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  /// Protected off, idle-in-transaction timeout 1s: a user BEGIN idles 2.5s, so the server
  /// closes the session. Runs `body`, then always tears down.
  private func withServerClosedSession(
    _ table: String,
    _ body: (DatabaseConnectionManager, DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let (manager, observer) = try await setUp(table, protectedMode: false, idleTimeout: 1)
    do {
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      try await Task.sleep(for: .milliseconds(2500))
      try await body(manager, observer)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  private func backendPid(_ manager: DatabaseConnectionManager) async throws -> String {
    let value = try await manager.executeInternal("SELECT pg_backend_pid()").rows.first?.first
    guard case .int(let pid) = value else { throw DatabaseError.queryFailed("no backend pid", 0) }
    return String(pid)
  }

  private func terminate(_ pid: String, from observer: DatabaseConnectionManager) async throws {
    _ = try await observer.executeInternal("SELECT pg_terminate_backend(\(pid))")
  }

  /// Poll `condition` every 50 ms for up to `seconds`
  private func eventually(
    within seconds: Double = 2, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
  }

  /// The first session-lost event of `manager`, or nil after `duration`
  private func firstSessionLost(
    _ manager: DatabaseConnectionManager, within duration: Duration = .seconds(2)
  ) async -> SessionLostEvent? {
    let box = EventBox()
    let outcome = await bounded(duration) {
      for await event in manager.sessionEvents {
        box.set(event)
        return
      }
    }
    _ = outcome
    return box.value
  }

  // MARK: - Server-closed session: every entry fails fast

  @Test("Server-closed session: execute(userSQL:) throws within 2s", .timeLimit(.minutes(1)))
  func executeFailsFast() async throws {
    try await withServerClosedSession("c0_closed_execute") { manager, _ in
      let outcome = await bounded(.seconds(2)) {
        _ = try await manager.execute(userSQL: "SELECT 1", policy: open)
      }
      #expect(outcome.didThrow, "got \(outcome)")
      #expect(!(await manager.isConnected))
    }
  }

  @Test("Server-closed session: executeInternal throws within 2s", .timeLimit(.minutes(1)))
  func executeInternalFailsFast() async throws {
    try await withServerClosedSession("c0_closed_internal") { manager, _ in
      let outcome = await bounded(.seconds(2)) {
        _ = try await manager.executeInternal("SELECT 1")
      }
      #expect(outcome.didThrow, "got \(outcome)")
      #expect(!(await manager.isConnected))
    }
  }

  @Test("Server-closed session: fetchTables throws within 2s", .timeLimit(.minutes(1)))
  func fetchTablesFailsFast() async throws {
    try await withServerClosedSession("c0_closed_tables") { manager, _ in
      let outcome = await bounded(.seconds(2)) {
        _ = try await manager.fetchTables()
      }
      #expect(outcome.didThrow, "got \(outcome)")
      #expect(!(await manager.isConnected))
    }
  }

  @Test("Server-closed session: executeGatedUpdate throws within 2s", .timeLimit(.minutes(1)))
  func gatedUpdateFailsFast() async throws {
    let table = "c0_closed_edit"
    let (manager, observer) = try await setUp(table, protectedMode: false, idleTimeout: 1)
    do {
      let epoch = await manager.connectionEpoch
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      try await Task.sleep(for: .milliseconds(2500))
      let edit = try CellUpdateStatement.make(
        qualifiedName: "public.\(table)", columnName: "v", newValue: "11",
        primaryKeyColumns: ["id"], rowData: ["id": .int(1), "v": .int(10)])
      let policy = open
      let outcome = await bounded(.seconds(2)) {
        _ = try await manager.executeGatedUpdate(edit, policy: policy, connectionEpoch: epoch)
      }
      #expect(outcome.didThrow, "got \(outcome)")
      #expect(!(await manager.isConnected))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Server-closed session is detected without any query: not connected, event emitted",
    .timeLimit(.minutes(1)))
  func idleKillDetectedPassively() async throws {
    try await withServerClosedSession("c0_closed_passive") { manager, _ in
      #expect(await eventually { await !manager.isConnected })
      let event = await firstSessionLost(manager)
      #expect(event != nil)
      #expect(event?.pendingCount == 0)
      #expect(event?.userTransactionLost == true)
      #expect(!(await manager.userTxOpen))
    }
  }

  // MARK: - Terminated backend

  @Test(
    "Terminated backend with a pending Protected transaction: Commit throws within 2s",
    .timeLimit(.minutes(1)))
  func commitFailsFastAfterTermination() async throws {
    let table = "c0_terminated_commit"
    let (manager, observer) = try await setUp(table, protectedMode: true)
    do {
      let pid = try await backendPid(manager)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      #expect(await manager.transactionSnapshot().pending.count == 1)
      let generation = await manager.transactionStatus().generation
      try await terminate(pid, from: observer)
      // Detected without any query; the event reports the discarded pending statement
      #expect(await eventually { await !manager.isConnected })
      #expect(await manager.transactionSnapshot().isIdle)
      let event = await firstSessionLost(manager)
      #expect(event?.pendingCount == 1)
      #expect(event?.message.contains("1 pending change was rolled back by the server") == true)

      // Commit never reports a silent success for the transaction the server discarded
      let outcome = await bounded(.seconds(2)) {
        try await manager.commitAppTransaction(expectedGeneration: generation)
      }
      if case .threw(let error) = outcome,
        case .connectionLost(let message)? =
          error as? DatabaseError
      {
        #expect(message.contains("rolled back by the server"))
      } else {
        Issue.record("Expected connectionLost, got \(outcome)")
      }
      #expect(
        try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
          .rows.first?.first == .int(10))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A query in flight when the backend is terminated fails within 2s", .timeLimit(.minutes(1)))
  func inFlightQueryFailsFast() async throws {
    let table = "c0_terminated_in_flight"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    do {
      let pid = try await backendPid(manager)
      let running = Task {
        await bounded(.seconds(15)) {
          _ = try await manager.executeInternal("SELECT pg_sleep(10)")
        }
      }
      try await Task.sleep(for: .milliseconds(500))
      let terminatedAt = Date()
      try await terminate(pid, from: observer)
      let outcome = await running.value
      #expect(outcome.didThrow, "got \(outcome)")
      #expect(Date().timeIntervalSince(terminatedAt) < 2)
      #expect(await eventually { await !manager.isConnected })
      #expect(await firstSessionLost(manager) != nil)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "After a loss the manager reconnects and works again", .timeLimit(.minutes(1)))
  func reconnectAfterLoss() async throws {
    let table = "c0_terminated_reconnect"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    do {
      try await terminate(try await backendPid(manager), from: observer)
      #expect(await eventually { await !manager.isConnected })
      try await manager.connect(config: Self.config(protectedMode: false))
      #expect(try await manager.executeInternal("SELECT 1").rows.first?.first == .int(1))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Workspace

  @Test(
    "Workspace: a terminated session shows disconnected and the rolled-back pending changes",
    .timeLimit(.minutes(1)))
  func workspaceShowsConnectionLost() async throws {
    let table = "c0_ws_lost"
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")

    let workspace = WorkspaceManager(workspace: Workspace())
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    _ = workspace.newNotebook()
    do {
      try await workspace.connect(config: Self.config(protectedMode: true), globalSafeMode: .silent)
      let pid = try await backendPid(workspace.connectionManager)
      _ = try await workspace.connectionManager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      await workspace.refreshPendingTransaction()
      #expect(workspace.pendingTransaction.pending.count == 1)
      #expect(workspace.connectionLostMessage == nil)

      try await terminate(pid, from: observer)
      #expect(await eventually(within: 3) { workspace.connectionState == .disconnected })
      #expect(workspace.pendingTransaction.isIdle)
      #expect(
        workspace.connectionLostMessage?.contains(
          "1 pending change was rolled back by the server") == true,
        "got \(String(describing: workspace.connectionLostMessage))")
      #expect(workspace.viewModels.values.allSatisfy { $0.connectionState == .disconnected })
      #expect(!(await workspace.connectionManager.isConnected))
    } catch {
      Issue.record(error)
    }
    await workspace.disconnect(resolution: .rollback)
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }
}

private final class EventBox: @unchecked Sendable {
  private let lock = NSLock()
  private var event: SessionLostEvent?

  func set(_ value: SessionLostEvent) {
    lock.lock()
    event = value
    lock.unlock()
  }

  var value: SessionLostEvent? {
    lock.lock()
    defer { lock.unlock() }
    return event
  }
}
