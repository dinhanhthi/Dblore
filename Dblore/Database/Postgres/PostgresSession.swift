// PostgresSession.swift
// One PostgreSQL connection. Owns the socket, event-loop group, TLS, connect retries,
// session-brake SQL, the close watch, and Postgres error text. The connection actor
// classifies user SQL before anything here is sent.

import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// SQL that reached the server failed. `sql` is the text that was sent (a cursor statement
/// can differ from the user's text). `underlying` is the driver error.
struct PostgresSentError: Error, @unchecked Sendable {
  let sql: String
  let underlying: any Error
}

nonisolated final class PostgresSession: DatabaseSession, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let config: ConnectionConfig
  let closeEvents: AsyncStream<SessionCloseReason>

  private let lock = NSLock()
  private var connectionStorage: PostgresConnection?
  private var groupStorage: EventLoopGroup?
  private var watchStorage: ConnectionCloseWatch?
  private var didEmitClose = false
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation

  private static let maxRetries = 3
  // 1s, 2s, 4s in nanoseconds
  private static let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

  init(config: ConnectionConfig) {
    self.config = config
    capabilities = config.databaseType.capabilities
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    lock.lock()
    let finished = didEmitClose
    lock.unlock()
    if !finished { closeContinuation.finish() }
  }

  /// Live connection, if `open()` succeeded and the session has not been detached.
  var connection: PostgresConnection? {
    lock.lock()
    defer { lock.unlock() }
    return connectionStorage
  }

  // MARK: - Open / close

  /// Connect with the same TLS settings and retries as before. Does not apply session brakes
  /// and does not publish anything to the actor. Throws the same `DatabaseError.connectionFailed`
  /// values `connect` used to throw for transport failures.
  func open() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    setGroup(group)

    let tlsConfig: PostgresConnection.Configuration.TLS
    do {
      tlsConfig = try Self.configureTLS(for: config.sslMode)
    } catch {
      try? await group.shutdownGracefully()
      setGroup(nil)
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }

    let postgresConfig = Self.postgresConfiguration(config, tls: tlsConfig)
    let conn: PostgresConnection
    do {
      conn = try await attemptConnection(
        group: group, config: postgresConfig, timeoutSeconds: config.timeoutSeconds)
    } catch let error as PSQLError {
      await AppLogger.shared.error(
        "Failed to connect to database: \(formatPostgresError(error))", category: "Database")
      try? await group.shutdownGracefully()
      setGroup(nil)
      throw DatabaseError.connectionFailed(formatPostgresError(error))
    } catch {
      try? await group.shutdownGracefully()
      setGroup(nil)
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }

    let watch = ConnectionCloseWatch(closeFuture: conn.closeFuture)
    setConnected(conn, watch: watch)
    conn.closeFuture.whenComplete { [weak self] _ in
      self?.emit(.connectionLost)
    }
  }

  /// Test connection without storing it on the actor. Same probe as before: real connect,
  /// `SELECT 1 as test`, then close. Connect and the test query share one timeout.
  func probe() async throws -> Bool {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let tlsConfig: PostgresConnection.Configuration.TLS
    do {
      tlsConfig = try Self.configureTLS(for: config.sslMode)
    } catch {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }

    let postgresConfig = Self.postgresConfiguration(config, tls: tlsConfig)
    do {
      try await withTimeout(of: .seconds(config.timeoutSeconds)) {
        try await self.probeConnectAndQuery(group: group, postgresConfig: postgresConfig)
      }
      return true
    } catch is TimeoutError {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed(
        "Connection timeout after \(config.timeoutSeconds) seconds")
    } catch let error as PSQLError {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed(formatPostgresError(error))
    } catch {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  /// Connect, run `SELECT 1 as test`, and close. `withTimeout` waits until this task finishes.
  /// PostgresNIO writes the query with `promise: nil`, so a closed channel never completes that
  /// future and cancelling the wait does not either. Resume on cancel and leave the query running.
  private func probeConnectAndQuery(
    group: MultiThreadedEventLoopGroup,
    postgresConfig: PostgresConnection.Configuration
  ) async throws {
    let gate = ProbeCancelGate<Void>()
    let work = Task {
      try await self.runProbeQuery(group: group, postgresConfig: postgresConfig)
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        gate.start(continuation)
        Task {
          let result = await work.result
          gate.resume(with: result)
        }
      }
    } onCancel: {
      work.cancel()
      gate.cancel()
    }
  }

  private func runProbeQuery(
    group: MultiThreadedEventLoopGroup,
    postgresConfig: PostgresConnection.Configuration
  ) async throws {
    let conn = try await attemptConnection(
      group: group, config: postgresConfig, timeoutSeconds: config.timeoutSeconds)
    do {
      let testQuery = PostgresQuery(unsafeSQL: "SELECT 1 as test")
      let stream = try await conn.query(testQuery, logger: Logger(label: "dblore.testquery"))
      var rowCount = 0
      for try await _ in stream {
        rowCount += 1
      }
      guard rowCount == 1 else {
        throw DatabaseError.connectionFailed("Test query returned unexpected results")
      }
    } catch {
      // The query promise fails before the channel is inactive. Deinit asserts if this
      // connection is released while the socket is still open.
      try? await conn.close()
      throw error
    }
    try await conn.close()
    try await group.shutdownGracefully()
  }

  /// Close the socket and the event-loop group. Yields `.closedByApp` when this session had
  /// not already reported a close.
  func close() async {
    emit(.closedByApp)
    let (conn, group) = takeResources()
    try? await conn?.close()
    try? await group?.shutdownGracefully()
  }

  /// Drop the socket and group without closing them. The actor closes or shuts them down.
  /// Yields `.closedByApp` so a later socket close is not reported as a loss.
  func detach() -> (connection: PostgresConnection?, group: EventLoopGroup?) {
    emit(.closedByApp)
    return takeResources()
  }

  func interrupt() async {
    try? await connection?.close()
  }

  // MARK: - Statements

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let query = Self.postgresQuery(sql, binds: binds)
    let stream = try await runWatched {
      guard let connection = self.connection else { throw ConnectionClosedError() }
      return try await connection.query(query, logger: Logger(label: "dblore"))
    }
    let columns = Self.columnInfos(stream.columns)
    let pull = RowPull(stream.makeAsyncIterator())
    let rows = AsyncThrowingStream<[CellValue], Error>(unfolding: {
      guard let row = try await pull.next() else { return nil }
      return row.makeRandomAccess().map { DatabaseConnectionManager.parseCellValue(from: $0) }
    })
    return SessionRowSource(columns: columns, rows: rows)
  }

  private static func columnInfos(_ columns: PostgresColumns) -> [ColumnInfo] {
    columns.map { column in
      ColumnInfo(
        name: column.name,
        type: DatabaseConnectionManager.postgresDataTypeName(column.dataType),
        origin: column)
    }
  }

  /// Read `sql` the way the actor's capped reader used to: stop after `maxRows` rows, or
  /// count the rest when `readToEnd` is set. One task, so a full buffer cannot drop a row.
  func readQuery(
    _ sql: String, binds: [SQLBindValue], maxRows: Int, readToEnd: Bool
  ) async throws -> CollectedRows {
    let query = Self.postgresQuery(sql, binds: binds)
    let stream = try await runWatched {
      guard let connection = self.connection else { throw ConnectionClosedError() }
      return try await connection.query(query, logger: Logger(label: "dblore"))
    }
    var collected = CollectedRows()
    for try await row in stream {
      collected.total += 1
      if collected.rows.count >= maxRows {
        collected.truncated = true
        if readToEnd { continue }
        break
      }
      let randomAccess = row.makeRandomAccess()
      if collected.total == 1 {
        for (index, cell) in randomAccess.enumerated() {
          collected.columns.append(
            ColumnInfo(
              name: cell.columnName,
              type: DatabaseConnectionManager.postgresDataTypeName(cell.dataType),
              origin: stream.columns.dropFirst(index).first))
        }
      }
      collected.rows.append(randomAccess.map { DatabaseConnectionManager.parseCellValue(from: $0) })
    }
    return collected
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    let metadata = try await commandMetadata(sql, binds: binds)
    let affected =
      StatementRoute.affectedRowCount(rows: metadata.rows, command: metadata.command) ?? 0
    return CommandResult(affectedRows: affected, tag: metadata.command)
  }

  /// Command tag for a statement whose rows are discarded. Empty `binds` uses the same
  /// `PostgresQuery` as a bind-less send.
  func commandMetadata(
    _ sql: String, binds: [SQLBindValue] = [], logLabel: String = "dblore"
  ) async throws -> PostgresQueryMetadata {
    let query = Self.postgresQuery(sql, binds: binds)
    let label = logLabel
    return try await runWatched {
      guard let connection = self.connection else { throw ConnectionClosedError() }
      return try await connection.query(query, logger: Logger(label: label)) { _ in }.get()
    }
  }

  /// Race `body` against this session's close watch.
  func runWatched<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    guard let watch = watchIfOpen() else { throw ConnectionClosedError() }
    return try await watch.run(body)
  }

  /// The close watch while the socket is still open. Synchronous so the lock stays out of
  /// an async function.
  private func watchIfOpen() -> ConnectionCloseWatch? {
    lock.lock()
    defer { lock.unlock() }
    guard let watch = watchStorage, connectionStorage?.isClosed == false else { return nil }
    return watch
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    let statements = Self.brakeStatements(
      statement: statementTimeoutSeconds, lock: lockTimeoutSeconds, idle: idleTimeoutSeconds)
    for sql in statements {
      do {
        _ = try await runWatched {
          guard let connection = self.connection else { throw ConnectionClosedError() }
          return try await connection.query(
            PostgresQuery(unsafeSQL: sql), logger: Logger(label: "dblore.session")
          ).get()
        }
      } catch let error as PSQLError {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(formatPostgresError(error))")
      } catch is ConnectionClosedError {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): the server closed the connection")
      } catch {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(error.localizedDescription)")
      }
    }
  }

  /// Best effort, after the brakes. Failure is logged; Cancel still closes the socket.
  func applyDisconnectCheck() async {
    do {
      _ = try await runWatched {
        guard let connection = self.connection else { throw ConnectionClosedError() }
        return try await connection.query(
          PostgresQuery(unsafeSQL: Self.disconnectCheckSQL),
          logger: Logger(label: "dblore.session")
        ).get()
      }
    } catch {
      await AppLogger.shared.warning(
        "client_connection_check_interval not applied (server work continues after Cancel "
          + "until its next write): \(String(describing: error))", category: "Database")
    }
  }

  func formatError(_ error: Error) -> String {
    if let error = error as? PSQLError {
      return formatPostgresError(error, query: nil)
    }
    return error.localizedDescription
  }

  /// User-facing Postgres error, including the statement-timeout brake text.
  func formatPostgresError(_ error: PSQLError, query: String? = nil) -> String {
    Self.formatPostgresError(
      error, query: query, statementTimeoutSeconds: config.statementTimeoutSeconds)
  }

  // MARK: - Brake SQL

  /// The SQL sent after every connect. Values are clamped with `SessionBrakeLimits`.
  static func brakeStatements(for config: ConnectionConfig) -> [String] {
    brakeStatements(
      statement: config.statementTimeoutSeconds, lock: config.lockTimeoutSeconds,
      idle: config.idleInTransactionTimeoutSeconds)
  }

  static func brakeStatements(statement: Int, lock: Int, idle: Int) -> [String] {
    let statement = SessionBrakeLimits.clampStatementTimeout(statement)
    let lock = SessionBrakeLimits.clampLockTimeout(lock)
    let idle = SessionBrakeLimits.clampIdleTimeout(idle)
    return [
      "SET statement_timeout = '\(statement)s'",
      "SET lock_timeout = '\(lock)s'",
      "SET idle_in_transaction_session_timeout = '\(idle)s'",
      "SET application_name = 'Dblore'",
    ]
  }

  static let disconnectCheckSQL = "SET client_connection_check_interval = '1s'"

  // MARK: - Connect helpers

  private func attemptConnection(
    group: EventLoopGroup,
    config: PostgresConnection.Configuration,
    timeoutSeconds: Int,
    attempt: Int = 0
  ) async throws -> PostgresConnection {
    do {
      let timeoutDuration = Duration.seconds(timeoutSeconds)
      let conn = try await withTimeout(of: timeoutDuration) {
        try await PostgresConnection.connect(
          on: group.next(),
          configuration: config,
          id: 1,
          logger: Logger(label: "dblore.connection")
        )
      }
      return conn
    } catch is TimeoutError {
      throw DatabaseError.connectionFailed("Connection timeout after \(timeoutSeconds) seconds")
    } catch {
      if attempt >= Self.maxRetries {
        throw error
      }
      let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
      try await Task.sleep(nanoseconds: delay)
      return try await attemptConnection(
        group: group, config: config, timeoutSeconds: timeoutSeconds, attempt: attempt + 1)
    }
  }

  private static func postgresConfiguration(
    _ config: ConnectionConfig, tls: PostgresConnection.Configuration.TLS
  ) -> PostgresConnection.Configuration {
    PostgresConnection.Configuration(
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      database: config.database,
      tls: tls
    )
  }

  private static func configureTLS(
    for sslMode: SSLMode
  ) throws
    -> PostgresConnection.Configuration
    .TLS
  {
    switch sslMode {
    case .disable:
      return .disable

    case .allow, .prefer:
      do {
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        return .prefer(context)
      } catch {
        throw DatabaseError.connectionFailed(
          "Failed to create TLS context for prefer mode: \(error.localizedDescription)")
      }

    case .require:
      do {
        let sslConfig = TLSConfiguration.makeClientConfiguration()
        let context = try NIOSSLContext(configuration: sslConfig)
        return .require(context)
      } catch {
        throw DatabaseError.connectionFailed(
          "Failed to create TLS context for require mode: \(error.localizedDescription)")
      }

    case .verifyCa, .verifyFull:
      do {
        var sslConfig = TLSConfiguration.makeClientConfiguration()
        sslConfig.certificateVerification = .fullVerification
        let context = try NIOSSLContext(configuration: sslConfig)
        return .require(context)
      } catch {
        throw DatabaseError.connectionFailed(
          "Failed to create TLS context for verify mode: \(error.localizedDescription)")
      }
    }
  }

  private static func postgresQuery(_ sql: String, binds: [SQLBindValue]) -> PostgresQuery {
    if binds.isEmpty { return PostgresQuery(unsafeSQL: sql) }
    return PostgresQuery(unsafeSQL: sql, binds: untypedTextBindings(binds))
  }

  // MARK: - Rows

  static func rowSource(_ collected: CollectedRows) -> SessionRowSource {
    let rows = collected.rows
    let stream = AsyncThrowingStream<[CellValue], Error> { continuation in
      for row in rows {
        continuation.yield(row)
      }
      continuation.finish()
    }
    return SessionRowSource(columns: collected.columns, rows: stream)
  }

  // MARK: - Close state

  private func emit(_ reason: SessionCloseReason) {
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

  private func setGroup(_ group: EventLoopGroup?) {
    lock.lock()
    groupStorage = group
    lock.unlock()
  }

  private func setConnected(_ connection: PostgresConnection, watch: ConnectionCloseWatch) {
    lock.lock()
    connectionStorage = connection
    watchStorage = watch
    lock.unlock()
  }

  /// One resume of a probe continuation. A result that wins the race with cancel is kept
  /// until `start`, so neither side resumes twice.
  private final class ProbeCancelGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<T, Error>) {
      lock.lock()
      if let pending {
        self.pending = nil
        finished = true
        lock.unlock()
        continuation.resume(with: pending)
        return
      }
      if finished {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func resume(with result: Result<T, Error>) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      guard let continuation else {
        pending = result
        lock.unlock()
        return
      }
      finished = true
      self.continuation = nil
      lock.unlock()
      continuation.resume(with: result)
    }

    func cancel() {
      lock.lock()
      if finished || pending != nil {
        lock.unlock()
        return
      }
      finished = true
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Pulls one Postgres row per consumer request, on the consumer's task, so a capped read
  /// stops the server stream where `readQuery` used to break.
  private final class RowPull: @unchecked Sendable {
    var iterator: PostgresRowSequence.AsyncIterator

    init(_ iterator: PostgresRowSequence.AsyncIterator) {
      self.iterator = iterator
    }

    func next() async throws -> PostgresRow? {
      try await iterator.next()
    }
  }

  private func takeResources() -> (connection: PostgresConnection?, group: EventLoopGroup?) {
    lock.lock()
    let forgotten = (connectionStorage, groupStorage)
    connectionStorage = nil
    groupStorage = nil
    watchStorage = nil
    lock.unlock()
    return forgotten
  }
}

/// Production sessions. Tests inject a different `DatabaseSessionFactory`.
nonisolated struct PostgresSessionFactory: DatabaseSessionFactory {
  func makeSession(config: ConnectionConfig) -> any DatabaseSession {
    PostgresSession(config: config)
  }
}
