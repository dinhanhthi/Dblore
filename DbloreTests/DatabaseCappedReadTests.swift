// DatabaseCappedReadTests.swift
// C2 capped reader (C1 spike assertions kept) through the real actor API: the SQL is sent as
// written and the reader stops after `maxRows` rows by its own counter.
// - App transaction pending: break (PostgresNIO drains), the transaction and its pending changes
//   survive.
// - No app transaction, a plain column read (no function call, see CapResetSharedSessionTests):
//   the connection is closed and reopened with the same config (brakes re-applied); temp tables
//   / SET are lost and reported; the remaining statements are not run.
// - The user's own transaction is open (Protected off): drained like the app transaction, so
//   uncommitted work is never discarded by the cap (only Cancel rolls it back).
// - Cursor inside a transaction (app or user): a plain read (SELECT / VALUES / TABLE / WITH, no
//   function call) is sent as DECLARE / FETCH cap+1 / CLOSE, so the server stops at the cap
//   instead of draining; SHOW, EXPLAIN, function-calling and row-locking (FOR UPDATE / SHARE)
//   reads still drain.
// - Write routes (RETURNING) never close mid-stream: rows past the cap are counted, not kept.
// Against the docker test database (TEST_DB_* env, port 5435 in CI/autopilot).

import Foundation
import Testing

@testable import Dblore

/// Lock-protected box shared with a listening task
private final class Box<Value: Sendable>: @unchecked Sendable {
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

@Suite("Capped Read - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct DatabaseCappedReadTests {
  private static let largeRead = "SELECT * FROM generate_series(1, 1000000)"
  /// A plain column read of a filled table: no function call, so it can be reset
  private static func plainRead(_ table: String) -> String { "SELECT * FROM \(table)" }
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

  private func value(_ result: QueryResult) -> CellValue? {
    result.rows.first?.first
  }

  /// Connects an unprotected observer that creates `table (id int PRIMARY KEY, v int)` with
  /// row (1, 10) (and rows 2...100000 when `filled`), and `manager` with the given Protected mode.
  private func setUp(
    _ table: String, protectedMode: Bool, filled: Bool = false
  ) async throws -> (manager: DatabaseConnectionManager, observer: DatabaseConnectionManager) {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")
    if filled {
      _ = try await observer.executeInternal(
        "INSERT INTO \(table) SELECT g, g FROM generate_series(2, 100000) g")
    }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: protectedMode))
    return (manager, observer)
  }

  private func tearDown(
    _ table: String, _ manager: DatabaseConnectionManager, _ observer: DatabaseConnectionManager
  ) async {
    // A pending UPDATE holds a row lock: end it (disconnect rolls back) before DROP TABLE
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func isAborted(_ manager: DatabaseConnectionManager) async -> Bool {
    if case .aborted = await manager.transactionSnapshot() { return true }
    return false
  }

  /// Open server-side cursors of the session. `count(` is a function call, so this probe drains
  /// instead of opening a cursor of its own (and does not bump `cursorReadCount`). Its own
  /// unnamed extended-protocol portal is listed too, so it is excluded.
  private func openCursors(_ manager: DatabaseConnectionManager) async throws -> CellValue? {
    let open = open
    let cursors = try await manager.execute(
      userSQL: "SELECT count(*)::int FROM pg_cursors WHERE name <> ''", policy: open)
    return value(cursors)
  }

  /// The first value of `events` within `duration`, or nil
  private func first<Event: Sendable>(
    _ events: AsyncStream<Event>, within duration: Duration
  ) async -> Event? {
    let box = Box<Event>()
    _ = await bounded(duration) {
      for await event in events {
        box.set(event)
        return
      }
    }
    return box.value
  }

  // MARK: - App transaction pending: drain, transaction kept (C1 (a))

  @Test(
    "Inside the app transaction a 1e6-row read stops at the cap; tx and pending UPDATE survive",
    .timeLimit(.minutes(1)))
  func appTransactionTruncationKeepsTransaction() async throws {
    let table = "c2_apptx"
    let (manager, observer) = try await setUp(table, protectedMode: true)
    let open = open
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let epoch = await manager.connectionEpoch

      let read = try await manager.execute(
        userSQL: Self.largeRead, policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.rowCount == Self.cap)
      #expect(read.truncated)
      #expect(read.wasLimited)
      #expect(!read.sessionReset)
      #expect(await manager.connectionEpoch == epoch)

      // Next query waits for the drain, then answers on the same session and transaction
      let one = try await manager.execute(userSQL: "SELECT 1", policy: open)
      #expect(value(one) == .int(1))
      let inside = try await manager.execute(
        userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: open)
      #expect(value(inside) == .int(20))
      let outside = try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
      #expect(value(outside) == .int(10))
      let status = await manager.transactionStatus()
      guard case .appTx(let pending) = status.state else {
        Issue.record("app transaction lost after the capped read: \(status.state)")
        throw DatabaseError.notConnected
      }
      #expect(pending.count == 1)

      try await manager.commitAppTransaction(expectedGeneration: status.generation)
      let committed = try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
      #expect(value(committed) == .int(20))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Concurrent close does not deadlock (C1 (b))

  @Test(
    "Disconnect while another task runs a slow capped read returns < 2s; reader fails; reconnect works",
    .timeLimit(.minutes(1)))
  func concurrentCloseDoesNotDeadlock() async throws {
    let manager = DatabaseConnectionManager()
    let config = Self.config(protectedMode: false)
    try await manager.connect(config: config)
    let open = open
    // ~1 ms per row: still streaming when the disconnect arrives
    let reader = Task {
      try await manager.execute(
        userSQL: "SELECT g, pg_sleep(0.001) FROM generate_series(1, 100000) g", policy: open,
        maxRows: 1_000_000)
    }
    try await Task.sleep(for: .milliseconds(500))

    let closed = await bounded(.seconds(2)) { await manager.disconnect() }
    guard case .returned = closed else {
      Issue.record("disconnect did not return within 2s: \(closed)")
      reader.cancel()
      return
    }
    let readerOutcome = await bounded(.seconds(5)) { _ = try await reader.value }
    #expect(readerOutcome.didThrow, "reader must fail, not hang or finish: \(readerOutcome)")

    let reconnected = await bounded(.seconds(10)) {
      try await manager.connect(config: config)
      let one = try await manager.execute(userSQL: "SELECT 1", policy: open)
      guard case .int(1) = one.rows.first?.first else {
        throw DatabaseError.queryFailed("SELECT 1 returned \(one.rows)", 0)
      }
    }
    #expect({ if case .returned = reconnected { true } else { false } }(), "got \(reconnected)")
    await manager.disconnect()
  }

  // MARK: - No app transaction: session reset

  @Test(
    "Without a transaction a 1e6-row read stops at the cap and resets the session",
    .timeLimit(.minutes(1)))
  func noTransactionTruncationResetsSession() async throws {
    let table = "c2_reset"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      _ = try await manager.execute(userSQL: "CREATE TEMP TABLE c2_tmp (id int)", policy: open)
      let epoch = await manager.connectionEpoch
      let resets = manager.sessionResets
      let losses = manager.sessionEvents

      let read = try await manager.execute(
        userSQL: Self.plainRead(table), policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(read.sessionReset)
      #expect(read.skippedStatements.isEmpty)
      #expect(await manager.isConnected)
      #expect(await manager.connectionEpoch != epoch)
      let reset = await first(resets, within: .seconds(1))
      #expect(reset?.userTxRolledBack == false)
      #expect(await first(losses, within: .milliseconds(300)) == nil, "no connection-lost event")

      let one = try await manager.execute(userSQL: "SELECT 1", policy: open)
      #expect(value(one) == .int(1))
      await #expect(throws: DatabaseError.self) {
        _ = try await manager.execute(userSQL: "SELECT * FROM c2_tmp", policy: open)
      }
      let timeout = try await manager.execute(userSQL: "SHOW statement_timeout", policy: open)
      #expect(value(timeout) == .string("45s"))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A reset stops the remaining statements of the script and lists them as not run",
    .timeLimit(.minutes(1)))
  func resetStopsRemainingStatements() async throws {
    let table = "c2_multi"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      let script = "\(Self.plainRead(table)); UPDATE \(table) SET v = 99 WHERE id = 1"
      let detailed = try await manager.executeDetailed(
        userSQL: script, policy: open, maxRows: Self.cap)
      #expect(detailed.results.count == 1)
      let first = detailed.results.first?.result
      #expect(first?.rows.count == Self.cap)
      #expect(first?.sessionReset == true)
      #expect(first?.skippedStatements.count == 1)
      #expect(first?.skippedStatements.first?.contains("UPDATE \(table)") == true)
      let row = try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
      #expect(value(row) == .int(10))

      // The combined result keeps the flags
      let combined = try await manager.execute(userSQL: script, policy: open, maxRows: Self.cap)
      #expect(combined.truncated)
      #expect(combined.sessionReset)
      #expect(combined.skippedStatements.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Inside the user's own transaction (Protected off) a capped read drains; the tx is kept",
    .timeLimit(.minutes(1)))
  func cappedReadInUserTransactionDrains() async throws {
    let table = "c2_usertx"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let read = try await manager.execute(
        userSQL: Self.plainRead(table), policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(!read.sessionReset)
      #expect(await manager.userTxOpen)
      let mine = try await manager.execute(
        userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: open)
      #expect(value(mine) == .int(20))
      let outside = try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
      #expect(value(outside) == .int(10))
      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
      #expect(await manager.userTxOpen == false)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - The cap does not depend on the LIMIT wrapper

  @Test("A WITH read of 1e6 rows stops at the cap", .timeLimit(.minutes(1)))
  func withQueryIsCapped() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: false))
    do {
      let read = try await manager.execute(
        userSQL: "WITH x AS (SELECT generate_series(1, 1000000) g) SELECT * FROM x", policy: open,
        maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
    } catch {
      Issue.record(error)
    }
    await manager.disconnect()
  }

  @Test("Results within the cap are not truncated and keep the session", .timeLimit(.minutes(1)))
  func resultsWithinCapAreNotTruncated() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: false))
    do {
      let epoch = await manager.connectionEpoch
      let values = try await manager.execute(
        userSQL: "VALUES (1), (2)", policy: open, maxRows: Self.cap)
      #expect(values.rows.count == 2)
      #expect(!values.truncated)
      #expect(!values.sessionReset)
      let exact = try await manager.execute(
        userSQL: "SELECT * FROM generate_series(1, \(Self.cap))", policy: open, maxRows: Self.cap)
      #expect(exact.rows.count == Self.cap)
      #expect(!exact.truncated)
      #expect(!exact.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
    } catch {
      Issue.record(error)
    }
    await manager.disconnect()
  }

  // MARK: - Write routes never close mid-stream

  @Test(
    "INSERT ... RETURNING past the cap keeps the session; all rows counted and committed",
    .timeLimit(.minutes(1)))
  func returningPastCapIsNotReset() async throws {
    let table = "c2_returning"
    let (manager, observer) = try await setUp(table, protectedMode: false)
    let open = open
    do {
      let epoch = await manager.connectionEpoch
      let insert = try await manager.execute(
        userSQL: "INSERT INTO \(table) SELECT g, g FROM generate_series(2, 301) g RETURNING id",
        policy: open, maxRows: Self.cap)
      #expect(insert.rows.count == Self.cap)
      #expect(insert.truncated)
      #expect(!insert.sessionReset)
      #expect(insert.affectedRows == 300)
      #expect(await manager.connectionEpoch == epoch)
      let count = try await observer.executeInternal("SELECT count(*)::int FROM \(table)")
      #expect(value(count) == .int(301))
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  // MARK: - Cursor inside a transaction

  /// A plain read of a filled table with an order: the cursor must stop it at the cap
  private static func orderedRead(_ table: String) -> String {
    "SELECT * FROM \(table) ORDER BY id"
  }

  @Test(
    "Inside the app transaction a plain read goes through a cursor: capped, tx and UPDATE kept",
    .timeLimit(.minutes(1)))
  func appTransactionReadUsesCursor() async throws {
    let table = "c2_cursor_apptx"
    let (manager, observer) = try await setUp(table, protectedMode: true, filled: true)
    let open = open
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      let epoch = await manager.connectionEpoch

      let read = try await manager.execute(
        userSQL: Self.orderedRead(table), policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(read.wasLimited)
      #expect(!read.sessionReset)
      #expect(await manager.connectionEpoch == epoch)
      // Checked first: any later plain read in the transaction goes through a cursor too
      #expect(await manager.cursorReadCount == 1)

      let inside = try await manager.execute(
        userSQL: "SELECT v FROM \(table) WHERE id = 1", policy: open)
      #expect(value(inside) == .int(20))
      let outside = try await observer.executeInternal("SELECT v FROM \(table) WHERE id = 1")
      #expect(value(outside) == .int(10))
      #expect(try await openCursors(manager) == .int(0))
      let status = await manager.transactionStatus()
      guard case .appTx(let pending) = status.state else {
        Issue.record("app transaction lost after the cursor read: \(status.state)")
        throw DatabaseError.notConnected
      }
      #expect(pending.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Inside the user's own transaction a plain read goes through a cursor; the tx is kept",
    .timeLimit(.minutes(1)))
  func userTransactionReadUsesCursor() async throws {
    let table = "c2_cursor_usertx"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      let read = try await manager.execute(
        userSQL: Self.orderedRead(table), policy: open, maxRows: Self.cap)
      #expect(read.rows.count == Self.cap)
      #expect(read.truncated)
      #expect(!read.sessionReset)
      #expect(await manager.cursorReadCount == 1)
      #expect(await manager.userTxOpen)
      #expect(try await openCursors(manager) == .int(0))
      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
      #expect(await manager.userTxOpen == false)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "An error in a cursor read points at the user's SQL and aborts the app transaction",
    .timeLimit(.minutes(1)))
  func cursorReadErrorAbortsTransaction() async throws {
    let table = "c2_cursor_error"
    let (manager, observer) = try await setUp(table, protectedMode: true, filled: true)
    let open = open
    do {
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 20 WHERE id = 1", policy: open)
      do {
        _ = try await manager.execute(
          userSQL: "SELECT nosuchcol FROM \(table)", policy: open, maxRows: Self.cap)
        Issue.record("expected DatabaseError.queryFailed")
      } catch DatabaseError.queryFailed(let message, _) {
        // The server position is relative to the DECLARE text: it must still name the column
        #expect(message.contains("Near: \"nosuchcol\""), "got \(message)")
      }
      #expect(await isAborted(manager))
      #expect(await manager.transactionSnapshot().pending.count == 1)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "A cursor read keeps the column origins of the plain read (cell edit inside a tx)",
    .timeLimit(.minutes(1)))
  func cursorReadKeepsColumnOrigins() async throws {
    let table = "c2_cursor_origin"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      // Outside a transaction: the plain capped read (session reset path)
      let plain = try await manager.execute(
        userSQL: Self.orderedRead(table), policy: open, maxRows: Self.cap)
      #expect(plain.sessionReset)

      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      let cursor = try await manager.execute(
        userSQL: Self.orderedRead(table), policy: open, maxRows: Self.cap)
      #expect(await manager.cursorReadCount == 1)
      #expect(cursor.columns.map(\.name) == ["id", "v"])
      // Non-nil and non-zero, so the comparison below is not vacuous
      #expect(cursor.columns.allSatisfy { $0.origin?.tableID != TableRef.postgresql(oid: 0) })
      #expect(cursor.columns.allSatisfy { ($0.origin?.columnOrdinal ?? 0) != 0 })
      #expect(cursor.columns.map(\.origin) == plain.columns.map(\.origin))
      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }

  @Test(
    "Inside a transaction SHOW, EXPLAIN and function-calling reads do not use the cursor",
    .timeLimit(.minutes(1)))
  func nonCursorReadsInsideTransaction() async throws {
    let table = "c2_cursor_skip"
    let (manager, observer) = try await setUp(table, protectedMode: false, filled: true)
    let open = open
    do {
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      let show = try await manager.execute(
        userSQL: "SHOW statement_timeout", policy: open, maxRows: Self.cap)
      #expect(show.rows.count == 1)
      #expect(value(show) == .string("45s"))
      let explain = try await manager.execute(
        userSQL: "EXPLAIN SELECT * FROM \(table)", policy: open, maxRows: Self.cap)
      #expect(explain.rows.count > 0)
      // A function call keeps draining (its side effects run in full)
      let series = try await manager.execute(
        userSQL: Self.largeRead, policy: open, maxRows: Self.cap)
      #expect(series.rows.count == Self.cap)
      #expect(series.truncated)
      #expect(!series.sessionReset)
      // A row lock drains: a cursor would lock only the rows it fetched
      for lock in ["FOR UPDATE", "FOR SHARE"] {
        let locked = try await manager.execute(
          userSQL: "SELECT * FROM \(table) \(lock)", policy: open, maxRows: Self.cap)
        #expect(locked.rows.count == Self.cap)
        #expect(locked.truncated)
        #expect(!locked.sessionReset)
      }
      #expect(await manager.cursorReadCount == 0)
      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
      #expect(await manager.userTxOpen == false)
    } catch {
      Issue.record(error)
    }
    await tearDown(table, manager, observer)
  }
}
