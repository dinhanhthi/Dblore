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

  /// Current database type (nil if not connected)
  var databaseType: DatabaseType? {
    config?.databaseType
  }

  // MARK: - Connection Management

  /// Connect to PostgreSQL database
  func connect(config: ConnectionConfig) async throws {
    // Disconnect if already connected
    await disconnect()

    // Store config
    self.config = config

    // Create event loop group
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.eventLoopGroup = group

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

    // Establish connection
    do {
      let conn = try await PostgresConnection.connect(
        on: group.next(),
        configuration: postgresConfig,
        id: 1,
        logger: Logger(label: "sqlnotebook.connection")
      )
      self.connection = conn
    } catch {
      // Cleanup on failure
      try? await group.shutdownGracefully()
      self.eventLoopGroup = nil
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
      let conn = try await PostgresConnection.connect(
        on: group.next(),
        configuration: postgresConfig,
        id: 1,
        logger: Logger(label: "sqlnotebook.testconnection")
      )

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
      throw DatabaseError.connectionFailed("Authentication failed: \(error.code.description)")
    } catch {
      try? await group.shutdownGracefully()
      throw DatabaseError.connectionFailed(error.localizedDescription)
    }
  }

  /// Disconnect from database
  func disconnect() async {
    if let conn = connection {
      try? await conn.close()
      self.connection = nil
    }

    if let group = eventLoopGroup {
      try? await group.shutdownGracefully()
      self.eventLoopGroup = nil
    }

    self.config = nil
  }

  /// Check if currently connected
  var isConnected: Bool {
    connection != nil
  }

  // MARK: - Internal Access

  /// Access to internal connection for extensions
  internal var _connection: PostgresConnection? {
    connection
  }
}
