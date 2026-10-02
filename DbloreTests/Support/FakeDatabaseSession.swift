// FakeDatabaseSession.swift
// In-memory session for contract tests. Scripts rows, errors, close events, and slow queries.
// It cannot bypass the actor's gate: user SQL reaches here only after the actor allows it.

import Foundation

@testable import Dblore

/// Builds one fake session per `makeSession`. Each connect / reconnect gets its own session.
final class FakeDatabaseSessionFactory: DatabaseSessionFactory, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let columns: [ColumnInfo]
  let rows: [[CellValue]]
  let slowQueries: Bool

  private let lock = NSLock()
  private var made: [FakeDatabaseSession] = []

  init(
    capabilities: DatabaseCapabilities, columns: [ColumnInfo] = [], rows: [[CellValue]] = [],
    slowQueries: Bool = false
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let session = FakeDatabaseSession(
      capabilities: capabilities, columns: columns, rows: rows, slowQueries: slowQueries)
    lock.lock()
    made.append(session)
    lock.unlock()
    return session
  }

  var sessions: [FakeDatabaseSession] {
    lock.lock()
    defer { lock.unlock() }
    return made
  }

  /// SQL that reached any session, in the order it was accepted.
  var statements: [String] {
    sessions.flatMap(\.statements)
  }
}

/// One scripted connection. `query`, `command`, and `openCursor` record the text and binds
/// they were given. FETCH and CLOSE record no binds.
final class FakeDatabaseSession: DatabaseSession, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let closeEvents: AsyncStream<SessionCloseReason>

  private let columns: [ColumnInfo]
  private let rows: [[CellValue]]
  private let slowQueries: Bool
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation
  private let lock = NSLock()
  private var recorded: [String] = []
  private var recordedBinds: [[SQLBindValue]] = []
  private var queriesRecorded: [String] = []
  private var didEmitClose = false
  private var slowContinuation: CheckedContinuation<Void, Error>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var queryDidStart = false

  private(set) var didOpen = false
  private(set) var didClose = false
  private(set) var interruptCount = 0
  private(set) var openCursorCount = 0
  private(set) var closeCursorCount = 0
  private(set) var fetchCounts: [Int] = []

  init(
    capabilities: DatabaseCapabilities, columns: [ColumnInfo], rows: [[CellValue]],
    slowQueries: Bool
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  var statements: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  /// Binds accepted with each entry in `statements`, in the same order.
  var statementBinds: [[SQLBindValue]] {
    lock.lock()
    defer { lock.unlock() }
    return recordedBinds
  }

  var queries: [String] {
    lock.lock()
    defer { lock.unlock() }
    return queriesRecorded
  }

  func open() async throws {
    markOpen()
  }

  func close() async {
    markClose()
    emit(.closedByApp)
  }

  /// The server or the network ended this session. At most one close reason is delivered.
  func emit(_ reason: SessionCloseReason) {
    lock.lock()
    if didEmitClose {
      lock.unlock()
      return
    }
    didEmitClose = true
    lock.unlock()
    closeContinuation.yield(reason)
    closeContinuation.finish()
  }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    record(sql, binds: binds, query: true)
    if slowQueries { try await waitUntilInterrupted() }
    return rowSource()
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    record(sql, binds: binds, query: false)
    return Self.commandResult(sql)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    record(sql, binds: binds, query: false)
    noteOpenCursor()
    return SessionCursor(name: "fake_cap")
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    record("FETCH \(maxRows)", query: false)
    noteFetch(maxRows)
    return rowSource()
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    record("CLOSE \(cursor.name)", query: false)
    noteCloseCursor()
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {}

  func interrupt() async {
    takeSlowWait()?.resume(throwing: CancellationError())
  }

  func formatError(_ error: Error) -> String {
    error.localizedDescription
  }

  /// Resumes once `query` is waiting inside a slow read, so cancel can call `interrupt`.
  func waitUntilQueryStarted() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      if !self.storeQueryWaiter(cont) { cont.resume() }
    }
  }

  private func waitUntilInterrupted() async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      self.armSlowWait(cont)?.resume()
    }
  }

  private func markOpen() {
    lock.lock()
    didOpen = true
    lock.unlock()
  }

  private func markClose() {
    lock.lock()
    didClose = true
    lock.unlock()
  }

  private func noteOpenCursor() {
    lock.lock()
    openCursorCount += 1
    lock.unlock()
  }

  private func noteFetch(_ maxRows: Int) {
    lock.lock()
    fetchCounts.append(maxRows)
    lock.unlock()
  }

  private func noteCloseCursor() {
    lock.lock()
    closeCursorCount += 1
    lock.unlock()
  }

  /// `true` when the waiter was stored. `false` when the query had already started.
  private func storeQueryWaiter(_ cont: CheckedContinuation<Void, Never>) -> Bool {
    lock.lock()
    if queryDidStart {
      lock.unlock()
      return false
    }
    startedContinuation = cont
    lock.unlock()
    return true
  }

  private func armSlowWait(
    _ cont: CheckedContinuation<Void, Error>
  ) -> CheckedContinuation<Void, Never>? {
    lock.lock()
    slowContinuation = cont
    queryDidStart = true
    let started = startedContinuation
    startedContinuation = nil
    lock.unlock()
    return started
  }

  private func takeSlowWait() -> CheckedContinuation<Void, Error>? {
    lock.lock()
    interruptCount += 1
    let pending = slowContinuation
    slowContinuation = nil
    lock.unlock()
    return pending
  }

  private func record(_ sql: String, binds: [SQLBindValue] = [], query: Bool) {
    lock.lock()
    recorded.append(sql)
    recordedBinds.append(binds)
    if query { queriesRecorded.append(sql) }
    lock.unlock()
  }

  private func rowSource() -> SessionRowSource {
    let rows = rows
    let stream = AsyncThrowingStream<[CellValue], Error> { continuation in
      for row in rows {
        continuation.yield(row)
      }
      continuation.finish()
    }
    return SessionRowSource(columns: columns, rows: stream)
  }

  /// Command tag the actor already understands (`COMMIT`, `ROLLBACK`, `UPDATE`, …).
  private static func commandResult(_ sql: String) -> CommandResult {
    let verb =
      sql.split(whereSeparator: \.isWhitespace).first.map(String.init)?.uppercased()
      ?? sql
    switch verb {
    case "INSERT", "UPDATE", "DELETE", "MERGE":
      return CommandResult(affectedRows: 1, tag: verb)
    case "COMMIT":
      return CommandResult(affectedRows: 0, tag: "COMMIT")
    case "ROLLBACK":
      return CommandResult(affectedRows: 0, tag: "ROLLBACK")
    default:
      return CommandResult(affectedRows: 0, tag: verb)
    }
  }
}

extension DatabaseCapabilities {
  /// PostgreSQL-shaped flags with a chosen cancel strategy, for a fake session.
  static func contract(
    cancelStrategy: CancelStrategy = .reconnect, supportsServerCursor: Bool = true
  ) -> DatabaseCapabilities {
    DatabaseCapabilities(
      usesNetwork: false,
      usesPassword: false,
      supportsSSL: false,
      supportsSchemas: true,
      supportsRolesAndUsers: false,
      supportsFunctions: false,
      supportsServerCursor: supportsServerCursor,
      supportsSessionBrakes: true,
      cancelStrategy: cancelStrategy,
      cappedReadResetsSession: true,
      supportsExplainJSON: false,
      supportsUpdateOnly: false,
      isAvailable: true
    )
  }
}
