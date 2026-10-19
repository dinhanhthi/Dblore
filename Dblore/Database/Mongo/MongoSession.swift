// MongoSession.swift
// One MongoDB session through MongoKitten (Key decision c, phase-2 decision record). Owns the
// connection pool, the statement timeout (`maxTimeMS`), cancel (killOp) and the MongoDB error
// text. Statements are mongosh-subset text (`MongoshParser`); the commands themselves are in
// `MongoSession+Commands.swift`.
//
// How a config connects (`plan(config:material:resolver:)`):
// - no stored URI: `config.host:config.port`, `MongoCluster`;
// - `mongodb://…`: the URI's hosts, `MongoCluster`;
// - `mongodb://…?directConnection=true`: its one host, one injected `MongoConnection` behind
//   `MongoSingleConnectionPool` (no discovery);
// - `mongodb+srv://…`: the SRV answers (dnssd, `MongoSRV`), `MongoCluster`.
// - with `sshTunnel`: the URI's one host through the tunnel, as with `directConnection=true`
//   (`MongoSession+SSHTunnel.swift`); `+srv` and several hosts are refused.
// - TLS is on exactly when `sslMode != .disable` (6.2: `sslMode` is the source of truth), with
//   chain and host-name verification (MongoKitten always verifies). A custom CA comes from the
//   Keychain picker as PEM (`sslCaCertificate`; the cluster path trusts the first certificate of
//   the PEM, the direct path all of them). A client certificate is refused (no mTLS). An IP
//   literal with TLS is refused up front: NIOSSL cannot send an IP address as SNI.
// - Credentials come from `config.username`/`config.password` (the stored URI has none); no
//   user name means no authentication. `authMechanism` nil means `.auto` (SCRAM negotiation).
// - authSource: the URI's `authSource`, else the TXT record's (`+srv`), else the database of the
//   connection (`identityDatabase`: the saved database after a database switch), else `admin`
//   (connection string spec). A user stored in `admin` while the connection names another
//   database therefore needs `authSource=admin` in the URI.
// - Database: `config.database`, or `test` (mongosh's default) when empty.
// - `replicaSet` and `readPreference` are kept in the URI but not applied: commands always go to
//   a writable (primary) connection.
// - Event loops: NIO's shared `MultiThreadedEventLoopGroup.singleton`, passed to every MongoKitten
//   connect (never the group-less APIs, which leak a thread each). Not an owned group shut down
//   on close (2.6 Q10): MongoKitten completes reply promises from Swift tasks and never fails the
//   pending ones when a channel closes, only when its context deinitializes, possibly after
//   `close()` returned; on a shut-down loop that completion is dropped, which leaks the promise
//   (a Debug assertion crash, seen with TLS). MongoKitten's 30 s client `queryTimeout` is cleared
//   on every connection the session uses (`maxTimeMS` and killOp bound statements instead).
// - The cluster path has NIO's 10 s TCP connect timeout (MongoKitten ignores `connectTimeout`);
//   the direct path uses the connection's timeout.
// - closeEvents: the direct path watches the channel of each connection it builds
//   (`closeFuture`); the cluster path watches `MongoCluster.onStateChange`, which reports
//   `.disconnected` once its last pooled connection closed or failed a heartbeat. Either yields
//   `.connectionLost` (once); `close()` yields `.closedByApp` first.
// - Cancel: every command carries `comment: "dblore:<uuid>"`. `interrupt()` opens a control
//   connection (the same plan, on the shared NIO group), finds the operation with
//   `currentOp {$ownOps: true}` by that comment (also as the originating comment of a getMore)
//   and kills it with `killOp`. The statement fails with `DatabaseError.queryCancelled`
//   (`connectionKept: true`); the session stays usable.
// - Over SSH the killOp control connection is a channel of the same tunnel, never a direct
//   connection (`usesTunnel`), and losing the tunnel yields `.connectionLost`. `close()` closes
//   the connections, waits (bounded) for a killOp control connection under way, then closes the
//   tunnel.

import BSON
import Foundation
import Logging
import MongoClient
import MongoKitten
import NIOCore
import NIOPosix
import NIOSSL

/// A MongoDB error as the user reads it: `ERROR code (codeName): message`. Server text is
/// untrusted: control characters become spaces and the message is capped at 2,000 characters.
nonisolated struct MongoSessionError: Error, Equatable, Sendable, LocalizedError {
  static let maxMessageLength = 2000

  var code: Int?
  var codeName: String?
  var message: String
  /// A write error: the documents written before it (`n` of the reply)
  var written: Int?

  var errorDescription: String? {
    guard let code else { return message }
    return "ERROR \(code) (\(codeName ?? "MongoServerError")): \(message)"
  }

  static let closed = MongoSessionError(message: "The connection to the server is closed.")
  static let bindsRefused = MongoSessionError(
    message: "MongoDB commands take no bind parameters; write the values into the command.")
  static let cursorUnsupported = MongoSessionError(
    message: "Server-side cursors are not supported on MongoDB.")

  init(code: Int? = nil, codeName: String? = nil, message: String, written: Int? = nil) {
    self.code = code
    self.codeName = codeName.map { Self.sanitized($0, limit: 100) }
    self.message = Self.sanitized(message, limit: Self.maxMessageLength)
    self.written = written
  }

  /// An `ok: 0` reply or a write error: `code`, `codeName`, `errmsg`.
  init(reply: Document) {
    self.init(
      code: MongoSession.int(reply["code"]), codeName: reply["codeName"] as? String,
      message: reply["errmsg"] as? String ?? "The server refused the command.")
  }

  /// Any driver error; server errors keep their code.
  init(_ error: any Error) {
    switch error {
    case let error as MongoSessionError:
      self = error
    case let error as MongoServerError:
      self.init(reply: error.document)
    case let error as MongoGenericErrorReply:
      self.init(
        code: error.code, codeName: error.codeName,
        message: error.errorMessage ?? "The server refused the command.")
    default:
      self.init(message: String(describing: error))
    }
  }

  /// One line of at most `limit` characters (an ellipsis marks the cut).
  static func sanitized(_ text: String, limit: Int) -> String {
    let scalars = text.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
    }
    guard scalars.count > limit else { return String(scalars) }
    return String(scalars.prefix(limit - 1)) + "…"
  }
}

/// The server version from `buildInfo` (`version`, e.g. "8.0.4" or "4.4.29-rc0"; the suffix is
/// ignored).
nonisolated struct MongoServerVersion: Comparable, Sendable {
  var major: Int
  var minor: Int
  var patch: Int

  init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
    (self.major, self.minor, self.patch) = (major, minor, patch)
  }

  /// The leading digits and dots of `text`; missing minor or patch is 0. Nil without a major.
  init?(_ text: String) {
    let parts = text.prefix { ("0"..."9").contains($0) || $0 == "." }
      .split(separator: ".", omittingEmptySubsequences: false).prefix(3).map { Int($0) }
    guard let major = parts.first ?? nil else { return nil }
    self.init(major, parts.count > 1 ? parts[1] ?? 0 : 0, parts.count > 2 ? parts[2] ?? 0 : 0)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

/// What `MongoSession.open` connects to: driver settings plus the pool to use.
nonisolated struct MongoConnectionPlan: Sendable {
  /// Hosts (SRV resolved), credentials, authSource, database, TLS and the first CA certificate.
  var settings: ConnectionSettings
  /// `directConnection=true` or an SSH tunnel: one connection behind
  /// `MongoSingleConnectionPool`, no discovery.
  var isDirect: Bool
  /// Reached only through the SSH tunnel: never connected to directly.
  var usesTunnel: Bool
  /// Every certificate of the custom CA PEM (empty: the system trust store).
  var caCertificates: [NIOSSLCertificate]

  var database: String { settings.targetDatabase ?? MongoSession.defaultDatabase }
  var authSource: String { settings.authenticationSource ?? "admin" }
  var usesTLS: Bool { settings.useSSL }
}

nonisolated final class MongoSession: DatabaseSession, @unchecked Sendable {
  /// mongosh's database when the connection names none.
  static let defaultDatabase = "test"
  /// Most documents a read buffers: one more than the largest row cap, so the manager still sees
  /// the overflow row. A find without a limit stops here and its cursor is closed.
  static let maxBufferedDocuments = SessionBrakeLimits.rowCapRange.upperBound + 1
  static let ipTLSMessage = "TLS to MongoDB needs the server's host name, not an IP address."

  let capabilities: DatabaseCapabilities
  let config: ConnectionConfig
  let closeEvents: AsyncStream<SessionCloseReason>
  /// Builds the SSH tunnel when `config.sshTunnel` is set.
  let tunnelFactory: any SSHTunnelFactory
  /// Decides whether the bastion's host key is trusted.
  let hostKeyValidator: any SSHHostKeyValidating
  private let resolver: any MongoSRVResolving

  /// How the open session reaches the server.
  private enum Topology {
    case cluster(MongoCluster)
    case direct(MongoSingleConnectionPool)
  }

  private let lock = NSLock()
  private var topologyStorage: Topology?
  private var planStorage: MongoConnectionPlan?
  /// Connections the single pool built (closed by `close()`), with the context of a tunneled one.
  private var directConnections: [(connection: MongoConnection, context: MongoClientContext?)] = []
  private var tunnelStorage: (any SSHTunneling)?
  /// The error recorder of the last connection built through the tunnel.
  private var channelErrorsStorage: MongoChannelErrorRecorder?
  private var isClosed = false
  private var statementTimeoutStorage: Int
  private var documentCapStorage = MongoSession.maxBufferedDocuments
  /// `buildInfo`'s version once read (`serverVersion()`); a failure is not cached.
  private var serverVersionStorage: MongoServerVersion?
  /// `hello`'s write limits once read (`writeLimits()`); a failure is not cached.
  private var writeLimitsStorage: MongoWriteLimits?
  /// Comment tokens of the statements in flight; true once `interrupt()` targeted them.
  private var running: [String: Bool] = [:]
  /// killOp control connections under way through the tunnel, and what waits for them to end.
  private var controlDials = 0
  private var controlDialsEnded: [AsyncStream<Void>.Continuation] = []
  private var didEmitClose = false
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation

  init(
    config: ConnectionConfig, resolver: (any MongoSRVResolving)? = nil,
    tunnelFactory: any SSHTunnelFactory = LiveSSHTunnelFactory(),
    hostKeyValidator: any SSHHostKeyValidating = RejectUnknownSSHHostKeys()
  ) {
    self.config = config
    self.tunnelFactory = tunnelFactory
    self.hostKeyValidator = hostKeyValidator
    self.resolver = resolver ?? MongoDNSServiceResolver(timeoutSeconds: config.timeoutSeconds)
    capabilities = config.databaseType.capabilities
    statementTimeoutStorage = SessionBrakeLimits.clampStatementTimeout(
      config.statementTimeoutSeconds ?? SessionBrakeLimits.defaultStatementTimeout)
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    lock.lock()
    let finished = didEmitClose
    lock.unlock()
    if !finished { closeContinuation.finish() }
  }

  /// `maxTimeMS` of every command: the clamped statement timeout.
  var maxTimeMS: Int64 {
    lock.withLock { Int64(statementTimeoutStorage) * 1000 }
  }

  /// Test hook: the most documents a read buffers (`maxBufferedDocuments`).
  var documentCap: Int {
    get { lock.withLock { documentCapStorage } }
    set { lock.withLock { documentCapStorage = max(1, newValue) } }
  }

  /// The cached server version (`serverVersion()`).
  var cachedServerVersion: MongoServerVersion? {
    get { lock.withLock { serverVersionStorage } }
    set { lock.withLock { serverVersionStorage = newValue } }
  }

  /// The cached server write limits (`writeLimits()`).
  var cachedWriteLimits: MongoWriteLimits? {
    get { lock.withLock { writeLimitsStorage } }
    set { lock.withLock { writeLimitsStorage = newValue } }
  }

  // MARK: - Open / close

  /// Connect and authenticate. Throws `DatabaseError.connectionFailed` (SSH errors keep their
  /// type). The caller closes the session after a failure, which also closes the tunnel.
  func open() async throws {
    let plan = try await Self.plan(
      config: config, material: try Self.certificateMaterial(for: config), resolver: resolver)
    let tunnel = config.sshTunnel != nil ? try await openTunnel() : nil
    let group = MultiThreadedEventLoopGroup.singleton
    lock.withLock { planStorage = plan }
    do {
      if plan.isDirect {
        let pool = MongoSingleConnectionPool(
          authenticationSource: plan.authSource, credentials: plan.settings.authentication
        ) { [weak self] in
          guard let self else { throw MongoSessionError.closed }
          return try await buildDirectConnection(plan: plan, group: group)
        }
        lock.withLock { topologyStorage = .direct(pool) }
        // Connect and log in now, so a wrong password fails here as on the cluster path.
        _ = try await pool.next(for: .writable)
      } else {
        let cluster = try await MongoCluster(connectingTo: plan.settings, eventLoopGroup: group)
        cluster.onStateChange = { [weak self] state in
          if case .disconnected = state.connectionState { self?.emit(.connectionLost) }
        }
        lock.withLock { topologyStorage = .cluster(cluster) }
      }
    } catch let error as DatabaseError {
      throw error
    } catch {
      // Over the tunnel MongoKitten reports a TLS failure only as a closed channel.
      let cause = lock.withLock { channelErrorsStorage?.first } ?? error
      throw DatabaseError.connectionFailed(formatError(cause))
    }
    // Registered only once connected: a tunnel lost during the login fails the open instead.
    tunnel?.whenClosed { [weak self] in self?.emit(.connectionLost) }
  }

  /// Test connection: connect, authenticate, `hello`, close (also the SSH tunnel, on every
  /// path).
  static func probe(
    config: ConnectionConfig, hostKeyValidator: any SSHHostKeyValidating
  ) async throws -> Bool {
    try await MongoSession(config: config, hostKeyValidator: hostKeyValidator).probe()
  }

  func probe() async throws -> Bool {
    do {
      try await open()
      try await hello()
      await close()
      return true
    } catch {
      await close()
      switch error {
      case is DatabaseError, is SSHTunnelError, is SSHPrivateKeyError: throw error
      default: throw DatabaseError.connectionFailed(formatError(error))
      }
    }
  }

  /// Disconnect every connection, then the SSH tunnel (if any). Yields `.closedByApp` first.
  func close() async {
    emit(.closedByApp)
    let (topology, connections, tunnel) = lock.withLock {
      defer {
        isClosed = true
        topologyStorage = nil
        directConnections = []
        tunnelStorage = nil
      }
      return (topologyStorage, directConnections, tunnelStorage)
    }
    if case .cluster(let cluster) = topology { await cluster.disconnect() }
    for (connection, context) in connections {
      await Self.closeConnection(connection, context: context)
    }
    if tunnel != nil { await controlDialsDone() }
    await tunnel?.close()
  }

  /// How long `close()` waits for a killOp control connection before closing the tunnel anyway.
  /// Covers the control connection's last `currentOp` round trip (its statement is gone once
  /// `close()` closed the connections) plus its own `closeConnection` grace.
  static let controlDialGrace: Duration = .seconds(5)

  /// Returns once no killOp control connection runs through the tunnel (none starts once
  /// closed), or after `controlDialGrace`.
  private func controlDialsDone() async {
    let (ended, continuation) = AsyncStream<Void>.makeStream()
    let waiting = lock.withLock { () -> Bool in
      guard controlDials > 0 else { return false }
      controlDialsEnded.append(continuation)
      return true
    }
    guard waiting else { return }
    Task {
      try? await Task.sleep(for: Self.controlDialGrace)
      continuation.finish()
    }
    for await _ in ended {}
  }

  private func endControlDial() {
    let waiters = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
      controlDials -= 1
      guard controlDials == 0 else { return [] }
      defer { controlDialsEnded.removeAll() }
      return controlDialsEnded
    }
    for waiter in waiters { waiter.finish() }
  }

  /// The tunnel of the session being opened. False (and nothing kept) once the session closed.
  func keepTunnel(_ tunnel: any SSHTunneling) -> Bool {
    lock.withLock {
      guard !isClosed else { return false }
      tunnelStorage = tunnel
      return true
    }
  }

  /// The error recorder of the connection being built through the tunnel.
  func setChannelErrors(_ recorder: MongoChannelErrorRecorder) {
    lock.withLock { channelErrorsStorage = recorder }
  }

  /// A writable connection with MongoKitten's client timeout cleared.
  func nextConnection() async throws -> MongoConnection {
    guard let topology = lock.withLock({ topologyStorage }) else { throw MongoSessionError.closed }
    let connection: MongoConnection
    switch topology {
    case .cluster(let cluster): connection = try await cluster.next(for: .writable)
    case .direct(let pool): connection = try await pool.next(for: .writable)
    }
    await connection.dbloreSetQueryTimeout(nil)
    return connection
  }

  /// The single pool's builder: a new connection (a fresh tunnel channel over SSH), watched for
  /// loss, closed by `close()`.
  private func buildDirectConnection(
    plan: MongoConnectionPlan, group: any EventLoopGroup
  ) async throws -> MongoConnection {
    let (closed, tunnel) = lock.withLock { (isClosed, tunnelStorage) }
    guard !closed else { throw MongoSessionError.closed }
    let connection: MongoConnection
    var context: MongoClientContext?
    if let tunnel {
      let recorder = MongoChannelErrorRecorder()
      setChannelErrors(recorder)
      (connection, context) = try await Self.connectThroughTunnel(
        plan: plan, tunnel: tunnel, errors: recorder)
    } else {
      connection = try await Self.connectDirect(
        plan: plan, group: group, timeoutSeconds: config.timeoutSeconds)
    }
    let kept = lock.withLock { () -> Bool in
      guard !isClosed else { return false }
      directConnections.append((connection, context))
      return true
    }
    guard kept else {
      await Self.closeConnection(connection, context: context)
      throw MongoSessionError.closed
    }
    connection.closeFuture.whenComplete { [weak self] _ in self?.emit(.connectionLost) }
    return connection
  }

  /// One TCP (and TLS) connection to the plan's first host, not authenticated yet.
  static func connectDirect(
    plan: MongoConnectionPlan, group: any EventLoopGroup, timeoutSeconds: Int
  ) async throws -> MongoConnection {
    guard let host = plan.settings.hosts.first else {
      throw MongoError(.cannotConnect, reason: .noHostSpecified)
    }
    let sslContext = plan.usesTLS ? try NIOSSLContext(configuration: tlsConfiguration(plan)) : nil
    let context = MongoClientContext(logger: Logger(label: "dblore.mongo"))
    let channel = try await ClientBootstrap(group: group)
      .connectTimeout(.seconds(Int64(max(1, timeoutSeconds))))
      .channelInitializer { channel in
        guard let sslContext else {
          return MongoConnection.addHandlers(to: channel, context: context)
        }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: sslContext, serverHostname: host.hostname))
        }.flatMap { MongoConnection.addHandlers(to: channel, context: context) }
      }
      .connect(host: host.hostname, port: host.port)
      .get()
    return MongoConnection(channel: channel, context: context)
  }

  /// Full verification against the custom CA (or the system trust store).
  static func tlsConfiguration(_ plan: MongoConnectionPlan) -> TLSConfiguration {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .fullVerification
    if !plan.caCertificates.isEmpty { tls.trustRoots = .certificates(plan.caCertificates) }
    return tls
  }

  // MARK: - Connection plan

  /// The custom CA of `config` from the Keychain (or the operation scope). Nil without one.
  static func certificateMaterial(for config: ConnectionConfig) throws -> ClientCertificateMaterial?
  {
    guard config.clientCertificate != nil else { return nil }
    guard config.sslMode != .disable else {
      throw DatabaseError.connectionFailed("A custom CA certificate needs TLS (Verify Full).")
    }
    guard let material = ClientCertificateStoreFactory.load(for: config) else {
      throw DatabaseError.connectionFailed("The custom CA certificate is missing from the Keychain")
    }
    guard material.certificatePEM == nil, material.privateKeyPEM == nil else {
      throw DatabaseError.connectionFailed(
        "Client certificates are not supported for MongoDB. Keep only the custom CA certificate.")
    }
    return material
  }

  /// Hosts, credentials, authSource, database, TLS and pool of `config` (see the file header).
  /// Throws `DatabaseError.connectionFailed`; resolves `+srv` hosts through `resolver`.
  static func plan(
    config: ConnectionConfig, material: ClientCertificateMaterial?,
    resolver: any MongoSRVResolving
  ) async throws -> MongoConnectionPlan {
    let uri: ParsedMongoURI
    if let stored = config.mongoURI {
      do {
        uri = try MongoURIParser.parse(stored)
      } catch {
        throw DatabaseError.connectionFailed(
          "The saved MongoDB connection string is not valid: \(error.localizedDescription)")
      }
    } else {
      uri = ParsedMongoURI(
        isSRV: false, hosts: [ParsedMongoURI.Host(name: config.host, port: config.port)],
        database: nil, username: nil, password: nil, authSource: nil, authMechanism: nil,
        tls: nil, replicaSet: nil, directConnection: nil, appName: nil, readPreference: nil,
        ignoredOptions: [])
    }
    // Before any SRV lookup: a tunnel reaches one host as the bastion resolves it.
    if config.sshTunnel != nil, uri.isSRV || uri.hosts.count != 1 {
      throw DatabaseError.connectionFailed(sshSingleHostMessage)
    }
    let usesTLS = config.sslMode != .disable
    var hosts = uri.hosts
    var txtAuthSource: String?
    if uri.isSRV, let srvHost = hosts.first {
      try refuseIPWithTLS([srvHost], usesTLS: usesTLS)
      do {
        let seedlist = try await MongoSRV.seedlist(for: srvHost.name, resolver: resolver)
        hosts = seedlist.hosts
        txtAuthSource = seedlist.authSource
      } catch let error as MongoSRV.LookupError {
        throw DatabaseError.connectionFailed(error.message)
      } catch {
        throw DatabaseError.connectionFailed(
          "The SRV lookup failed: \(MongoSessionError(error).message)")
      }
    }
    try refuseIPWithTLS(hosts, usesTLS: usesTLS)

    let database = config.database.isEmpty ? defaultDatabase : config.database
    let identity = config.identityDatabase
    let authSource = uri.authSource ?? txtAuthSource ?? (identity.isEmpty ? "admin" : identity)
    var settings = ConnectionSettings(
      authentication: authentication(
        username: config.username, password: config.password, mechanism: uri.authMechanism),
      authenticationSource: authSource,
      hosts: hosts.map {
        ConnectionSettings.Host(hostname: $0.name, port: $0.port ?? MongoURIParser.defaultPort)
      },
      targetDatabase: database, useSSL: usesTLS, applicationName: uri.appName)
    var certificates: [NIOSSLCertificate] = []
    if usesTLS, let pem = material?.caPEM {
      do {
        certificates = try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))
      } catch {
        throw DatabaseError.connectionFailed("The custom CA certificate could not be read.")
      }
      guard !certificates.isEmpty else {
        throw DatabaseError.connectionFailed("The custom CA certificate could not be read.")
      }
      settings.sslCaCertificate = certificates.first
    }
    return MongoConnectionPlan(
      settings: settings, isDirect: uri.directConnection == true || config.sshTunnel != nil,
      usesTunnel: config.sshTunnel != nil, caCertificates: certificates)
  }

  static func authentication(
    username: String, password: String, mechanism: MongoAuthMechanism?
  ) -> ConnectionSettings.Authentication {
    guard !username.isEmpty else { return .unauthenticated }
    switch mechanism {
    case nil: return .auto(username: username, password: password)
    case .scramSHA1: return .scramSha1(username: username, password: password)
    case .scramSHA256: return .scramSha256(username: username, password: password)
    }
  }

  /// NIOSSL cannot send an IP address as SNI (`cannotUseIPAddressInSNI`, 2.6 Q4).
  private static func refuseIPWithTLS(_ hosts: [ParsedMongoURI.Host], usesTLS: Bool) throws {
    guard usesTLS else { return }
    if hosts.contains(where: { (try? SocketAddress(ipAddress: $0.name, port: 0)) != nil }) {
      throw DatabaseError.connectionFailed(ipTLSMessage)
    }
  }

  // MARK: - Session settings

  /// Only the statement timeout applies (`maxTimeMS`); MongoDB has no lock or idle timeout per
  /// session.
  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    lock.withLock {
      statementTimeoutStorage = SessionBrakeLimits.clampStatementTimeout(statementTimeoutSeconds)
    }
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw MongoSessionError.cursorUnsupported
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw MongoSessionError.cursorUnsupported
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    throw MongoSessionError.cursorUnsupported
  }

  // MARK: - Statements in flight and cancel

  /// Runs `body` as one statement with a fresh comment token (or `token`, unique per statement,
  /// for `interrupt(token:)`). A failure after `interrupt()` (or a server interrupt, 11601)
  /// becomes `DatabaseError.queryCancelled`.
  func withStatement<T>(
    token given: String? = nil,
    _ body: (_ token: String, _ connection: MongoConnection) async throws -> T
  ) async throws -> T {
    let token = given ?? "dblore:\(UUID().uuidString)"
    // A token already in flight is refused: its entry is not reset nor removed by this one
    let registered = lock.withLock {
      guard running[token] == nil else { return false }
      running[token] = false
      return true
    }
    guard registered else {
      throw MongoSessionError(message: "A statement with this token is already running.")
    }
    defer { _ = lock.withLock { running.removeValue(forKey: token) } }
    do {
      let connection = try await nextConnection()
      return try await body(token, connection)
    } catch {
      let interrupted = lock.withLock { running[token] == true }
      if interrupted || Self.isInterruption(error) {
        throw DatabaseError.queryCancelled(
          pendingCount: 0, userTxRolledBack: false, connectionKept: true)
      }
      throw error
    }
  }

  /// The server stopped the operation (killOp: `Interrupted`, 11601).
  static func isInterruption(_ error: any Error) -> Bool {
    if case DatabaseError.queryCancelled = error { return true }
    switch error {
    case let error as MongoSessionError: return error.code == 11601
    case let error as MongoServerError: return int(error.document["code"]) == 11601
    case let error as MongoGenericErrorReply: return error.code == 11601
    default: return false
    }
  }

  private func isRunning(_ token: String) -> Bool {
    lock.withLock { running[token] != nil }
  }

  /// killOp of every statement in flight, from a control connection. The statements fail with
  /// `queryCancelled`; the session stays open. Over SSH, nothing is dialed once the session
  /// closed, and `close()` waits for a control connection under way before closing the tunnel.
  func interrupt() async {
    await interrupt(where: { _ in true })
  }

  /// killOp of the statement run with `token` only, if it is still running: the other
  /// statements (other tabs) and the batch cancellation state are untouched.
  func interrupt(token: String) async {
    await interrupt(where: { $0 == token })
  }

  private func interrupt(where selects: (String) -> Bool) async {
    let (tokens, plan, tunnel) = lock.withLock {
      () -> ([String], MongoConnectionPlan?, (any SSHTunneling)?) in
      let selected = running.keys.filter(selects)
      for token in selected { running[token] = true }
      guard !selected.isEmpty, let planStorage else { return ([], nil, nil) }
      guard planStorage.usesTunnel else { return (selected, planStorage, nil) }
      guard let tunnelStorage else { return ([], nil, nil) }
      // A tunnel is returned only with a control dial counted, which the defer below ends.
      controlDials += 1
      return (selected, planStorage, tunnelStorage)
    }
    guard !tokens.isEmpty, let plan else { return }
    defer { if tunnel != nil { endControlDial() } }
    do {
      let control = try await ControlConnection.open(
        plan: plan, timeoutSeconds: config.timeoutSeconds, tunnel: tunnel)
      do {
        for token in tokens { try await killOperations(tagged: token, on: control.connection) }
      } catch {
        await AppLogger.shared.warning(
          "MongoDB killOp failed: \(formatError(error))", category: "Database")
      }
      await control.close()
    } catch {
      await AppLogger.shared.warning(
        "MongoDB killOp control connection failed: \(formatError(error))", category: "Database")
    }
  }

  /// Finds the operations commented `token` (polling while the statement runs, as it may not be
  /// registered yet) and kills them.
  private func killOperations(tagged token: String, on connection: MongoConnection) async throws {
    let filter: MongoValue = .document([
      .init("currentOp", .int32(1)), .init("$ownOps", .bool(true)),
      .init(
        "$or",
        .array([
          .document([.init("command.comment", .string(token))]),
          .document([.init("cursor.originatingCommand.comment", .string(token))]),
        ])),
    ])
    let currentOp = try MongoBSONMapping.bsonDocument(filter)
    for _ in 0..<40 {
      guard isRunning(token) else { return }
      let reply = try await connection.execute(currentOp, namespace: .administrativeCommand)
        .getDocument()
      try Self.checkOK(reply)
      let operations = (reply["inprog"] as? Document)?.values.compactMap {
        ($0 as? Document)?["opid"]
      }
      if let operations, !operations.isEmpty {
        for operation in operations {
          let kill = try MongoBSONMapping.bsonDocument(
            .document([
              .init("killOp", .int32(1)),
              .init("op", try MongoBSONMapping.value(from: operation)),
            ]))
          try Self.checkOK(
            try await connection.execute(kill, namespace: .administrativeCommand).getDocument())
        }
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  // MARK: - Errors

  func formatError(_ error: Error) -> String {
    let (usesTLS, seconds) = lock.withLock {
      (planStorage?.usesTLS ?? (config.sslMode != .disable), statementTimeoutStorage)
    }
    return Self.message(for: error, usesTLS: usesTLS, statementTimeoutSeconds: seconds)
  }

  static let tlsHint =
    "The TLS connection could not be set up. Check that the server uses TLS, that its "
    + "certificate is signed by a trusted CA (or the custom CA of this connection), and that it "
    + "names the host you connect to."

  /// User-facing text of `error`, at most `MongoSessionError.maxMessageLength` characters.
  static func message(for error: any Error, usesTLS: Bool, statementTimeoutSeconds: Int) -> String {
    let text: String
    switch error {
    case let error as DatabaseError:
      text = error.localizedDescription
    case let error as MongoshParser.ParseError:
      text = error.message
    case let error as MongoBSONMapping.MappingError:
      text = error.message
    case let error as MongoError where error.kind == .queryTimeout:
      text = "MongoDB did not answer in time (client timeout)."
    case let error as MongoError:
      text = [error.kind.description, error.reason?.description].compactMap { $0 }
        .joined(separator: ": ")
    case let error as MongoAuthenticationError:
      text = "Authentication failed: \(error.description)"
    case is NIOSSLError, is BoringSSLError, is NIOSSLExtraError:
      text = "\(tlsHint) (\(String(describing: error)))"
    case ChannelError.ioOnClosedChannel where usesTLS, ChannelError.eof where usesTLS:
      text = tlsHint
    case is NIOConnectionError:
      text =
        "Could not connect to the MongoDB server. Check the host, the port and that the "
        + "server is running."
    default:
      let mapped = MongoSessionError(error)
      switch mapped.code {
      // The server text stays after the mapped words (it names the action and namespace)
      case 13:
        text = "Not authorized for this action: \(mapped.message)"
      case 166:
        text = "This is a view: \(mapped.message)"
      case 18:
        text =
          "Authentication failed. Check the user name, the password and the authentication "
          + "database (authSource) of this connection."
      case 50:
        text =
          "Statement timed out after \(statementTimeoutSeconds)s (MaxTimeMSExpired) — change "
          + "it in the connection's Safety settings"
      case 11601:
        text = "The operation was cancelled."
      default:
        text = mapped.errorDescription ?? mapped.message
      }
    }
    return MongoSessionError.sanitized(text, limit: MongoSessionError.maxMessageLength)
  }

  // MARK: - Reply helpers

  /// Throws the server error of an `ok: 0` reply.
  static func checkOK(_ reply: Document) throws {
    guard let ok = double(reply["ok"]), ok == 1 else { throw MongoSessionError(reply: reply) }
  }

  static func int(_ value: Primitive?) -> Int? {
    switch value {
    case let value as Int32: Int(value)
    case let value as Int: value
    case let value as Double where value.isFinite && value.rounded() == value:
      Int(exactly: value)
    default: nil
    }
  }

  private static func double(_ value: Primitive?) -> Double? {
    switch value {
    case let value as Int32: Double(value)
    case let value as Int: Double(value)
    case let value as Double: value
    default: nil
    }
  }

  // MARK: - Close state

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
}

/// A short-lived connection for killOp (its own connection on the shared NIO group, or its own
/// channel of the session's SSH tunnel).
private nonisolated struct ControlConnection: Sendable {
  let connection: MongoConnection
  private let cluster: MongoCluster?
  /// Set for a tunneled connection (see `MongoSession.closeConnection`).
  private let context: MongoClientContext?

  static func open(
    plan: MongoConnectionPlan, timeoutSeconds: Int, tunnel: (any SSHTunneling)?
  ) async throws -> ControlConnection {
    let group = MultiThreadedEventLoopGroup.singleton
    if plan.isDirect {
      let (connection, context): (MongoConnection, MongoClientContext?) =
        if let tunnel {
          try await MongoSession.connectThroughTunnel(
            plan: plan, tunnel: tunnel, errors: MongoChannelErrorRecorder())
        } else if plan.usesTunnel {
          // The tunnel is gone (the session closed): never dial around it.
          throw MongoSessionError.closed
        } else {
          (
            try await MongoSession.connectDirect(
              plan: plan, group: group, timeoutSeconds: timeoutSeconds), nil
          )
        }
      do {
        try await connection.authenticate(
          clientDetails: nil, using: plan.settings.authentication, to: plan.authSource)
      } catch {
        await MongoSession.closeConnection(connection, context: context)
        throw error
      }
      return ControlConnection(connection: connection, cluster: nil, context: context)
    }
    let cluster = try await MongoCluster(connectingTo: plan.settings, eventLoopGroup: group)
    do {
      return ControlConnection(
        connection: try await cluster.next(for: .writable), cluster: cluster, context: nil)
    } catch {
      await cluster.disconnect()
      throw error
    }
  }

  func close() async {
    if let cluster {
      await cluster.disconnect()
    } else {
      await MongoSession.closeConnection(connection, context: context)
    }
  }
}

extension MongoConnection {
  /// `queryTimeout` (30 s, also on getMore) is settable only from inside the actor (2.6 Q10).
  func dbloreSetQueryTimeout(_ timeout: TimeAmount?) {
    queryTimeout = timeout
  }
}
