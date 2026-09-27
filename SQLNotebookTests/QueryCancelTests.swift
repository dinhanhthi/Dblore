// QueryCancelTests.swift
// C3: Cancel stops the server work (close + reconnect with the current config, the only way
// with PostgresNIO 1.33.1), warns first when pending Protected changes would be discarded, and
// the server `statement_timeout` (not a client-side timeout) is the brake for long statements.
// Resets never produce a false "Connection lost". Against the docker test database (TEST_DB_*
// env, port 5435 in CI/autopilot). A second, unprotected manager observes the backends.

import Foundation
import Testing

@testable import SQLNotebook

/// Lock-protected list shared with a listening task
private final class Collected<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Value] = []

  func append(_ value: Value) {
    lock.lock()
    stored.append(value)
    lock.unlock()
  }

  var values: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

@Suite("Query Cancel - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct QueryCancelTests {
  private static let sleepSQL = "SELECT pg_sleep(30)"

  private static func config(protectedMode: Bool, statementTimeout: Int = 120) -> ConnectionConfig {
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
      statementTimeoutSeconds: statementTimeout
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Connects an unprotected observer that creates `table (id int PRIMARY KEY, v int)` with
  /// row (1, 10), and `manager` with the given settings.
  private func setUp(
    _ table: String, protectedMode: Bool, statementTimeout: Int = 120
  ) async throws -> (manager: DatabaseConnectionManager, observer: DatabaseConnectionManager) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: Self.config(protectedMode: protectedMode, statementTimeout: statementTimeout))
    return (manager, observer)
  }

  /// Disconnects, stops any sleeper left by a failing test, drops the table.
  private func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager,
    pid: String? = nil
  ) async {
    await manager.disconnect()
    if let pid {
      _ = try? await observer.executeInternal("SELECT pg_terminate_backend(\(pid))")
    }
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func backendPid(_ manager: DatabaseConnectionManager) async throws -> String {
    let value = try await manager.executeInternal("SELECT pg_backend_pid()").rows.first?.first
    guard case .int(let pid) = value else { throw DatabaseError.queryFailed("no backend pid", 0) }
    return String(pid)
  }

  /// Active `pg_sleep(30)` statements of backend `pid`, seen from the observer connection
  private func activeSleepers(_ pid: String, _ observer: DatabaseConnectionManager) async -> Int {
    let result = try? await observer.executeInternal(
      "SELECT count(*) FROM pg_stat_activity WHERE pid = \(pid) "
        + "AND query LIKE 'SELECT pg_sleep(30)%' AND state = 'active'")
    guard case .int(let count)? = result?.rows.first?.first else { return -1 }
    return Int(count)
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

  /// Session-lost events of `manager` emitted while `body` runs and during `settle` after it
  private func sessionLostEvents(
    _ manager: DatabaseConnectionManager, settle: Duration = .milliseconds(500),
    during body: () async throws -> Void
  ) async rethrows -> [SessionLostEvent] {
    let collected = Collected<SessionLostEvent>()
    let listener = Task {
      for await event in manager.sessionEvents { collected.append(event) }
    }
    try await body()
    try? await Task.sleep(for: settle)
    listener.cancel()
    return collected.values
  }

  private func isCancelled(_ outcome: BoundedOutcome) -> Bool {
    guard case .threw(let error) = outcome, case .queryCancelled? = error as? DatabaseError else {
      return false
    }
    return true
  }

  // MARK: - Cancel stops the server work

  @Test(
    "Cancel pg_sleep(30): returns in < 2s, the backend is gone, the next query works",
    .timeLimit(.minutes(1)))
  func cancelStopsBackend() async throws {
    let table = "c3_cancel_sleep"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    var pid: String?
    do {
      pid = try await backendPid(manager)
      guard let pid else { return }
      let policy = open
      let running = Task {
        await bounded(.seconds(10)) {
          _ = try await manager.execute(userSQL: Self.sleepSQL, policy: policy)
        }
      }
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })

      let events = await sessionLostEvents(manager) {
        let status = await manager.runningStatementStatus()
        #expect(status.inFlight)
        let start = Date()
        let outcome = await manager.cancelRunningStatement(
          expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
          expectedEpoch: status.epoch)
        #expect(outcome == .cancelled)
        let statement = await running.value
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(isCancelled(statement), "got \(statement)")
        if case .threw(let error) = statement {
          #expect(
            error.localizedDescription.contains(
              "Query cancelled — connection was reset (temp tables, SET, search_path lost)"))
        }
      }
      #expect(events.isEmpty, "unexpected session-lost events: \(events)")
      #expect(
        await eventually { await activeSleepers(pid, observer) == 0 },
        "the server is still running pg_sleep for backend \(pid)")
      #expect(await manager.isConnected)
      let next = try await manager.execute(userSQL: "SELECT 1", policy: open)
      #expect(next.rows.first?.first == .int(1))
      #expect(try await backendPid(manager) != pid)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  @Test(
    "Cancel inside the user's own BEGIN (Protected off) rolls it back and says so",
    .timeLimit(.minutes(1)))
  func cancelRollsBackUserTransaction() async throws {
    let table = "c3_cancel_usertx"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    var pid: String?
    do {
      pid = try await backendPid(manager)
      guard let pid else { return }
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      #expect(await manager.userTxOpen)
      let policy = open
      let running = Task {
        await bounded(.seconds(10)) {
          _ = try await manager.execute(userSQL: Self.sleepSQL, policy: policy)
        }
      }
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })

      let status = await manager.runningStatementStatus()
      #expect(status.userTxOpen)
      let outcome = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      #expect(outcome == .cancelled)
      let statement = await running.value
      #expect(isCancelled(statement), "got \(statement)")
      if case .threw(let error) = statement {
        #expect(error.localizedDescription.contains("Your open transaction was rolled back."))
      }
      #expect(await manager.userTxOpen == false)
      #expect(
        try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
          .rows.first?.first == .int(10))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  @Test("Cancel with nothing running does not reset the session", .timeLimit(.minutes(1)))
  func cancelWithNothingRunning() async throws {
    let table = "c3_cancel_idle"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    do {
      let pid = try await backendPid(manager)
      let status = await manager.runningStatementStatus()
      #expect(!status.inFlight)
      let outcome = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      #expect(outcome == .nothingRunning)
      #expect(try await backendPid(manager) == pid)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A second Cancel with the status read before the first reset is refused (idle to idle)",
    .timeLimit(.minutes(1)))
  func secondCancelAfterResetRefused() async throws {
    let table = "c3_cancel_twice"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    var pid: String?
    do {
      let policy = open
      let firstPid = try await backendPid(manager)
      let first = Task {
        await bounded(.seconds(10)) {
          _ = try await manager.execute(userSQL: Self.sleepSQL, policy: policy)
        }
      }
      #expect(await eventually { await activeSleepers(firstPid, observer) == 1 })
      // Both clicks read the same status before either cancel ran
      let seen = await manager.runningStatementStatus()
      let firstOutcome = await manager.cancelRunningStatement(
        expectedGeneration: seen.generation, expectedUserTxOpen: seen.userTxOpen,
        expectedEpoch: seen.epoch)
      #expect(firstOutcome == .cancelled)
      _ = await first.value

      // A new statement runs on the reopened session
      pid = try await backendPid(manager)
      guard let pid else { return }
      let second = Task {
        await bounded(.seconds(10)) {
          _ = try await manager.execute(userSQL: Self.sleepSQL, policy: policy)
        }
      }
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })
      #expect(await manager.runningStatementStatus().generation == seen.generation)

      let secondOutcome = await manager.cancelRunningStatement(
        expectedGeneration: seen.generation, expectedUserTxOpen: seen.userTxOpen,
        expectedEpoch: seen.epoch)
      #expect(secondOutcome == .nothingRunning)
      #expect(await activeSleepers(pid, observer) == 1)

      let status = await manager.runningStatementStatus()
      _ = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      _ = await second.value
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  // MARK: - Protected pending changes: confirm first

  @Test(
    "Cancel with pending Protected changes asks first; Keep running keeps it, confirm rolls back",
    .timeLimit(.minutes(1)))
  func cancelWithPendingChangesConfirms() async throws {
    let table = "c3_cancel_pending"
    let (manager, observer) = try await setUp(table, protectedMode: true)
    var pid: String?
    do {
      pid = try await backendPid(manager)
      guard let pid else { return }
      let viewModel = NotebookViewModel()
      viewModel.connectionManager = manager
      let caller = viewModel.id
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open, caller: caller)
      #expect(await manager.transactionSnapshot().pending.count == 1)

      let policy = open
      let running = Task {
        await bounded(.seconds(10)) {
          _ = try await manager.execute(userSQL: Self.sleepSQL, policy: policy, caller: caller)
        }
      }
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })

      // Keep running: nothing is cancelled
      var warnings: [QueryCancelWarning] = []
      viewModel.cancelQueryPrompt = { warning in
        warnings.append(warning)
        return false
      }
      #expect(await viewModel.cancelRunningStatement(cancelQueue: false) == false)
      #expect(warnings.first?.title == "Cancelling will roll back 1 pending change")
      #expect(warnings.first?.detail.contains("UPDATE \(table) SET v = 20") == true)
      #expect(await activeSleepers(pid, observer) == 1)
      #expect(await manager.transactionSnapshot().pending.count == 1)

      // Cancel query & discard
      viewModel.cancelQueryPrompt = { _ in true }
      let start = Date()
      #expect(await viewModel.cancelRunningStatement(cancelQueue: false))
      let statement = await running.value
      #expect(Date().timeIntervalSince(start) < 2)
      #expect(isCancelled(statement), "got \(statement)")
      if case .threw(let error) = statement {
        #expect(error.localizedDescription.contains("1 pending change was rolled back"))
      }
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(await eventually { await activeSleepers(pid, observer) == 0 })
      #expect(
        try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
          .rows.first?.first == .int(10))
      #expect(await manager.isConnected)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  // MARK: - ViewModel paths: editor and Run All

  @Test(
    "Editor run: isEditorQueryRunning while it runs; Cancel ends it with the cancel notice",
    .timeLimit(.minutes(1)))
  func editorCancel() async throws {
    let table = "c3_cancel_editor"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    var pid: String?
    do {
      pid = try await backendPid(manager)
      guard let pid else { return }
      let viewModel = NotebookViewModel()
      viewModel.connectionManager = manager
      viewModel.connectionState = .connected
      viewModel.cancelQueryPrompt = { _ in
        Issue.record("no prompt expected")
        return false
      }
      viewModel.queryConfirmationState.pendingQuery = Self.sleepSQL
      let running = Task { await viewModel.executeConfirmedEditorQuery() }
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })
      #expect(viewModel.isEditorQueryRunning)

      let start = Date()
      #expect(await viewModel.cancelRunningStatement(cancelQueue: false))
      await running.value
      #expect(Date().timeIntervalSince(start) < 2)
      #expect(!viewModel.isEditorQueryRunning)
      #expect(viewModel.editorResult?.error?.contains("Query cancelled") == true)
      #expect(await eventually { await activeSleepers(pid, observer) == 0 })
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  @Test(
    "Run All: Cancel stops the running cell on the server and the queued cells",
    .timeLimit(.minutes(1)))
  func runAllCancel() async throws {
    let table = "c3_cancel_run_all"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    var pid: String?
    do {
      pid = try await backendPid(manager)
      guard let pid else { return }
      let viewModel = NotebookViewModel()
      viewModel.connectionManager = manager
      viewModel.connectionState = .connected
      let sleeper = NotebookCell(content: Self.sleepSQL)
      let next = NotebookCell(content: "UPDATE \(table) SET v = 30 WHERE id = 1")
      viewModel.notebook.cells = [sleeper, next]
      viewModel.executionQueue.enqueue(cellId: sleeper.id, query: sleeper.content)
      viewModel.executionQueue.enqueue(cellId: next.id, query: next.content)
      #expect(await viewModel.executionQueue.waitForExecuting(cellId: sleeper.id))
      #expect(await eventually { await activeSleepers(pid, observer) == 1 })

      let start = Date()
      #expect(await viewModel.cancelRunningStatement(cancelQueue: true))
      #expect(await viewModel.executionQueue.waitForTask(cellId: next.id) == .cancelled)
      #expect(
        await eventually {
          viewModel.notebook.cells.first?.result?.error?.contains("Query cancelled") == true
        })
      #expect(Date().timeIntervalSince(start) < 2)
      #expect(await eventually { await activeSleepers(pid, observer) == 0 })
      #expect(viewModel.notebook.cells.last?.result == nil)
      #expect(
        try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
          .rows.first?.first == .int(10))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer, pid: pid)
  }

  // MARK: - statement_timeout is the brake

  @Test(
    "statement_timeout = 1s: pg_sleep(3) fails with statement_timeout / 57014",
    .timeLimit(.minutes(1)))
  func statementTimeoutSurfaces() async throws {
    let table = "c3_statement_timeout"
    let (manager, observer) = try await setUp(table, protectedMode: false, statementTimeout: 1)
    do {
      let start = Date()
      do {
        _ = try await manager.execute(userSQL: "SELECT pg_sleep(3)", policy: open)
        Issue.record("pg_sleep(3) should time out")
      } catch {
        let message = error.localizedDescription
        #expect(message.contains("statement_timeout"), "got \(message)")
        #expect(message.contains("57014"), "got \(message)")
        #expect(message.contains("after 1s"), "got \(message)")
      }
      #expect(Date().timeIntervalSince(start) < 2.5)
      #expect(try await manager.execute(userSQL: "SELECT 1", policy: open).rows.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Resets never look like a lost connection

  @Test("Several resets in a row emit no session-lost event", .timeLimit(.minutes(1)))
  func repeatedResetsAreNotLosses() async throws {
    let table = "c3_repeated_resets"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    do {
      // A plain column read (no function call) over the cap resets the session
      _ = try await observer.executeInternal(
        "INSERT INTO \(table) SELECT g, g FROM generate_series(2, 100000) g")
      var staleEpochs: [UInt64] = []
      let events = try await sessionLostEvents(manager, settle: .seconds(1)) {
        for _ in 0..<5 {
          staleEpochs.append(await manager.connectionEpoch)
          let result = try await manager.execute(
            userSQL: "SELECT * FROM \(table)", policy: open, maxRows: 10)
          #expect(result.sessionReset)
        }
        // A late close callback of an old connection names its own epoch: ignored
        for epoch in staleEpochs { await manager.markSessionLost(epoch: epoch) }
      }
      #expect(events.isEmpty, "unexpected session-lost events: \(events)")
      #expect(await manager.isConnected)
      #expect(try await manager.execute(userSQL: "SELECT 1", policy: open).rows.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }
}
