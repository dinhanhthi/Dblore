//
//  DatabaseConnectionManager.swift
//  Dblore
//

import Foundation
import NIOCore
import PostgresNIO
import os

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
    case .mysql:
      MySQLSchemaIntrospector(database: config?.database ?? "")
    case .mongodb:
      MongoSchemaIntrospector()
    }
  }
  private(set) var config: ConnectionConfig?
  /// PEM for an unremembered connection, owned only while this actor's session is active.
  var activeUnrememberedCertificate: ClientCertificateStoreFactory.ConnectionMaterial?
  /// SSH secret of an unremembered connection, owned only while this actor's session is active.
  var activeUnrememberedSSHCredential: SSHCredentialStoreFactory.ConnectionCredential?
  /// Vault secret of an unremembered connection, owned only while this actor's session is
  /// active (cleared when it is forgotten)
  var activeUnrememberedVaultSecret: VaultCredentialStore.ConnectionSecret?
  /// Post-disconnect script of the workspace's main connection (`connectRunningScripts`), run
  /// once that connection is closed (`disconnect`). Nil for side managers and plain connects; an
  /// internal reset (`reconnectWithActiveCertificate`) keeps it. Behind a lock, not the actor,
  /// so a quit can see and start it synchronously (`hasPendingPostDisconnect`).
  private nonisolated let postDisconnectSlot = OSAllocatedUnfairLock<PendingScript?>(
    initialState: nil)
  /// Runs the connection scripts (`connectRunningScripts`, `testConnection`)
  nonisolated let scripts: ConnectionScriptRunner
  /// Which identities are locked: connects and user-initiated statements of a blocked identity
  /// are refused (`DatabaseError.connectionLocked`). `LockRegistry.shared` in the app.
  nonisolated let lockSource: LockRegistry
  /// An MCP pool manager: MCP never serves a locked file, so an attached file whose lock is set
  /// is skipped (and refused by the gate) even when the user unlocked it in the app
  nonisolated let servesMCP: Bool
  /// Identity of the current connection: advanced on every disconnect and successful connect,
  /// so an inline edit target resolved on another connection is refused (`executeGatedUpdate`).
  private(set) var connectionEpoch: UInt64 = 0
  /// What a capped read keeps per cell and in total (MCP managers); nil: what the read itself
  /// passes (`execute(userSQL:readLimits:)`, the app's editor and notebook results), else whole
  /// rows
  let readLimits: CappedReadLimits?
  /// A capped read closes and reopens the session (`resetSessionIfCapped`); false for a
  /// single-use manager disconnected right after its read, which closes the session anyway
  let resetsSessionAfterCappedRead: Bool
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
  /// Test hook awaited before an edit-table catalog read (`fetchEditTable`); nil in the app
  var catalogReadHook: (@Sendable () async -> Void)?
  /// Test hook answering the PostgreSQL column type catalog read (`enrichColumnTypes`) in place
  /// of the server; nil in the app
  var columnTypeReadHook: (@Sendable ([ColumnInfo]) async -> [ColumnInfo])?
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
  /// PostgreSQL view probes that failed for a passing reason, with when and why: not tried
  /// again for `viewProbeRetryDelay` (`viewEditTable`)
  var viewProbeFailures: [ViewProbeKey: (at: Date, error: any Error)] = [:]
  /// PostgreSQL view probes running: a lookup of the same view joins the one in flight
  var viewProbesInFlight: [ViewProbeKey: Task<EditTable?, Error>] = [:]
  /// MySQL result column origins: column ordinals by table identity, read from
  /// information_schema once per table. Cleared with `editTableCache` and on schema reload; a
  /// clear also rejects catalog reads still in flight (`MySQLTableColumnsCache.generation`).
  var mysqlTableColumns = MySQLTableColumnsCache()
  /// PostgreSQL result column types by origin (table identity and attnum), read from the
  /// catalog once (`enrichColumnTypes`). Cleared with `editTableCache`, never per table.
  var columnTypeCache = ColumnTypeCache()
  /// The saved rows' mask rules for a config (`SavedMaskRules` on `.standard`); tests read
  /// their own defaults
  var savedMaskRules: @Sendable (ConnectionConfig) -> [ColumnMaskRule] = {
    SavedMaskRules.rules(for: $0)
  }
  /// The MySQL server's character sets and collations, read once per connection (the epoch it
  /// was read on) for the structure editor (`fetchMySQLCharacterSets`)
  var mysqlCharacterSetsCache: (epoch: UInt64, sets: MySQLCharacterSets)?
  /// MySQL temporary tables this session created (no catalog lists them); cleared with the
  /// session (`forgetConnection`)
  var mysqlTempTables = MySQLTempTableTracker()
  /// The last server-closed session (cleared on connect / disconnect), see `markSessionLost`
  var lastSessionLoss: SessionLostEvent?
  /// Where Data Rewind entries go; nil records nothing. The app takes `RewindRecorder.shared`
  /// (opened off the actor on connect) on the first edit with a plan; tests set their own
  /// (`setRewindRecorder`).
  var rewindRecorder: RewindRecorder?
  /// Keys this manager's pending Data Rewind entries in the recorder
  nonisolated let rewindScope = UUID()
  /// User COMMITs, MySQL implicit-commit statements and MySQL BEGINs (Protected mode off,
  /// `userTxOpen`) awaited, one per script: a connection lost meanwhile may or may not have
  /// committed
  var userCommitsInFlight = 0
  /// Why a SQLite file was opened read-only by the app (a sidecar could not be written); nil
  /// otherwise. Set on connect, cleared when the connection is forgotten.
  private(set) var sqliteReadOnlyReason: String?
  /// One warning per attached database the last connect left out (invalid, locked, missing,
  /// unreadable). Set on connect, cleared when the connection is forgotten.
  private(set) var attachWarnings: [String] = []
  /// MySQL or MariaDB and its version while a MySQL session is open, else nil.
  var mysqlServerInfo: MySQLServerInfo? {
    (session as? MySQLSession)?.serverInfo
  }
  /// How the open MySQL session is protected (plaintext after a Prefer / Allow fallback); nil
  /// without a MySQL session. Feeds the footer SSL badges.
  var mysqlTransport: MySQLTransport? {
    (session as? MySQLSession)?.transport
  }
  /// The last user cancel (see `cancelRunningStatement`): statements of its epoch fail with
  /// `DatabaseError.queryCancelled`
  var lastCancel: QueryCancelRecord?
  /// DuckDB: `connectionEpoch` of a session whose open transaction an interrupt cancel (or a
  /// failed statement, `settleAbortAfterFailure`) aborted
  /// (`DatabaseType.interruptAbortsTransaction`), until `settleInterruptAbort` rolls it back
  var interruptRollbackOwed: UInt64?
  /// One `SessionLostEvent` each time the server (or the network) closes the connected session
  nonisolated let sessionEvents: AsyncStream<SessionLostEvent>
  let sessionEventsContinuation: AsyncStream<SessionLostEvent>.Continuation
  /// One `SessionResetEvent` each time a capped read closed and reopened the session
  nonisolated let sessionResets: AsyncStream<SessionResetEvent>
  let sessionResetsContinuation: AsyncStream<SessionResetEvent>.Continuation

  /// TOFU for SSH bastions: the injected prompt confirms unknown host keys, pins go to the
  /// shared known-host store. Used by the default session factory and `testConnection`.
  nonisolated let sshHostKeyPolicy: SSHHostKeyPolicy

  /// Takes this manager's Vault leases (`VaultLeasing.app` in the app)
  nonisolated let vaultLeasing: VaultLeasing
  /// The one Vault lease of a Vault connection, never in `config`: kept by an internal reset
  /// of an equal key, revoked after the session closes on any other connect or disconnect.
  /// Behind a lock, not the actor, so a quit can see it synchronously (`holdsLease`).
  private nonisolated let leaseSlot = OSAllocatedUnfairLock<VaultLeaseSlot?>(initialState: nil)
  /// Why the Vault lease of the last lost connection ended (cleared on connect / disconnect)
  private(set) var lastLeaseEnd: VaultLeaseEnd?
  /// End of the timed write unlock of this session (`unlockWrites(for:)`), never in `config`
  /// and never saved; cleared when the session is forgotten or the protection level changes
  private(set) var writeUnlockExpiry: Date?
  /// Clock of the write unlock expiry (tests pass a fake one)
  nonisolated let now: @Sendable () -> Date

  /// `sshHostKeyPrompt` asks the user to trust an unknown SSH host key; the default declines.
  init(
    sessionFactory: (any DatabaseSessionFactory)? = nil,
    sshHostKeyPrompt: any SSHHostKeyPrompt = RejectingSSHHostKeyPrompt(),
    readLimits: CappedReadLimits? = nil, resetsSessionAfterCappedRead: Bool = true,
    scripts: ConnectionScriptRunner = .app, lockSource: LockRegistry = .shared,
    servesMCP: Bool = false, vaultLeasing: VaultLeasing = .app,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.vaultLeasing = vaultLeasing
    self.now = now
    self.scripts = scripts
    self.lockSource = lockSource
    self.servesMCP = servesMCP
    self.readLimits = readLimits
    self.resetsSessionAfterCappedRead = resetsSessionAfterCappedRead
    let policy = SSHHostKeyPolicy(prompt: sshHostKeyPrompt)
    sshHostKeyPolicy = policy
    self.sessionFactory =
      sessionFactory ?? AppDatabaseSessionFactory(hostKeyValidator: policy, lockSource: lockSource)
    (sessionEvents, sessionEventsContinuation) = AsyncStream.makeStream(
      of: SessionLostEvent.self, bufferingPolicy: .bufferingNewest(8))
    (sessionResets, sessionResetsContinuation) = AsyncStream.makeStream(
      of: SessionResetEvent.self, bufferingPolicy: .bufferingNewest(8))
  }

  /// A single-use manager, not connected, for an app check that must not run on this session,
  /// with this manager's lock source: its sessions come from this manager's factory, made
  /// read-only by `MCPReadOnlySessionFactory` (DuckDB is refused). SQLite opens like the SQL dump
  /// (`SQLDumpSessionFactory`): read-only with normal locking, never `immutable=1`, which would
  /// miss rows still in the WAL. The caller connects and disconnects it.
  nonisolated func makeReadOnlySideManager() -> DatabaseConnectionManager {
    DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(
        inner: SQLDumpSessionFactory(inner: sessionFactory)),
      resetsSessionAfterCappedRead: false, lockSource: lockSource, servesMCP: servesMCP,
      vaultLeasing: vaultLeasing)
  }

  /// `makeReadOnlySideManager` without the read-only wrapper, for an app read that sends its own
  /// `BEGIN … READ ONLY` and `SET LOCAL` (which `MCPReadOnlySession` refuses): sessions from this
  /// manager's factory, SQLite read-only as in the SQL dump. The caller connects and disconnects
  /// it.
  nonisolated func makeSnapshotSideManager() -> DatabaseConnectionManager {
    DatabaseConnectionManager(
      sessionFactory: SQLDumpSessionFactory(inner: sessionFactory),
      resetsSessionAfterCappedRead: false, lockSource: lockSource, servesMCP: servesMCP,
      vaultLeasing: vaultLeasing)
  }

  /// Connects the single-use `side` like this manager: `config` (this manager's when nil), its
  /// unremembered certificate and SSH secret. `identity` (`config` when nil) is the connection
  /// the certificate and SSH secret belong to, when `config` names another database (a MySQL
  /// side on another database of the server): its unremembered secrets, else its Keychain
  /// items, are used for `config`'s accounts (both accounts include the database). So is its
  /// Vault secret: the side takes its own lease with it.
  func connectSideManager(
    _ side: DatabaseConnectionManager, config: ConnectionConfig? = nil,
    identity: ConnectionConfig? = nil
  ) async throws {
    guard let config = config ?? self.config else { throw DatabaseError.notConnected }
    let identity = identity ?? config
    // This manager's lock source: the side's own is not consulted
    if let refusal = lockSource.refusal(for: config) { throw refusal }
    let vaultSecret =
      config.vault == nil ? nil : try sideVaultSecret(identity: identity, config: config)
    defer { vaultSecret?.clear() }
    try await VaultCredentialStore.$operationSecret.withValue(vaultSecret) {
      try await side.reconnectWithActiveCertificate(
        config: config, material: sideCertificate(identity: identity, config: config),
        sshCredential: sideSSHCredential(identity: identity, config: config))
    }
  }

  /// `identity`'s certificate under `config`'s account
  private func sideCertificate(
    identity: ConnectionConfig, config: ConnectionConfig
  ) -> ClientCertificateStoreFactory.ConnectionMaterial? {
    let account = ClientCertificateStoreFactory.account(for: config)
    let identityAccount = ClientCertificateStoreFactory.account(for: identity)
    // Only a secret of `config`'s own account: never the one of a connection switched to since
    guard identityAccount != account else {
      return activeUnrememberedCertificate.flatMap { $0.account == account ? $0 : nil }
    }
    let material: ClientCertificateMaterial?
    if let active = activeUnrememberedCertificate, active.account == identityAccount {
      material = active.material
    } else if identity.clientCertificate != nil {
      material = ClientCertificateStoreFactory.load(for: identity)
    } else {
      material = nil
    }
    return material.map { .init(account: account, material: $0) }
  }

  /// `identity`'s SSH secret under `config`'s account
  private func sideSSHCredential(
    identity: ConnectionConfig, config: ConnectionConfig
  ) -> SSHCredentialStoreFactory.ConnectionCredential? {
    let identityAccount = SSHCredentialStoreFactory.account(for: identity)
    guard let account = SSHCredentialStoreFactory.account(for: config) else { return nil }
    guard identityAccount != account else {
      return activeUnrememberedSSHCredential.flatMap { $0.account == account ? $0 : nil }
    }
    let credential: SSHStoredCredential?
    if let active = activeUnrememberedSSHCredential, active.account == identityAccount {
      credential = active.credential
    } else {
      credential = SSHCredentialStoreFactory.load(for: identity)
    }
    return credential.map { .init(account: account, credential: $0) }
  }

  /// `identity`'s Vault secret (its unremembered one, else its stored one) under `config`'s
  /// account, still bound to `identity`'s destination: the side's config must match it. A
  /// stored secret the Keychain could not read refuses the side connect.
  private func sideVaultSecret(
    identity: ConnectionConfig, config: ConnectionConfig
  ) throws -> VaultCredentialStore.ScopedSecret? {
    let secret: VaultSecret?
    if let active = activeUnrememberedVaultSecret,
      active.account == VaultCredentialStore.account(for: identity),
      active.destination == VaultCredentialStore.destination(for: identity)
    {
      secret = active.secret
    } else {
      switch VaultCredentialStore.lookup(for: identity, from: vaultLeasing.store) {
      case .found(let found): secret = found
      case .destinationChanged, .missing: secret = nil
      case .unreadable:
        throw DatabaseError.passwordStoreUnreadable(
          name: identity.name.isEmpty ? identity.displayString : identity.name)
      }
    }
    return VaultCredentialStore.scoped(secret, for: config, boundTo: identity)
  }

  deinit {
    // A manager dropped without a disconnect revokes its lease from a task that does not
    // retain the manager
    if let slot = leaseSlot.withLock({ $0 }) { Task.detached { await slot.lease.revoke() } }
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
  /// new DuckDB session may read (`duckDBAllowedPaths` once connected). A locked identity
  /// (`lockSource`) is refused before the current connection is closed; a bookmark that
  /// resolves to a locked file, once resolved (after the close).
  func connect(config: ConnectionConfig, extraAllowedPaths: [String] = []) async throws {
    if let refusal = lockSource.refusal(for: config) { throw refusal }
    try await connectUnchecked(
      config: config, extraAllowedPaths: extraAllowedPaths, checkingOpenedFile: true)
  }

  /// An ask-on-connect config of an engine that uses a password, without its typed password:
  /// refused by connect and Test (a stale flag on a file engine blocks nothing).
  private static func lacksTypedPassword(_ config: ConnectionConfig) -> Bool {
    config.askPasswordOnConnect && config.databaseType.capabilities.usesPassword
      && config.password.isEmpty
  }

  /// `connect` without the lock check, for this manager's own resets
  /// (`reconnectWithActiveCertificate`): a relock never drops a live session.
  /// `checkingOpenedFile`: refuse the locked file a bookmark resolves to (`connect` only).
  /// A Vault connection's session gets the lease's username and password; `config` and the
  /// published config keep the saved ones. `keepingLease` (internal resets only): a held lease
  /// of an equal key is reused, never revoked; otherwise the held lease is revoked once the
  /// current session is closed, and a new one is taken. An ask-on-connect config without its
  /// typed password is refused before anything closes or opens: never an empty-password login.
  private func connectUnchecked(
    config: ConnectionConfig, extraAllowedPaths: [String], checkingOpenedFile: Bool = false,
    keepingLease: Bool = false
  ) async throws {
    if Self.lacksTypedPassword(config) { throw DatabaseError.passwordRequiredOnConnect }
    let config = config.resolvingBrakes(
      await MainActor.run { AppSettings.shared.sessionBrakeDefaults })
    let suppliedCertificate = ClientCertificateStoreFactory.currentMaterial(for: config)
    let suppliedSSHCredential = SSHCredentialStoreFactory.currentCredential(for: config)
    let suppliedVaultSecret = VaultCredentialStore.currentSecret(for: config)
    await AppLogger.shared.info(
      "Attempting to connect to database: \(config.safeDisplayString)", category: "Database")
    // The Data Rewind store opens off this actor, long before the first edit reads it
    if !SessionManager.isRunningAsTestHost {
      Task.detached(priority: .utility) { _ = RewindRecorder.shared }
    }

    // Disconnect if already connected. Nothing of the new connection (session, config,
    // epoch) is published until its session brakes are applied.
    let leaseKey = VaultLeaseKey(config)
    await disconnect(keepingLeaseFor: keepingLease ? leaseKey : nil)

    var prepared: PreparedSQLiteOpen
    do {
      prepared = try await prepareSQLiteOpen(config)
    } catch {
      throw error
    }
    // The saved path text may name another file than its bookmark (moved, stale, edited)
    if checkingOpenedFile, let refusal = lockSource.refusal(for: prepared.config) {
      prepared.release?()
      throw refusal
    }
    let lease: VaultLeaseManager?
    let tookLease: Bool
    do {
      (lease, tookLease) = try await leaseForConnect(leaseKey, config: prepared.config)
    } catch {
      prepared.release?()
      throw error
    }
    let sessionConfig = lease?.overlay(on: prepared.config) ?? prepared.config
    let opening: any DatabaseSession
    do {
      opening = try await withLeaseAccounts(sessionConfig, saved: prepared.config) {
        let made = try await sessionFactory.makeSession(
          config: sessionConfig, extraAllowedPaths: extraAllowedPaths)
        if servesMCP { (made as? SQLiteSession)?.refuseLockedFilesForMCP() }
        do {
          try await made.open()
        } catch {
          await made.close()
          throw error
        }
        return made
      }
    } catch {
      prepared.release?()
      if tookLease, let lease { await revokeOwnLease(lease) }
      throw error
    }
    // A file picked with "New File…" exists only now: bookmark it so it reopens after relaunch
    if prepared.config.fileBookmark == nil, prepared.hasFileGrant {
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
      if tookLease, let lease { await revokeOwnLease(lease) }
      throw error
    }
    // A reset's kept lease may have ended while the new session opened (`vaultLeaseEnded`
    // recorded why), or a newer connect or a disconnect took this connect's lease out of the
    // slot (and revoked it): that session is closed, never published, and the reset reports
    // the loss
    if let lease, leaseSlot.withLock({ $0?.lease.leaseID }) != lease.leaseID {
      await opening.close()
      prepared.release?()
      throw VaultLeaseError.leaseEnded
    }

    session = opening
    self.config = prepared.config
    duckDBAllowedPaths = extraAllowedPaths
    if !config.rememberConnection {
      activeUnrememberedCertificate = suppliedCertificate
      activeUnrememberedSSHCredential = suppliedSSHCredential
      activeUnrememberedVaultSecret = suppliedVaultSecret
    }
    sqliteFileAccessRelease = prepared.release
    sqliteReadOnlyReason = prepared.readOnlyReason
    attachWarnings = prepared.warnings + ((opening as? SQLiteSession)?.attachWarnings ?? [])
    connectionEpoch &+= 1
    lastSessionLoss = nil
    lastLeaseEnd = nil
    // The UI learns about a session the server closed even when no query is running.
    observeSession(opening, epoch: connectionEpoch)
    if tookLease, let lease {
      let leaseID = lease.leaseID
      lease.startRenewal { [weak self] reason in
        await self?.vaultLeaseEnded(leaseID: leaseID, reason: reason)
      }
    }

    await AppLogger.shared.info(
      "Successfully connected to database: \(config.safeDisplayString)", category: "Database")
  }

  /// The workspace's main connect: closes the current connection (its post-disconnect script
  /// runs), runs `config`'s pre-connect script (a failure aborts with its exit status and
  /// capped stderr), then its password command, whose password replaces the Keychain one in the
  /// connected config only: never saved, and gone with the connection. Side managers and
  /// internal resets copy that connected config, so they reuse the password and run no script.
  /// The post-disconnect script pairs with a pre-connect script that ran: it runs when the
  /// connect then fails, or once the connection closes. A locked identity, and an ask-on-connect
  /// config without its typed password, are refused before anything closes or any script runs.
  func connectRunningScripts(
    config: ConnectionConfig, extraAllowedPaths: [String] = []
  ) async throws {
    if let refusal = lockSource.refusal(for: config) { throw refusal }
    if Self.lacksTypedPassword(config) { throw DatabaseError.passwordRequiredOnConnect }
    let pending = config.postDisconnectScript.map {
      PendingScript(runner: scripts, name: $0, config: config)
    }
    var resolved = config
    var preConnectRan = false
    do {
      if config.preConnectScript != nil || config.passwordCommandScript != nil {
        await disconnect()
        if let name = config.preConnectScript {
          try await scripts.runPreConnect(name, for: config)
          preConnectRan = true
        }
        resolved = try await withPasswordCommand(config)
      }
      // `connect` closes the current connection first: the script is recorded only after it
      try await connect(config: resolved, extraAllowedPaths: extraAllowedPaths)
    } catch {
      if preConnectRan { pending?.run() }
      throw error
    }
    postDisconnectSlot.withLock { $0 = pending }
  }

  /// Whether `disconnect` will run a post-disconnect script.
  nonisolated var hasPendingPostDisconnect: Bool {
    postDisconnectSlot.withLock { $0 != nil }
  }

  /// For a quit: takes the pending post-disconnect script, so `disconnect` no longer runs it,
  /// and returns what starts it. The quit calls it once the connection is closed, or when the
  /// close takes too long.
  nonisolated func takePostDisconnectForQuit() -> (@Sendable () -> Void)? {
    guard let script = takePendingPostDisconnect() else { return nil }
    return { script.run() }
  }

  private nonisolated func takePendingPostDisconnect() -> PendingScript? {
    postDisconnectSlot.withLock { slot in
      defer { slot = nil }
      return slot
    }
  }

  /// `config` with the password its password command prints, for engines with a password.
  private func withPasswordCommand(_ config: ConnectionConfig) async throws -> ConnectionConfig {
    guard let name = config.passwordCommandScript,
      config.databaseType.capabilities.usesPassword
    else { return config }
    var resolved = config
    resolved.password = try await scripts.password(from: name, for: config)
    return resolved
  }

  /// Internal reset of this connection. A fresh connect must use the active unremembered
  /// certificate and SSH secret rather than same-account Keychain items from an older saved
  /// connection, and the same picked DuckDB files. A held Vault lease of the same connection is
  /// kept (a capped-read or Cancel reset); a manager without one takes its own, with
  /// `vaultSecret` (an unremembered connection's) when given, else the caller's scoped secret or
  /// the stored one.
  func reconnectWithActiveCertificate(
    config: ConnectionConfig,
    material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential? = nil,
    vaultSecret: VaultCredentialStore.ConnectionSecret? = nil
  ) async throws {
    let allowedPaths = duckDBAllowedPaths
    let scoped = material.map {
      ClientCertificateStoreFactory.ScopedMaterial(account: $0.account, material: $0.material)
    }
    let scopedSSH = sshCredential.map {
      SSHCredentialStoreFactory.ScopedSSHCredential(
        account: $0.account, credential: $0.credential)
    }
    let scopedVault =
      vaultSecret.map(VaultCredentialStore.ScopedSecret.init)
      ?? VaultCredentialStore.operationSecret
    defer {
      scoped?.clear()
      scopedSSH?.clear()
      if vaultSecret != nil { scopedVault?.clear() }
    }
    // The reset keeps the connection: its post-disconnect script waits for the real close
    let keptScript = takePendingPostDisconnect()
    do {
      try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
        try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
          try await VaultCredentialStore.$operationSecret.withValue(scopedVault) {
            try await connectUnchecked(
              config: config, extraAllowedPaths: allowedPaths, keepingLease: true)
          }
        }
      }
    } catch {
      keptScript?.run()
      throw error
    }
    postDisconnectSlot.withLock { $0 = keptScript }
  }

  /// Test connection without storing it.
  /// Performs a real connection AND executes a test query to verify credentials. A password
  /// command supplies the password, as on connect; no other script runs. A locked identity is
  /// refused before the password command. A Vault connection probes with a lease of its own,
  /// revoked after the probe: this manager's lease and session are left alone. An
  /// ask-on-connect config without its typed password is refused as on connect.
  func testConnection(config: ConnectionConfig) async throws -> Bool {
    if let refusal = lockSource.refusal(for: config) { throw refusal }
    if Self.lacksTypedPassword(config) { throw DatabaseError.passwordRequiredOnConnect }
    let config = try await withPasswordCommand(config)
    guard config.vault != nil else { return try await probe(config) }
    let lease = try await vaultLeasing.take(for: config)
    let probing = lease.overlay(on: config)
    do {
      let probed = try await withLeaseAccounts(probing, saved: config) {
        try await probe(probing)
      }
      await lease.revoke()
      return probed
    } catch {
      await lease.revoke()
      throw error
    }
  }

  /// `SELECT 1` (or the engine's ping) on a session of its own, closed after.
  private func probe(_ config: ConnectionConfig) async throws -> Bool {
    switch config.databaseType {
    case .postgresql:
      return try await PostgresSession(config: config, hostKeyValidator: sshHostKeyPolicy)
        .probe()
    case .sqlite, .duckdb:
      return try await probeFile(config)
    case .mysql:
      return try await MySQLSession(config: config, hostKeyValidator: sshHostKeyPolicy).probe()
    case .mongodb:
      return try await MongoSession.probe(config: config, hostKeyValidator: sshHostKeyPolicy)
    }
  }

  /// The main file's grant (`prepareMainFile`), then one per attached file
  /// (`prepareAttachments`), for SQLite and DuckDB.
  private func prepareSQLiteOpen(_ config: ConnectionConfig) async throws -> PreparedSQLiteOpen {
    guard config.databaseType == .sqlite || config.databaseType == .duckdb else {
      return PreparedSQLiteOpen(config: config, release: nil)
    }
    var prepared = try await prepareMainFile(config)
    await prepareAttachments(&prepared)
    return prepared
  }

  /// Bookmark present: sandbox grant, then the resolved path. No bookmark: the path as given
  /// (a file the process can already open, including a temporary file in tests), except a
  /// read-write DuckDB file, whose `.wal` still needs the grant. In-memory DuckDB needs no
  /// file access.
  private func prepareMainFile(_ config: ConnectionConfig) async throws -> PreparedSQLiteOpen {
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
      config: resolved, release: { grant.release() }, readOnlyReason: grant.bannerReason,
      hasFileGrant: true)
  }

  /// Leaves in `prepared.config` only the attachments the session may attach
  /// (`validatedAttachedDatabases`), each with its own grant like a main file
  /// (`SQLiteFileAccess.open`: bookmark, sidecar presenters registered before the ATTACH, write
  /// probe) at the path it resolves to, released with the main file's. Runs after the main file,
  /// also for an in-memory DuckDB. A file this manager's `lockSource` blocks (its saved path, then
  /// the file its bookmark resolves to; for MCP, any locked file), whose grant fails, or that
  /// opens only read-only on a read-write connection is left out with a warning. No bookmark:
  /// the path as given.
  private func prepareAttachments(_ prepared: inout PreparedSQLiteOpen) async {
    let main = prepared.config
    let (attachments, warnings) = main.validatedAttachedDatabases()
    prepared.warnings = warnings
    var kept: [AttachedDatabase] = []
    var grants: [SQLiteFileAccess.AccessGrant] = []
    for var attachment in attachments {
      var reason: String?
      if isBlockedFile(attachment.path, engine: main.databaseType) {
        reason = "its file is locked."
      } else if let bookmark = attachment.bookmark {
        let file = ConnectionConfig(
          databaseType: main.databaseType, database: attachment.path, fileBookmark: bookmark,
          readOnlyFile: main.readOnlyFile)
        if let grant = try? await SQLiteFileAccess.open(config: file) {
          attachment.path = grant.url.path
          if isBlockedFile(attachment.path, engine: main.databaseType) {
            reason = "its file is locked."
          } else if grant.readOnly, !main.readOnlyFile {
            reason = "allow its folder so Dblore can write its journal files."
          } else {
            grants.append(grant)
          }
          if reason != nil { grant.release() }
        } else {
          reason = "its file cannot be opened. Choose it again in the connection's settings."
        }
      }
      if let reason {
        prepared.warnings.append(SQLiteFileAccess.attachmentSkipped(attachment.name, reason))
      } else {
        kept.append(attachment)
      }
    }
    prepared.config.attachedDatabases = kept
    guard !grants.isEmpty else { return }
    let releaseMain = prepared.release
    prepared.release = { [grants] in
      releaseMain?()
      for grant in grants { grant.release() }
    }
  }

  private func isBlockedFile(_ path: String, engine: DatabaseType) -> Bool {
    SQLiteFileAccess.refusesAttaching(
      path, engine: engine, lockSource: lockSource, servesMCP: servesMCP)
  }

  /// `SELECT 1` on a SQLite or DuckDB database, then close. The grant is released either way.
  private func probeFile(_ config: ConnectionConfig) async throws -> Bool {
    let prepared = try await prepareSQLiteOpen(config)
    // The file the bookmark resolved to, as on connect
    if let refusal = lockSource.refusal(for: prepared.config) {
      prepared.release?()
      throw refusal
    }
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

  // MARK: - Vault Lease

  /// Whether this manager holds a Vault lease (revoked by `disconnect`).
  nonisolated var holdsLease: Bool {
    leaseSlot.withLock { $0 != nil }
  }

  /// A quit closes this manager: it has a post-disconnect script or a Vault lease.
  nonisolated var closesAtQuit: Bool {
    hasPendingPostDisconnect || holdsLease
  }

  /// The held Vault lease, if any
  nonisolated var vaultLease: VaultLeaseManager? {
    leaseSlot.withLock { $0?.lease }
  }

  /// The lease the session of a `key` connection uses: the held one when `disconnect` kept it
  /// (same key), else a new one, held from now on. Nil for a connection without Vault.
  /// `took`: this connect took it (revoked again when the connect fails).
  private func leaseForConnect(
    _ key: VaultLeaseKey?, config: ConnectionConfig
  ) async throws -> (lease: VaultLeaseManager?, took: Bool) {
    if let held = leaseSlot.withLock({ $0 }), held.key != key {
      await revokeLease()
    }
    guard let key else { return (nil, false) }
    if let held = vaultLease { return (held, false) }
    let lease = try await vaultLeasing.take(for: config)
    let replaced = leaseSlot.withLock { slot in
      defer { slot = VaultLeaseSlot(key: key, lease: lease) }
      return slot
    }
    // Another connect took one meanwhile: only the newest is held
    if let replaced { await Self.revoke(replaced) }
    return (lease, true)
  }

  /// A failed connect's own lease: out of the slot only while the slot still holds it (a newer
  /// connect's lease stays), then revoked (again, when whoever replaced it revoked it already).
  private func revokeOwnLease(_ lease: VaultLeaseManager) async {
    leaseSlot.withLock { if $0?.lease.leaseID == lease.leaseID { $0 = nil } }
    await lease.revoke()
  }

  /// Takes the held lease out of the slot (its renewal cancelled at once), then revokes it.
  private func revokeLease() async {
    if let slot = takeLeaseSlot() { await Self.revoke(slot) }
  }

  private nonisolated func takeLeaseSlot() -> VaultLeaseSlot? {
    leaseSlot.withLock { slot in
      defer { slot = nil }
      slot?.lease.cancelRenewal()
      return slot
    }
  }

  private static func revoke(_ slot: VaultLeaseSlot) async {
    await slot.lease.revoke()
  }

  /// Runs `body` with `saved`'s client certificate and SSH secret (the caller's scoped ones, else
  /// the Keychain's) scoped under the accounts of `session`, the config with the lease username,
  /// which both accounts include. `body` alone when `session` has no Vault source.
  func withLeaseAccounts<T: Sendable>(
    _ session: ConnectionConfig, saved: ConnectionConfig, _ body: () async throws -> T
  ) async throws -> T {
    guard session.vault != nil else { return try await body() }
    let material =
      saved.clientCertificate == nil ? nil : ClientCertificateStoreFactory.load(for: saved)
    let scoped = material.map {
      ClientCertificateStoreFactory.ScopedMaterial(
        account: ClientCertificateStoreFactory.account(for: session), material: $0)
    }
    let scopedSSH = SSHCredentialStoreFactory.scoped(
      SSHCredentialStoreFactory.load(for: saved), for: session)
    defer {
      scoped?.clear()
      scopedSSH?.clear()
    }
    return try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
        try await body()
      }
    }
  }

  /// The renewal of lease `leaseID` reported its end. Applied only while it is still the held
  /// lease: the session is forgotten and closed as `disconnect` does, then reported lost
  /// (`SessionLostEvent`, `lastLeaseEnd`), never reconnected. In the middle of a reset (no
  /// session) only the end is recorded: the reset sees the empty slot and reports the loss. A
  /// Vault or network blip never gets here (it is retried until the lease's known expiry).
  private func vaultLeaseEnded(leaseID: String, reason: VaultLeaseEnd.Reason) async {
    let held = leaseSlot.withLock { slot -> VaultLeaseManager? in
      guard let lease = slot?.lease, lease.leaseID == leaseID else { return nil }
      slot = nil
      return lease
    }
    guard let held else { return }
    // An AppRole login token outlives its lease: revoked once the loss is reported, unless Vault
    // refused it already
    let revokesToken = reason != .tokenGone
    guard session != nil else {
      lastLeaseEnd = VaultLeaseEnd(reason: reason, epoch: connectionEpoch)
      if revokesToken { await held.revokeOwnedToken() }
      return
    }
    let event = SessionLostEvent(state: txState, userTxOpen: userTxOpen, epoch: connectionEpoch)
    lastLeaseEnd = VaultLeaseEnd(reason: reason, epoch: event.epoch)
    let forgotten = forgetConnection()
    activeUnrememberedCertificate = nil
    activeUnrememberedSSHCredential = nil
    lastSessionLoss = event
    await AppLogger.shared.warning("Vault lease ended: \(reason)", category: "Database")
    await Self.closeForgotten(forgotten, includingConnection: true)
    sessionEventsContinuation.yield(event)
    if revokesToken { await held.revokeOwnedToken() }
  }

  /// Stores the hook `disconnect` calls after the session closes. Passing nil clears it.
  func setSQLiteFileAccessRelease(_ release: (@Sendable () -> Void)?) {
    sqliteFileAccessRelease = release
  }

  /// Disconnect from database. The picked DuckDB files go with the connection. The main
  /// connection's post-disconnect script runs after the close, without being awaited. A Vault
  /// lease is revoked once the session is closed (revoking first would leave an open session
  /// that only fails its next query).
  func disconnect() async {
    await disconnect(keepingLeaseFor: nil)
  }

  /// `disconnect`, keeping a held Vault lease of key `leaseKey` (an internal reset)
  private func disconnect(keepingLeaseFor leaseKey: VaultLeaseKey?) async {
    let lease = leaseSlot.withLock { $0?.key } == leaseKey ? nil : takeLeaseSlot()
    let postDisconnect = takePendingPostDisconnect()
    duckDBAllowedPaths = []
    activeUnrememberedCertificate = nil
    activeUnrememberedSSHCredential = nil
    let releaseFileAccess = sqliteFileAccessRelease
    sqliteFileAccessRelease = nil

    let forgotten = forgetConnection()
    lastSessionLoss = nil
    lastLeaseEnd = nil

    if forgotten.session != nil {
      await AppLogger.shared.info("Disconnecting from database", category: "Database")
      await Self.closeForgotten(forgotten, includingConnection: true)
    }
    if let lease { await Self.revoke(lease) }

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
    postDisconnect?.run()
  }

  /// Forget the current connection before any suspension point: no edit can use its targets,
  /// and a statement failing meanwhile sees the connection gone (state stays idle). Closing it
  /// (or the server closing it) rolls back any open transaction on the server.
  /// A PostgreSQL or MySQL session is detached synchronously (`.closedByApp`) so its socket or
  /// SSH tunnel close is not a loss. Any other session is closed by the caller.
  func forgetConnection() -> ForgottenSession {
    connectionEpoch &+= 1
    let forgotten = session
    let resources = (forgotten as? PostgresSession)?.detach() ?? DetachedPostgresSession()
    let mysql = (forgotten as? MySQLSession)?.detach()
    // The server rolls back what was open, except a COMMIT already sent (the app's or the
    // user's): unknown, so the entries stay pending (unconfirmed)
    closeRewindEntries(
      as: txState.endingKind == .commit || userCommitsInFlight > 0 ? nil : .discarded)
    session = nil
    config = nil
    writeUnlockExpiry = nil
    activeUnrememberedVaultSecret = nil
    sqliteReadOnlyReason = nil
    attachWarnings = []
    txState = .idle
    userTxOpen = false
    schemaRefreshPending = false
    schemaDirtyInAppTx = false
    schemaDirtyInUserTx = false
    editTableCache.removeAll()
    mysqlTableColumns.removeAll()
    columnTypeCache.removeAll()
    mysqlTempTables.reset()
    return ForgottenSession(
      session: forgotten, connection: resources.connection, group: resources.group,
      tunnel: resources.tunnel, mysql: mysql)
  }

  /// Close what `forgetConnection` returned. PostgreSQL closes the detached socket, its SSH
  /// tunnel (always, even when the socket is already closed) and its event-loop group, in that
  /// order; MySQL its socket, SSH forwarder, tunnel and group. Any other session closes itself.
  static func closeForgotten(_ forgotten: ForgottenSession, includingConnection: Bool) async {
    if let mysql = forgotten.mysql {
      await mysql.close(includingConnection: includingConnection)
      return
    }
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
  /// The execution gate enforces the stricter of this and the caller's policy. A running write
  /// unlock lowers Read-only to Schema only (`ProtectionPolicy.unlockingWrites`).
  var connectedPolicy: ProtectionPolicy {
    ProtectionPolicy(config: config).unlockingWrites(isWriteUnlocked)
  }

  /// A timed write unlock of this session runs now. Never on an MCP manager.
  var isWriteUnlocked: Bool {
    guard !servesMCP, let writeUnlockExpiry else { return false }
    return now() < writeUnlockExpiry
  }

  /// Starts (or restarts) the write unlock of this session for `duration`. Returns its end, or
  /// nil when refused: an MCP manager, not connected, or a connected config the unlock cannot
  /// write (`ProtectionPolicy.writeUnlockRefusal`). Nothing is written to `config`.
  func unlockWrites(for duration: TimeInterval) -> Date? {
    guard !servesMCP, let config, ProtectionPolicy.writeUnlockRefusal(for: config) == nil else {
      return nil
    }
    let expiry = now().addingTimeInterval(duration)
    writeUnlockExpiry = expiry
    return expiry
  }

  /// Ends the write unlock of this session (no-op when none runs)
  func lockWrites() {
    writeUnlockExpiry = nil
  }

  /// The workspace's mask rules changed (another window saved a removal): the connected config
  /// takes them, so the next query masks with them. No-op when not connected, or connected to
  /// another connection than `workspaceConfig` meanwhile.
  func updateConnectedMaskRules(_ rules: [ColumnMaskRule], of workspaceConfig: ConnectionConfig) {
    guard let config, config.databaseType == workspaceConfig.databaseType,
      ConnectionKeychainKey.password(for: config)
        == ConnectionKeychainKey.password(for: workspaceConfig)
    else { return }
    self.config?.maskRules = rules
  }

  /// Apply a runtime change of the connection's protection settings (protection level,
  /// commit style, Safe Mode, protected mode) to the connected config. No-op when not
  /// connected. `connectedPolicy` still reads only `protectedMode` from that config.
  func updateConnectedProtection(from newConfig: ConnectionConfig) {
    guard config != nil else { return }
    // A changed level ends the write unlock: raising it back never inherits the old one
    if config?.protectionLevel != newConfig.protectionLevel { writeUnlockExpiry = nil }
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
  /// A detached MySQL session's resources.
  var mysql: DetachedMySQLSession?
}

/// A post-disconnect script and the connection it ran for (without its password).
private nonisolated struct PendingScript: Sendable {
  var runner: ConnectionScriptRunner
  var name: String
  var config: ConnectionConfig

  init(runner: ConnectionScriptRunner, name: String, config: ConnectionConfig) {
    self.runner = runner
    self.name = name
    var config = config
    config.password = ""
    self.config = config
  }

  func run() { runner.runPostDisconnect(name, for: config) }
}

/// A SQLite open, plus the sandbox release `disconnect` calls (the main file's and the attached
/// files' grants). `release` is nil for PostgreSQL and for SQLite paths the process can already
/// open.
private struct PreparedSQLiteOpen: Sendable {
  var config: ConnectionConfig
  var release: (@Sendable () -> Void)?
  /// `SQLiteFileAccess.AccessGrant.bannerReason`: set when the app itself opened the file read-only
  var readOnlyReason: String?
  /// The main file has a grant (`release` may also hold only the attached files')
  var hasFileGrant = false
  /// The attached databases left out (`DatabaseConnectionManager.attachWarnings`)
  var warnings: [String] = []
}

/// PostgreSQL stays `PostgresSession`. SQLite is `SQLiteSession` and DuckDB `DuckDBSession`
/// after the caller has resolved sandbox access. MySQL / MariaDB is `MySQLSession`, MongoDB
/// `MongoSession`.
nonisolated struct AppDatabaseSessionFactory: DatabaseSessionFactory {
  /// The DuckDB plugin's loader, or nil when the plugin is not installed. Read on the main actor
  /// before each DuckDB session, after the launch check: a removed plugin stays loaded (and
  /// cached) until the app quits.
  typealias DuckDBLibraryLoader = @Sendable () async -> (@Sendable () throws -> DuckDBLibrary)?

  var hostKeyValidator: any SSHHostKeyValidating = SSHHostKeyPolicy()
  /// What a SQLite session's authorizer checks a typed ATTACH against
  var lockSource: LockRegistry = .shared
  var duckDBLibraryLoader: DuckDBLibraryLoader = { @MainActor in
    guard let manager = PluginRegistry.shared.manager(for: .duckdb),
      await manager.isInstalledAfterLaunchCheck()
    else { return nil }
    return { try manager.loadDuckDBLibrary() }
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
      return SQLiteSession(config: config, lockSource: lockSource)
    case .duckdb:
      guard let load = await duckDBLibraryLoader() else {
        throw DatabaseError.engineUnavailable(.duckdb)
      }
      // `open()` runs the loader (hash, signature check, dlopen) on the session's own queue.
      return DuckDBSession(config: config, extraAllowedPaths: extraAllowedPaths, loadLibrary: load)
    case .mysql:
      return MySQLSession(config: config, hostKeyValidator: hostKeyValidator)
    case .mongodb:
      return MongoSession(config: config, hostKeyValidator: hostKeyValidator)
    }
  }
}
