// FakeDatabaseSession.swift
// In-memory session for contract tests. Scripts rows, errors, close events, slow queries and
// PostgreSQL's side-connection cancel (pid, answer, statements in flight).
// It cannot bypass the actor's gate: user SQL reaches here only after the actor allows it.

import Foundation

@testable import Dblore

/// The columns and rows a fake `query` answers with in place of the scripted ones.
struct FakeQueryAnswer: Sendable {
  typealias Script = @Sendable (_ sql: String, _ binds: [SQLBindValue]) -> FakeQueryAnswer?

  var columns: [ColumnInfo]
  var rows: [[CellValue]]
}

/// Builds one fake session per `makeSession`. Each connect / reconnect gets its own session.
final class FakeDatabaseSessionFactory: DatabaseSessionFactory, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let columns: [ColumnInfo]
  let rows: [[CellValue]]
  let slowQueries: Bool
  /// A `query` whose SQL contains this text throws `failingQueryError`.
  let failingQuery: String?
  let failingQueryError: any Error
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
  /// Answers a `query` (or a cursor's `fetch`, by the cursor's query) in place of `columns` /
  /// `rows` when it returns non-nil (an app catalog read, by its SQL and binds).
  let queryAnswer: FakeQueryAnswer.Script?

  private let lock = NSLock()
  private var made: [FakeDatabaseSession] = []
  private var madeConfigs: [ConnectionConfig] = []

  init(
    capabilities: DatabaseCapabilities, columns: [ColumnInfo] = [], rows: [[CellValue]] = [],
    slowQueries: Bool = false, failingQuery: String? = nil, openError: (any Error)? = nil,
    errorFormatter: (@Sendable (any Error) -> String)? = nil,
    commandRows: (@Sendable (String) -> Int?)? = nil,
    commandModifiedRows: (@Sendable (String) -> Int?)? = nil,
    typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)? = nil,
    failTypedAt: Int? = nil, typedError: any Error = FakeQueryError(),
    writeLimits: MongoWriteLimits = .fallback, queryAnswer: FakeQueryAnswer.Script? = nil,
    failingQueryError: any Error = FakeQueryError()
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
    self.failingQuery = failingQuery
    self.failingQueryError = failingQueryError
    self.openError = openError
    self.errorFormatter = errorFormatter
    self.commandRows = commandRows
    self.commandModifiedRows = commandModifiedRows
    self.typedCommandResult = typedCommandResult
    self.failTypedAt = failTypedAt
    self.typedError = typedError
    self.writeLimits = writeLimits
    self.queryAnswer = queryAnswer
  }

  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    let session = FakeDatabaseSession(
      capabilities: capabilities, columns: columns, rows: rows, slowQueries: slowQueries,
      failingQuery: failingQuery, openError: openError, errorFormatter: errorFormatter,
      commandRows: commandRows, commandModifiedRows: commandModifiedRows,
      typedCommandResult: typedCommandResult, failTypedAt: failTypedAt, typedError: typedError,
      writeLimits: writeLimits, queryAnswer: queryAnswer, failingQueryError: failingQueryError)
    lock.lock()
    made.append(session)
    madeConfigs.append(config)
    lock.unlock()
    return session
  }

  /// The config of each session made, in order.
  var configs: [ConnectionConfig] {
    lock.lock()
    defer { lock.unlock() }
    return madeConfigs
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
  private let failingQueryError: any Error
  private let openError: (any Error)?
  private let errorFormatter: (@Sendable (any Error) -> String)?
  private let commandRows: (@Sendable (String) -> Int?)?
  private let commandModifiedRows: (@Sendable (String) -> Int?)?
  private let typedCommandResult: (@Sendable (MongoCommand) -> CommandResult)?
  private let failTypedAt: Int?
  private let typedError: any Error
  private let limits: MongoWriteLimits
  private let queryAnswer: FakeQueryAnswer.Script?
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation
  private let lock = NSLock()
  private var recorded: [String] = []
  /// SQL and binds of the open cursor, which `fetch` answers through `queryAnswer`
  private var cursorQuery: (sql: String, binds: [SQLBindValue])?
  /// Rows of the open cursor already fetched: each `fetch` answers the next `maxRows`
  private var cursorOffset = 0
  private var recordedBinds: [[SQLBindValue]] = []
  private var queriesRecorded: [String] = []
  private var typedRecorded: [MongoCommand] = []
  private var didEmitClose = false
  /// Slow reads waiting for `interrupt`, which ends them all
  private var slowContinuations: [CheckedContinuation<Void, Error>] = []
  private var interruptReport: (@Sendable () async -> Bool?)?
  /// `prepareCancelBackend` / `cancelBackend`: the pid read at connect (nil: never read) and
  /// what the server answers
  private var cancelPID: Int32? = 1
  private var cancelResult: @Sendable () async -> Bool = { true }
  private var cancelTargetsSeen: [CancelBackendTarget] = []
  /// `brakeFlavor`: nil (every brake) unless a test marks the server as verified Redshift
  private var brakeFlavorStorage: DatabaseFlavor?
  /// `query` / `command` calls that have not answered yet, oldest first
  private var inFlight: [(token: UInt64, sql: String)] = []
  private var nextToken: UInt64 = 0
  /// `interrupt` leaves the slow reads waiting until `releaseSlowReads` (see
  /// `holdSlowReadsOnInterrupt`)
  private var interruptHolds = false
  /// Only reads whose SQL contains this text are slow (every read when nil)
  private var slowOnly: String?
  /// The next `command` containing this text waits in `heldCommands` (`holdNextCommand`)
  private var commandHold: String?
  private var heldCommands: [CheckedContinuation<Void, Never>] = []
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var queryDidStart = false
  private var failingCommand: String?
  private var failingCommands: [String] = []
  /// The next `command` containing `text` answers with `tag` (`tagNextCommand`)
  private var scriptedTag: (text: String, tag: String)?
  private var queryHook: (@Sendable (String) async -> Void)?

  private(set) var didOpen = false
  private(set) var didClose = false
  private(set) var interruptCount = 0
  private(set) var cancelBackendCount = 0
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
    writeLimits: MongoWriteLimits = .fallback, queryAnswer: FakeQueryAnswer.Script? = nil,
    failingQueryError: any Error = FakeQueryError()
  ) {
    self.capabilities = capabilities
    self.columns = columns
    self.rows = rows
    self.slowQueries = slowQueries
    self.failingQuery = failingQuery
    self.failingQueryError = failingQueryError
    self.openError = openError
    self.errorFormatter = errorFormatter
    self.commandRows = commandRows
    self.commandModifiedRows = commandModifiedRows
    self.typedCommandResult = typedCommandResult
    self.failTypedAt = failTypedAt
    self.typedError = typedError
    limits = writeLimits
    self.queryAnswer = queryAnswer
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
    let token = beginInFlight(sql)
    defer { endInFlight(token) }
    if let hook = takeQueryHook() { await hook(sql) }
    if let failingQuery, sql.contains(failingQuery) { throw failingQueryError }
    // A PostgreSQL restore's own search_path read, like a control statement: never slow,
    // the server's default path unless `queryAnswer` scripts it
    if sql == DatabaseConnectionManager.SearchPathPin.readSQL {
      if let answer = queryAnswer?(sql, binds) {
        return Self.rowSource(columns: answer.columns, rows: answer.rows)
      }
      return Self.rowSource(
        columns: [ColumnInfo(name: "current_setting", type: "text")],
        rows: [[.string("\"$user\", public")]])
    }
    if slowQueries, lock.withLock({ slowOnly.map { sql.contains($0) } ?? true }) {
      try await waitUntilInterrupted()
    }
    if let answer = queryAnswer?(sql, binds) {
      return Self.rowSource(columns: answer.columns, rows: answer.rows)
    }
    return rowSource()
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    record(sql, binds: binds, query: false)
    let token = beginInFlight(sql)
    defer { endInFlight(token) }
    if takeCommandHold(sql) {
      await withCheckedContinuation { wait in lock.withLock { heldCommands.append(wait) } }
    }
    if takeFailingCommand(sql) { throw FakeQueryError() }
    if let tag = takeScriptedTag(sql) { return CommandResult(affectedRows: 0, tag: tag) }
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

  /// The next `command` whose SQL contains `text` answers with `tag` (once), e.g. a PostgreSQL
  /// COMMIT of an aborted transaction answering ROLLBACK
  func tagNextCommand(containing text: String, as tag: String) {
    lock.withLock { scriptedTag = (text, tag) }
  }

  private func takeScriptedTag(_ sql: String) -> String? {
    lock.withLock {
      guard let scripted = scriptedTag, sql.contains(scripted.text) else { return nil }
      scriptedTag = nil
      return scripted.tag
    }
  }

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

  /// From now on only reads whose SQL contains `text` are slow (with `slowQueries`)
  func slowReads(containing text: String) {
    lock.withLock { slowOnly = text }
  }

  /// The next `command` whose SQL contains `text` is recorded, then waits until
  /// `releaseHeldCommands`, like a statement queued behind the running one
  func holdNextCommand(containing text: String) {
    lock.withLock { commandHold = text }
  }

  /// Commands `holdNextCommand` left waiting
  var heldCommandCount: Int {
    lock.withLock { heldCommands.count }
  }

  /// Lets the held commands answer
  func releaseHeldCommands() {
    let held = lock.withLock {
      let held = heldCommands
      heldCommands = []
      return held
    }
    for wait in held { wait.resume() }
  }

  private func takeCommandHold(_ sql: String) -> Bool {
    lock.withLock {
      guard let text = commandHold, sql.contains(text) else { return false }
      commandHold = nil
      return true
    }
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
    lock.withLock {
      cursorQuery = (sql, binds)
      cursorOffset = 0
    }
    return SessionCursor(name: "fake_cap")
  }

  /// The next `maxRows` rows of the open cursor, as a server's FETCH answers
  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    record("FETCH \(maxRows)", query: false)
    noteFetch(maxRows)
    var columns = self.columns
    var rows = self.rows
    if let query = lock.withLock({ cursorQuery }), let answer = queryAnswer?(query.sql, query.binds)
    {
      (columns, rows) = (answer.columns, answer.rows)
    }
    let start = lock.withLock {
      let start = min(cursorOffset, rows.count)
      cursorOffset = min(start + maxRows, rows.count)
      return start
    }
    return Self.rowSource(
      columns: columns, rows: Array(rows[start..<min(start + maxRows, rows.count)]))
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    record("CLOSE \(cursor.name)", query: false)
    noteCloseCursor()
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {}

  func interrupt() async {
    lock.withLock { interruptCount += 1 }
    stopSlowReads()
  }

  /// PostgreSQL's side-connection cancel: nil without a pid or with nothing in flight, else the
  /// oldest statement in flight
  func prepareCancelBackend() -> CancelBackendTarget? {
    lock.withLock {
      guard let pid = cancelPID, let oldest = inFlight.first else { return nil }
      return CancelBackendTarget(
        pid: pid, backendStart: "fake", statement: oldest.sql, token: oldest.token)
    }
  }

  func runningStatementToken() -> UInt64? {
    lock.withLock { inFlight.first?.token }
  }

  func statementInFlight(_ token: UInt64) -> Bool {
    lock.withLock { inFlight.contains { $0.token == token } }
  }

  /// The scripted answer; true stops the slow reads as `interrupt` does
  func cancelBackend(_ target: CancelBackendTarget) async -> Bool {
    let result = lock.withLock {
      cancelBackendCount += 1
      cancelTargetsSeen.append(target)
      return cancelResult
    }
    guard await result() else { return false }
    stopSlowReads()
    return true
  }

  /// What each `cancelBackend` was asked to match, in order
  var cancelTargets: [CancelBackendTarget] {
    lock.withLock { cancelTargetsSeen }
  }

  /// What `prepareCancelBackend` sees and `cancelBackend` answers (default: pid 1,
  /// cancelled). `result` runs in the caller's task, so it sees its task-local values
  func scriptCancelBackend(pid: Int32?, result: @escaping @Sendable () async -> Bool) {
    lock.withLock {
      cancelPID = pid
      cancelResult = result
    }
  }

  var brakeFlavor: DatabaseFlavor? {
    get { lock.withLock { brakeFlavorStorage } }
    set { lock.withLock { brakeFlavorStorage = newValue } }
  }

  /// Ends the slow reads, unless `holdSlowReadsOnInterrupt` keeps them waiting
  private func stopSlowReads() {
    guard !lock.withLock({ interruptHolds }) else { return }
    for pending in takeSlowWaits() { pending.resume(throwing: CancellationError()) }
  }

  /// Later interrupts leave the slow reads waiting, like an engine still unwinding the
  /// statement: they end only with `releaseSlowReads`
  func holdSlowReadsOnInterrupt() {
    lock.withLock { interruptHolds = true }
  }

  /// Ends the slow reads an interrupt left waiting, as the interrupt would have
  func releaseSlowReads() {
    let pending = lock.withLock {
      let pending = slowContinuations
      slowContinuations = []
      return pending
    }
    for wait in pending { wait.resume(throwing: CancellationError()) }
  }

  /// What `transactionOpenAfterInterrupt` answers (nil until set: the session cannot tell)
  func reportAfterInterrupt(_ body: @escaping @Sendable () async -> Bool?) {
    lock.withLock { interruptReport = body }
  }

  func transactionOpenAfterInterrupt() async -> Bool? {
    guard let report = lock.withLock({ interruptReport }) else { return nil }
    return await report()
  }

  /// Slow reads waiting for `interrupt`
  var slowQueryCount: Int {
    lock.withLock { slowContinuations.count }
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
    slowContinuations.append(cont)
    queryDidStart = true
    let started = startedContinuation
    startedContinuation = nil
    lock.unlock()
    return started
  }

  private func takeSlowWaits() -> [CheckedContinuation<Void, Error>] {
    lock.lock()
    let pending = slowContinuations
    slowContinuations = []
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

  private func beginInFlight(_ sql: String) -> UInt64 {
    lock.withLock {
      nextToken &+= 1
      inFlight.append((token: nextToken, sql: sql))
      return nextToken
    }
  }

  private func endInFlight(_ token: UInt64) {
    lock.withLock { inFlight.removeAll { $0.token == token } }
  }

  /// Records `command` and returns its index.
  private func recordTyped(_ command: MongoCommand) -> Int {
    lock.lock()
    defer { lock.unlock() }
    typedRecorded.append(command)
    return typedRecorded.count - 1
  }

  private func rowSource() -> SessionRowSource {
    Self.rowSource(columns: columns, rows: rows)
  }

  private static func rowSource(columns: [ColumnInfo], rows: [[CellValue]]) -> SessionRowSource {
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
      supportsDefaultInUpdate: false,
      supportsRowStaging: true,
      supportsDataImport: true,
      supportsForeignKeyLookup: true,
      requiresPlugin: false,
      isAvailable: true,
      queryLanguage: .sql,
      supportsTransactions: true,
      supportsStructure: true,
      supportsSQLDump: true,
      supportsUserTypes: false
    )
  }
}
