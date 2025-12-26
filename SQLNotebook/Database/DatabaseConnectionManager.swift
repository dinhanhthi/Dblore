//
//  DatabaseConnectionManager.swift
//  SQLNotebook
//

import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOSSL
import PostgresNIO

/// Actor managing PostgreSQL database connections and query execution
actor DatabaseConnectionManager {
  private var connection: PostgresConnection?
  private var eventLoopGroup: EventLoopGroup?
  private var config: ConnectionConfig?

  /// Maximum number of rows to fetch from database to prevent memory issues
  static let maxFetchRows = 500

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

  // MARK: - Schema Introspection

  /// Fetch all tables from the database
  func fetchTables() async throws -> [DatabaseTable] {
    guard let connection = connection else {
      throw DatabaseError.notConnected
    }

    let query = """
      SELECT
        table_schema,
        table_name
      FROM information_schema.tables
      WHERE table_schema NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND table_type = 'BASE TABLE'
      ORDER BY table_schema, table_name
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var tables: [DatabaseTable] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        guard let schemaCell = randomAccess.first,
              let nameCell = randomAccess.dropFirst().first,
              let schema = try? schemaCell.decode(String.self, context: .default),
              let name = try? nameCell.decode(String.self, context: .default)
        else {
          continue
        }

        tables.append(DatabaseTable(schema: schema, name: name))
      }

      return tables
    } catch {
      throw DatabaseError.queryFailed("Failed to fetch tables: \(error.localizedDescription)", 0)
    }
  }

  /// Fetch columns for a specific table
  func fetchColumns(tableSchema: String, tableName: String) async throws -> [DatabaseColumn] {
    guard let connection = connection else {
      throw DatabaseError.notConnected
    }

    // Use string interpolation for now since parameter binding is complex with PostgresNIO
    let query = """
      SELECT
        column_name,
        data_type,
        is_nullable,
        column_default
      FROM information_schema.columns
      WHERE table_schema = '\(tableSchema)'
        AND table_name = '\(tableName)'
      ORDER BY ordinal_position
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      var columns: [DatabaseColumn] = []

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        let cells = Array(randomAccess)
        guard cells.count >= 3 else { continue }

        guard let columnName = try? cells[0].decode(String.self, context: .default),
              let dataType = try? cells[1].decode(String.self, context: .default),
              let isNullableStr = try? cells[2].decode(String.self, context: .default)
        else {
          continue
        }

        let isNullable = isNullableStr.uppercased() == "YES"

        // TODO: Detect primary keys from constraints (for now, set to false)
        let isPrimaryKey = false

        columns.append(
          DatabaseColumn(
            name: columnName,
            type: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey
          )
        )
      }

      return columns
    } catch {
      throw DatabaseError.queryFailed(
        "Failed to fetch columns for \(tableSchema).\(tableName): \(error.localizedDescription)",
        0
      )
    }
  }

  /// Fetch row count for a specific table
  func fetchRowCount(tableSchema: String, tableName: String) async throws -> Int {
    guard let connection = connection else {
      throw DatabaseError.notConnected
    }

    // Use COUNT(*) to get exact row count
    let query = """
      SELECT COUNT(*) as row_count
      FROM "\(tableSchema)".\"\(tableName)\"
      """

    do {
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook.schema")
      )

      for try await row in stream {
        let randomAccess = row.makeRandomAccess()

        if let countCell = randomAccess.first,
           let count = try? countCell.decode(Int.self, context: .default) {
          return count
        }
      }

      return 0
    } catch {
      // If fetching row count fails, return 0 instead of throwing
      print("Failed to fetch row count for \(tableSchema).\(tableName): \(error)")
      return 0
    }
  }

  // MARK: - Query Execution

  /// Execute a SQL query and return results
  func executeQuery(_ query: String) async throws -> QueryResult {
    guard let connection = connection else {
      throw DatabaseError.notConnected
    }

    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DatabaseError.emptyQuery
    }

    let startTime = Date()

    do {
      // Execute query and collect rows
      let stream = try await connection.query(
        PostgresQuery(unsafeSQL: query),
        logger: Logger(label: "sqlnotebook")
      )

      var columns: [ColumnInfo] = []
      var resultRows: [[CellValue]] = []
      var isFirstRow = true

      var wasLimited = false

      for try await row in stream {
        // Stop fetching if we've reached the limit
        if resultRows.count >= Self.maxFetchRows {
          wasLimited = true
          break
        }

        let randomAccess = row.makeRandomAccess()

        // On first row, extract column metadata from PostgresCells
        if isFirstRow {
          // PostgresRandomAccessRow is a Sequence of PostgresCell
          for cell in randomAccess {
            columns.append(
              ColumnInfo(
                name: cell.columnName,
                type: postgresDataTypeName(cell.dataType)
              ))
          }
          isFirstRow = false
        }

        // Parse values for each cell
        var rowValues: [CellValue] = []
        for cell in randomAccess {
          let value = parseCellValue(from: cell)
          rowValues.append(value)
        }
        resultRows.append(rowValues)
      }

      let executionTime = Date().timeIntervalSince(startTime)

      return QueryResult(
        columns: columns,
        rows: resultRows,
        rowCount: resultRows.count,
        executionTime: executionTime,
        wasLimited: wasLimited
      )

    } catch let error as PSQLError {
      let executionTime = Date().timeIntervalSince(startTime)
      throw DatabaseError.queryFailed(error.code.description, executionTime)
    } catch {
      let executionTime = Date().timeIntervalSince(startTime)
      throw DatabaseError.queryFailed(error.localizedDescription, executionTime)
    }
  }

  // MARK: - Type Mapping

  /// Map PostgreSQL data type to display name
  private func postgresDataTypeName(_ dataType: PostgresDataType) -> String {
    switch dataType {
    case .bool:
      return "BOOLEAN"
    case .int2:
      return "SMALLINT"
    case .int4:
      return "INTEGER"
    case .int8:
      return "BIGINT"
    case .float4:
      return "REAL"
    case .float8:
      return "DOUBLE PRECISION"
    case .numeric:
      return "NUMERIC"
    case .money:
      return "MONEY"
    case .char:
      return "CHAR"
    case .varchar:
      return "VARCHAR"
    case .text:
      return "TEXT"
    case .bytea:
      return "BYTEA"
    case .date:
      return "DATE"
    case .timestamp:
      return "TIMESTAMP"
    case .timestamptz:
      return "TIMESTAMPTZ"
    case .time:
      return "TIME"
    case .timetz:
      return "TIMETZ"
    case .interval:
      return "INTERVAL"
    case .uuid:
      return "UUID"
    case .json:
      return "JSON"
    case .jsonb:
      return "JSONB"
    case .xml:
      return "XML"
    case .point:
      return "POINT"
    case .inet:
      return "INET"
    case .cidr:
      return "CIDR"
    case .macaddr:
      return "MACADDR"
    default:
      return "UNKNOWN"
    }
  }

  /// Parse a cell value from PostgresCell
  private func parseCellValue(from cell: PostgresCell) -> CellValue {
    // Check for NULL first
    guard cell.bytes != nil else {
      return .null
    }

    // Parse based on PostgreSQL data type
    switch cell.dataType {
    case .bool:
      if let value = try? cell.decode(Bool.self, context: .default) {
        return .bool(value)
      }

    case .int2:
      if let value = try? cell.decode(Int16.self, context: .default) {
        return .int(Int(value))
      }

    case .int4:
      if let value = try? cell.decode(Int32.self, context: .default) {
        return .int(Int(value))
      }

    case .int8:
      if let value = try? cell.decode(Int64.self, context: .default) {
        return .int(Int(value))
      }

    case .float4:
      if let value = try? cell.decode(Float.self, context: .default) {
        return .double(Double(value))
      }

    case .float8:
      if let value = try? cell.decode(Double.self, context: .default) {
        return .double(value)
      }

    case .numeric, .money:
      if let value = try? cell.decode(String.self, context: .default) {
        if let doubleValue = Double(value) {
          return .double(doubleValue)
        }
        return .string(value)
      }

    case .char, .varchar, .text:
      if let value = try? cell.decode(String.self, context: .default) {
        return .string(value)
      }

    case .date, .timestamp, .timestamptz:
      if let value = try? cell.decode(Date.self, context: .default) {
        return .date(value)
      }

    case .uuid:
      if let value = try? cell.decode(UUID.self, context: .default) {
        return .string(value.uuidString)
      }

    case .json, .jsonb:
      if let value = try? cell.decode(String.self, context: .default) {
        return .json(value)
      }

    case .bytea:
      if let value = try? cell.decode(ByteBuffer.self, context: .default) {
        return .data(Data(buffer: value))
      }

    default:
      // Default: try to decode as string
      if let value = try? cell.decode(String.self, context: .default) {
        // Check if it looks like JSON
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespaces)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
          || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
          return .json(value)
        }
        return .string(value)
      }
    }

    return .null
  }
}

// MARK: - Supporting Types

/// Result of a query execution
struct QueryResult: Sendable {
  let columns: [ColumnInfo]
  let rows: [[CellValue]]
  let rowCount: Int
  let executionTime: TimeInterval
  /// True if the result was limited due to reaching maxFetchRows
  let wasLimited: Bool

  nonisolated init(
    columns: [ColumnInfo], rows: [[CellValue]], rowCount: Int, executionTime: TimeInterval,
    wasLimited: Bool = false
  ) {
    self.columns = columns
    self.rows = rows
    self.rowCount = rowCount
    self.executionTime = executionTime
    self.wasLimited = wasLimited
  }
}

/// Database-specific errors
enum DatabaseError: LocalizedError {
  case notConnected
  case connectionFailed(String)
  case queryFailed(String, TimeInterval)
  case emptyQuery

  var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Not connected to database"
    case .connectionFailed(let message):
      return "Connection failed: \(message)"
    case .queryFailed(let message, _):
      return "Query failed: \(message)"
    case .emptyQuery:
      return "Query is empty"
    }
  }

  var executionTime: TimeInterval? {
    if case .queryFailed(_, let time) = self {
      return time
    }
    return nil
  }
}
