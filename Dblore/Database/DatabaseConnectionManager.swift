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
  /// Production uses `PostgresSessionFactory`. Tests inject another `DatabaseSessionFactory`.
  private let sessionFactory: any DatabaseSessionFactory
  private(set) var config: ConnectionConfig?
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
  /// Reads that went through a server-side cursor (`executeCursorRead`); observed by tests
  var cursorReadCount = 0
  /// App catalog queries that passed `catalogConnection()`; observed by performance tests
  var catalogQueryCount = 0
  /// Queries waiting in `performSend`: queued on the connection or running (see
  /// `resetSessionIfCapped`)
  var activeSends = 0
  /// Caller token (tab) that opened the app transaction: while it is pending, only this caller
  /// may run gated statements. Claimed before BEGIN is sent, cleared when the state is idle.
  var txOwner: UUID?
  /// A transaction the user opened with BEGIN while Protected mode was off
  var userTxOpen = false
  /// Inline edit tables resolved outside any app transaction, by table OID (see `cachedEditTable`)
  var editTableCache: [UInt32: EditTable] = [:]
  /// The last server-closed session (cleared on connect / disconnect), see `markSessionLost`
  var lastSessionLoss: SessionLostEvent?
  /// The last user cancel (see `cancelRunningStatement`): statements of its epoch fail with
  /// `DatabaseError.queryCancelled`
  var lastCancel: QueryCancelRecord?
  /// One `SessionLostEvent` each time the server (or the network) closes the connected session
  nonisolated let sessionEvents: AsyncStream<SessionLostEvent>
  let sessionEventsContinuation: AsyncStream<SessionLostEvent>.Continuation
  /// One `SessionResetEvent` each time a capped read closed and reopened the session
  nonisolated let sessionResets: AsyncStream<SessionResetEvent>
  let sessionResetsContinuation: AsyncStream<SessionResetEvent>.Continuation

  init(sessionFactory: any DatabaseSessionFactory = PostgresSessionFactory()) {
    self.sessionFactory = sessionFactory
    (sessionEvents, sessionEventsContinuation) = AsyncStream.makeStream(
      of: SessionLostEvent.self, bufferingPolicy: .bufferingNewest(8))
    (sessionResets, sessionResetsContinuation) = AsyncStream.makeStream(
      of: SessionResetEvent.self, bufferingPolicy: .bufferingNewest(8))
  }

  deinit {
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
  /// no user statement can run before the timeouts are set.
  func connect(config: ConnectionConfig) async throws {
    await AppLogger.shared.info(
      "Attempting to connect to database: \(config.safeDisplayString)", category: "Database")

    // Disconnect if already connected. Nothing of the new connection (session, config,
    // epoch) is published until its session brakes are applied.
    await disconnect()

    let opening = sessionFactory.makeSession(config: config)
    do {
      try await opening.open()
    } catch {
      await opening.close()
      throw error
    }

    do {
      try await opening.applySessionSettings(
        statementTimeoutSeconds: SessionBrakeLimits.clampStatementTimeout(
          config.statementTimeoutSeconds),
        lockTimeoutSeconds: SessionBrakeLimits.clampLockTimeout(config.lockTimeoutSeconds),
        idleTimeoutSeconds: SessionBrakeLimits.clampIdleTimeout(
          config.idleInTransactionTimeoutSeconds))
      if let postgres = opening as? PostgresSession {
        await postgres.applyDisconnectCheck()
      }
    } catch {
      await AppLogger.shared.error(
        "Failed to apply session brakes: \(error.localizedDescription)", category: "Database")
      await opening.close()
      throw error
    }

    session = opening
    self.config = config
    connectionEpoch &+= 1
    lastSessionLoss = nil
    // The UI learns about a session the server closed even when no query is running.
    observeSession(opening, epoch: connectionEpoch)

    await AppLogger.shared.info(
      "Successfully connected to database: \(config.safeDisplayString)", category: "Database")
  }

  /// Test connection without storing it.
  /// Performs a real connection AND executes a test query to verify credentials.
  func testConnection(config: ConnectionConfig) async throws -> Bool {
    try await PostgresSession(config: config).probe()
  }

  /// Disconnect from database
  func disconnect() async {
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
    }
  }

  /// Forget the current connection before any suspension point: no edit can use its targets,
  /// and a statement failing meanwhile sees the connection gone (state stays idle). Closing it
  /// (or the server closing it) rolls back any open transaction on the server.
  /// A PostgreSQL session is detached synchronously (`.closedByApp`) so its socket close is not
  /// a loss. Any other session is closed by the caller.
  func forgetConnection() -> ForgottenSession {
    connectionEpoch &+= 1
    let forgotten = session
    let resources = (forgotten as? PostgresSession)?.detach() ?? (nil, nil)
    session = nil
    config = nil
    txState = .idle
    userTxOpen = false
    editTableCache.removeAll()
    return ForgottenSession(
      session: forgotten, connection: resources.0, group: resources.1)
  }

  /// Close what `forgetConnection` returned. PostgreSQL closes the detached socket and its
  /// event-loop group. Any other session closes itself.
  static func closeForgotten(_ forgotten: ForgottenSession, includingConnection: Bool) async {
    if forgotten.connection != nil || forgotten.group != nil {
      if includingConnection { try? await forgotten.connection?.close() }
      try? await forgotten.group?.shutdownGracefully()
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
  /// Safe Mode, protected mode) to the connected config. No-op when not connected.
  func updateConnectedProtection(from newConfig: ConnectionConfig) {
    guard config != nil else { return }
    config?.protectionLevel = newConfig.protectionLevel
    config?.safeMode = newConfig.safeMode
    config?.protectedMode = newConfig.protectedMode
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
}
