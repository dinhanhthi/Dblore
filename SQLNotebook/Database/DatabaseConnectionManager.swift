//
//  DatabaseConnectionManager.swift
//  SQLNotebook
//

import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

/// Actor managing PostgreSQL database connections and query execution
actor DatabaseConnectionManager {
  private var connection: PostgresConnection?
  private var eventLoopGroup: EventLoopGroup?
  private var config: ConnectionConfig?

  /// Default maximum number of rows to fetch from database to prevent memory issues
  /// This is overridden by the notebook's maxRowLimit setting
  static let defaultMaxFetchRows = 100

  /// Retry configuration for connection attempts
  private static let maxRetries = 3
  private static let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000] // 1s, 2s, 4s in nanoseconds

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
  ///   - attempt: Current attempt number (0-indexed)
  /// - Returns: Connected PostgresConnection
  /// - Throws: DatabaseError after max retries (3) exhausted
  private func attemptConnection(
    group: EventLoopGroup,
    config: PostgresConnection.Configuration,
    attempt: Int = 0
  ) async throws -> PostgresConnection {
    do {
      let conn = try await PostgresConnection.connect(
        on: group.next(),
        configuration: config,
        id: 1,
        logger: Logger(label: "sqlnotebook.connection")
      )
      return conn
    } catch {
      // If we've exhausted retries, throw the error
      if attempt >= Self.maxRetries {
        throw error
      }

      // Wait with exponential backoff before retry
      let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
      try await Task.sleep(nanoseconds: delay)

      // Retry with incremented attempt counter
      return try await attemptConnection(group: group, config: config, attempt: attempt + 1)
    }
  }

  /// Connect to PostgreSQL database
  func connect(config: ConnectionConfig) async throws {
    // Disconnect if already connected
    await disconnect()

    // Store config
    self.config = config

    // Create event loop group
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    eventLoopGroup = group

    // Configure PostgreSQL connection
    let tlsConfig: PostgresConnection.Configuration.TLS
    switch config.sslMode {
    case .disable:
      tlsConfig = .disable
    case .allow, .prefer:
      tlsConfig = .prefer(try! NIOSSLContext(configuration: .makeClientConfiguration()))
    case .require:
      // Use .require for cloud databases with valid certificates
      // Note: Certificate verification is set to .none to allow self-signed or cloud provider certs
      var sslConfig = TLSConfiguration.makeClientConfiguration()
      sslConfig.certificateVerification = .none
      tlsConfig = .require(try! NIOSSLContext(configuration: sslConfig))
    case .verifyCa, .verifyFull:
      var sslConfig = TLSConfiguration.makeClientConfiguration()
      sslConfig.certificateVerification = .fullVerification
      tlsConfig = .require(try! NIOSSLContext(configuration: sslConfig))
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
    do {
      let conn = try await attemptConnection(group: group, config: postgresConfig)
      connection = conn
    } catch let error as PSQLError {
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
  }

  /// Test connection without storing it
  /// Performs a real connection AND executes a test query to verify credentials
  func testConnection(config: ConnectionConfig) async throws -> Bool {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let tlsConfig: PostgresConnection.Configuration.TLS
    switch config.sslMode {
    case .disable:
      tlsConfig = .disable
    case .allow, .prefer:
      tlsConfig = .prefer(try! NIOSSLContext(configuration: .makeClientConfiguration()))
    case .require:
      // Use .require for cloud databases with certificate verification disabled
      // This allows connection to cloud providers like Supabase that use valid certs
      // but may not be in the system trust store
      var sslConfig = TLSConfiguration.makeClientConfiguration()
      sslConfig.certificateVerification = .none
      tlsConfig = .require(try! NIOSSLContext(configuration: sslConfig))
    case .verifyCa, .verifyFull:
      var sslConfig = TLSConfiguration.makeClientConfiguration()
      sslConfig.certificateVerification = .fullVerification
      tlsConfig = .require(try! NIOSSLContext(configuration: sslConfig))
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
      let conn = try await attemptConnection(group: group, config: postgresConfig)

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

  // MARK: - Internal Access

  /// Access to internal connection for extensions
  var _connection: PostgresConnection? {
    connection
  }
}
