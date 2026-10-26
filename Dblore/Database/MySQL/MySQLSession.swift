// MySQLSession.swift
// One MySQL / MariaDB connection through mysql-nio. Owns the socket, its event-loop group, TLS,
// the session pins, the brakes, KILL QUERY and the MySQL error text. The connection actor
// classifies user SQL before anything here is sent.
// - Every open (connect and every reconnect) pins the session: `SET NAMES utf8mb4`, sql_mode
//   without NO_BACKSLASH_ESCAPES / ANSI_QUOTES (the app's lexer assumes both are off) and
//   time_zone '+00:00', then reads them back and fails closed.
// - Statements without binds use the text protocol, statements with binds a prepared statement
//   (`MySQLSession+Commands.swift`); both report column headers even without rows.
// - Cancel and the row cap send `KILL QUERY <id>` from a short control connection: the
//   statement stops, the session and its transaction stay. A killed SLEEP returns 1 on MySQL
//   (1317 on MariaDB), so a statement counts as cancelled by the session's own flag.
// - A procedure that returns a result set cannot be called (1312, no multi-results flag).
// - With `sshTunnel`, every connection goes through a loopback forwarder over the SSH tunnel
//   (`MySQLSession+SSHTunnel.swift`).

import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// A MySQL error as the user reads it: `ERROR code (SQLSTATE): message`, plus a hint for the
/// cases the app knows.
nonisolated struct MySQLSessionError: Error, Equatable, Sendable, LocalizedError {
  var code: UInt16?
  var sqlState: String?
  var message: String

  var errorDescription: String? {
    guard let code else { return message }
    return "ERROR \(code) (\(sqlState ?? "HY000")): \(message)"
  }

  /// The user cancelled the statement (KILL QUERY).
  static let interrupted = MySQLSessionError(message: "The statement was cancelled.")
  static let closed = MySQLSessionError(message: "The connection to the server is closed.")

  init(code: UInt16? = nil, sqlState: String? = nil, message: String) {
    self.code = code
    self.sqlState = sqlState
    self.message = message
  }

  /// Any driver error. Server errors keep their code and SQLSTATE.
  init(_ error: any Error) {
    switch error {
    case let error as MySQLSessionError:
      self = error
    case MySQLError.server(let packet):
      self.init(
        code: packet.errorCode.rawValue, sqlState: packet.sqlState, message: packet.errorMessage)
      if packet.errorCode.rawValue == 1312 {
        message +=
          ". Dblore cannot read a result set returned by CALL: run the procedure's SELECT "
          + "directly, or call procedures that return no rows."
      }
    case MySQLError.duplicateEntry(let text):
      self.init(code: 1062, sqlState: "23000", message: text)
    case MySQLError.invalidSyntax(let text):
      self.init(code: 1064, sqlState: "42000", message: text)
    case MySQLError.closed, is ConnectionClosedError:
      self = .closed
    case MySQLError.tlsNotSupportedByServer:
      self.init(
        message:
          "The server does not support TLS, and this connection's SSL mode requires it. Turn "
          + "on SSL on the server or choose another SSL mode.")
    case MySQLError.publicKeyRetrievalNotAllowed:
      self.init(message: MySQLSession.plaintextFullAuthRefusedMessage)
    case MySQLError.unsupportedAuthPlugin(let name):
      self.init(message: MySQLSession.unsupportedAuthPluginMessage(name))
    case let error as MySQLError:
      self.init(message: error.message)
    case let error as DatabaseError:
      self.init(message: error.localizedDescription)
    default:
      self.init(message: String(describing: error))
    }
  }
}

nonisolated final class MySQLSession: DatabaseSession, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let config: ConnectionConfig
  let closeEvents: AsyncStream<SessionCloseReason>
  /// Builds the SSH tunnel when `config.sshTunnel` is set.
  let tunnelFactory: any SSHTunnelFactory
  /// Decides whether the bastion's host key is trusted.
  let hostKeyValidator: any SSHHostKeyValidating

  private let lock = NSLock()
  private var connectionStorage: MySQLConnection?
  private var groupStorage: MultiThreadedEventLoopGroup?
  private var tunnelStorage: (any SSHTunneling)?
  private var forwarderStorage: SSHLoopbackForwarder?
  /// The TLS settings and address of the open session, reused by the KILL control connection
  /// (an unremembered client certificate is only in scope while connecting). Over SSH the
  /// address is the forwarder's.
  private var tlsStorage: TLSConfiguration?
  private var addressStorage: SocketAddress?
  private var connectionID: Int?
  private var serverInfoStorage: MySQLServerInfo?
  /// The open session runs over TLS (a TLS handler in the pipeline after connect).
  private var encryptedStorage = false
  /// Statements sent and not finished, oldest first (mysql-nio runs them in order).
  private var runs: [MySQLStatementRun] = []
  /// The last statement started (sent or waiting). Each statement waits for it to finish, then
  /// for any pending kill, before it is sent: a KILL aimed at the previous statement cannot
  /// land on it, even when mysql-nio would have queued it behind that statement.
  private var lastRun: MySQLStatementRun?
  /// Statements started and not sent yet, oldest first. A cancel fails the first one before it
  /// is sent (the session cannot tell callers apart, so it cancels no other).
  private var waiting: [MySQLStatementRun] = []
  /// The last KILL QUERY (a cancel or a read left at the row cap) and the statement it stops.
  /// The next statement waits for it, so the kill cannot land on that statement; a repeated
  /// cancel of the same statement waits for it instead of opening another connection.
  private var pendingKill: (run: MySQLStatementRun, task: Task<Void, Never>)?
  private var beforeKillStorage: (@Sendable () async -> Void)?
  private var didEmitClose = false
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation

  /// sql_mode flags that change how the app's lexer must read strings and identifiers. ANSI
  /// and MariaDB's ORACLE / POSTGRESQL / MSSQL / DB2 / MAXDB modes imply ANSI_QUOTES.
  static let unpinnedSQLModes: Set<String> = [
    "NO_BACKSLASH_ESCAPES", "ANSI_QUOTES", "ANSI", "ORACLE", "POSTGRESQL", "MSSQL", "DB2",
    "MAXDB",
  ]

  init(
    config: ConnectionConfig,
    tunnelFactory: any SSHTunnelFactory = LiveSSHTunnelFactory(),
    hostKeyValidator: any SSHHostKeyValidating = RejectUnknownSSHHostKeys()
  ) {
    self.config = config
    self.tunnelFactory = tunnelFactory
    self.hostKeyValidator = hostKeyValidator
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

  /// MySQL or MariaDB and its version, once open.
  var serverInfo: MySQLServerInfo? {
    lock.withLock { serverInfoStorage }
  }

  /// How the open session is protected (nil when not open). Plaintext after Allow or Prefer fell
  /// back to plain TCP.
  var transport: MySQLTransport? {
    let (open, encrypted) = lock.withLock { (connectionStorage != nil, encryptedStorage) }
    return open ? Self.transport(sslMode: config.sslMode, isEncrypted: encrypted) : nil
  }

  private var connection: MySQLConnection? {
    lock.withLock { connectionStorage }
  }

  /// Test hook: runs before each KILL QUERY control connection opens.
  var beforeKillForTesting: (@Sendable () async -> Void)? {
    get { lock.withLock { beforeKillStorage } }
    set { lock.withLock { beforeKillStorage = newValue } }
  }

  // MARK: - Open / close

  /// Connect, check the transport against the SSL mode, then pin the session. Throws
  /// `DatabaseError.connectionFailed`. The caller closes the session after a failure.
  func open() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    lock.withLock { groupStorage = group }
    let tls: TLSConfiguration?
    do {
      tls = try Self.tlsConfiguration(
        sslMode: config.sslMode, material: try Self.clientCertificateMaterial(for: config))
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }
    let addresses =
      config.sshTunnel != nil
      ? [try await openTunnelEndpoint()]
      : try await Self.addresses(host: config.host, port: config.port)
    let (connection, address, usedTLS, encrypted) = try await connect(
      to: addresses, tls: tls, on: group.next())
    let tunnel = lock.withLock {
      connectionStorage = connection
      tlsStorage = usedTLS
      encryptedStorage = encrypted
      addressStorage = address
      return tunnelStorage
    }
    connection.channel.closeFuture.whenComplete { [weak self] _ in
      self?.emit(.connectionLost)
    }
    // Registered only once connected: a tunnel lost during the login fails the open instead.
    tunnel?.whenClosed { [weak self] in
      self?.emit(.connectionLost)
    }
    do {
      try await pinSession()
    } catch {
      throw DatabaseError.connectionFailed(
        "Could not set up the MySQL session: \(formatError(error))")
    }
  }

  /// Test connection: open (with the pins), `SELECT 1`, close (also the SSH forwarder and
  /// tunnel, on every path).
  func probe() async throws -> Bool {
    do {
      try await open()
      let source = try await query("SELECT 1", binds: [])
      var count = 0
      for try await _ in source.rows { count += 1 }
      await close()
      guard count == 1 else {
        throw DatabaseError.connectionFailed("Test query returned unexpected results")
      }
      return true
    } catch {
      await close()
      switch error {
      case is DatabaseError, is SSHTunnelError, is SSHPrivateKeyError: throw error
      default: throw DatabaseError.connectionFailed(formatError(error))
      }
    }
  }

  /// Close the socket, the SSH forwarder and tunnel (if any) and the event-loop group, in that
  /// order. Yields `.closedByApp` first.
  func close() async {
    emit(.closedByApp)
    await takeResources().close(includingConnection: true)
  }

  /// Drop the socket, forwarder, tunnel and group without closing them. The actor closes them.
  /// Yields `.closedByApp` so a later socket or tunnel close is not reported as a loss.
  func detach() -> DetachedMySQLSession {
    emit(.closedByApp)
    return takeResources()
  }

  private func takeResources() -> DetachedMySQLSession {
    lock.withLock {
      defer {
        connectionStorage = nil
        groupStorage = nil
        forwarderStorage = nil
        tunnelStorage = nil
      }
      return DetachedMySQLSession(
        connection: connectionStorage, group: groupStorage, forwarder: forwarderStorage,
        tunnel: tunnelStorage)
    }
  }

  /// The tunnel of the session being opened. `close()` closes it.
  func setTunnel(_ tunnel: any SSHTunneling) {
    lock.withLock { tunnelStorage = tunnel }
  }

  /// The forwarder of the session being opened. `close()` stops it before the tunnel.
  func setForwarder(_ forwarder: SSHLoopbackForwarder) {
    lock.withLock { forwarderStorage = forwarder }
  }

  // MARK: - Statements

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let (arriving, continuation) = AsyncThrowingStream.makeStream(
      of: [CellValue].self, throwing: Error.self, bufferingPolicy: .unbounded)
    let run = try await start(sql, binds: binds) { continuation.yield($0) }
    // The event loop holds `continuation` until the statement ends, so `arriving` never
    // reports a reader that left. The pull stream below owns the only reference to its
    // reader: when the caller drops the rows early (row cap), the reader goes away and the
    // rest is stopped on the server; the session stays.
    let reader = MySQLRowReader(arriving.makeAsyncIterator()) { [weak self] in
      self?.killAtCap(run)
    }
    let rows = AsyncThrowingStream<[CellValue], Error>(unfolding: { try await reader.next() })
    run.done.futureResult.whenComplete { result in
      switch result {
      case .success: continuation.finish()
      case .failure(let error): continuation.finish(throwing: MySQLSessionError(error))
      }
    }
    let definitions: [MySQLProtocol.ColumnDefinition41]
    do {
      definitions = try await run.header.futureResult.get()
    } catch {
      throw MySQLSessionError(error)
    }
    return SessionRowSource(columns: definitions.map(Self.columnInfo), rows: rows)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    let run = try await start(sql, binds: binds) { _ in }
    let affected: UInt64
    do {
      affected = try await run.done.futureResult.get()
    } catch {
      throw MySQLSessionError(error)
    }
    let verb =
      SQLTokenizer.tokens(sql, dialect: .mysql).first { $0.kind == .word }?.keyword ?? ""
    return CommandResult(affectedRows: Int(clamping: affected), tag: verb)
  }

  /// Whether a transaction is open on the server, from the status flags of the OK to `DO 0`
  /// (MySQL 8 has no `@@in_transaction`). `DO 0` opens no transaction.
  func isInTransaction() async throws -> Bool {
    let run = try await start("DO 0", binds: []) { _ in }
    do {
      _ = try await run.done.futureResult.get()
    } catch {
      throw MySQLSessionError(error)
    }
    return run.inTransaction
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw Self.cursorError
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw Self.cursorError
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    throw Self.cursorError
  }

  private static let cursorError = MySQLSessionError(
    message: "Server-side cursors are not supported on MySQL.")

  /// Send `sql` once the previous statement finished and any pending kill was sent. `onRow`
  /// gets each row on the event loop.
  private func start(
    _ sql: String, binds: [SQLBindValue], onRow: @escaping @Sendable ([CellValue]) -> Void
  ) async throws -> MySQLStatementRun {
    guard let connection else { throw MySQLSessionError.closed }
    let run = MySQLStatementRun(eventLoop: connection.eventLoop)
    let previous = lock.withLock {
      defer {
        lastRun = run
        waiting.append(run)
      }
      return lastRun
    }
    // A kill of `previous` is registered before it finishes (markInterrupted / markKilledAtCap
    // need it unfinished), so it is pending once `done` completes.
    _ = try? await previous?.done.futureResult.get()
    if let kill = lock.withLock({ pendingKill?.task }) { await kill.value }
    // Under the lock, so a cancel either fails `run` here or finds it among `runs`.
    let failure = lock.withLock { () -> MySQLSessionError? in
      waiting.removeAll { $0 === run }
      if run.isInterrupted { return .interrupted }
      guard connection.channel.isActive else { return .closed }
      runs.append(run)
      return nil
    }
    if let failure {
      run.complete(.failure(failure))
      throw failure
    }
    let callbacks = MySQLStatementCallbacks(
      columns: { run.header.succeed($0) },
      row: { onRow(MySQLValueConverter.cells($0)) },
      ok: { run.setOK($0) })
    let command: any MySQLCommand =
      binds.isEmpty
      ? MySQLTextQuery(sql: sql, callbacks: callbacks)
      : MySQLPreparedQuery(sql: sql, binds: binds, callbacks: callbacks)
    connection.send(command, logger: connection.logger).whenComplete { [weak self] result in
      self?.forget(run)
      run.complete(result)
    }
    return run
  }

  private func forget(_ run: MySQLStatementRun) {
    lock.withLock { runs.removeAll { $0 === run } }
  }

  // MARK: - Pins and brakes

  /// utf8mb4, sql_mode without the lexer-changing flags, UTC; read back, fail closed.
  private func pinSession() async throws {
    _ = try await command("SET NAMES utf8mb4", binds: [])
    let current = try await firstRow(
      "SELECT VERSION(), CONNECTION_ID(), @@SESSION.sql_mode, @@SESSION.max_allowed_packet")
    guard current.count == 4, case .string(let version) = current[0],
      var info = MySQLServerInfo(version: version), case .int(let id) = current[1],
      case .string(let mode) = current[2]
    else { throw MySQLSessionError(message: "Unexpected answer to the session setup query.") }
    // Import chunks stay under it (`ImportSQLBuilder.mysqlChunkByteCap`).
    if case .int(let packet) = current[3] { info.maxAllowedPacket = packet }
    let pinned = Self.pinnedSQLMode(mode)
    guard pinned.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "," }) else {
      throw MySQLSessionError(message: "Unexpected sql_mode '\(mode)'.")
    }
    _ = try await command(
      "SET SESSION sql_mode = '\(pinned)', time_zone = '+00:00'", binds: [])
    let check = try await firstRow(
      """
      SELECT @@SESSION.sql_mode, @@character_set_client, @@character_set_connection,
        @@character_set_results, @@SESSION.time_zone
      """)
    let utf8 = CellValue.string("utf8mb4")
    guard check.count == 5, case .string(let applied) = check[0],
      Self.pinnedSQLMode(applied) == applied, Array(check[1...3]) == [utf8, utf8, utf8],
      check[4] == .string("+00:00")
    else {
      throw MySQLSessionError(
        message: "The server did not keep the session settings (sql_mode, utf8mb4, time_zone).")
    }
    lock.withLock {
      serverInfoStorage = info
      connectionID = id
    }
  }

  /// `mode` without the flags in `unpinnedSQLModes`.
  static func pinnedSQLMode(_ mode: String) -> String {
    mode.split(separator: ",").filter { !unpinnedSQLModes.contains(String($0)) }
      .joined(separator: ",")
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    guard let info = serverInfo else { throw DatabaseError.notConnected }
    let statements = Self.brakeStatements(
      info: info, statement: statementTimeoutSeconds, lock: lockTimeoutSeconds,
      idle: idleTimeoutSeconds)
    for sql in statements {
      do {
        _ = try await command(sql, binds: [])
      } catch {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(formatError(error))")
      }
    }
  }

  /// The statement timeout (milliseconds on MySQL, where it stops only SELECT; seconds on
  /// MariaDB), the row-lock and metadata-lock waits, and the idle timeout of the connection.
  static func brakeStatements(
    info: MySQLServerInfo, statement: Int, lock: Int, idle: Int
  ) -> [String] {
    let statement = SessionBrakeLimits.clampStatementTimeout(statement)
    let lock = SessionBrakeLimits.clampLockTimeout(lock)
    let idle = SessionBrakeLimits.clampIdleTimeout(idle)
    return [
      "SET SESSION \(info.statementTimeoutVariable) = "
        + "\(info.statementTimeoutValue(seconds: statement))",
      "SET SESSION innodb_lock_wait_timeout = \(lock)",
      "SET SESSION lock_wait_timeout = \(lock)",
      "SET SESSION wait_timeout = \(idle)",
    ]
  }

  // MARK: - KILL QUERY

  /// Cancel: KILL QUERY on the oldest running statement, and the first statement waiting to be
  /// sent fails without reaching the server. Both fail with `MySQLSessionError.interrupted`,
  /// whatever the server answered.
  func interrupt() async {
    let kill = lock.withLock { () -> Task<Void, Never>? in
      _ = waiting.first?.markInterrupted()
      guard let run = runs.first, run.markInterrupted() else { return nil }
      if let pendingKill, pendingKill.run === run { return pendingKill.task }
      return scheduleKill(of: run)
    }
    await kill?.value
  }

  /// The reader stopped at the cap while `run` still streams: kill it, drop its rows.
  private func killAtCap(_ run: MySQLStatementRun) {
    lock.withLock {
      guard run.markKilledAtCap() else { return }
      _ = scheduleKill(of: run)
    }
  }

  /// Starts the KILL QUERY of `run` as the pending kill, cleared once sent (a later cancel may
  /// retry a kill that failed). Call with `lock` held.
  private func scheduleKill(of run: MySQLStatementRun) -> Task<Void, Never> {
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await killRunningStatement(run)
      lock.withLock { if pendingKill?.run === run { pendingKill = nil } }
    }
    pendingKill = (run, task)
    return task
  }

  /// Whether `run` is still the statement the server runs, so KILL QUERY stops it and no other.
  private func isRunning(_ run: MySQLStatementRun) -> Bool {
    lock.withLock { runs.first === run && !run.isFinished }
  }

  private func killRunningStatement(_ run: MySQLStatementRun) async {
    let (id, open, tls, address, forwarder) = lock.withLock {
      (connectionID, connectionStorage != nil, tlsStorage, addressStorage, forwarderStorage)
    }
    guard let id, open, let address else { return }
    let dial = {
      if let hook = self.beforeKillForTesting { await hook() }
      // Not the session's own loop: it may be busy decoding the rows this kill should stop.
      return try await Self.connect(
        to: address, config: self.config, tls: tls,
        on: MultiThreadedEventLoopGroup.singleton.next(), forwarder: forwarder)
    }
    do {
      // Over SSH, never dial a stopped forwarder's port (any local process may hold it by then,
      // and the login carries the user's credentials).
      let control: MySQLConnection
      if let forwarder {
        guard let dialed = try await forwarder.whileListening(dial) else { return }
        control = dialed
      } else {
        control = try await dial()
      }
      do {
        // It may have finished while the control connection opened: skip the KILL.
        if isRunning(run) { _ = try await control.simpleQuery("KILL QUERY \(id)").get() }
      } catch {
        await AppLogger.shared.warning(
          "KILL QUERY failed: \(formatError(error))", category: "Database")
      }
      try? await control.close().get()
    } catch {
      await AppLogger.shared.warning(
        "KILL QUERY control connection failed: \(formatError(error))", category: "Database")
    }
  }

  // MARK: - Errors

  func formatError(_ error: Error) -> String {
    if let error = error as? DatabaseError { return error.localizedDescription }
    let mapped = MySQLSessionError(error)
    guard mapped.code == 3024 || mapped.code == 1969 else {
      return mapped.errorDescription ?? mapped.message
    }
    let seconds = SessionBrakeLimits.clampStatementTimeout(
      config.statementTimeoutSeconds ?? SessionBrakeLimits.defaultStatementTimeout)
    return "Statement timed out after \(seconds)s (ERROR \(mapped.code ?? 0)) — change it in "
      + "the connection's Safety settings"
  }

  // MARK: - Connect helpers

  /// Every address of the host (or the SSH forwarder) in turn, until one accepts the TCP
  /// connection. Login and TLS failures are not retried, except that Allow and Prefer reconnect
  /// without TLS to a server that does not offer it. Returns the TLS settings the connection
  /// used and whether it is encrypted.
  private func connect(
    to addresses: [SocketAddress], tls: TLSConfiguration?, on loop: any EventLoop
  ) async throws -> (MySQLConnection, SocketAddress, TLSConfiguration?, Bool) {
    var lastError: (any Error)?
    let forwarder = lock.withLock { forwarderStorage }
    for address in addresses {
      let connection: MySQLConnection
      var usedTLS = tls
      do {
        do {
          connection = try await Self.connect(
            to: address, config: config, tls: tls, on: loop, forwarder: forwarder)
        } catch MySQLError.tlsNotSupportedByServer
          where tls != nil && Self.mayFallBack(config.sslMode)
        {
          usedTLS = nil
          connection = try await Self.connect(
            to: address, config: config, tls: nil, on: loop, forwarder: forwarder)
        }
      } catch let error as SSHTunnelError {
        // Typed like the bastion's own errors, so it reads as it does for PostgreSQL.
        throw error
      } catch {
        lastError = error
        if Self.isTransportError(error) { continue }
        throw DatabaseError.connectionFailed(Self.connectMessage(error))
      }
      let encrypted = await Self.isEncrypted(connection)
      do {
        try Self.checkTransport(sslMode: config.sslMode, isEncrypted: encrypted)
      } catch {
        try? await connection.close().get()
        throw error
      }
      return (connection, address, usedTLS, encrypted)
    }
    throw DatabaseError.connectionFailed(
      lastError.map { Self.connectMessage($0) }
        ?? "Could not resolve host \(config.host)")
  }

  /// One handshake, bounded by the connection timeout. A connection that completes after the
  /// timeout is closed. TLS checks `config.host`, whatever `address` is (the SSH forwarder's
  /// loopback address included). The bootstrap sets what mysql-nio's `connect(to:)` sets, and
  /// adds the full-authentication guard in front of the handlers the login appends. Through
  /// `forwarder`, a connection closed because the bastion refused its tunnel channel fails with
  /// that refusal instead of the login's own error.
  static func connect(
    to address: SocketAddress, config: ConnectionConfig, tls: TLSConfiguration?,
    on loop: any EventLoop, forwarder: SSHLoopbackForwarder?
  ) async throws -> MySQLConnection {
    let result = loop.makePromise(of: MySQLConnection.self)
    let seconds = config.timeoutSeconds
    let timer = loop.scheduleTask(in: .seconds(Int64(seconds))) {
      result.fail(DatabaseError.connectionFailed("Connection timeout after \(seconds) seconds"))
    }
    let refusal = FullAuthRefusal()
    let armed = armsFullAuthGuard(
      tlsMode: config.sslMode, host: config.host, usesSSH: config.sshTunnel != nil)
    ClientBootstrap(group: loop)
      .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            MySQLFullAuthGuard(armed: armed, refusal: refusal))
        }
      }
      .connect(to: address)
      // On the channel's loop as the connect completes, before the greeting is read.
      .flatMap { channel in
        // Read while connected: a closed channel no longer has its address.
        let clientPort = channel.localAddress?.port
        return login(over: channel, config: config, tls: tls, refusal: refusal)
          .flatMapErrorThrowing { error in
            // The bastion's refusal wins over whatever error the closed channel gave the login.
            guard let forwarder, let openError = forwarder.takeOpenError(clientPort: clientPort)
            else { throw error }
            throw openError
          }
      }
      .whenComplete { outcome in
        timer.cancel()
        switch outcome {
        case .success(let connection):
          result.futureResult.whenFailure { _ in _ = connection.close() }
          result.succeed(connection)
        case .failure(let error):
          result.fail(error)
        }
      }
    return try await result.futureResult.get()
  }

  /// The login over `channel`, whose pipeline holds the full-authentication guard. Call it on
  /// the channel's event loop before any data arrives. Disarms the guard once the login
  /// succeeded, before the connection is returned (so before any command); a refused login
  /// fails with the refusal's text instead of mysql-nio's `.closed`.
  static func login(
    over channel: any Channel, config: ConnectionConfig, tls: TLSConfiguration?,
    refusal: FullAuthRefusal
  ) -> EventLoopFuture<MySQLConnection> {
    MySQLConnection.connect(
      over: channel, username: config.username, database: config.database,
      password: config.password, tlsConfiguration: tls,
      serverHostname: tls == nil ? nil : serverHostname(for: config.host),
      // Never fetch the server's RSA key over plain TCP: after a stripped-TLS fallback the key
      // could be the attacker's. The guard's allow-list relies on this, and an armed guard
      // would block an RSA key retrieval opt-in over plain TCP.
      allowPublicKeyRetrieval: false,
      logger: Logger(label: "dblore.mysql")
    )
    .flatMapThrowing { connection in
      do {
        try channel.pipeline.syncOperations.handler(type: MySQLFullAuthGuard.self).disarm()
      } catch {
        channel.close(promise: nil)
        throw error
      }
      return connection
    }
    .flatMapErrorThrowing { error in
      // The guard closed the channel, so mysql-nio reports `.closed`: say what the server asked.
      guard let reason = refusal.reason else { throw error }
      throw MySQLSessionError(message: loginRefusalMessage(reason))
    }
  }

  /// The host's addresses (getaddrinfo off the cooperative pool), IP literals as they are.
  private static func addresses(host: String, port: Int) async throws -> [SocketAddress] {
    if let address = try? SocketAddress(ipAddress: host, port: port) { return [address] }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try resolve(host: host, port: port) })
      }
    }
  }

  private static func resolve(host: String, port: Int) throws -> [SocketAddress] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &list)
    guard status == 0, let first = list else {
      throw DatabaseError.connectionFailed(
        "Could not resolve host \(host): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(first) }
    var addresses: [SocketAddress] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
      cursor = info.pointee.ai_next
      guard let raw = info.pointee.ai_addr else { continue }
      let address: SocketAddress
      switch info.pointee.ai_family {
      case AF_INET:
        address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          SocketAddress($0.pointee, host: host)
        }
      case AF_INET6:
        address = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          SocketAddress($0.pointee, host: host)
        }
      default:
        continue
      }
      if !addresses.contains(address) { addresses.append(address) }
    }
    return addresses
  }

  /// The TCP connection itself failed (refused, unreachable): try the next address.
  private static func isTransportError(_ error: any Error) -> Bool {
    error is NIOConnectionError || error is IOError || error is ChannelError
  }

  /// Connect error text.
  private static func connectMessage(_ error: any Error) -> String {
    if let error = error as? DatabaseError { return error.localizedDescription }
    let mapped = MySQLSessionError(error)
    return mapped.errorDescription ?? mapped.message
  }

  // MARK: - Rows

  private func firstRow(_ sql: String) async throws -> [CellValue] {
    let source = try await query(sql, binds: [])
    var first: [CellValue]?
    for try await row in source.rows where first == nil { first = row }
    return first ?? []
  }

  /// The source names when the column reads a table column (empty `org_table` for an
  /// expression). The manager resolves them to an origin (`resolveMySQLOrigins`).
  private static func columnInfo(_ column: MySQLProtocol.ColumnDefinition41) -> ColumnInfo {
    let source =
      column.orgTable.isEmpty || column.orgName.isEmpty || column.schema.isEmpty
      ? nil
      : ColumnSourceName(schema: column.schema, table: column.orgTable, column: column.orgName)
    return ColumnInfo(name: column.name, type: typeName(column), sourceName: source)
  }

  /// MySQL type name of a result column. Binary character set (63) marks byte strings.
  static func typeName(_ column: MySQLProtocol.ColumnDefinition41) -> String {
    let binary = column.characterSet == .binary
    return switch column.columnType {
    case .tiny: "TINYINT"
    case .short: "SMALLINT"
    case .int24: "MEDIUMINT"
    case .long: "INT"
    case .longlong: "BIGINT"
    case .float: "FLOAT"
    case .double: "DOUBLE"
    case .decimal, .newdecimal: "DECIMAL"
    case .date, .newdate: "DATE"
    case .datetime, .datetime2: "DATETIME"
    case .timestamp, .timestamp2: "TIMESTAMP"
    case .time, .time2: "TIME"
    case .year: "YEAR"
    case .bit: "BIT"
    case .json: "JSON"
    case .geometry: "GEOMETRY"
    case .enum: "ENUM"
    case .set: "SET"
    case .tinyBlob, .mediumBlob, .longBlob, .blob: binary ? "BLOB" : "TEXT"
    case .varchar, .varString: binary ? "VARBINARY" : "VARCHAR"
    case .string: binary ? "BINARY" : "CHAR"
    default: "TEXT"
    }
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
}

/// Pulls the rows of one statement for its caller. Dropped before the end of the rows (the
/// caller stopped at the cap, or never read), it calls `onAbandon`.
nonisolated final class MySQLRowReader: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<[CellValue], Error>.AsyncIterator
  private var finished = false
  private let onAbandon: @Sendable () -> Void

  init(
    _ iterator: AsyncThrowingStream<[CellValue], Error>.AsyncIterator,
    onAbandon: @escaping @Sendable () -> Void
  ) {
    self.iterator = iterator
    self.onAbandon = onAbandon
  }

  deinit {
    if !finished { onAbandon() }
  }

  /// Rows are pulled one at a time by one consumer, so `iterator` needs no lock.
  func next() async throws -> [CellValue]? {
    do {
      let row = try await iterator.next()
      if row == nil { finished = true }
      return row
    } catch {
      finished = true
      throw error
    }
  }
}

/// One statement in flight: its header (columns) and outcome (affected rows), plus whether
/// cancel or the row cap killed it.
nonisolated final class MySQLStatementRun: @unchecked Sendable {
  let header: EventLoopPromise<[MySQLProtocol.ColumnDefinition41]>
  let done: EventLoopPromise<UInt64>
  private let lock = NSLock()
  private var finished = false
  private var interrupted = false
  private var killedAtCap = false
  private var affectedRows: UInt64 = 0
  private var inTransactionStorage = false

  init(eventLoop: any EventLoop) {
    header = eventLoop.makePromise()
    done = eventLoop.makePromise()
  }

  func setOK(_ ok: MySQLProtocol.OK_Packet) {
    lock.withLock {
      affectedRows = ok.affectedRows
      inTransactionStorage = ok.statusFlags.contains(.SERVER_STATUS_IN_TRANS)
    }
  }

  /// SERVER_STATUS_IN_TRANS of the statement's OK: a transaction is open on the server.
  var inTransaction: Bool {
    lock.withLock { inTransactionStorage }
  }

  var isFinished: Bool {
    lock.withLock { finished }
  }

  var isInterrupted: Bool {
    lock.withLock { interrupted }
  }

  /// True when the statement still runs, so a KILL is due.
  func markInterrupted() -> Bool {
    lock.withLock {
      guard !finished else { return false }
      interrupted = true
      return true
    }
  }

  /// True the first time, while the statement still runs.
  func markKilledAtCap() -> Bool {
    lock.withLock {
      guard !finished, !killedAtCap, !interrupted else { return false }
      killedAtCap = true
      return true
    }
  }

  /// A cancelled statement fails with `interrupted` even when the server finished it (a killed
  /// SLEEP returns 1 on MySQL). The cap's 1317 is the expected end of a read nobody reads.
  func complete(_ result: Result<Void, any Error>) {
    let (interrupted, capped, affected) = lock.withLock {
      finished = true
      return (self.interrupted, killedAtCap, affectedRows)
    }
    let outcome: Result<UInt64, any Error>
    switch result {
    case _ where interrupted:
      outcome = .failure(MySQLSessionError.interrupted)
    case .success:
      outcome = .success(affected)
    case .failure(let error):
      outcome =
        capped && MySQLSessionError(error).code == 1317 ? .success(affected) : .failure(error)
    }
    header.completeWith(outcome.map { _ in [] })
    done.completeWith(outcome)
  }
}
