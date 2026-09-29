//
//  DatabaseConnectionManager.swift
//  Dblore
//

import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

/// Actor managing PostgreSQL database connections and query execution
actor DatabaseConnectionManager {
  private var connection: PostgresConnection?
  /// Fails in-flight queries when `connection` closes (see `send(on:_:)`)
  private(set) var closeWatch: ConnectionCloseWatch?
  private var eventLoopGroup: EventLoopGroup?
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
  /// Queries waiting in `send(on:)`: queued on the connection or running (see
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

  init() {
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

  /// Retry configuration for connection attempts
  private static let maxRetries = 3
  // 1s, 2s, 4s in nanoseconds
  private static let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

  /// Current database type (nil if not connected)
  var databaseType: DatabaseType? {
    config?.databaseType
  }

  // MARK: - Connection Management

  /// Helper method to perform connection with retry logic
  /// Implements exponential backoff: 1s, 2s, 4s delays
  /// - Parameters:
  ///   - group: EventLoopGroup for the connection
  ///   - config: PostgreSQL connection configuration
  ///   - timeoutSeconds: Connection timeout in seconds
  ///   - attempt: Current attempt number (0-indexed)
  /// - Returns: Connected PostgresConnection
  /// - Throws: DatabaseError after max retries (3) exhausted or timeout
  private func attemptConnection(
    group: EventLoopGroup,
    config: PostgresConnection.Configuration,
    timeoutSeconds: Int,
    attempt: Int = 0
  ) async throws -> PostgresConnection {
    do {
      // Create a task with timeout
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
      // If timeout occurs, throw immediately without retry
      throw DatabaseError.connectionFailed("Connection timeout after \(timeoutSeconds) seconds")
    } catch {
      // If we've exhausted retries, throw the error
      if attempt >= Self.maxRetries {
        throw error
      }

      // Wait with exponential backoff before retry
      let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
      try await Task.sleep(nanoseconds: delay)

      // Retry with incremented attempt counter
      return try await attemptConnection(
        group: group, config: config, timeoutSeconds: timeoutSeconds, attempt: attempt + 1)
    }
  }

  /// Connect to PostgreSQL database
  func connect(config: ConnectionConfig) async throws {
    // Log connection attempt (with sanitized config)
    await AppLogger.shared.info(
      "Attempting to connect to database: \(config.safeDisplayString)", category: "Database")

    // Disconnect if already connected. Nothing of the new connection (connection, config,
    // epoch) is published until its session brakes are applied.
    await disconnect()

    // Create event loop group
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    eventLoopGroup = group

    // Configure PostgreSQL connection with TLS
    let tlsConfig: PostgresConnection.Configuration.TLS
    do {
      tlsConfig = try configureTLS(for: config.sslMode)
    } catch {
      // Cleanup on TLS configuration failure
      try? await group.shutdownGracefully()
      eventLoopGroup = nil
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }

    let postgresConfig = PostgresConnection.Configuration(
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      database: config.database,
      tls: tlsConfig
    )

    // Establish connection with retry logic
    let conn: PostgresConnection
    do {
      conn = try await attemptConnection(
        group: group, config: postgresConfig, timeoutSeconds: config.timeoutSeconds)
    } catch let error as PSQLError {
      // Log connection failure
      await AppLogger.shared.error(
        "Failed to connect to database: \(formatPostgresError(error))", category: "Database")
      // Cleanup on failure
      try? await group.shutdownGracefully()
      self.eventLoopGroup = nil
      let errorMessage = formatPostgresError(error)
      throw DatabaseError.connectionFailed(errorMessage)
    } catch {
      // Cleanup on failure
      try? await group.shutdownGracefully()
      eventLoopGroup = nil
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }

    // Session brakes are mandatory and applied on the local connection before it is published,
    // so no user statement (actor reentrancy) can run before the timeouts are set. On failure
    // the connection is closed and nothing was published.
    let watch = ConnectionCloseWatch(closeFuture: conn.closeFuture)
    do {
      try await applySessionBrakes(on: conn, watch: watch, config: config)
      await applyDisconnectCheck(on: conn, watch: watch)
    } catch {
      await AppLogger.shared.error(
        "Failed to apply session brakes: \(error.localizedDescription)", category: "Database")
      try? await conn.close()
      try? await group.shutdownGracefully()
      eventLoopGroup = nil
      throw error
    }
    connection = conn
    closeWatch = watch
    self.config = config
    connectionEpoch &+= 1
    lastSessionLoss = nil
    // The UI learns about a session the server closed even when no query is running. The
    // epoch names this connection exactly (an ObjectIdentifier can be reused after a reset).
    let epoch = connectionEpoch
    conn.closeFuture.whenComplete { [weak self] _ in
      Task { await self?.markSessionLost(epoch: epoch) }
    }

    await AppLogger.shared.info(
      "Successfully connected to database: \(config.safeDisplayString)", category: "Database")
  }

  /// Test connection without storing it
  /// Performs a real connection AND executes a test query to verify credentials
  func testConnection(config: ConnectionConfig) async throws -> Bool {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    // Configure TLS
    let tlsConfig: PostgresConnection.Configuration.TLS
    do {
      tlsConfig = try configureTLS(for: config.sslMode)
    } catch {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed("Failed to configure TLS: \(error.localizedDescription)")
    }

    let postgresConfig = PostgresConnection.Configuration(
      host: config.host,
      port: config.port,
      username: config.username,
      password: config.password,
      database: config.database,
      tls: tlsConfig
    )

    do {
      let conn = try await attemptConnection(
        group: group, config: postgresConfig, timeoutSeconds: config.timeoutSeconds)

      // Execute a test query to verify the connection actually works
      // This ensures credentials are valid and we have proper permissions
      let testQuery = PostgresQuery(unsafeSQL: "SELECT 1 as test")
      let stream = try await conn.query(testQuery, logger: Logger(label: "dblore.testquery"))

      // Consume the stream to ensure query completes
      var rowCount = 0
      for try await _ in stream {
        rowCount += 1
      }

      // Verify we got exactly one row back
      guard rowCount == 1 else {
        try await conn.close()
        try await group.shutdownGracefully()
        throw DatabaseError.connectionFailed("Test query returned unexpected results")
      }

      try await conn.close()
      try await group.shutdownGracefully()
      return true
    } catch let error as PSQLError {
      try? await group.shutdownGracefully()
      let errorMessage = formatPostgresError(error)
      throw DatabaseError.connectionFailed(errorMessage)
    } catch {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  /// Disconnect from database
  func disconnect() async {
    let (closing, group) = forgetConnection()
    lastSessionLoss = nil

    if let closing {
      await AppLogger.shared.info("Disconnecting from database", category: "Database")
      try? await closing.close()
    }
    try? await group?.shutdownGracefully()

    // A statement that resumed during the awaits above must not leave a stale state
    if connection == nil {
      txState = .idle
      userTxOpen = false
    }
  }

  /// Forget the current connection before any suspension point: no edit can use its targets,
  /// and a statement failing meanwhile sees the connection gone (state stays idle). Closing it
  /// (or the server closing it) rolls back any open transaction on the server.
  func forgetConnection() -> (connection: PostgresConnection?, group: EventLoopGroup?) {
    connectionEpoch &+= 1
    let forgotten = (connection, eventLoopGroup)
    connection = nil
    closeWatch = nil
    eventLoopGroup = nil
    config = nil
    txState = .idle
    userTxOpen = false
    editTableCache.removeAll()
    return forgotten
  }

  /// Check if currently connected
  var isConnected: Bool {
    connection != nil
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

  /// Access to internal connection for extensions
  var _connection: PostgresConnection? {
    connection
  }

  // MARK: - TLS Configuration

  /// Configure TLS settings based on SSL mode
  /// - Parameter sslMode: The SSL mode from connection configuration
  /// - Returns: PostgreSQL TLS configuration
  /// - Throws: Error if TLS configuration fails
  private func configureTLS(for sslMode: SSLMode) throws -> PostgresConnection.Configuration.TLS {
    switch sslMode {
    case .disable:
      return .disable

    case .allow, .prefer:
      // For .allow/.prefer modes, try to use TLS but fall back to unencrypted if unavailable
      // Use default client configuration with full verification
      do {
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        return .prefer(context)
      } catch {
        throw DatabaseError.connectionFailed(
          "Failed to create TLS context for prefer mode: \(error.localizedDescription)")
      }

    case .require:
      // For .require mode, use full certificate verification
      // This is the PostgreSQL standard behavior - verify certificates if possible
      // Note: If you need to connect to servers with self-signed certificates,
      // you should add the CA certificate to the system trust store or use .allow/.prefer modes
      do {
        let sslConfig = TLSConfiguration.makeClientConfiguration()
        let context = try NIOSSLContext(configuration: sslConfig)
        return .require(context)
      } catch {
        throw DatabaseError.connectionFailed(
          "Failed to create TLS context for require mode: \(error.localizedDescription)")
      }

    case .verifyCa, .verifyFull:
      // For .verifyCa/.verifyFull modes, enforce full certificate verification
      // These modes provide the highest security by validating the server certificate
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
}
