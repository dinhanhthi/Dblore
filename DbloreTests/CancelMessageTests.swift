// CancelMessageTests.swift
// The cancel message and record depend on the cancel strategy: an interrupt keeps the session
// (MySQL KILL QUERY, MongoDB killOp, SQLite, DuckDB) and says only what it rolled back, or that
// the connection was kept when nothing was. Only PostgreSQL (reconnect) says the connection was
// reset. Fake sessions, no server.

import Foundation
import Testing

@testable import Dblore

@Suite("Cancel Message")
struct CancelMessageTests {
  private static let resetText =
    "Query cancelled — connection was reset (temp tables, SET, search_path lost)."

  @Test(
    "interruptKeepsTransaction is true only for MySQL and MongoDB",
    arguments: DatabaseType.allCases)
  func interruptKeepsTransactionPerEngine(type: DatabaseType) {
    #expect(type.interruptKeepsTransaction == (type == .mysql || type == .mongodb))
  }

  @Test("A kept connection says so and nothing else")
  func keptMessage() {
    let error = DatabaseError.queryCancelled(
      pendingCount: 0, userTxRolledBack: false, connectionKept: true)
    #expect(error.localizedDescription == "Query cancelled. The connection was kept.")
  }

  @Test("An interrupt that rolled back says what, never that the connection was reset")
  func interruptRollbackMessage() {
    let error = DatabaseError.queryCancelled(
      pendingCount: 1, userTxRolledBack: true, connectionKept: true)
    #expect(
      error.localizedDescription
        == "Query cancelled. 1 pending change was rolled back. "
        + "Your open transaction was rolled back.")
  }

  @Test("Without connectionKept the reset text is unchanged")
  func resetMessageUnchanged() {
    #expect(
      DatabaseError.queryCancelled(pendingCount: 0, userTxRolledBack: false)
        .localizedDescription == Self.resetText)
    #expect(
      DatabaseError.queryCancelled(pendingCount: 2, userTxRolledBack: true)
        .localizedDescription
        == Self.resetText + " 2 pending changes were rolled back. "
        + "Your open transaction was rolled back.")
  }

  /// Only engines with transactions: without them (MongoDB) Protected mode never holds a
  /// pending change, and the gate refuses the write this test stages.
  @Test(
    "Cancel with one pending Protected change builds the engine's record",
    .timeLimit(.minutes(1)),
    arguments: DatabaseType.allCases.filter { $0.capabilities.supportsTransactions })
  func recordPerEngine(type: DatabaseType) async throws {
    let strategy = type.capabilities.cancelStrategy
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: strategy), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    // In-memory and read-only: no file grant for SQLite / DuckDB
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    #expect(await connection.transactionSnapshot().pending.count == 1)

    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: protected)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    // An interrupt that keeps the transaction discards nothing: no rollback warning first
    let keeps = strategy == .interrupt && type.interruptKeepsTransaction
    #expect(status.keepsTransaction == keeps)
    let warning = QueryCancelWarning.make(
      state: status.state, userTxOpen: status.userTxOpen,
      keepsTransaction: status.keepsTransaction, interrupts: status.interrupts,
      interruptRollsBack: status.interruptRollsBack)
    #expect((warning == nil) == keeps)
    // DuckDB's interrupt always rolls back: the warning is definite
    let aborts = strategy == .interrupt && type.interruptAbortsTransaction
    #expect(status.interruptRollsBack == aborts)
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let interrupts = strategy == .interrupt
    // The fake's close does not end its slow read: end it as the server would
    if !interrupts { await session.interrupt() }
    let error = await #expect(throws: DatabaseError.self) { try await running.value }

    let generation = await connection.batchCancellationGeneration
    // The fake cannot tell whether the transaction survived (nil): the record and the state stay
    // as built, except on DuckDB, whose interrupt always aborts it: rolled back, state cleared
    let expected = QueryCancelRecord(
      epoch: status.epoch, pendingCount: keeps ? 0 : 1, userTxRolledBack: false,
      interruptGeneration: interrupts ? generation : nil, connectionKept: interrupts,
      reconciled: aborts)
    #expect(await connection.lastCancel == expected)
    // A reconnect starts idle too
    #expect(await connection.transactionSnapshot().isIdle == (aborts || !interrupts))
    let message = error?.localizedDescription ?? ""
    #expect(message == expected.error.localizedDescription)
    if keeps {
      #expect(message == "Query cancelled. The connection was kept.")
    } else if interrupts {
      #expect(message == "Query cancelled. 1 pending change was rolled back.")
    } else {
      #expect(message == Self.resetText + " 1 pending change was rolled back.")
    }
    await connection.disconnect()
  }

  /// One cancel stops two statements (two tabs inside one transaction): both ask the session
  /// while the transaction is still open. The first one clears it; the second must report the
  /// same rollback, not overwrite it with "nothing was rolled back".
  @Test("Two statements stopped by one cancel report the same rollback", .timeLimit(.minutes(1)))
  func twoStoppedStatementsShareTheRecord() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    // The session answers "rolled back" once both stopped statements asked
    let arrivals = Arrivals(expected: 2)
    session.reportAfterInterrupt {
      await arrivals.arrive()
      return false
    }
    let first = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: protected)
    }
    let second = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(31)", policy: protected)
    }
    while session.slowQueryCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)

    let rolledBack = "Query cancelled. 1 pending change was rolled back."
    for running in [first, second] {
      let error = await #expect(throws: DatabaseError.self) { try await running.value }
      #expect(error?.localizedDescription == rolledBack)
    }
    #expect(await connection.lastCancel?.pendingCount == 1)
    #expect(await connection.transactionSnapshot().isIdle)
    await connection.disconnect()
  }

  /// DuckDB's interrupt aborts the user's transaction at once, and a COMMIT on it answers
  /// success. Before the stopped statement unwinds, another tab's COMMIT must not be sent.
  @Test("DuckDB: a COMMIT before the stopped statement ends is refused", .timeLimit(.minutes(1)))
  func duckDBCommitAfterCancelRefused() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    // The stopped statement keeps waiting: its catch has not run yet
    session.holdSlowReadsOnInterrupt()
    try await cancel(on: connection)

    await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: "COMMIT", policy: self.open, caller: UUID())
    }
    #expect(!session.statements.contains("COMMIT"))
    #expect(await connection.userTxOpen == false)

    session.releaseSlowReads()
    let error = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(
      error?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    await connection.disconnect()
  }

  /// Two statements stopped by one cancel (the second one was another send in flight): the
  /// aborted transaction is still rolled back, once
  @Test("DuckDB: one cancel stopping two statements sends ROLLBACK once", .timeLimit(.minutes(1)))
  func duckDBRollbackOnceWithAnotherSend() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    let first = Task { try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open) }
    let second = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(31)", policy: open, caller: UUID())
    }
    while session.slowQueryCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
    try await cancel(on: connection)

    for running in [first, second] {
      let error = await #expect(throws: DatabaseError.self) { try await running.value }
      #expect(
        error?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    }
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(await connection.userTxOpen == false)
    await connection.disconnect()
  }

  /// Protected mode: the owner's next write, sent before the stopped statement unwinds, must
  /// not run in autocommit once the owed ROLLBACK ended the app transaction it was meant for
  @Test(
    "DuckDB: a write after the cancel never runs outside the app transaction",
    .timeLimit(.minutes(1)))
  func duckDBWriteAfterCancelNotAutocommitted() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: protected)
    }
    await session.waitUntilQueryStarted()
    session.holdSlowReadsOnInterrupt()
    try await cancel(on: connection)

    await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: protected)
    }
    #expect(!session.statements.contains("UPDATE t SET a = 2"))
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(await connection.transactionSnapshot().isIdle)
    session.releaseSlowReads()
    _ = try? await running.value
    await connection.disconnect()
  }

  /// Tab B's COMMIT was already sent and waits behind tab A's statement when A is cancelled:
  /// the interrupt aborts the transaction first, so the COMMIT's success committed nothing
  @Test(
    "DuckDB: a COMMIT in flight at the cancel is not reported committed", .timeLimit(.minutes(1)))
  func duckDBCommitInFlightNotCommitted() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    let rewind = try await RewindProbe.make(on: connection)
    defer { rewind.removeFiles() }
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    session.holdSlowReadsOnInterrupt()
    session.holdNextCommand(containing: "COMMIT")
    let commit = Task {
      try await connection.execute(userSQL: "COMMIT", policy: self.open, caller: UUID())
    }
    while session.heldCommandCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
    try await cancel(on: connection)

    session.releaseHeldCommands()
    let error = await #expect(throws: DatabaseError.self) { try await commit.value }
    #expect(
      error?.localizedDescription
        == DatabaseConnectionManager.commitAfterInterruptError.localizedDescription)
    #expect(await connection.userTxOpen == false)
    #expect(try await rewind.state() == .discarded)

    session.releaseSlowReads()
    let stopped = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(
      stopped?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    await connection.disconnect()
  }

  /// SQLite keeps the transaction when a read is interrupted. A COMMIT queued behind the read
  /// ends it, so the session's autocommit answer says nothing about the interrupt
  @Test(
    "SQLite: a read stopped while a COMMIT is in flight discards nothing", .timeLimit(.minutes(1)))
  func sqliteReadStoppedDuringCommitKeepsEntries() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: false,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    let rewind = try await RewindProbe.make(on: connection)
    defer { rewind.removeFiles() }
    // Autocommit is back on: the COMMIT may have ended the transaction, not the interrupt
    session.reportAfterInterrupt { false }
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    session.holdNextCommand(containing: "COMMIT")
    let commit = Task {
      try await connection.execute(userSQL: "COMMIT", policy: self.open, caller: UUID())
    }
    while session.heldCommandCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
    try await cancel(on: connection)

    let stopped = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(stopped?.localizedDescription == "Query cancelled. The connection was kept.")
    #expect(try await rewind.state() == .pending)
    session.releaseHeldCommands()
    _ = try await commit.value
    #expect(try await rewind.state() == .committed)
    #expect(await connection.userTxOpen == false)
    await connection.disconnect()
  }

  /// Only a statement meant for the aborted transaction is refused: an app catalog read goes
  /// through after the owed ROLLBACK, and the user's own ROLLBACK is that ROLLBACK
  @Test(
    "DuckDB: after the cancel a catalog read and a typed ROLLBACK succeed", .timeLimit(.minutes(1)))
  func duckDBReadAndRollbackAfterCancel() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    session.holdSlowReadsOnInterrupt()
    for round in 1...2 {
      if round == 2 { _ = try await connection.execute(userSQL: "BEGIN", policy: open) }
      let running = Task {
        try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
      }
      while session.slowQueryCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
      try await cancel(on: connection)
      if round == 1 {
        _ = try await connection.fetchAllColumns()
      } else {
        _ = try await connection.execute(userSQL: "ROLLBACK", policy: open, caller: UUID())
      }
      #expect(session.statements.filter { $0 == "ROLLBACK" }.count == round)
      #expect(await connection.userTxOpen == false)
      session.releaseSlowReads()
      _ = try? await running.value
    }
    await connection.disconnect()
  }

  /// Another tab's COMMIT arrives while the cancel is still starting, after the cancel
  /// generation moved: it must already find the ROLLBACK owed, or it is sent and answers success
  @Test("DuckDB: a COMMIT arriving while the cancel starts is refused", .timeLimit(.minutes(1)))
  func duckDBCommitDuringCancelRefused() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    let rewind = try await RewindProbe.make(on: connection)
    defer { rewind.removeFiles() }
    session.slowReads(containing: "pg_sleep")
    session.holdSlowReadsOnInterrupt()
    session.holdNextCommand(containing: "COMMIT")
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let policy = open
    let commit = TaskBox()
    await connection.setScriptCheckpointHook { checkpoint in
      guard checkpoint == .cancelling else { return }
      commit.start {
        _ = try await connection.execute(userSQL: "COMMIT", policy: policy, caller: UUID())
      }
      // Sent (held behind the running statement) or refused
      while session.heldCommandCount < 1, !commit.finished {
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
    try await cancel(on: connection)
    await connection.setScriptCheckpointHook(nil)

    session.releaseHeldCommands()
    let task = try #require(commit.task)
    let error = await #expect(throws: DatabaseError.self) { try await task.value }
    #expect(
      error?.localizedDescription
        == DatabaseConnectionManager.commitAfterInterruptError.localizedDescription)
    #expect(!session.statements.contains("COMMIT"))
    #expect(await connection.userTxOpen == false)
    #expect(try await rewind.state() == .discarded)

    session.releaseSlowReads()
    let stopped = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(
      stopped?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    await connection.disconnect()
  }

  /// A statement admitted inside the user's transaction before the cancel, whose send comes
  /// after another caller already sent the owed ROLLBACK: never sent in autocommit. One
  /// admitted after the ROLLBACK is sent as usual
  @Test(
    "DuckDB: a statement admitted before the cancel is not sent after its ROLLBACK",
    .timeLimit(.minutes(1)))
  func duckDBStatementAdmittedBeforeCancelRefused() async throws {
    let (connection, session) = try await duckDBInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    session.holdSlowReadsOnInterrupt()
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let tab = UUID()
    let pause = Pause()
    await connection.setScriptCheckpointHook { checkpoint in
      guard checkpoint == .beforeSend(caller: tab, index: 0) else { return }
      await pause.pause()
    }
    let admitted = Task {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: open, caller: tab)
    }
    await pause.waitUntilPaused()
    try await cancel(on: connection)
    // Another caller sends the owed ROLLBACK first
    _ = try await connection.fetchAllColumns()
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    await pause.release()

    await #expect(throws: DatabaseError.self) { try await admitted.value }
    #expect(!session.statements.contains("UPDATE t SET a = 2"))
    await connection.setScriptCheckpointHook(nil)
    _ = try await connection.execute(userSQL: "UPDATE t SET a = 3", policy: open, caller: UUID())
    #expect(session.statements.contains("UPDATE t SET a = 3"))

    session.releaseSlowReads()
    _ = try? await running.value
    await connection.disconnect()
  }

  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  /// A fake DuckDB connection (interrupt cancel, Protected mode off) inside the user's BEGIN
  private func duckDBInUserTransaction() async throws -> (
    DatabaseConnectionManager, FakeDatabaseSession
  ) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: false,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    #expect(await connection.userTxOpen)
    return (connection, session)
  }

  /// Confirms the cancel with the status read now
  private func cancel(on connection: DatabaseConnectionManager) async throws {
    let status = await connection.runningStatementStatus()
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
  }
}

/// Holds every caller of `arrive` until `expected` callers arrived
private actor Arrivals {
  private let expected: Int
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(expected: Int) { self.expected = expected }

  func arrive() async {
    if waiting.count + 1 >= expected {
      for waiter in waiting { waiter.resume() }
      waiting = []
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }
}

/// A task started from a test hook, kept to be awaited later
private final class TaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Task<Void, Error>?
  private var done = false

  func start(_ body: @escaping @Sendable () async throws -> Void) {
    let task = Task {
      defer { self.lock.withLock { self.done = true } }
      try await body()
    }
    lock.withLock { stored = task }
  }

  var task: Task<Void, Error>? { lock.withLock { stored } }
  var finished: Bool { lock.withLock { done } }
}

/// Holds the caller of `pause` until `release`; `waitUntilPaused` returns once it arrived
private actor Pause {
  private var paused = false
  private var held: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?

  func pause() async {
    paused = true
    arrival?.resume()
    arrival = nil
    await withCheckedContinuation { held = $0 }
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { arrival = $0 }
  }

  func release() {
    held?.resume()
    held = nil
  }
}

/// One pending Data Rewind entry in the connection's scope, in a temporary store
private struct RewindProbe {
  let url: URL
  let store: RewindStore
  let recorder: RewindRecorder

  static func make(on connection: DatabaseConnectionManager) async throws -> RewindProbe {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-cancel-rewind-\(UUID().uuidString).sqlite")
    let store = try RewindStore(url: url)
    let recorder = RewindRecorder(store: store)
    await connection.setRewindRecorder(recorder)
    let entry = RewindEntry(
      id: 0, connectionKey: "fake", schema: nil, table: "t", qualifiedName: "t", engine: .duckdb,
      created: Date(), state: .pending, editKind: .inline, statementCount: 1, columns: [],
      notCaptured: false, notRewindableReason: nil)
    recorder.record(entry, rows: [], scope: connection.rewindScope)
    return RewindProbe(url: url, store: store, recorder: recorder)
  }

  func state() async throws -> RewindEntry.State? {
    await recorder.flushed()
    return try store.entries(connectionKey: nil).first?.state
  }

  func removeFiles() {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
