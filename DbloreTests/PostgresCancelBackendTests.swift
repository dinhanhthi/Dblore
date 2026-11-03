// PostgresCancelBackendTests.swift
// PostgreSQL Cancel keeps the session: pg_cancel_backend runs on a short side connection, matched
// on the pid, the connect-time backend_start text, the active state and the statement running
// when Cancel decided: the oldest one sent and not finished (a pooler's other client is never
// cancelled). No match, a pid never read or the 5 s bound fall back to the reconnect, unless
// the statement running at the cancel ended meanwhile. A loopback wire stand-in and fake
// sessions, no server.

import Darwin
import Foundation
import Testing

@testable import Dblore

// MARK: - PostgresSession (loopback wire stand-in)

@Suite("PostgreSQL cancel from a side connection")
struct PostgresCancelBackendTests {
  private static let start = "2026-11-03 10:15:42.123456+01"
  /// The VM QA statement: CPU only, no function call, so it runs as a cursor read in BEGIN
  private static let cursorRead =
    "SELECT a.g FROM qa_cancel a CROSS JOIN qa_cancel b WHERE a.g + b.g < 0"

  private static func config(port: Int) -> ConnectionConfig {
    ConnectionConfig(
      host: "127.0.0.1", port: port, database: "db", username: "u", password: "p",
      sslMode: .disable, timeoutSeconds: 5)
  }

  @Test(
    "A cursor read's FETCH is the statement the cancel matches, with the pid and start text",
    .timeLimit(.minutes(1)))
  func cancelMatchesTheCursorFetch() async throws {
    let qa = try #require(SQLStatementClassifier.classifyStatement(Self.cursorRead))
    #expect(DatabaseConnectionManager.usesCursor(qa, dialect: .postgresql))
    let server = FakePostgresServer(
      pid: 4242, backendStart: Self.start, answer: .cancelled, holds: { $0.hasPrefix("FETCH") })
    try await withOpenSession(on: server) { session in
      let cursor = try await session.openCursor(Self.cursorRead, binds: [])
      let fetching = Task { try await session.fetch(cursor, maxRows: 501) }
      try await waitUntil { server.receivedStatements.contains { $0.hasPrefix("FETCH") } }

      let target = try #require(session.prepareCancelBackend())
      #expect(await session.cancelBackend(target))
      let cancel = server.cancelRequests.first
      for predicate in [
        "pg_cancel_backend($1)", "pid = $1", "backend_start = $2::timestamptz",
        "state = 'active'", "$3 <> ''", "query = left($3, length(query))",
      ] {
        #expect(cancel?.sql.contains(predicate) == true, "missing \(predicate)")
      }
      // The start text exactly as the server printed it, and the FETCH, not the user's SELECT
      #expect(
        cancel?.binds == ["4242", Self.start, "FETCH FORWARD 501 FROM \(cursor.name)"])
      server.releaseHeld()
      _ = try await fetching.value
    }
  }

  @Test(
    "No matching backend, or no answer within 5 s: not cancelled",
    .timeLimit(.minutes(1)), arguments: [FakePostgresServer.Answer.noMatch, .stall])
  func unmatchedOrSilentCancelFails(answer: FakePostgresServer.Answer) async throws {
    let server = FakePostgresServer(
      pid: 7, backendStart: Self.start, answer: answer, holds: { $0 == Self.sleep })
    try await withOpenSession(on: server) { session in
      let running = Task { try await session.command(Self.sleep, binds: []) }
      try await waitUntilReceived(Self.sleep, on: server)
      let target = try #require(session.prepareCancelBackend())
      let clock = ContinuousClock()
      let started = clock.now
      #expect(await session.cancelBackend(target) == false)
      let elapsed = clock.now - started
      #expect(elapsed < .seconds(7))
      #expect(server.cancelRequests.count == 1, "after \(elapsed)")
      server.releaseHeld()
      _ = try await running.value
    }
  }

  @Test("Without the pid read at connect nothing can be matched", .timeLimit(.minutes(1)))
  func missingPidFailsAtOnce() async throws {
    let server = FakePostgresServer(
      pid: nil, backendStart: Self.start, answer: .cancelled, holds: { $0 == Self.sleep })
    try await withOpenSession(on: server) { session in
      #expect(session.backendPID == nil)
      let running = Task { try await session.command(Self.sleep, binds: []) }
      try await waitUntilReceived(Self.sleep, on: server)
      #expect(session.prepareCancelBackend() == nil)
      server.releaseHeld()
      _ = try await running.value
      #expect(server.connectionCount == 1)
      #expect(server.cancelRequests.isEmpty)
    }
  }

  /// PostgresNIO runs one statement at a time in arrival order: a catalog read or the ROLLBACK
  /// a cancel owes, queued behind the running statement, never becomes the text matched
  @Test(
    "Statements queued behind the running one do not change what the cancel matches",
    .timeLimit(.minutes(1)))
  func queuedStatementsKeepTheRunningText() async throws {
    let catalog = "SELECT relname FROM pg_class WHERE relnamespace = 2200"
    let server = FakePostgresServer(
      pid: 9, backendStart: Self.start, answer: .cancelled, holds: { $0 == Self.sleep })
    try await withOpenSession(on: server) { session in
      let running = Task { try await session.command(Self.sleep, binds: []) }
      try await waitUntilReceived(Self.sleep, on: server)
      let queued = Task {
        _ = try await session.readQuery(catalog, binds: [], maxRows: 10, readToEnd: false)
      }
      try await waitUntil { session.statementsInFlight.contains(catalog) }
      let rollback = Task { try await session.command("ROLLBACK", binds: []) }
      try await waitUntil { session.statementsInFlight.contains("ROLLBACK") }

      #expect(session.prepareCancelBackend()?.statement == Self.sleep)
      #expect(await session.cancelBackend(try #require(session.prepareCancelBackend())))
      #expect(server.cancelRequests.first?.binds.last == Self.sleep)
      server.releaseHeld()
      _ = try await running.value
      _ = try await queued.value
      _ = try await rollback.value
    }
  }

  @Test("A statement that finished is no longer matched", .timeLimit(.minutes(1)))
  func finishedStatementNotMatched() async throws {
    let server = FakePostgresServer(pid: 9, backendStart: Self.start, answer: .cancelled)
    try await withOpenSession(on: server) { session in
      _ = try await session.command("SELECT 1", binds: [])
      _ = try await session.readQuery("SELECT 2", binds: [], maxRows: 10, readToEnd: false)
      let rows = try await session.query("SELECT 3", binds: [])
      for try await _ in rows.rows {}
      #expect(session.statementsInFlight.isEmpty)
      #expect(session.prepareCancelBackend() == nil)
      #expect(server.cancelRequests.isEmpty)
    }
  }

  /// `left($3, 0)` matches any backend showing an empty text: never asked
  @Test("An empty statement text is never matched", .timeLimit(.minutes(1)))
  func emptyStatementNotMatched() async throws {
    let server = FakePostgresServer(
      pid: 9, backendStart: Self.start, answer: .cancelled, holds: { $0.isEmpty })
    try await withOpenSession(on: server) { session in
      let running = Task { try await session.command("", binds: []) }
      try await waitUntilReceived("", on: server)
      #expect(session.prepareCancelBackend() == nil)
      server.releaseHeld()
      _ = try await running.value
    }
  }

  /// A failed cancel resets the session only while the statement it matched still runs
  @Test(
    "The cancel's target is in flight only while its own statement runs", .timeLimit(.minutes(1)))
  func targetTokenFollowsItsStatement() async throws {
    let server = FakePostgresServer(
      pid: 9, backendStart: Self.start, answer: .noMatch, holds: { $0 == Self.sleep })
    try await withOpenSession(on: server) { session in
      let running = Task { try await session.command(Self.sleep, binds: []) }
      try await waitUntilReceived(Self.sleep, on: server)
      let target = try #require(session.prepareCancelBackend())
      #expect(session.runningStatementToken() == target.token)
      #expect(session.statementInFlight(target.token))
      server.releaseHeld()
      _ = try await running.value
      #expect(!session.statementInFlight(target.token))
      #expect(session.runningStatementToken() == nil)
    }
  }

  @Test(
    "A statement that failed or whose rows were dropped unread is no longer in flight",
    .timeLimit(.minutes(1)))
  func failedAndDroppedStatementsNotInFlight() async throws {
    let failing = "SELECT dblore_fails()"
    let server = FakePostgresServer(
      pid: 9, backendStart: Self.start, answer: .cancelled, fails: { $0 == failing })
    try await withOpenSession(on: server) { session in
      await #expect(throws: (any Error).self) { try await session.command(failing, binds: []) }
      #expect(session.statementsInFlight.isEmpty)
      do { _ = try await session.query("SELECT 4", binds: []) }
      #expect(session.statementsInFlight.isEmpty)
      #expect(session.prepareCancelBackend() == nil)
      // The connection still answers
      _ = try await session.command("SELECT 5", binds: [])
    }
  }

  private static let sleep = "SELECT pg_sleep(30)"

  /// Polls until `server` received `sql` (exactly)
  private func waitUntilReceived(_ sql: String, on server: FakePostgresServer) async throws {
    try await waitUntil { server.receivedStatements.contains(sql) }
  }

  private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never met")
  }

  /// Opens a session on `server`, runs `body`, and always closes it (a connection released open
  /// asserts in debug builds)
  private func withOpenSession(
    on server: FakePostgresServer, _ body: (PostgresSession) async throws -> Void
  ) async throws {
    let port = try server.start()
    defer { server.stop() }
    let session = PostgresSession(config: Self.config(port: port))
    try await session.open()
    do {
      try await body(session)
    } catch {
      Issue.record(error)
    }
    await session.close()
  }
}

// MARK: - Manager (fake sessions)

@Suite("PostgreSQL cancel - manager")
struct PostgresCancelManagerTests {
  private static let resetText =
    "Query cancelled — connection was reset (temp tables, SET, search_path lost)."
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test(
    "Cancel inside BEGIN keeps the session and says the transaction was rolled back",
    .timeLimit(.minutes(1)))
  func cancelKeepsSessionAndRollsBack() async throws {
    let (factory, connection, session) = try await postgresInUserTransaction()
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    #expect(status.interrupts && status.interruptRollsBack && !status.keepsTransaction)
    try await cancel(on: connection)

    let stopped = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(
      stopped?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(session.cancelBackendCount == 1)
    #expect(session.interruptCount == 0)
    #expect(factory.sessions.count == 1)
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(await connection.userTxOpen == false)
    #expect(await connection.lastCancel?.connectionKept == true)
    await connection.disconnect()
  }

  @Test(
    "No pid or no match: the cancel falls back to the reconnect, connection not kept",
    .timeLimit(.minutes(1)), arguments: [true, false])
  func failedCancelReconnects(missingPid: Bool) async throws {
    let (factory, connection, session) = try await postgresInUserTransaction()
    session.scriptCancelBackend(pid: missingPid ? nil : 1) { false }
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let status = await connection.runningStatementStatus()
    try await cancel(on: connection)
    // The fake's close does not end its slow read: end it as the server would
    await session.interrupt()

    let stopped = await #expect(throws: DatabaseError.self) { try await running.value }
    #expect(
      stopped?.localizedDescription
        == Self.resetText + " Your open transaction was rolled back.")
    #expect(factory.sessions.count == 2)
    #expect(session.didClose)
    #expect(!session.statements.contains("ROLLBACK"))
    #expect(
      await connection.lastCancel
        == QueryCancelRecord(
          epoch: status.epoch, pendingCount: 0, userTxRolledBack: true, interruptGeneration: nil,
          connectionKept: false))
    #expect(await connection.userTxOpen == false)
    await connection.disconnect()
  }

  @Test(
    "The cancel's side connection sees the unremembered client certificate",
    .timeLimit(.minutes(1)))
  func cancelSeesUnrememberedCertificate() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake-mtls", port: 1, database: "fake", username: "u",
      password: "p", sslMode: .require,
      clientCertificate: ClientCertificateInfo(subject: "draft", expiry: nil, hasCA: false),
      rememberConnection: false, safeMode: .silent, protectedMode: false)
    let material = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: config), material: material)
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await connection.connect(config: config)
    }
    scoped.clear()
    let session = try #require(factory.sessions.first)
    let seen = SeenCertificate()
    session.scriptCancelBackend(pid: 1) {
      seen.set(ClientCertificateStoreFactory.load(for: config))
      return true
    }
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    try await cancel(on: connection)
    _ = try? await running.value

    #expect(seen.value == material)
    #expect(factory.sessions.count == 1)
    await connection.disconnect()
  }

  /// (a) The script's next statement was admitted before the cancel; another caller already sent
  /// the owed ROLLBACK when it is sent: never run in autocommit
  @Test(
    "A statement admitted before the cancel is not sent after its ROLLBACK",
    .timeLimit(.minutes(1)))
  func statementAdmittedBeforeCancelRefused() async throws {
    let (_, connection, session) = try await postgresInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    session.holdSlowReadsOnInterrupt()
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let tab = UUID()
    let pause = CancelPause()
    await connection.setScriptCheckpointHook { checkpoint in
      guard checkpoint == .beforeSend(caller: tab, index: 0) else { return }
      await pause.pause()
    }
    let policy = open
    let admitted = Task {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: policy, caller: tab)
    }
    await pause.waitUntilPaused()
    try await cancel(on: connection)
    // An app read sends the owed ROLLBACK first
    _ = try await connection.executeInternal("SELECT 1")
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    await pause.release()

    // Refused before the send (`sentAfterInterruptError`); its script reports the cancel
    let error = await #expect(throws: DatabaseError.self) { try await admitted.value }
    #expect(
      error?.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(!session.statements.contains("UPDATE t SET a = 2"))
    await connection.setScriptCheckpointHook(nil)
    session.releaseSlowReads()
    _ = try? await running.value
    await connection.disconnect()
  }

  /// (b) The first user statement sent after the cancel settles the owed ROLLBACK, which ended
  /// the transaction it was meant for: refused
  @Test(
    "The first user send after the cancel settles the ROLLBACK and is refused",
    .timeLimit(.minutes(1)))
  func firstSendAfterCancelRefused() async throws {
    let (_, connection, session) = try await postgresInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    session.holdSlowReadsOnInterrupt()
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    try await cancel(on: connection)

    let error = await #expect(throws: DatabaseError.self) {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: open, caller: UUID())
    }
    let refusal = DatabaseConnectionManager.sentAfterInterruptError.localizedDescription
    #expect(error?.localizedDescription.hasSuffix(refusal) == true)
    #expect(!session.statements.contains("UPDATE t SET a = 2"))
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(await connection.userTxOpen == false)
    session.releaseSlowReads()
    _ = try? await running.value
    await connection.disconnect()
  }

  /// The ROLLBACK the cancel owes may be queued while the cancel is still on its way (here an
  /// app read in the gap sends it): the text matched was read before, in the cancel's turn
  @Test(
    "The ROLLBACK owed since the cancel is never the statement it matches",
    .timeLimit(.minutes(1)))
  func owedRollbackNotMatched() async throws {
    let (_, connection, session) = try await postgresInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: open)
    }
    await session.waitUntilQueryStarted()
    let runningText = try #require(session.statements.last)
    await connection.setScriptCheckpointHook { checkpoint in
      guard checkpoint == .cancelling else { return }
      _ = try? await connection.executeInternal("SELECT 1")
    }
    try await cancel(on: connection)
    await connection.setScriptCheckpointHook(nil)

    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(session.cancelTargets.map(\.statement) == [runningText])
    _ = try? await running.value
    await connection.disconnect()
  }

  /// The statement ended on its own before the server cancel (often why nothing matched):
  /// nothing is reset, and the ROLLBACK owed since the cancel ends the transaction
  @Test(
    "A failed cancel once nothing runs anymore keeps the session (no reset)",
    .timeLimit(.minutes(1)))
  func failedCancelWhenIdleKeepsSession() async throws {
    let (factory, connection, session) = try await postgresInUserTransaction()
    session.slowReads(containing: "pg_sleep")
    session.holdNextCommand(containing: "UPDATE")
    let running = Task {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: open)
    }
    while session.heldCommandCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    session.scriptCancelBackend(pid: 1) {
      session.releaseHeldCommands()
      _ = try? await running.value
      return false
    }
    let status = await connection.runningStatementStatus()
    try await cancel(on: connection)

    #expect(factory.sessions.count == 1)
    #expect(!session.didClose)
    #expect(await connection.connectionEpoch == status.epoch)
    #expect(await connection.lastCancel?.connectionKept == true)
    _ = try await connection.executeInternal("SELECT 1")
    #expect(session.statements.filter { $0 == "ROLLBACK" }.count == 1)
    #expect(await connection.userTxOpen == false)
    await connection.disconnect()
  }

  /// The statement the cancel matched ended on its own while the side cancel was on its way, and
  /// another tab's statement started meanwhile: nothing the user confirmed still runs, so that
  /// statement is not killed by a reset
  @Test(
    "A failed cancel after its statement ended does not reset another tab's statement",
    .timeLimit(.minutes(1)))
  func failedCancelKeepsLaterStatement() async throws {
    let (factory, connection, session) = try await postgresAutocommit()
    session.slowReads(containing: "pg_sleep")
    session.holdNextCommand(containing: "UPDATE")
    let policy = open
    let running = Task {
      try await connection.execute(userSQL: "UPDATE t SET a = 2", policy: policy)
    }
    while session.heldCommandCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    let other = TaskSlot()
    session.scriptCancelBackend(pid: 1) {
      session.releaseHeldCommands()
      _ = try? await running.value
      other.start {
        _ = try await connection.execute(
          userSQL: "SELECT pg_sleep(30)", policy: policy, caller: UUID())
      }
      while session.slowQueryCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
      return false
    }
    let status = await connection.runningStatementStatus()
    try await cancel(on: connection)

    #expect(factory.sessions.count == 1)
    #expect(!session.didClose)
    #expect(await connection.connectionEpoch == status.epoch)
    #expect(session.slowQueryCount == 1)
    await session.interrupt()
    _ = try? await other.task?.value
    await connection.disconnect()
  }

  /// Same as the other interrupt engines: the cancel kept the session, so a status read before
  /// it still names this connection, and the statement running now is cancelled
  @Test(
    "A second Cancel with a status read before the first is accepted on the same connection",
    .timeLimit(.minutes(1)))
  func secondCancelWithStaleStatusAccepted() async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 1, database: "fake", username: "u",
        password: "p", sslMode: .disable, safeMode: .silent, protectedMode: false))
    let session = try #require(factory.sessions.first)
    let policy = open
    let first = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: policy)
    }
    await session.waitUntilQueryStarted()
    let seen = await connection.runningStatementStatus()
    try await cancel(on: connection)
    _ = try? await first.value

    let second = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(31)", policy: policy)
    }
    while session.slowQueryCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: seen.generation, expectedUserTxOpen: seen.userTxOpen,
      expectedEpoch: seen.epoch)
    #expect(outcome == .cancelled)
    await #expect(throws: DatabaseError.self) { try await second.value }
    #expect(session.cancelBackendCount == 2)
    #expect(factory.sessions.count == 1)
    await connection.disconnect()
  }

  /// A fake PostgreSQL connection (Protected mode off), no transaction open
  private func postgresAutocommit() async throws -> (
    FakeDatabaseSessionFactory, DatabaseConnectionManager, FakeDatabaseSession
  ) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 1, database: "fake", username: "u",
        password: "p", sslMode: .disable, safeMode: .silent, protectedMode: false))
    return (factory, connection, try #require(factory.sessions.first))
  }

  /// A fake PostgreSQL connection (Protected mode off) inside the user's BEGIN
  private func postgresInUserTransaction() async throws -> (
    FakeDatabaseSessionFactory, DatabaseConnectionManager, FakeDatabaseSession
  ) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: .interrupt), slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 1, database: "fake", username: "u",
        password: "p", sslMode: .disable, safeMode: .silent, protectedMode: false))
    let session = try #require(factory.sessions.first)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    #expect(await connection.userTxOpen)
    return (factory, connection, session)
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

/// The certificate the fake's cancel saw
/// A task started from a `@Sendable` closure, awaited later
private final class TaskSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Task<Void, Error>?

  func start(_ body: @escaping @Sendable () async throws -> Void) {
    lock.withLock { stored = Task { try await body() } }
  }

  var task: Task<Void, Error>? { lock.withLock { stored } }
}

private final class SeenCertificate: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ClientCertificateMaterial?

  func set(_ material: ClientCertificateMaterial?) { lock.withLock { stored = material } }
  var value: ClientCertificateMaterial? { lock.withLock { stored } }
}

/// Holds the caller of `pause` until `release`; `waitUntilPaused` returns once it arrived
private actor CancelPause {
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

// MARK: - Loopback wire stand-in

/// A PostgreSQL v3 stand-in on loopback (no TLS, trust auth). Every client completes startup;
/// each extended-protocol batch (Parse … Sync) is answered by its SQL: the identity read at open
/// returns `pid` and `backendStart` (an error when `pid` is nil), the cancel statement answers as
/// `answer` says and is recorded with its text binds, a statement `fails` names answers an
/// error, anything else returns no rows.
final class FakePostgresServer: @unchecked Sendable {
  enum Answer: Sendable, CustomTestStringConvertible {
    /// One row, true
    case cancelled
    /// No row: no backend matched
    case noMatch
    /// Never answered
    case stall

    var testDescription: String {
      switch self {
      case .cancelled: "cancelled"
      case .noMatch: "no match"
      case .stall: "no answer"
      }
    }
  }

  struct CancelRequest: Sendable {
    let sql: String
    let binds: [String?]
  }

  private let pid: Int32?
  private let backendStart: String
  private let answer: Answer
  /// Statements answered only once `releaseHeld` (or `stop`) runs: still running on the server
  private let holds: @Sendable (String) -> Bool
  /// Statements answered with an error
  private let fails: @Sendable (String) -> Bool
  private let lock = NSLock()
  private let held = NSCondition()
  private var released = false
  private var received: [String] = []
  private var port: UInt16 = 0
  private var stopping = false
  /// Open client sockets: closed under `lock`, so `stop` never touches a reused descriptor
  private var clients: Set<Int32> = []
  private var accepted = 0
  private var cancels: [CancelRequest] = []

  init(
    pid: Int32?, backendStart: String, answer: Answer,
    holds: @escaping @Sendable (String) -> Bool = { _ in false },
    fails: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.pid = pid
    self.backendStart = backendStart
    self.answer = answer
    self.holds = holds
    self.fails = fails
  }

  var cancelRequests: [CancelRequest] { lock.withLock { cancels } }
  /// Every statement that reached the server, in order (the cancel's included)
  var receivedStatements: [String] { lock.withLock { received } }

  /// Answers the held statements, and every later one at once
  func releaseHeld() {
    held.lock()
    released = true
    held.broadcast()
    held.unlock()
  }
  /// Clients accepted so far
  var connectionCount: Int { lock.withLock { accepted } }

  func start() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENODEV) }
    var noSignal: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ready = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard ready else {
      close(fd)
      throw POSIXError(.EADDRNOTAVAIL)
    }
    let bound = UInt16(bigEndian: address.sin_port)
    lock.withLock { port = bound }
    Thread.detachNewThread { self.acceptLoop(fd) }
    return Int(bound)
  }

  /// Ends the open clients, then wakes the accept loop with one last connect: it closes the
  /// listening socket itself (closing it here could hit a descriptor another test reuses)
  func stop() {
    releaseHeld()
    let port = lock.withLock {
      stopping = true
      for client in clients { shutdown(client, SHUT_RDWR) }
      return port
    }
    let wake = socket(AF_INET, SOCK_STREAM, 0)
    guard wake >= 0 else { return }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    close(wake)
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      let registered = lock.withLock { () -> Bool in
        guard !stopping, client >= 0 else { return false }
        accepted += 1
        clients.insert(client)
        return true
      }
      guard registered else {
        if client >= 0 { close(client) }
        close(fd)
        return
      }
      var noSignal: Int32 = 1
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal)))
      Thread.detachNewThread {
        self.serve(client)
        self.lock.withLock {
          self.clients.remove(client)
          close(client)
        }
      }
    }
  }

  private func serve(_ fd: Int32) {
    guard let header = readExact(fd, 4) else { return }
    let length = Int(Self.int32(header, at: 0))
    guard length >= 8, length <= 8192, readExact(fd, length - 4) != nil else { return }
    guard writeAll(fd, Self.startupComplete) else { return }
    var sql = ""
    var binds: [String?] = []
    while let head = readExact(fd, 5) {
      let size = Int(Self.int32(head, at: 1)) - 4
      guard size >= 0, let body = size == 0 ? [] : readExact(fd, size) else { return }
      switch head[0] {
      case UInt8(ascii: "P"):
        var offset = 0
        _ = Self.cString(body, &offset)
        sql = Self.cString(body, &offset)
      case UInt8(ascii: "B"):
        binds = Self.bindValues(body)
      case UInt8(ascii: "S"):
        lock.withLock { received.append(sql) }
        if holds(sql) {
          held.lock()
          while !released { held.wait() }
          held.unlock()
        }
        guard writeAll(fd, reply(sql: sql, binds: binds)) else { return }
      case UInt8(ascii: "X"):
        return
      default:
        break
      }
    }
  }

  private func reply(sql: String, binds: [String?]) -> [UInt8] {
    if sql.contains("pg_cancel_backend") {
      lock.withLock { cancels.append(CancelRequest(sql: sql, binds: binds)) }
      switch answer {
      case .stall: return []
      case .cancelled, .noMatch:
        let row =
          answer == .cancelled ? [Self.message("D", Self.int16(1) + Self.int32(1) + [1])] : []
        return Self.rows(
          params: [23, 1184, 25], columns: [("pg_cancel_backend", 16)], rows: row,
          tag: answer == .cancelled ? "SELECT 1" : "SELECT 0")
      }
    }
    if fails(sql) { return Self.error("42883", "function does not exist") }
    if sql.contains("server_version_num") {
      guard let pid else { return Self.error("42501", "permission denied") }
      let start = Array(backendStart.utf8)
      let row =
        Self.int16(3) + Self.int32(4) + Self.int32(160_000) + Self.int32(4)
        + Self.int32(UInt32(bitPattern: pid)) + Self.int32(UInt32(start.count)) + start
      return Self.rows(
        params: [],
        columns: [("current_setting", 23), ("pg_backend_pid", 23), ("backend_start", 25)],
        rows: [Self.message("D", row)], tag: "SELECT 1")
    }
    return Self.message("1", []) + Self.message("t", Self.int16(0)) + Self.message("n", [])
      + Self.message("2", []) + Self.message("C", Array("SELECT 0".utf8) + [0])
      + Self.message("Z", [UInt8(ascii: "I")])
  }

  private static func rows(
    params: [UInt32], columns: [(String, UInt32)], rows: [[UInt8]], tag: String
  ) -> [UInt8] {
    var description = int16(UInt16(columns.count))
    for (name, type) in columns {
      description += Array(name.utf8) + [0] + int32(0) + int16(0) + int32(type)
      description += int16(type == 16 ? 1 : type == 23 ? 4 : 0xFFFF) + int32(0xFFFF_FFFF) + int16(0)
    }
    return message("1", []) + message("t", int16(UInt16(params.count)) + params.flatMap(int32))
      + message("T", description) + message("2", []) + rows.flatMap { $0 }
      + message("C", Array(tag.utf8) + [0]) + message("Z", [UInt8(ascii: "I")])
  }

  /// ErrorResponse, ReadyForQuery (idle)
  private static func error(_ code: String, _ text: String) -> [UInt8] {
    let fields: [UInt8] =
      [UInt8(ascii: "S")] + Array("ERROR".utf8) + [0] + [UInt8(ascii: "C")] + Array(code.utf8)
      + [0] + [UInt8(ascii: "M")] + Array(text.utf8) + [0, 0]
    return message("E", fields) + message("Z", [UInt8(ascii: "I")])
  }

  /// Text values of a Bind message (nil for NULL)
  private static func bindValues(_ body: [UInt8]) -> [String?] {
    var offset = 0
    _ = cString(body, &offset)
    _ = cString(body, &offset)
    let formats = Int(int16Value(body, at: offset))
    offset += 2 + 2 * formats
    let count = Int(int16Value(body, at: offset))
    offset += 2
    var values: [String?] = []
    for _ in 0..<count {
      let length = Int32(bitPattern: int32(body, at: offset))
      offset += 4
      guard length >= 0 else {
        values.append(nil)
        continue
      }
      values.append(String(decoding: body[offset..<offset + Int(length)], as: UTF8.self))
      offset += Int(length)
    }
    return values
  }

  /// AuthenticationOk, BackendKeyData, ReadyForQuery (idle)
  private static let startupComplete: [UInt8] =
    message("R", int32(0)) + message("K", int32(1) + int32(1)) + message("Z", [UInt8(ascii: "I")])

  private static func message(_ id: Character, _ payload: [UInt8]) -> [UInt8] {
    [UInt8(ascii: id.unicodeScalars.first!)] + int32(UInt32(4 + payload.count)) + payload
  }

  private static func int32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
  }

  private static func int16(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
  }

  private static func int32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func int16Value(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
  }

  private static func cString(_ bytes: [UInt8], _ offset: inout Int) -> String {
    let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
    let text = String(decoding: bytes[offset..<end], as: UTF8.self)
    offset = min(end + 1, bytes.count)
    return text
  }

  private func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: count)
    while result.count < count {
      let read = Darwin.read(fd, &buffer, count - result.count)
      if read <= 0 { return nil }
      result.append(contentsOf: buffer.prefix(read))
    }
    return result
  }

  private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var sent = 0
    while sent < bytes.count {
      let count = bytes.withUnsafeBytes { raw -> Int in
        write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
      }
      if count <= 0 { return false }
      sent += count
    }
    return true
  }
}
