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
  /// A `query` whose SQL contains this text throws `FakeQueryError`.
  let failingQuery: String?
  /// Every `open` throws this when set (a failed connect).
  let openError: (any Error)?
  /// `formatError` text when set (else `localizedDescription`).
  let errorFormatter: (@Sendable (any Error) -> String)?
  /// Affected rows of a `command` when it returns non-nil (else derived from the verb).
  let commandRows: (@Sendable (String) -> Int?)?
  /// `modifiedRows` of a `command` (nil when unset or when it returns nil).
  let commandModifiedRows: (@Sendable (String) -> Int?)?
  /// Result of a typed `command(_: MongoCommand)` when set (else derived from the command).
  let typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)?
  /// The typed command at this index (0-based, per session) throws `typedError`.
  let failTypedAt: Int?
  let typedError: any Error
  /// What `writeLimits()` returns.
  let writeLimits: MongoWriteLimits

  private let lock = NSLock()
  private var made: [FakeDatabaseSession] = []

  init(
    capabilities: DatabaseCapabilities, columns: [ColumnInfo] = [], rows: [[CellValue]] = [],
    slowQueries: Bool = false, failingQuery: String? = nil, openError: (any Error)? = nil,
    errorFormatter: (@Sendable (any Error) -> String)? = nil,
    commandRows: (@Sendable (String) -> Int?)? = nil,
    commandModifiedRows: (@Sendable (String) -> Int?)? = nil,
    typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)? = nil,
    failTypedAt: Int? = nil, typedError: any Error = FakeQueryError(),
    writeLimits: MongoWriteLimits = .fallback
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
    self.failingQuery = failingQuery
    self.openError = openError
    self.errorFormatter = errorFormatter
    self.commandRows = commandRows
    self.commandModifiedRows = commandModifiedRows
    self.typedCommandResult = typedCommandResult
    self.failTypedAt = failTypedAt
    self.typedError = typedError
    self.writeLimits = writeLimits
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let session = FakeDatabaseSession(
      capabilities: capabilities, columns: columns, rows: rows, slowQueries: slowQueries,
      failingQuery: failingQuery, openError: openError, errorFormatter: errorFormatter,
      commandRows: commandRows, commandModifiedRows: commandModifiedRows,
      typedCommandResult: typedCommandResult, failTypedAt: failTypedAt, typedError: typedError,
      writeLimits: writeLimits)
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

  /// Typed commands that reached any session, in the order they were sent.
  var typedCommands: [MongoCommand] {
    sessions.flatMap(\.typedCommands)
  }
}

/// One scripted connection. `query`, `command`, and `openCursor` record the text and binds
/// they were given. FETCH and CLOSE record no binds. Typed MongoDB commands are recorded apart
/// (`typedCommands`).
final class FakeDatabaseSession: DatabaseSession, MongoTypedCommandSending, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let closeEvents: AsyncStream<SessionCloseReason>

  private let columns: [ColumnInfo]
  private let rows: [[CellValue]]
  private let slowQueries: Bool
  private let failingQuery: String?
  private let openError: (any Error)?
  private let errorFormatter: (@Sendable (any Error) -> String)?
  private let commandRows: (@Sendable (String) -> Int?)?
  private let commandModifiedRows: (@Sendable (String) -> Int?)?
  private let typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)?
  private let failTypedAt: Int?
  private let typedError: any Error
  private let limits: MongoWriteLimits
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation
  private let lock = NSLock()
  private var recorded: [String] = []
  private var recordedBinds: [[SQLBindValue]] = []
  private var queriesRecorded: [String] = []
  private var typedRecorded: [MongoCommand] = []
  private var didEmitClose = false
  private var slowContinuation: CheckedContinuation<Void, Error>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var queryDidStart = false
  private var failingCommand: String?
  private var failingCommands: [String] = []
  private var queryHook: (@Sendable (String) async -> Void)?

  private(set) var didOpen = false
  private(set) var didClose = false
  private(set) var interruptCount = 0
  private(set) var openCursorCount = 0
  private(set) var closeCursorCount = 0
  private(set) var fetchCounts: [Int] = []

  init(
    capabilities: DatabaseCapabilities, columns: [ColumnInfo], rows: [[CellValue]],
    slowQueries: Bool, failingQuery: String? = nil, openError: (any Error)? = nil,
    errorFormatter: (@Sendable (any Error) -> String)? = nil,
    commandRows: (@Sendable (String) -> Int?)? = nil,
    commandModifiedRows: (@Sendable (String) -> Int?)? = nil,
    typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)? = nil,
    failTypedAt: Int? = nil, typedError: any Error = FakeQueryError(),
    writeLimits: MongoWriteLimits = .fallback
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
    self.failingQuery = failingQuery
    self.openError = openError
    self.errorFormatter = errorFormatter
    self.commandRows = commandRows
    self.commandModifiedRows = commandModifiedRows
    self.typedCommandResult = typedCommandResult
    self.failTypedAt = failTypedAt
    self.typedError = typedError
    limits = writeLimits
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

  /// Typed commands sent, in order (a failing one included).
  var typedCommands: [MongoCommand] {
    lock.lock()
    defer { lock.unlock() }
    return typedRecorded
  }

  func open() async throws {
    if let openError { throw openError }
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
    if let hook = takeQueryHook() { await hook(sql) }
    if let failingQuery, sql.contains(failingQuery) { throw FakeQueryError() }
    if slowQueries { try await waitUntilInterrupted() }
    return rowSource()
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    record(sql, binds: binds, query: false)
    if takeFailingCommand(sql) { throw FakeQueryError() }
    var result =
      commandRows?(sql).map { CommandResult(affectedRows: $0, tag: "FAKE \($0)") }
      ?? Self.commandResult(sql)
    result.modifiedRows = commandModifiedRows?(sql)
    return result
  }

  /// Records `command`; the one at `failTypedAt` throws `typedError`. Inserts count their
  /// documents, admin commands 0, any other write 1, unless `typedCommandResult` is set.
  func command(_ command: MongoCommand) async throws -> CommandResult {
    let index = recordTyped(command)
    if index == failTypedAt { throw typedError }
    if let typedCommandResult { return typedCommandResult(command) }
    let rows: Int
    switch command {
    case .insertMany(_, let documents): rows = documents.count
    case .admin: rows = 0
    default: rows = 1
    }
    return CommandResult(affectedRows: rows, tag: "FAKE \(rows)")
  }

  func writeLimits() async -> MongoWriteLimits { limits }

  /// The next `command` whose SQL contains `text` throws `FakeQueryError` (once).
  func failNextCommand(containing text: String) {
    lock.lock()
    failingCommand = text
    lock.unlock()
  }

  /// Each text fails the next `command` whose SQL contains it (once each), besides
  /// `failNextCommand`.
  func failCommands(containing texts: [String]) {
    lock.lock()
    failingCommands += texts
    lock.unlock()
  }

  /// The next `query` runs `hook` (once) before it answers, e.g. to cancel meanwhile.
  func onNextQuery(_ hook: @escaping @Sendable (String) async -> Void) {
    lock.lock()
    queryHook = hook
    lock.unlock()
  }

  private func takeQueryHook() -> (@Sendable (String) async -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    let hook = queryHook
    queryHook = nil
    return hook
  }

  private func takeFailingCommand(_ sql: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let index = failingCommands.firstIndex(where: { sql.contains($0) }) {
      failingCommands.remove(at: index)
      return true
    }
    guard let text = failingCommand, sql.contains(text) else { return false }
    failingCommand = nil
    return true
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
    errorFormatter?(error) ?? error.localizedDescription
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

  /// Records `command` and returns its index.
  private func recordTyped(_ command: MongoCommand) -> Int {
    lock.lock()
    defer { lock.unlock() }
    typedRecorded.append(command)
    return typedRecorded.count - 1
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

/// The scripted failure of a `failingQuery` match.
struct FakeQueryError: Error {}

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
      supportsExplainAnalyze: false,
      supportsUpdateOnly: false,
      supportsRowStaging: true,
      supportsDataImport: true,
      supportsForeignKeyLookup: true,
      requiresPlugin: false,
      isAvailable: true,
      queryLanguage: .sql,
      supportsTransactions: true,
      supportsStructure: true,
      supportsSQLDump: true
    )
  }
}
