// EnginePluginSession.swift
// One connection to a database engine plugin (protocol v1) through its runtime's router. The
// core keeps the SSH tunnel and its loopback forwarder, the SSL mode and CA, credit and cancel;
// the plugin speaks the engine's wire protocol.
// - `open` loads the plugin (handshake) then sends `open`, the only request with the password,
//   under the session timeout (plus a margin, so the plugin's own connect error comes first).
//   Request JSON is never logged.
// - `query` pulls: `more` is sent once per consumed `rows` event, `cancel` after a stream
//   failure or when the caller drops the rows early (row cap). Queries and commands have no
//   deadline; the statement brakes bound them.
// - `close` cancels what still runs, lets go of the close stream (so the answer is not a loss),
//   sends `close` and waits up to `closeTimeout` for its answer (not at all after a loss or a
//   failed open), fails what still waits with `connectionClosed`, then stops the forwarder and
//   the tunnel whatever the answer.
// - A plugin message has the password replaced before it is shown or logged (`redacting`):
//   a server error may echo it.

import Foundation

/// A refusal of the session itself. Plugin errors stay `EnginePluginError.server`.
nonisolated enum EnginePluginSessionError: LocalizedError, Equatable {
  /// The running statement was cancelled (`interrupt`)
  case cancelled
  /// The session does not offer this
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .cancelled: "The statement was cancelled."
    case .unsupported(let what): "\(what) is not supported by this database plugin."
    }
  }
}

nonisolated final class EnginePluginSession: DatabaseSession, @unchecked Sendable {
  /// Rows per `rows` event at most; the plugin also keeps each event near 512 KiB
  static let batchRows = 1_000
  /// Added to the session timeout for the `open` watchdog
  static let openTimeoutMargin = 5
  /// Longest wait for the answer to `close`
  static let closeTimeout: Duration = .seconds(5)
  /// Stands for the password in a plugin message
  static let passwordMask = "••••"

  let pluginID: String
  let config: ConnectionConfig
  let capabilities: DatabaseCapabilities
  let closeEvents: AsyncStream<SessionCloseReason>
  /// Decides whether the bastion's host key is trusted
  let hostKeyValidator: any SSHHostKeyValidating
  /// DEBUG probe only (always nil in Release): the name the server certificate must match, in
  /// place of `config.host`
  let tlsServerNameOverride: String?
  /// DEBUG probe only (always empty in Release): sent unchanged as `open.options`
  let openOptions: [String: EngineJSONValue]

  private let lock = NSLock()
  private var router: EnginePluginRouter?
  private var connectionID: Int?
  /// The plugin answered `open` with `opened`
  private var isOpen = false
  /// `opened.serverVersion`, plain text from the plugin
  private var openedServerVersion: String?
  private var inFlight: Set<String> = []
  private var tunnelStorage: (any SSHTunneling)?
  private var forwarderStorage: SSHLoopbackForwarder?
  private var closeWatch: Task<Void, Never>?
  /// The first close reason, the only one yielded
  private var emitted: SessionCloseReason?
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation

  #if DEBUG
    convenience init(
      pluginID: String, config: ConnectionConfig, hostKeyValidator: any SSHHostKeyValidating,
      tlsServerNameOverride: String? = nil, openOptions: [String: EngineJSONValue] = [:]
    ) {
      self.init(
        pluginID: pluginID, config: config, hostKeyValidator: hostKeyValidator,
        probe: (tlsServerNameOverride, openOptions))
    }
  #else
    convenience init(
      pluginID: String, config: ConnectionConfig, hostKeyValidator: any SSHHostKeyValidating
    ) {
      self.init(
        pluginID: pluginID, config: config, hostKeyValidator: hostKeyValidator, probe: (nil, [:]))
    }
  #endif

  private init(
    pluginID: String, config: ConnectionConfig, hostKeyValidator: any SSHHostKeyValidating,
    probe: (tlsServerName: String?, options: [String: EngineJSONValue])
  ) {
    self.pluginID = pluginID
    self.config = config
    self.hostKeyValidator = hostKeyValidator
    tlsServerNameOverride = probe.tlsServerName
    openOptions = probe.options
    capabilities = config.databaseType.capabilities
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  /// The plugin's `opened.serverVersion`; nil before a successful open
  var serverVersion: String? { lock.withLock { openedServerVersion } }

  deinit {
    let finished = lock.withLock { emitted != nil }
    if !finished { closeContinuation.finish() }
  }

  // MARK: - Open / close

  /// Loads the plugin, opens the SSH forward when set, then sends `open`. Throws
  /// `DatabaseError.connectionFailed` (or a typed SSH error), `CancellationError` (the `open`
  /// cancelled) when the caller's task is cancelled. The caller closes after a failure.
  func open() async throws {
    let runtime = EnginePluginRuntime.runtime(for: pluginID)
    _ = try await runtime.start()
    let router = runtime.router
    let tls = try tlsSettings()
    let forwarder = config.sshTunnel != nil ? try await openTunnelForwarder() : nil
    let connection = router.makeConnectionID()
    let closes = router.closeEvents(connection: connection)
    let watch = Task { [weak self] in
      // Any `closed` here is unsolicited: `close()` forgets the stream before it sends `close`.
      for await _ in closes { self?.emit(.connectionLost) }
    }
    lock.withLock {
      self.router = router
      connectionID = connection
      closeWatch = watch
    }
    let request = EngineRequest.Open(
      host: forwarder == nil ? config.host : "127.0.0.1",
      port: forwarder?.localPort ?? config.port,
      tlsServerName: tlsServerNameOverride ?? config.host, database: config.database,
      username: config.username, password: config.password, tls: tls,
      timeoutSeconds: config.timeoutSeconds,
      readOnly: config.readOnlyFile || config.protectionLevel == .readOnly, options: openOptions)
    let version: String
    if let forwarder {
      // The plugin dials the forwarder during `open`; never once it has stopped.
      let opened: String? = try await forwarder.whileListening {
        try await sendOpen(request, router: router, connection: connection)
      }
      guard let opened else {
        throw DatabaseError.connectionFailed("The SSH tunnel closed while connecting.")
      }
      lock.withLock { tunnelStorage }?.whenClosed { [weak self] in self?.emit(.connectionLost) }
      version = opened
    } else {
      version = try await sendOpen(request, router: router, connection: connection)
    }
    lock.withLock {
      isOpen = true
      openedServerVersion = version
    }
  }

  private func sendOpen(
    _ request: EngineRequest.Open, router: EnginePluginRouter, connection: Int
  ) async throws -> String {
    let seconds = max(1, config.timeoutSeconds) + Self.openTimeoutMargin
    let sent = try router.send(.open(request), connection: connection, timeout: .seconds(seconds))
    var last: EngineEvent.Kind?
    do {
      for try await event in sent.events { last = event.kind }
    } catch EnginePluginError.timedOut {
      router.cancel(target: sent.id)
      throw DatabaseError.connectionFailed(
        "Connection timeout after \(config.timeoutSeconds) seconds")
    } catch {
      router.cancel(target: sent.id)
      throw DatabaseError.connectionFailed(formatError(error))
    }
    switch last {
    case .opened(let serverVersion): return serverVersion
    case .error(let failure): throw DatabaseError.connectionFailed(redacting(failure.message))
    case nil:
      // The caller's task was cancelled before the answer
      router.cancel(target: sent.id)
      throw CancellationError()
    default:
      throw DatabaseError.connectionFailed("The database plugin did not open the connection.")
    }
  }

  /// SSLMode as `open.tls.mode`, with the connection's CA when one was picked. The CA is read
  /// only behind `hasCA` and never logged; client certificates are never sent.
  private func tlsSettings() throws -> EngineRequest.Open.TLS {
    let mode = Self.tlsMode(config.sslMode)
    guard config.clientCertificate?.hasCA == true else { return .init(mode: mode) }
    guard let caPEM = ClientCertificateStoreFactory.load(for: config)?.caPEM else {
      throw DatabaseError.connectionFailed("The certificate authority is missing from the Keychain")
    }
    return .init(mode: mode, caPEM: caPEM)
  }

  static func tlsMode(_ mode: SSLMode) -> EngineRequest.Open.TLS.Mode {
    switch mode {
    case .disable: .off
    case .allow, .prefer: .request
    case .require: .require
    case .verifyCa: .verifyCA
    case .verifyFull: .verifyFull
    }
  }

  /// Opens the tunnel and a loopback forwarder to `config.host:config.port` as the bastion
  /// resolves it. Both are kept before anything else can fail, so `close()` tears them down.
  private func openTunnelForwarder() async throws -> SSHLoopbackForwarder {
    do {
      let authentication = try SSHTunnelConnector.sshAuthentication(for: config)
      let tunnel = try await SSHTunnelConnector.connectTunnel(
        config: config, authentication: authentication, hostKeyValidator: hostKeyValidator,
        factory: LiveSSHTunnelFactory())
      lock.withLock { tunnelStorage = tunnel }
      let forwarder = try await SSHLoopbackForwarder.start(
        tunnel: tunnel, targetHost: config.host, targetPort: config.port)
      lock.withLock { forwarderStorage = forwarder }
      return forwarder
    } catch let error
      where error is DatabaseError || error is SSHTunnelError || error is SSHPrivateKeyError
      || error is CancellationError
    {
      throw error
    } catch {
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  /// Yields `.closedByApp` first, cancels what still runs, sends `close` and waits up to
  /// `closeTimeout` for its answer, then stops the forwarder and the tunnel whatever the answer.
  /// The answer is not awaited after a failed or timed-out open (the plugin serves `close` behind
  /// that `open` on the connection's queue) nor after a loss (the router already let the
  /// connection go).
  func close() async {
    emit(.closedByApp)
    let (router, connection, awaitsAnswer, running, forwarder, tunnel, watch) = lock.withLock {
      defer {
        self.router = nil
        connectionID = nil
        isOpen = false
        inFlight = []
        forwarderStorage = nil
        tunnelStorage = nil
        closeWatch = nil
      }
      return (
        self.router, connectionID, isOpen && emitted != .connectionLost, inFlight,
        forwarderStorage, tunnelStorage, closeWatch
      )
    }
    watch?.cancel()
    if let router, let connection {
      router.forget(connection: connection)
      running.forEach(router.cancel(target:))
      let sent = try? router.send(.close, connection: connection, timeout: Self.closeTimeout)
      if let sent, awaitsAnswer {
        do { for try await _ in sent.events {} } catch {}
      }
      // No consumer stays suspended once the answer timed out or was not awaited
      running.forEach { router.fail($0, with: .connectionClosed(.closed)) }
    }
    await forwarder?.stop()
    await tunnel?.close()
  }

  private func emit(_ reason: SessionCloseReason) {
    let first = lock.withLock {
      guard emitted == nil else { return false }
      emitted = reason
      return true
    }
    guard first else { return }
    closeContinuation.yield(reason)
    closeContinuation.finish()
  }

  // MARK: - Statements

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let (router, connection) = try live()
    let query = EngineRequest.Query(
      sql: sql, binds: binds.map(Self.wire), language: "sql", batchRows: Self.batchRows)
    let sent = try router.send(.query(query), connection: connection)
    track(sent.id)
    let reader = EnginePluginRowReader(
      id: sent.id, router: router, events: sent.events, password: config.password
    ) { [weak self] in self?.untrack(sent.id) }
    let columns = try await reader.header()
    return SessionRowSource(
      columns: columns, rows: AsyncThrowingStream(unfolding: { try await reader.next() }))
  }

  /// The plugin's `done`. An empty tag becomes the statement's first keyword (`COMMIT`,
  /// `ROLLBACK`), upper-cased: the transaction code accepts a commit only by its tag.
  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    let (router, connection) = try live()
    let sent = try router.send(
      .command(.init(sql: sql, binds: binds.map(Self.wire))), connection: connection)
    track(sent.id)
    defer { untrack(sent.id) }
    var last: EngineEvent.Kind?
    do {
      for try await event in sent.events {
        // A command reads no rows: any it gets are dropped, with credit so it can finish.
        if case .rows = event.kind { router.more(target: sent.id) }
        last = event.kind
      }
    } catch {
      router.cancel(target: sent.id)
      throw error
    }
    switch last {
    case .done(let affectedRows, let tag):
      return CommandResult(
        affectedRows: affectedRows ?? 0, tag: tag.isEmpty ? firstKeyword(of: sql) : tag)
    case .error(let failure): throw EnginePluginError.server(redacting(failure))
    case .cancelled: throw EnginePluginSessionError.cancelled
    case nil, .columns, .rows, .chunk:
      // The caller's task was cancelled before the answer
      router.cancel(target: sent.id)
      throw CancellationError()
    default:
      router.cancel(target: sent.id)
      throw EnginePluginError.unreadableEvent
    }
  }

  /// One `catalog` read (no deadline, as for commands). Throws `EnginePluginError.server` with
  /// the plugin's failure, `unreadableEvent` when the answer is another kind or names another
  /// read.
  func catalog(
    _ read: EngineCatalogRead, args: [String: EngineJSONValue] = [:]
  ) async throws -> EngineCatalogResult {
    let (router, connection) = try live()
    let sent = try router.send(.catalog(.init(read: read, args: args)), connection: connection)
    track(sent.id)
    defer { untrack(sent.id) }
    var last: EngineEvent.Kind?
    do {
      for try await event in sent.events { last = event.kind }
    } catch {
      router.cancel(target: sent.id)
      throw error
    }
    switch last {
    case .catalog(let result):
      guard result.read == read else { throw EnginePluginError.unreadableEvent }
      return result
    case .error(let failure): throw EnginePluginError.server(redacting(failure))
    case .cancelled: throw EnginePluginSessionError.cancelled
    case nil, .columns, .rows, .chunk:
      // The caller's task was cancelled before the answer
      router.cancel(target: sent.id)
      throw CancellationError()
    default:
      router.cancel(target: sent.id)
      throw EnginePluginError.unreadableEvent
    }
  }

  private func firstKeyword(of sql: String) -> String {
    let word = SQLTokenizer.tokens(sql, dialect: config.databaseType.dialect)
      .first { $0.kind == .word }?.keyword
    return word?.uppercased() ?? ""
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw EnginePluginSessionError.unsupported("A server-side cursor")
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw EnginePluginSessionError.unsupported("A server-side cursor")
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    throw EnginePluginSessionError.unsupported("A server-side cursor")
  }

  /// The default reads a PostgreSQL view body; a plugin engine has none
  func columnOrigins(ofViewBody body: String) async throws -> [ColumnOrigin?] {
    throw EnginePluginSessionError.unsupported("Reading the columns of a view body")
  }

  // MARK: - Brakes, cancel, transaction state

  /// Sends the brakes as one `settings` request. An engine that lacks one answers `unsupported`:
  /// logged, and the session opens without it. Any other refusal fails the open.
  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    let (router, connection) = try live()
    let settings = EngineRequest.Settings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
    var last: EngineEvent.Kind?
    let id: String
    do {
      let sent = try router.send(.settings(settings), connection: connection)
      id = sent.id
      for try await event in sent.events { last = event.kind }
    } catch {
      throw DatabaseError.connectionFailed(
        "Could not apply session safety settings: \(formatError(error))")
    }
    switch last {
    case .settingsApplied: return
    case .error(let failure) where failure.code == .unsupported:
      await AppLogger.shared.warning(
        "The \(pluginID) plugin does not apply every session safety setting: "
          + redacting(failure.message),
        category: "Database")
    case .error(let failure):
      throw DatabaseError.connectionFailed(
        "Could not apply session safety settings: \(redacting(failure.message))")
    case nil:
      // The caller's task was cancelled before the answer
      router.cancel(target: id)
      throw CancellationError()
    default:
      throw DatabaseError.connectionFailed(
        "Could not apply session safety settings: the database plugin did not answer.")
    }
  }

  /// Cancels every statement this session has in flight; each ends with `cancelled`.
  func interrupt() async {
    let (router, running) = lock.withLock { (self.router, inFlight) }
    guard let router else { return }
    running.forEach(router.cancel(target:))
  }

  func transactionOpenAfterInterrupt() async -> Bool? {
    guard let (router, connection) = try? live(),
      let sent = try? router.send(.transactionState, connection: connection)
    else { return nil }
    var open: Bool?
    do {
      for try await event in sent.events {
        if case .transactionState(let state) = event.kind { open = state }
      }
    } catch {
      return nil
    }
    return open
  }

  /// Plugin and bridge texts are plain text, shown as they are but for the password.
  func formatError(_ error: Error) -> String {
    redacting((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
  }

  /// `text` with every occurrence of the password replaced by `passwordMask`
  func redacting(_ text: String) -> String {
    Self.redacting(text, password: config.password)
  }

  private func redacting(_ failure: EngineEvent.Failure) -> EngineEvent.Failure {
    Self.redacting(failure, password: config.password)
  }

  static func redacting(_ text: String, password: String) -> String {
    password.isEmpty ? text : text.replacingOccurrences(of: password, with: passwordMask)
  }

  static func redacting(_ failure: EngineEvent.Failure, password: String) -> EngineEvent.Failure {
    .init(
      code: failure.code, message: redacting(failure.message, password: password),
      serverCode: failure.serverCode)
  }

  // MARK: - Helpers

  private func live() throws -> (EnginePluginRouter, Int) {
    let state = lock.withLock { (router, connectionID) }
    guard let router = state.0, let connection = state.1 else {
      throw DatabaseError.notConnected
    }
    return (router, connection)
  }

  private func track(_ id: String) {
    lock.withLock { _ = inFlight.insert(id) }
  }

  private func untrack(_ id: String) {
    lock.withLock { _ = inFlight.remove(id) }
  }

  private static func wire(_ bind: SQLBindValue) -> String? {
    switch bind {
    case .null: nil
    case .text(let text): text
    }
  }
}

// MARK: - Rows

/// The events of one query, pulled one row at a time by one consumer. It sends `more` once a
/// `rows` event is consumed (when the row after its last one is asked for), rebuilds chunked
/// cells, and cancels the query when the stream fails or the caller drops it early. A row whose
/// width differs from the columns, or a second `columns`, cancels it as unreadable.
nonisolated final class EnginePluginRowReader: @unchecked Sendable {
  private let id: String
  private let router: EnginePluginRouter
  /// Replaced in the plugin's error text
  private let password: String
  private let onEnd: @Sendable () -> Void
  private var iterator: EnginePluginRouter.Events.AsyncIterator
  private var assembler = EngineChunkAssembler()
  private var columnCount = 0
  /// Rows of the current event, last first
  private var pending: [[CellValue]] = []
  private var owesCredit = false
  private var finished = false

  init(
    id: String, router: EnginePluginRouter, events: EnginePluginRouter.Events, password: String,
    onEnd: @escaping @Sendable () -> Void
  ) {
    self.id = id
    self.router = router
    self.password = password
    self.onEnd = onEnd
    iterator = events.makeAsyncIterator()
  }

  deinit {
    // Runs before `iterator` is released, so the router still knows the query's connection.
    if !finished {
      router.cancel(target: id)
      onEnd()
    }
  }

  /// The columns; empty when the statement ended without a result set
  func header() async throws -> [ColumnInfo] {
    switch try await nextEvent() {
    case .columns(let columns):
      columnCount = columns.count
      assembler = EngineChunkAssembler(columnCount: columns.count)
      return columns.map(Self.column)
    case .done:
      finish()
      return []
    case .some(let kind): throw end(kind)
    case nil: throw stopped()
    }
  }

  /// The next row, nil once the query is done. Pulled by one consumer, so no lock.
  func next() async throws -> [CellValue]? {
    while true {
      if let row = pending.popLast() { return row }
      guard !finished else { return nil }
      if owesCredit {
        owesCredit = false
        router.more(target: id)
      }
      switch try await nextEvent() {
      case .rows(let rows):
        guard rows.allSatisfy({ $0.count == columnCount }) else {
          cancel()
          throw EnginePluginError.unreadableEvent
        }
        let resolved = try guarded { try assembler.resolve(rows) }
        pending = resolved.reversed().map { $0.map(Self.cell) }
        owesCredit = true
      case .chunk(let chunk):
        try guarded { try assembler.append(chunk) }
      case .done:
        finish()
        return nil
      case .some(let kind): throw end(kind)
      case nil: throw stopped()
      }
    }
  }

  /// The next event's kind, nil when the stream ended without one. A stream failure cancels the
  /// query.
  private func nextEvent() async throws -> EngineEvent.Kind? {
    do {
      return try await iterator.next()?.kind
    } catch {
      cancel()
      throw error
    }
  }

  /// Runs a chunk step; a failure cancels the query and reads as an unreadable answer
  private func guarded<T>(_ step: () throws -> T) throws -> T {
    do { return try step() } catch {
      cancel()
      throw (error as? EngineProtocolError) == .tooLarge
        ? EnginePluginError.server(
          .init(code: .tooLarge, message: "A row's chunked values are over the 256 MiB limit."))
        : EnginePluginError.unreadableEvent
    }
  }

  /// The error of a last event (`error`, `cancelled`), or of one out of place
  private func end(_ kind: EngineEvent.Kind) -> Error {
    switch kind {
    case .error(let failure):
      finish()
      return EnginePluginError.server(
        EnginePluginSession.redacting(failure, password: password))
    case .cancelled:
      finish()
      return EnginePluginSessionError.cancelled
    default:
      cancel()
      return EnginePluginError.unreadableEvent
    }
  }

  /// The stream ended with no last event: the consuming task was cancelled
  private func stopped() -> Error {
    cancel()
    return CancellationError()
  }

  private func cancel() {
    router.cancel(target: id)
    finish()
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    pending = []
    onEnd()
  }

  // MARK: Mapping

  static func column(_ column: EngineEvent.Column) -> ColumnInfo {
    ColumnInfo(
      name: column.name, type: column.type,
      sourceName: column.origin.map {
        ColumnSourceName(schema: $0.schema, table: $0.table, column: $0.column)
      },
      wallClock: column.wallClock)
  }

  static func cell(_ cell: EngineCell) -> CellValue {
    switch cell {
    case .null, .chunked: .null
    case .text(let text): .string(text)
    case .int(let value): .int(value)
    case .double(let value): .double(value)
    case .bool(let value): .bool(value)
    case .json(let text): .json(text)
    case .date(let text): date(text).map(CellValue.date) ?? .string(text)
    case .bytes(let data): .data(data)
    case .decimal(let text): .decimal(text)
    }
  }

  private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  /// An ISO-8601 instant with up to 6 fraction digits kept whole (the formatter keeps only
  /// milliseconds): the whole seconds are parsed, the microseconds added. Nil when unreadable.
  static func date(_ text: String) -> Date? {
    var whole = text
    var micros = 0
    if let time = text.firstIndex(of: "T"), let dot = text[time...].firstIndex(of: ".") {
      let start = text.index(after: dot)
      let end = text[start...].firstIndex { !("0"..."9").contains($0) } ?? text.endIndex
      let digits = text[start..<end]
      guard !digits.isEmpty, let value = Int((digits + "000000").prefix(6)) else { return nil }
      micros = value
      whole = String(text[..<dot] + text[end...])
    }
    guard let seconds = isoFormatter.date(from: whole) else { return nil }
    return Date(
      timeIntervalSince1970: seconds.timeIntervalSince1970.rounded() + Double(micros) / 1e6)
  }
}
