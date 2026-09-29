// CapResetSharedSessionTests.swift
// Tabs share one actor and one connection. A capped read stops by closing the session only when
// nothing else can lose work:
// - no other gated statement / edit / script (`commitGuard.inFlight == 1`) and no other query
//   waiting in `send(on:)` (catalog, internal, transaction control);
// - the statement calls no function (`SQLStatementClassifier.mayCallFunctions`): closing would
//   abort it on the server and roll back what the function wrote.
// Otherwise the read drains (session kept, result truncated). A script whose connection changed
// between two statements (reconnect, reset, cancel) stops: the rest never runs on the new session.
// Interleavings are forced with the `ScriptCheckpoint` test hook. Against the docker test
// database (TEST_DB_* env, port 5435 in CI/autopilot).

import Foundation
import Testing

@testable import Dblore

/// Lock-protected box shared with the hook
private final class Shared<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?

  func set(_ value: Value) {
    lock.lock()
    stored = value
    lock.unlock()
  }

  var value: Value? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

@Suite("Cap Reset on a Shared Session - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct CapResetSharedSessionTests {
  private static let cap = 100

  private static func config(protectedMode: Bool) -> ConnectionConfig {
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
      statementTimeoutSeconds: 45
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  /// An unprotected observer creates `table (id int PRIMARY KEY, v text)` with 1e5 rows
  /// (row 1 has v = 'a'); `manager` connects with Protected mode off.
  private func setUp(
    _ table: String
  ) async throws -> (manager: DatabaseConnectionManager, observer: DatabaseConnectionManager) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v text)")
    _ = try await observer.executeInternal(
      "INSERT INTO \(table) SELECT g, CASE WHEN g = 1 THEN 'a' ELSE 'v' || g END "
        + "FROM generate_series(1, 100000) g")
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: false))
    return (manager, observer)
  }

  private func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    await manager.setScriptCheckpointHook(nil)
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func rowOne(
    _ table: String, _ observer: DatabaseConnectionManager
  ) async throws
    -> CellValue?
  {
    try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1").rows.first?.first
  }

  /// Poll `condition` every 10 ms for up to 5 s
  private nonisolated static func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  // MARK: - Fix 3: function calls drain, plain column reads reset

  @Test("A plain column read over the cap resets the session", .timeLimit(.minutes(1)))
  func plainReadResets() async throws {
    let table = "cap_plain"
    let (manager, observer) = try await setUp(table)
    do {
      let epoch = await manager.connectionEpoch
      let read = try await manager.execute(
        userSQL: "SELECT * FROM \(table)", policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(read.sessionReset)
      #expect(await manager.connectionEpoch != epoch)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A read calling a function over the cap drains: truncated, session and temp table kept",
    .timeLimit(.minutes(1)))
  func functionReadDrains() async throws {
    let table = "cap_function"
    let (manager, observer) = try await setUp(table)
    do {
      _ = try await manager.execute(userSQL: "CREATE TEMP TABLE cap_tmp (id int)", policy: open)
      let epoch = await manager.connectionEpoch
      let read = try await manager.execute(
        userSQL: "SELECT upper(v) FROM \(table)", policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(!read.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
      let temp = try await manager.execute(userSQL: "SELECT count(*) FROM cap_tmp", policy: open)
      #expect(temp.rows.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A truncated EXPLAIN ANALYZE drains without protocol desync; the next query works",
    .timeLimit(.minutes(1)))
  func truncatedExplainAnalyzeKeepsProtocol() async throws {
    let table = "cap_explain"
    let (manager, observer) = try await setUp(table)
    do {
      let epoch = await manager.connectionEpoch
      let plan = try await manager.execute(
        userSQL: "EXPLAIN ANALYZE SELECT * FROM \(table)", policy: open, maxRows: 1)
      #expect(plan.rows.count == 1)
      #expect(plan.truncated)
      #expect(!plan.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
      let one = try await manager.execute(userSQL: "SELECT 1", policy: open)
      #expect(one.rows.first?.first == .int(1))
      let count = try await manager.execute(
        userSQL: "SELECT count(*)::int FROM \(table)", policy: open)
      #expect(count.rows.first?.first == .int(100_000))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Fix 1: no reset while another caller is in flight

  @Test(
    "Another tab's UPDATE ... RETURNING queued behind a capped read: no reset, the write commits",
    .timeLimit(.minutes(1)))
  func otherCallersWriteBlocksReset() async throws {
    let table = "cap_other_write"
    let (manager, observer) = try await setUp(table)
    let open = open
    let writer = Shared<Task<QueryResult, Error>>()
    do {
      await manager.setScriptCheckpointHook { checkpoint in
        guard checkpoint == .beforeCapReset, writer.value == nil else { return }
        writer.set(
          Task {
            try await manager.execute(
              userSQL: "UPDATE \(table) SET v = 'b' WHERE id = 1 RETURNING id", policy: open,
              caller: UUID())
          })
        // The write is counted and queued on the connection behind the capped read
        let queued = await Self.eventually {
          let inFlight = await manager.commitGuard.inFlight
          let sends = await manager.activeSends
          return inFlight == 2 && sends == 1
        }
        #expect(queued, "the other tab's write never got in flight")
      }
      let epoch = await manager.connectionEpoch
      let read = try await manager.execute(
        userSQL: "SELECT * FROM \(table)", policy: open, maxRows: Self.cap, caller: UUID())
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(!read.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
      let write = try #require(writer.value)
      #expect(try await write.value.affectedRows == 1)
      #expect(try await rowOne(table, observer) == .string("b"))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "An internal query queued behind a capped read: no reset, it answers",
    .timeLimit(.minutes(1)))
  func queuedInternalQueryBlocksReset() async throws {
    let table = "cap_other_internal"
    let (manager, observer) = try await setUp(table)
    let open = open
    let queued = Shared<Task<QueryResult, Error>>()
    do {
      await manager.setScriptCheckpointHook { checkpoint in
        guard checkpoint == .beforeCapReset, queued.value == nil else { return }
        queued.set(Task { try await manager.executeInternal("SELECT 7") })
        let waiting = await Self.eventually { await manager.activeSends == 1 }
        #expect(waiting, "the internal query never reached send(on:)")
      }
      let epoch = await manager.connectionEpoch
      let read = try await manager.execute(
        userSQL: "SELECT * FROM \(table)", policy: open, maxRows: Self.cap)
      #expect(read.truncated)
      #expect(!read.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
      let seven = try #require(queued.value)
      #expect(try await seven.value.rows.first?.first == .int(7))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Fix 2: a script stops when its connection changed

  @Test(
    "Reconnect between two statements: the rest is not run; the autocommitted first write stays",
    .timeLimit(.minutes(1)))
  func scriptStopsAfterReconnect() async throws {
    let table = "cap_script_autocommit"
    let (manager, observer) = try await setUp(table)
    let config = Self.config(protectedMode: false)
    let tab = UUID()
    do {
      await manager.setScriptCheckpointHook { checkpoint in
        guard checkpoint == .beforeStatement(caller: tab, index: 1) else { return }
        try? await manager.connect(config: config)
      }
      do {
        _ = try await manager.executeDetailed(
          userSQL: "UPDATE \(table) SET v = 'b' WHERE id = 1; UPDATE \(table) SET v = 'c' "
            + "WHERE id = 1",
          policy: open, caller: tab)
        Issue.record("the script must stop after the reconnect")
      } catch DatabaseError.sessionChanged(let skipped) {
        #expect(skipped == 1)
      }
      // The first UPDATE autocommitted before the reconnect; the second never ran
      #expect(try await rowOne(table, observer) == .string("b"))
      #expect(await manager.isConnected)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Reconnect inside the user's BEGIN: the server rolled it back, the rest is not run",
    .timeLimit(.minutes(1)))
  func scriptInUserTransactionStopsAfterReconnect() async throws {
    let table = "cap_script_usertx"
    let (manager, observer) = try await setUp(table)
    let config = Self.config(protectedMode: false)
    let tab = UUID()
    do {
      await manager.setScriptCheckpointHook { checkpoint in
        guard checkpoint == .beforeStatement(caller: tab, index: 2) else { return }
        try? await manager.connect(config: config)
      }
      do {
        _ = try await manager.executeDetailed(
          userSQL: "BEGIN; UPDATE \(table) SET v = 'b' WHERE id = 1; UPDATE \(table) SET v = 'c' "
            + "WHERE id = 1; COMMIT",
          policy: open, caller: tab)
        Issue.record("the script must stop after the reconnect")
      } catch DatabaseError.sessionChanged(let skipped) {
        #expect(skipped == 2)
      }
      // Closing the old session rolled back the BEGIN block; nothing ran outside it
      #expect(try await rowOne(table, observer) == .string("a"))
      #expect(await manager.userTxOpen == false)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A script expected on another connection epoch is refused before anything is sent",
    .timeLimit(.minutes(1)))
  func staleExpectedEpochRefused() async throws {
    let table = "cap_expected_epoch"
    let (manager, observer) = try await setUp(table)
    do {
      let stale = await manager.connectionEpoch &- 1
      do {
        _ = try await manager.execute(
          userSQL: "UPDATE \(table) SET v = 'b' WHERE id = 1", policy: open, expectedEpoch: stale)
        Issue.record("the statement must be refused")
      } catch DatabaseError.sessionChanged(let skipped) {
        #expect(skipped == 1)
      }
      do {
        _ = try await manager.executeDetailed(
          userSQL: "UPDATE \(table) SET v = 'c' WHERE id = 1; UPDATE \(table) SET v = 'd' "
            + "WHERE id = 1",
          policy: open, expectedEpoch: stale)
        Issue.record("the script must be refused")
      } catch DatabaseError.sessionChanged(let skipped) {
        #expect(skipped == 2)
      }
      #expect(try await rowOne(table, observer) == .string("a"))
      // The current epoch runs
      let current = await manager.connectionEpoch
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 'e' WHERE id = 1", policy: open, expectedEpoch: current)
      #expect(try await rowOne(table, observer) == .string("e"))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }
}
