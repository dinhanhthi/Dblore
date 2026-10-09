//
//  DatabaseConnectionManager.swift
//  Dblore
//

import Foundation
import NIOCore
import PostgresNIO

/// Actor managing PostgreSQL database connections and query execution
actor DatabaseConnectionManager {
  /// Published only after `open` and session brakes succeed. The gate and transaction
  /// bookkeeping stay on this actor; the session owns the socket.
  var session: (any DatabaseSession)?
  /// Production uses `AppDatabaseSessionFactory`. Tests inject another `DatabaseSessionFactory`.
  private let sessionFactory: any DatabaseSessionFactory
  /// Catalog SQL for the connected engine. PostgreSQL while nothing is connected.
  var introspector: any SchemaIntrospector {
    switch config?.databaseType {
    case .postgresql, nil:
      PostgresSchemaIntrospector()
    case .sqlite:
      SQLiteSchemaIntrospector()
    case .duckdb:
      DuckDBSchemaIntrospector()
    }
  }
  private(set) var config: ConnectionConfig?
  /// PEM for an unremembered connection, owned only while this actor's session is active.
  var activeUnrememberedCertificate: ClientCertificateStoreFactory.ConnectionMaterial?
  /// SSH secret of an unremembered connection, owned only while this actor's session is active.
  var activeUnrememberedSSHCredential: SSHCredentialStoreFactory.ConnectionCredential?
  /// Identity of the current connection: advanced on every disconnect and successful connect,
  /// so an inline edit target resolved on another connection is refused (`executeGatedUpdate`).
  private(set) var connectionEpoch: UInt64 = 0
  /// Protected mode transaction state (see `DatabaseConnectionManager+Transaction.swift`)
  var txState: TransactionState = .idle {
    didSet {
      if txState.isIdle { txOwner = nil }
      if txState != oldValue { commitGuard.generation &+= 1 }
    }
  }
  /// What the Commit confirmation reviewed, and gated statements in flight (`commitAppTransaction`)
  var commitGuard = CommitGuard()
  /// Test hook: awaited inside Commit / Rollback right after the state became `.ending`, before
  /// COMMIT / ROLLBACK is sent (see `setTransactionEndHook`)
  var transactionEndHook: (@Sendable (TransactionEndKind) async -> Void)?
  /// Test hook awaited at the `ScriptCheckpoint`s of `runUserStatements`; nil in the app
  var scriptCheckpointHook: (@Sendable (ScriptCheckpoint) async -> Void)?
  /// Test hook after a batch statement returns, before the next one is sent.
  var batchCheckpointHook: (@Sendable (Int) async -> Void)?
  /// Advances when Cancel is requested, even if SQLite's interrupt misses between statements.
  var batchCancellationGeneration: UInt64 = 0
  /// Stops sandbox access for a SQLite file. `disconnect` calls it after the session closes.
  /// Nil until a file grant is stored. Must not call back into this actor.
  var sqliteFileAccessRelease: (@Sendable () -> Void)?
  /// Files the current DuckDB session may read (`DuckDBSession` `extraAllowedPaths`). Set when
  /// a connect succeeds, cleared by `disconnect`. Internal reconnects (capped read, cancel) go
  /// through `reconnectWithActiveCertificate`, which passes it on to the new session.
  private(set) var duckDBAllowedPaths: [String] = []
  /// Reads that went through a server-side cursor (`executeCursorRead`); observed by tests
  var cursorReadCount = 0
  /// App catalog queries that passed `catalogConnection()`; observed by performance tests
  var catalogQueryCount = 0
  /// A DuckDB catalog read holds the session's one open result (see `withCatalogReadSession`)
  var isDuckDBCatalogReadActive = false
  /// DuckDB catalog reads waiting for the running one, in arrival order
  var duckDBCatalogWaiters: [CheckedContinuation<Void, Never>] = []
  /// Queries waiting in `performSend`: queued on the connection or running (see
  /// `resetSessionIfCapped`)
  var activeSends = 0
  /// Caller token (tab) that opened the app transaction: while it is pending, only this caller
  /// may run gated statements. Claimed before BEGIN is sent, cleared when the state is idle.
  var txOwner: UUID?
  /// A transaction the user opened with BEGIN while Protected mode was off
  var userTxOpen = false
  /// Committed schema change the sidebar has not reloaded yet
  var schemaRefreshPending = false
  /// Schema change inside the open app transaction. Commit makes it `schemaRefreshPending`.
  var schemaDirtyInAppTx = false
  /// Schema change inside a user-opened transaction. COMMIT makes it `schemaRefreshPending`.
  var schemaDirtyInUserTx = false
  /// Inline edit tables resolved outside any app transaction, by table identity
  /// (see `cachedEditTable`)
  var editTableCache: [TableRef: EditTable] = [:]
  /// The last server-closed session (cleared on connect / disconnect), see `markSessionLost`
  var lastSessionLoss: SessionLostEvent?
  /// Why a SQLite file was opened read-only by the app (a sidecar could not be written); nil
  /// otherwise. Set on connect, cleared when the connection is forgotten.
  private(set) var sqliteReadOnlyReason: String?
  /// The last user cancel (see `cancelRunningStatement`): statements of its epoch fail with
  /// `DatabaseError.queryCancelled`
  var lastCancel: QueryCancelRecord?
  /// One `SessionLostEvent` each time the server (or the network) closes the connected session
  nonisolated let sessionEvents: AsyncStream<SessionLostEvent>
  let sessionEventsContinuation: AsyncStream<SessionLostEvent>.Continuation
  /// One `SessionResetEvent` each time a capped read closed and reopened the session
  nonisolated let sessionResets: AsyncStream<SessionResetEvent>
  let sessionResetsContinuation: AsyncStream<SessionResetEvent>.Continuation

  /// TOFU for SSH bastions: the injected prompt confirms unknown host keys, pins go to the
  /// shared known-host store. Used by the default session factory and `testConnection`.
  nonisolated let sshHostKeyPolicy: SSHHostKeyPolicy

  /// `sshHostKeyPrompt` asks the user to trust an unknown SSH host key; the default declines.
  init(
    sessionFactory: (any DatabaseSessionFactory)? = nil,
    sshHostKeyPrompt: any SSHHostKeyPrompt = RejectingSSHHostKeyPrompt()
  ) {
    let policy = SSHHostKeyPolicy(prompt: sshHostKeyPrompt)
    sshHostKeyPolicy = policy
    self.sessionFactory = sessionFactory ?? AppDatabaseSessionFactory(hostKeyValidator: policy)
    (sessionEvents, sessionEventsContinuation) = AsyncStream.makeStream(
      of: SessionLostEvent.self, bufferingPolicy: .bufferingNewest(8))
    (sessionResets, sessionResetsContinuation) = AsyncStream.makeStream(
      of: SessionResetEvent.self, bufferingPolicy: .bufferingNewest(8))
  }

  deinit {
    sqliteFileAccessRelease?()
    sessionEventsContinuation.finish()
    sessionResetsContinuation.finish()
  }

  /// Default maximum number of rows to fetch from database to prevent memory issues
  /// Callers pass the effective result row cap (`NotebookViewModel.effectiveRowCap`)
  static let defaultMaxFetchRows = 100

  /// Current database type (nil if not connected)
  var databaseType: DatabaseType? {
    config?.databaseType
  }

  // MARK: - Connection Management

  /// Connect to PostgreSQL. The session is published only after its brakes are applied, so
  /// no user statement can run before the timeouts are set. `extraAllowedPaths`: the files the
  /// new DuckDB session may read (`duckDBAllowedPaths` once connected).
  func connect(config: ConnectionConfig, extraAllowedPaths: [String] = []) async throws {
    let config = config.resolvingBrakes(
      await MainActor.run { AppSettings.shared.sessionBrakeDefaults })
    let suppliedCertificate = ClientCertificateStoreFactory.currentMaterial(for: config)
    let suppliedSSHCredential = SSHCredentialStoreFactory.currentCredential(for: config)
    await AppLogger.shared.info(
      "Attempting to connect to database: \(config.safeDisplayString)", category: "Database")

    // Disconnect if already connected. Nothing of the new connection (session, config,
    // epoch) is published until its session brakes are applied.
    await disconnect()

    var prepared: PreparedSQLiteOpen
    do {
      prepared = try await prepareSQLiteOpen(config)
    } catch {
      throw error
    }
    let opening: any DatabaseSession
    do {
      opening = try await sessionFactory.makeSession(
        config: prepared.config, extraAllowedPaths: extraAllowedPaths)
    } catch {
      prepared.release?()
      throw error
    }
    do {
      try await opening.open()
    } catch {
      await opening.close()
      prepared.release?()
      throw error
    }
    // A file picked with "New File…" exists only now: bookmark it so it reopens after relaunch
    if prepared.config.fileBookmark == nil, prepared.release != nil {
      prepared.config.fileBookmark = SecurityScopedAccess.bookmarkIfPossible(
        for: URL(fileURLWithPath: prepared.config.database))
    }

    do {
      try await opening.applySessionSettings(
        statementTimeoutSeconds: SessionBrakeLimits.clampStatementTimeout(
          prepared.config.statementTimeoutSeconds ?? SessionBrakeLimits.defaultStatementTimeout),
        lockTimeoutSeconds: SessionBrakeLimits.clampLockTimeout(
          prepared.config.lockTimeoutSeconds ?? SessionBrakeLimits.defaultLockTimeout),
        idleTimeoutSeconds: SessionBrakeLimits.clampIdleTimeout(
          prepared.config.idleInTransactionTimeoutSeconds
            ?? SessionBrakeLimits.defaultIdleTimeout))
      if let postgres = opening as? PostgresSession {
        await postgres.applyDisconnectCheck()
      }
    } catch {
      await AppLogger.shared.error(
        "Failed to apply session brakes: \(error.localizedDescription)", category: "Database")
      await opening.close()
      prepared.release?()
      throw error
    }

    session = opening
    self.config = prepared.config
    duckDBAllowedPaths = extraAllowedPaths
    if !config.rememberConnection {
      activeUnrememberedCertificate = suppliedCertificate
      activeUnrememberedSSHCredential = suppliedSSHCredential
    }
    sqliteFileAccessRelease = prepared.release
    sqliteReadOnlyReason = prepared.readOnlyReason
    connectionEpoch &+= 1
    lastSessionLoss = nil
    // The UI learns about a session the server closed even when no query is running.
    observeSession(opening, epoch: connectionEpoch)

    await AppLogger.shared.info(
      "Successfully connected to database: \(config.safeDisplayString)", category: "Database")
  }

  /// Internal reset of this connection. A fresh connect must use the active unremembered
  /// certificate and SSH secret rather than same-account Keychain items from an older saved
  /// connection, and the same picked DuckDB files.
  func reconnectWithActiveCertificate(
    config: ConnectionConfig,
    material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential? = nil
  ) async throws {
    let allowedPaths = duckDBAllowedPaths
    let scoped = material.map {
      ClientCertificateStoreFactory.ScopedMaterial(account: $0.account, material: $0.material)
    }
    let scopedSSH = sshCredential.map {
      SSHCredentialStoreFactory.ScopedSSHCredential(
        account: $0.account, credential: $0.credential)
    }
    defer {
      scoped?.clear()
      scopedSSH?.clear()
    }
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
        try await connect(config: config, extraAllowedPaths: allowedPaths)
      }
    }
  }

  /// Test connection without storing it.
  /// Performs a real connection AND executes a test query to verify credentials.
  func testConnection(config: ConnectionConfig) async throws -> Bool {
    switch config.databaseType {
    case .postgresql:
      return try await PostgresSession(config: config, hostKeyValidator: sshHostKeyPolicy)
        .probe()
    case .sqlite, .duckdb:
      return try await probeFile(config)
    }
  }

  /// Bookmark present: sandbox grant, then the resolved path. No bookmark: the path as given
  /// (a file the process can already open, including a temporary file in tests), except a
  /// read-write DuckDB file, whose `.wal` still needs the grant. In-memory DuckDB needs no
  /// file access.
  private func prepareSQLiteOpen(_ config: ConnectionConfig) async throws -> PreparedSQLiteOpen {
    guard config.databaseType == .sqlite || config.databaseType == .duckdb else {
      return PreparedSQLiteOpen(config: config, release: nil)
    }
    let duckDBReadWrite = config.databaseType == .duckdb && !config.readOnlyFile
    guard config.fileBookmark != nil || duckDBReadWrite,
      config.database != DuckDBSession.inMemoryPath
    else {
      return PreparedSQLiteOpen(config: config, release: nil)
    }
    let grant = try await SQLiteFileAccess.open(config: config)
    var resolved = config
    resolved.database = grant.url.path
    if grant.readOnly { resolved.readOnlyFile = true }
    if let bookmark = grant.bookmark { resolved.fileBookmark = bookmark }
    return PreparedSQLiteOpen(
      config: resolved, release: { grant.release() }, readOnlyReason: grant.bannerReason)
  }

  /// `SELECT 1` on a SQLite or DuckDB database, then close. The grant is released either way.
  private func probeFile(_ config: ConnectionConfig) async throws -> Bool {
    let prepared = try await prepareSQLiteOpen(config)
    let session: any DatabaseSession
    do {
      session = try await sessionFactory.makeSession(config: prepared.config)
    } catch {
      prepared.release?()
      throw error
    }
    do {
      try await session.open()
      let source = try await session.query("SELECT 1", binds: [])
      var count = 0
      for try await _ in source.rows {
        count += 1
      }
      await session.close()
      prepared.release?()
      guard count == 1 else {
        throw DatabaseError.connectionFailed("Test query returned unexpected results")
      }
      return true
    } catch {
      await session.close()
      prepared.release?()
      if error is DatabaseError { throw error }
      throw DatabaseError.connectionFailed(session.formatError(error))
    }
  }

  /// Stores the hook `disconnect` calls after the session closes. Passing nil clears it.
  func setSQLiteFileAccessRelease(_ release: (@Sendable () -> Void)?) {
    sqliteFileAccessRelease = release
  }

  /// Disconnect from database. The picked DuckDB files go with the connection.
  func disconnect() async {
    duckDBAllowedPaths = []
    activeUnrememberedCertificate = nil
    activeUnrememberedSSHCredential = nil
    let releaseFileAccess = sqliteFileAccessRelease
    sqliteFileAccessRelease = nil

    let forgotten = forgetConnection()
    lastSessionLoss = nil

    if forgotten.session != nil {
      await AppLogger.shared.info("Disconnecting from database", category: "Database")
      await Self.closeForgotten(forgotten, includingConnection: true)
    }

    // A statement that resumed during the awaits above must not leave a stale state
    if session == nil {
      txState = .idle
      userTxOpen = false
      schemaRefreshPending = false
      schemaDirtyInAppTx = false
      schemaDirtyInUserTx = false
    }

    // After the session is closed, so a SQLite file is not yanked while it is still open.
    releaseFileAccess?()
  }

  /// Forget the current connection before any suspension point: no edit can use its targets,
  /// and a statement failing meanwhile sees the connection gone (state stays idle). Closing it
  /// (or the server closing it) rolls back any open transaction on the server.
  /// A PostgreSQL session is detached synchronously (`.closedByApp`) so its socket close is not
  /// a loss. Any other session is closed by the caller.
  func forgetConnection() -> ForgottenSession {
    connectionEpoch &+= 1
    let forgotten = session
    let resources = (forgotten as? PostgresSession)?.detach() ?? DetachedPostgresSession()
    session = nil
    config = nil
    sqliteReadOnlyReason = nil
    txState = .idle
    userTxOpen = false
    schemaRefreshPending = false
    schemaDirtyInAppTx = false
    schemaDirtyInUserTx = false
    editTableCache.removeAll()
    return ForgottenSession(
      session: forgotten, connection: resources.connection, group: resources.group,
      tunnel: resources.tunnel)
  }

  /// Close what `forgetConnection` returned. PostgreSQL closes the detached socket, its SSH
  /// tunnel (always, even when the socket is already closed) and its event-loop group, in that
  /// order. Any other session closes itself.
  static func closeForgotten(_ forgotten: ForgottenSession, includingConnection: Bool) async {
    if forgotten.connection != nil || forgotten.group != nil || forgotten.tunnel != nil {
      await DetachedPostgresSession(
        connection: forgotten.connection, group: forgotten.group, tunnel: forgotten.tunnel
      ).close(includingConnection: includingConnection)
      return
    }
    await forgotten.session?.close()
  }

  /// Check if currently connected
  var isConnected: Bool {
    session != nil
  }

  /// The PostgreSQL session, when the published session is one.
  var postgresSession: PostgresSession? {
    session as? PostgresSession
  }

  /// One reason from `session`, mapped onto session loss. `.closedByApp` is disconnect,
  /// cancel, or a reconnect: the actor has already forgotten that session.
  private func observeSession(_ session: any DatabaseSession, epoch: UInt64) {
    Task { [weak self] in
      for await reason in session.closeEvents {
        guard reason == .connectionLost else { continue }
        await self?.markSessionLost(epoch: epoch)
      }
    }
  }

  // MARK: - Connected Protection

  /// Protection of the config this actor connected with (`.none` when not connected).
  /// The execution gate enforces the stricter of this and the caller's policy.
  var connectedPolicy: ProtectionPolicy {
    ProtectionPolicy(config: config)
  }

  /// Apply a runtime change of the connection's protection settings (protection level,
  /// commit style, Safe Mode, protected mode) to the connected config. No-op when not
  /// connected. `connectedPolicy` still reads only `protectedMode` from that config.
  func updateConnectedProtection(from newConfig: ConnectionConfig) {
    guard config != nil else { return }
    config?.protectionLevel = newConfig.protectionLevel
    config?.safeMode = newConfig.safeMode
    config?.protectedMode = newConfig.protectedMode
    config?.commitStyle = newConfig.commitStyle
  }

  // MARK: - Internal Access

  /// Live `PostgresConnection` when the published session is PostgreSQL.
  var _postgresConnection: PostgresConnection? {
    postgresSession?.connection
  }
}

/// What `forgetConnection` dropped, so the caller can close it after the epoch has moved on.
nonisolated struct ForgottenSession: Sendable {
  var session: (any DatabaseSession)?
  var connection: PostgresConnection?
  var group: EventLoopGroup?
  var tunnel: (any SSHTunneling)?
}

/// A SQLite open, plus the sandbox release `disconnect` calls. `release` is nil for PostgreSQL
/// and for a SQLite path the process can already open.
private struct PreparedSQLiteOpen: Sendable {
  var config: ConnectionConfig
  var release: (@Sendable () -> Void)?
  /// `SQLiteFileAccess.AccessGrant.bannerReason`: set when the app itself opened the file read-only
  var readOnlyReason: String?
}

/// PostgreSQL stays `PostgresSession`. SQLite is `SQLiteSession` and DuckDB `DuckDBSession`
/// after the caller has resolved sandbox access.
nonisolated struct AppDatabaseSessionFactory: DatabaseSessionFactory {
  /// The DuckDB plugin's loader, or nil when the plugin is not installed. Read on the main actor
  /// before each DuckDB session: a removed plugin stays loaded (and cached) until the app quits.
  typealias DuckDBLibraryLoader = @Sendable () async -> (@Sendable () throws -> DuckDBLibrary)?

  var hostKeyValidator: any SSHHostKeyValidating = SSHHostKeyPolicy()
  var duckDBLibraryLoader: DuckDBLibraryLoader = {
    await MainActor.run {
      let manager = DuckDBPluginManager.shared
      guard manager.isInstalled else { return nil }
      return { try manager.loadLibrary() }
    }
  }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    try await makeSession(config: config, extraAllowedPaths: [])
  }

  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    switch config.databaseType {
    case .postgresql:
      return PostgresSession(config: config, hostKeyValidator: hostKeyValidator)
    case .sqlite:
      return SQLiteSession(config: config)
    case .duckdb:
      guard let load = await duckDBLibraryLoader() else {
        throw DatabaseError.engineUnavailable(.duckdb)
      }
      // `open()` runs the loader (hash, signature check, dlopen) on the session's own queue.
      return DuckDBSession(config: config, extraAllowedPaths: extraAllowedPaths, loadLibrary: load)
    }
  }
}

/// Catalog for an engine that cannot run in this build. Every read throws
/// `DatabaseError.engineUnavailable`; column enrichment keeps the driver types.
nonisolated struct UnavailableSchemaIntrospector: SchemaIntrospector {
  let engine: DatabaseType

  private var unavailable: DatabaseError { .engineUnavailable(engine) }

  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    throw unavailable
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    throw unavailable
  }

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    throw unavailable
  }

  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    throw unavailable
  }

  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    throw unavailable
  }

  func enrichColumnTypes(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async -> [ColumnInfo] {
    columns
  }

  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int
  {
    throw unavailable
  }

  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws -> [String] {
    throw unavailable
  }
}
