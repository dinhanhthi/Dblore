//
//  DatabaseConnectionManager.swift
//  SQLNotebook
//

import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

/// Error thrown when a task exceeds its timeout
struct TimeoutError: Error {
  let message: String
}

/// Execute an async operation with a timeout
/// - Parameters:
///   - duration: Maximum duration before timing out
///   - operation: The async operation to execute
/// - Returns: Result from the operation
/// - Throws: TimeoutError if operation exceeds duration, or any error from the operation
private func withTimeout<T: Sendable>(
  of duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    // Add the main operation task
    group.addTask {
      try await operation()
    }

    // Add the timeout task
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError(message: "Operation timed out after \(duration)")
    }

    // Wait for first task to complete (either operation or timeout)
    if let result = try await group.next() {
      group.cancelAll()
      return result
    }

    throw TimeoutError(message: "Unexpected task group completion")
  }
}

/// Actor managing PostgreSQL database connections and query execution
actor DatabaseConnectionManager {
  private var connection: PostgresConnection?
  private var eventLoopGroup: EventLoopGroup?
  private var config: ConnectionConfig?
  /// Identity of the current connection: advanced on every disconnect and successful connect,
  /// so an inline edit target resolved on another connection is refused (`executeGatedUpdate`).
  private(set) var connectionEpoch: UInt64 = 0

  /// Default maximum number of rows to fetch from database to prevent memory issues
  /// This is overridden by the notebook's maxRowLimit setting
  static let defaultMaxFetchRows = 100

  /// Retry configuration for connection attempts
  private static let maxRetries = 3
  private static let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]  // 1s, 2s, 4s in nanoseconds

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
          logger: Logger(label: "sqlnotebook.connection")
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
    do {
      try await applySessionBrakes(on: conn, config: config)
    } catch {
      await AppLogger.shared.error(
        "Failed to apply session brakes: \(error.localizedDescription)", category: "Database")
      try? await conn.close()
      try? await group.shutdownGracefully()
      eventLoopGroup = nil
      throw error
    }
    connection = conn
    self.config = config
    connectionEpoch &+= 1

    await AppLogger.shared.info(
      "Successfully connected to database: \(config.safeDisplayString)", category: "Database")
  }

  /// Apply the session brakes (`brakeStatements`) on a connection that is not published yet.
  /// - Throws: `DatabaseError.connectionFailed` if any statement fails.
  private func applySessionBrakes(
    on conn: PostgresConnection, config: ConnectionConfig
  )
    async throws
  {
    for sql in Self.brakeStatements(for: config) {
      do {
        _ = try await conn.query(
          PostgresQuery(unsafeSQL: sql), logger: Logger(label: "sqlnotebook.session")
        ).get()
      } catch let error as PSQLError {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(formatPostgresError(error))")
      } catch {
        throw DatabaseError.connectionFailed(
          "Could not apply session safety settings (\(sql)): \(error.localizedDescription)")
      }
    }
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
      let stream = try await conn.query(testQuery, logger: Logger(label: "sqlnotebook.testquery"))

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
    // Before any suspension point: no edit can use the closing connection's targets
    connectionEpoch &+= 1

    // Log disconnection if we were connected
    if connection != nil {
      await AppLogger.shared.info("Disconnecting from database", category: "Database")
    }

    if let conn = connection {
      try? await conn.close()
      connection = nil
    }

    if let group = eventLoopGroup {
      try? await group.shutdownGracefully()
      eventLoopGroup = nil
    }

    config = nil
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
