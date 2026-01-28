// DatabaseIntegrationConnectionTests.swift
// Integration tests for Database connection lifecycle and query execution
// Requires a running PostgreSQL instance

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Database Integration - Connection Tests (Requires PostgreSQL)")
@MainActor
struct DatabaseIntegrationConnectionTests {

  // MARK: - Test Configuration

  /// Test database configuration
  static let testConfig = ConnectionConfig(
    host: ProcessInfo.processInfo.environment["TEST_DB_HOST"] ?? "localhost",
    port: Int(ProcessInfo.processInfo.environment["TEST_DB_PORT"] ?? "5432") ?? 5432,
    database: ProcessInfo.processInfo.environment["TEST_DB_NAME"] ?? "postgres",
    username: ProcessInfo.processInfo.environment["TEST_DB_USER"] ?? "postgres",
    password: ProcessInfo.processInfo.environment["TEST_DB_PASSWORD"] ?? "",
    sslMode: .disable,
    timeoutSeconds: 30
  )

  // MARK: - Connection Lifecycle Tests

  @Test("Connect to PostgreSQL database successfully")
  func connectToDatabaseSuccessfully() async throws {
    let manager = DatabaseConnectionManager()

    do {
      try await manager.connect(config: Self.testConfig)
      #expect(await manager.isConnected, "Should be connected after successful connect()")
      await manager.disconnect()
      #expect(await !manager.isConnected, "Should be disconnected after disconnect()")
    } catch {
      Issue.record("Connection test failed: \(error.localizedDescription)")
    }
  }

  @Test("Test connection without actually connecting")
  func testConnectionWithoutConnecting() async throws {
    let manager = DatabaseConnectionManager()

    do {
      _ = try await manager.testConnection(config: Self.testConfig)
      #expect(await !manager.isConnected, "testConnection() should not leave manager connected")
    } catch {
      Issue.record("Test connection failed: \(error.localizedDescription)")
    }
  }

  @Test("Reconnect to database after disconnect")
  func reconnectAfterDisconnect() async throws {
    let manager = DatabaseConnectionManager()

    do {
      // First connection
      try await manager.connect(config: Self.testConfig)
      #expect(await manager.isConnected, "Should be connected")

      // Disconnect
      await manager.disconnect()
      #expect(await !manager.isConnected, "Should be disconnected")

      // Reconnect
      try await manager.connect(config: Self.testConfig)
      #expect(await manager.isConnected, "Should be connected again")

      await manager.disconnect()
    } catch {
      await manager.disconnect()
      Issue.record("Reconnect test failed: \(error.localizedDescription)")
    }
  }

  @Test("Connect with invalid credentials fails")
  func connectWithInvalidCredentialsFails() async throws {
    let manager = DatabaseConnectionManager()
    let invalidConfig = ConnectionConfig(
      host: "localhost",
      port: 5432,
      database: "nonexistent_db",
      username: "invalid_user",
      password: "wrong_password",
      sslMode: .disable,
      timeoutSeconds: 5
    )

    do {
      try await manager.connect(config: invalidConfig)
      Issue.record("Should have failed with invalid credentials")
    } catch {
      #expect(await !manager.isConnected, "Should not be connected after failed attempt")
    }
  }

  // MARK: - Query Execution Tests

  @Test("Execute SELECT query successfully")
  func executeSelectQuerySuccessfully() async throws {
    let manager = DatabaseConnectionManager()

    do {
      try await manager.connect(config: Self.testConfig)

      let result = try await manager.executeQuery("SELECT 1 AS num, 'test' AS str")

      #expect(result.rows.count == 1, "Should return 1 row")
      #expect(result.columns.count == 2, "Should have 2 columns")
      #expect(result.columns[0].name == "num", "First column should be 'num'")
      #expect(result.columns[1].name == "str", "Second column should be 'str'")

      if let firstRow = result.rows.first {
        #expect(firstRow.count == 2, "Row should have 2 values")
      }

      await manager.disconnect()
    } catch {
      await manager.disconnect()
      Issue.record("SELECT query test failed: \(error.localizedDescription)")
    }
  }

  @Test("Execute INSERT, UPDATE, DELETE queries")
  func executeModificationQueries() async throws {
    let manager = DatabaseConnectionManager()

    do {
      try await manager.connect(config: Self.testConfig)

      // Create test table
      let createTable = """
        CREATE TEMPORARY TABLE test_modifications (
            id SERIAL PRIMARY KEY,
            name VARCHAR(100),
            value INTEGER
        )
        """
      _ = try await manager.executeQuery(createTable)

      // INSERT
      let insertSQL =
        "INSERT INTO test_modifications (name, value) VALUES ('test1', 100), ('test2', 200)"
      let insertResult = try await manager.executeQuery(insertSQL)
      #expect(insertResult.rows.isEmpty, "INSERT should return no rows")

      // SELECT to verify INSERT
      let selectResult = try await manager.executeQuery("SELECT COUNT(*) FROM test_modifications")
      if let firstRow = selectResult.rows.first,
        let firstValue = firstRow.first,
        case .int(let count) = firstValue
      {
        #expect(count == 2, "Should have inserted 2 rows")
      } else {
        Issue.record("Failed to verify INSERT")
      }

      // UPDATE
      let updateSQL = "UPDATE test_modifications SET value = 150 WHERE name = 'test1'"
      _ = try await manager.executeQuery(updateSQL)

      // SELECT to verify UPDATE
      let verifyUpdate = try await manager.executeQuery(
        "SELECT value FROM test_modifications WHERE name = 'test1'")
      if let firstRow = verifyUpdate.rows.first,
        let firstValue = firstRow.first,
        case .int(let value) = firstValue
      {
        #expect(value == 150, "Value should be updated to 150")
      } else {
        Issue.record("Failed to verify UPDATE")
      }

      // DELETE
      let deleteSQL = "DELETE FROM test_modifications WHERE name = 'test2'"
      _ = try await manager.executeQuery(deleteSQL)

      // SELECT to verify DELETE
      let verifyDelete = try await manager.executeQuery("SELECT COUNT(*) FROM test_modifications")
      if let firstRow = verifyDelete.rows.first,
        let firstValue = firstRow.first,
        case .int(let count) = firstValue
      {
        #expect(count == 1, "Should have 1 row remaining after DELETE")
      } else {
        Issue.record("Failed to verify DELETE")
      }

      await manager.disconnect()
    } catch {
      await manager.disconnect()
      Issue.record("Modification queries test failed: \(error.localizedDescription)")
    }
  }

  // MARK: - JSON/JSONB Type Mapping Tests

  @Test("JSONB values decode correctly")
  func jsonbValuesDecodeCorrectly() async throws {
    let manager = DatabaseConnectionManager()

    do {
      try await manager.connect(config: Self.testConfig)

      // Create test table with JSONB
      let createTable = """
        CREATE TEMPORARY TABLE test_jsonb (
            id SERIAL PRIMARY KEY,
            data JSONB
        )
        """
      _ = try await manager.executeQuery(createTable)

      // Insert JSONB data
      let insertSQL = """
        INSERT INTO test_jsonb (data) VALUES
            ('{"name": "John", "age": 30}'::jsonb),
            ('["apple", "banana", "cherry"]'::jsonb),
            ('{"nested": {"key": "value"}}'::jsonb)
        """
      _ = try await manager.executeQuery(insertSQL)

      // Query JSONB data
      let result = try await manager.executeQuery("SELECT data FROM test_jsonb ORDER BY id")

      #expect(result.rows.count == 3, "Should return 3 rows")

      // Verify first row (JSON object)
      if let firstRow = result.rows.first,
        let jsonValue = firstRow.first,
        case .json(let jsonString) = jsonValue
      {
        #expect(jsonString.contains("John"), "JSON should contain 'John'")
        #expect(jsonString.contains("age"), "JSON should contain 'age' key")
      } else {
        Issue.record("Failed to decode JSONB object")
      }

      // Verify second row (JSON array)
      if result.rows.count > 1,
        let secondValue = result.rows[1].first,
        case .json(let jsonString) = secondValue
      {
        #expect(jsonString.contains("apple"), "JSON array should contain 'apple'")
      } else {
        Issue.record("Failed to decode JSONB array")
      }

      await manager.disconnect()
    } catch {
      await manager.disconnect()
      Issue.record("JSONB test failed: \(error.localizedDescription)")
    }
  }

  @Test("DATE and TIMESTAMP types decode correctly")
  func dateAndTimestampTypesDecodeCorrectly() async throws {
    let manager = DatabaseConnectionManager()

    do {
      try await manager.connect(config: Self.testConfig)

      // Create test table with date/time types
      let createTable = """
        CREATE TEMPORARY TABLE test_datetime (
            id SERIAL PRIMARY KEY,
            date_col DATE,
            timestamp_col TIMESTAMP,
            timestamptz_col TIMESTAMPTZ
        )
        """
      _ = try await manager.executeQuery(createTable)

      // Insert date/time data
      let insertSQL = """
        INSERT INTO test_datetime (date_col, timestamp_col, timestamptz_col) VALUES
            ('2024-01-15', '2024-01-15 14:30:00', '2024-01-15 14:30:00+00')
        """
      _ = try await manager.executeQuery(insertSQL)

      // Query date/time data
      let result = try await manager.executeQuery(
        "SELECT date_col, timestamp_col, timestamptz_col FROM test_datetime")

      #expect(result.rows.count == 1, "Should return 1 row")
      #expect(result.columns.count == 3, "Should have 3 columns")

      if let firstRow = result.rows.first {
        #expect(firstRow.count == 3, "Row should have 3 values")

        // All date/time values are decoded as .date type
        for value in firstRow {
          if case .date(let dateValue) = value {
            #expect(dateValue.timeIntervalSince1970 > 0, "Date should be valid")
          } else {
            Issue.record("Date/time value should be decoded as .date type, got: \(value)")
          }
        }
      }

      await manager.disconnect()
    } catch {
      await manager.disconnect()
      Issue.record("DATE/TIMESTAMP test failed: \(error.localizedDescription)")
    }
  }
}
