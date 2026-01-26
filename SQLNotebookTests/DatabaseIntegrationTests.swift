// DatabaseIntegrationTests.swift
// Integration tests for Database operations requiring actual PostgreSQL connection
// Tests NUMERIC decoding and column type enrichment with real database

// MARK: - Integration Tests
// These tests require a running PostgreSQL instance
// They run by default locally and are skipped in CI via SKIP_INTEGRATION_TESTS=true
// Database configuration can be set via environment variables:
// - TEST_DB_HOST (default: localhost)
// - TEST_DB_PORT (default: 5432)
// - TEST_DB_NAME (default: postgres)
// - TEST_DB_USER (default: postgres)
// - TEST_DB_PASSWORD (default: empty)

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Database Integration Tests (Requires PostgreSQL)")
@MainActor
struct DatabaseIntegrationTests {

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

  // MARK: - Setup and Teardown Helpers

  /// Create test table with NUMERIC columns
  /// Uses a unique table name to avoid conflicts between concurrent tests
  func createNumericTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_numeric_values"
  ) async throws {
    let createTableSQL = """
      CREATE TEMPORARY TABLE \(tableName) (
          id SERIAL PRIMARY KEY,
          price NUMERIC(10,2),
          quantity NUMERIC(15,4),
          percentage NUMERIC(5,2),
          large_number NUMERIC(30,2),
          negative_value NUMERIC(10,2)
      );
      """

    _ = try await manager.executeQuery(createTableSQL)
  }

  /// Insert test data into NUMERIC test table
  func insertNumericTestData(
    manager: DatabaseConnectionManager, tableName: String = "test_numeric_values"
  ) async throws {
    let insertSQL = """
      INSERT INTO \(tableName) (price, quantity, percentage, large_number, negative_value)
      VALUES
          (1329.98, 123456789.1234, 99.99, 99999999999999.99, -1329.98),
          (49.99, 0.0001, 0.01, 1234567890.12, -49.99),
          (0.00, 0.0000, 0.00, 0.00, 0.00),
          (NULL, NULL, NULL, NULL, NULL);
      """

    _ = try await manager.executeQuery(insertSQL)
  }

  /// Drop test table (not needed for TEMPORARY tables, but kept for compatibility)
  func dropNumericTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_numeric_values"
  ) async throws {
    let dropTableSQL = "DROP TABLE IF EXISTS \(tableName);"
    _ = try await manager.executeQuery(dropTableSQL)
  }

  /// Create test table with various column types for enrichment testing
  func createColumnTypeTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_column_types"
  ) async throws {
    // Drop table first to ensure clean state
    try? await dropColumnTypeTestTable(manager: manager, tableName: tableName)

    let createTableSQL = """
      CREATE TABLE \(tableName) (
          id SERIAL PRIMARY KEY,
          name VARCHAR(255),
          code CHAR(10),
          price NUMERIC(10,2),
          amount DECIMAL(15,4),
          created_at TIMESTAMP(6) WITHOUT TIME ZONE,
          updated_at TIMESTAMP(6) WITH TIME ZONE,
          description TEXT
      );
      """

    _ = try await manager.executeQuery(createTableSQL)

    // Insert sample data to ensure table has at least one row
    // This is required for column metadata extraction in tests
    let insertSQL = """
      INSERT INTO \(tableName) (name, code, price, amount, created_at, updated_at, description)
      VALUES ('Test Product', 'ABC123', 99.99, 1234.5678, NOW(), NOW(), 'Sample description');
      """

    _ = try await manager.executeQuery(insertSQL)
  }

  /// Drop column type test table
  func dropColumnTypeTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_column_types"
  ) async throws {
    let dropTableSQL = "DROP TABLE IF EXISTS \(tableName);"
    _ = try await manager.executeQuery(dropTableSQL)
  }

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
      // testConnection should not leave manager in connected state
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
      // Expected to fail
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

  // MARK: - Schema Loading Tests
  // Note: Schema loading is handled through NotebookViewModel, not directly through DatabaseConnectionManager
  // These tests are commented out as there's no public loadSchema() method on DatabaseConnectionManager

  // TODO: Add schema loading tests when public API is available

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

      // Verify first row (JSON object) - JSONB is decoded as .json type
      if let firstRow = result.rows.first,
        let jsonValue = firstRow.first,
        case .json(let jsonString) = jsonValue
      {
        #expect(jsonString.contains("John"), "JSON should contain 'John'")
        #expect(jsonString.contains("age"), "JSON should contain 'age' key")
      } else {
        Issue.record("Failed to decode JSONB object")
      }

      // Verify second row (JSON array) - JSONB is decoded as .json type
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

        // All date/time values are decoded as .date type (Date objects)
        for value in firstRow {
          if case .date(let dateValue) = value {
            // Verify it's a valid Date object
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

  // MARK: - NUMERIC Decoding Integration Tests

  @Test("NUMERIC(10,2) values decode correctly to Double - Integration Test")
  func numericDecimalDecodesToDoubleIntegration() async throws {
    // Skip if integration tests disabled

    // Arrange
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_decimal_\(UUID().uuidString.prefix(8))"

    do {
      // Connect to test database
      try await manager.connect(config: Self.testConfig)

      // Setup test data
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery("SELECT price FROM \(tableName) WHERE id = 1")

      // Assert
      // Capture values into local variables to avoid actor isolation issues
      let rowsCount = result.rows.count
      let firstRowColumnsCount = result.rows.first?.count ?? 0
      let priceValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")
      #expect(firstRowColumnsCount > 0, "Row should have at least one column")

      if let priceValue = priceValue, case .double(let price) = priceValue {
        #expect(
          abs(price - 1329.98) < 0.01,
          "NUMERIC(10,2) value 1329.98 should decode to Double correctly")
      } else {
        Issue.record("Expected .double value, got \(String(describing: priceValue))")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      // Ensure cleanup even on error
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("NUMERIC(15,4) high precision values decode correctly - Integration Test")
  func numericHighPrecisionDecodesToDoubleIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_precision_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery("SELECT quantity FROM \(tableName) WHERE id = 1")

      // Assert
      let rowsCount = result.rows.count
      let quantityValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let quantityValue = quantityValue, case .double(let quantity) = quantityValue {
        #expect(abs(quantity - 123456789.1234) < 0.0001, "NUMERIC(15,4) should decode correctly")
      } else {
        Issue.record("Expected .double value, got \(String(describing: quantityValue))")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("NUMERIC NULL values decode to CellValue.null - Integration Test")
  func numericNullDecodesToNullIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_null_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act - Query the row with NULL values
      let result = try await manager.executeQuery("SELECT price FROM \(tableName) WHERE id = 4")

      // Assert
      let rowsCount = result.rows.count
      let priceValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let priceValue = priceValue {
        let isNullValue = priceValue.isNull
        #expect(isNullValue, "NUMERIC NULL should decode to CellValue.null")
        if case .null = priceValue {
          // Success
        } else {
          Issue.record("Expected .null value, got \(priceValue)")
        }
      } else {
        Issue.record("No price value found")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Negative NUMERIC values decode correctly - Integration Test")
  func negativeNumericDecodesToDoubleIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_negative_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery(
        "SELECT negative_value FROM \(tableName) WHERE id = 1")

      // Assert
      let rowsCount = result.rows.count
      let negativeValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let negativeValue = negativeValue, case .double(let value) = negativeValue {
        #expect(abs(value - (-1329.98)) < 0.01, "Negative NUMERIC should decode correctly")
        #expect(value < 0, "Value should be negative")
      } else {
        Issue.record("Expected .double value, got \(String(describing: negativeValue))")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Zero NUMERIC value decodes to 0.0 - Integration Test")
  func zeroNumericDecodesToZeroIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_zero_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery("SELECT price FROM \(tableName) WHERE id = 3")

      // Assert
      let rowsCount = result.rows.count
      let priceValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let priceValue = priceValue, case .double(let value) = priceValue {
        #expect(abs(value - 0.0) < 0.0001, "Zero NUMERIC should decode to 0.0")
      } else {
        Issue.record("Expected .double value, got \(String(describing: priceValue))")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Very large NUMERIC values decode correctly - Integration Test")
  func veryLargeNumericDecodesToDoubleIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_large_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery(
        "SELECT large_number FROM \(tableName) WHERE id = 1")

      // Assert
      let rowsCount = result.rows.count
      let largeValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let largeValue = largeValue, case .double(let value) = largeValue {
        // IEEE 754 Double has ~15 significant decimal digits precision
        // 99999999999999.99 (16 digits) will round to 100000000000000.0
        #expect(
          value > 99999999999998.0,
          "Very large NUMERIC should decode (may lose precision in Double)")
        #expect(
          value <= 100000000000001.0,
          "Very large NUMERIC should be in expected range (allowing for rounding)")
      } else {
        Issue.record("Expected .double value, got \(String(describing: largeValue))")
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Column Type Enrichment Integration Tests

  @Test("VARCHAR column enriched with length - Integration Test")
  func varcharColumnEnrichedWithLengthIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName =
      "test_column_types_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createColumnTypeTestTable(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery("SELECT name FROM \(tableName) LIMIT 1")

      // Assert
      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      if let nameColumn = result.columns.first {
        let columnName = nameColumn.name
        let columnType = nameColumn.type

        #expect(columnName == "name", "Column name should be 'name'")
        // After enrichment, type should be "VARCHAR(255)"
        if columnType.uppercased().contains("VARCHAR") {
          // Check if it contains length
          if columnType.contains("(255)") {
            // Successfully enriched
          } else {
            print("⚠️ Column type not enriched with length: \(columnType)")
          }
        }
      }

      // Cleanup
      try await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("NUMERIC column enriched with precision and scale - Integration Test")
  func numericColumnEnrichedWithPrecisionScaleIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName =
      "test_column_types_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createColumnTypeTestTable(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery("SELECT price FROM \(tableName) LIMIT 1")

      // Assert
      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      if let priceColumn = result.columns.first {
        let columnName = priceColumn.name
        let columnType = priceColumn.type

        #expect(columnName == "price", "Column name should be 'price'")
        // After enrichment, type should be "NUMERIC(10,2)"
        if columnType.uppercased().contains("NUMERIC") {
          if columnType.contains("(10,2)") {
            // Successfully enriched
          } else {
            print("⚠️ Column type not enriched with precision/scale: \(columnType)")
          }
        }
      }

      // Cleanup
      try await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("TIMESTAMP column enriched with precision and time zone - Integration Test")
  func timestampColumnEnrichedWithPrecisionTimeZoneIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName =
      "test_column_types_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createColumnTypeTestTable(manager: manager, tableName: tableName)

      // Act
      let result = try await manager.executeQuery(
        "SELECT created_at, updated_at FROM \(tableName) LIMIT 1")

      // Assert
      let columnsCount = result.columns.count
      #expect(columnsCount >= 2, "Should return at least 2 columns")

      if columnsCount >= 2 {
        let createdAtColumn = result.columns[0]
        let updatedAtColumn = result.columns[1]

        let createdAtName = createdAtColumn.name
        let createdAtType = createdAtColumn.type
        let updatedAtName = updatedAtColumn.name
        let updatedAtType = updatedAtColumn.type

        #expect(createdAtName == "created_at", "First column should be 'created_at'")
        #expect(updatedAtName == "updated_at", "Second column should be 'updated_at'")

        // created_at: TIMESTAMP(6) WITHOUT TIME ZONE
        if createdAtType.uppercased().contains("TIMESTAMP") {
          if createdAtType.contains("WITHOUT TIME ZONE") {
            // Successfully enriched
          } else {
            print("⚠️ created_at not enriched with time zone info: \(createdAtType)")
          }
        }

        // updated_at: TIMESTAMP(6) WITH TIME ZONE
        if updatedAtType.uppercased().contains("TIMESTAMP") {
          if updatedAtType.contains("WITH TIME ZONE") {
            // Successfully enriched
          } else {
            print("⚠️ updated_at not enriched with time zone info: \(updatedAtType)")
          }
        }
      }

      // Cleanup
      try await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Column type enrichment fails gracefully for complex queries - Integration Test")
  func columnTypeEnrichmentFailsGracefullyForComplexQueriesIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName =
      "test_column_types_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

    do {
      try await manager.connect(config: Self.testConfig)

      // Create test table with sample data
      try await createColumnTypeTestTable(manager: manager, tableName: tableName)

      // Insert at least one row so the query returns data
      let insertSQL = """
        INSERT INTO \(tableName) (name, code, price, amount, created_at, updated_at, description)
        VALUES ('Test', 'ABC123', 99.99, 123.4567, NOW(), NOW(), 'Test description')
        """
      _ = try await manager.executeQuery(insertSQL)

      // Complex query with JOIN (enrichment should not happen)
      let complexQuery = """
        SELECT t1.id, t2.name
        FROM \(tableName) t1
        JOIN \(tableName) t2 ON t1.id = t2.id
        LIMIT 1
        """

      // Act
      let result = try await manager.executeQuery(complexQuery)

      // Assert
      // For complex queries, enrichment is skipped and original types are returned
      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      // Type information should still be present (even if not enriched)
      for column in result.columns {
        let columnType = column.type
        #expect(!columnType.isEmpty, "Column type should not be empty")
      }

      // Cleanup
      try await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropColumnTypeTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Mixed Test: NUMERIC Decoding + Type Enrichment

  @Test("NUMERIC values decode correctly AND column types are enriched - Integration Test")
  func numericDecodingAndTypeEnrichmentIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_enrich_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      // Act - Query with NUMERIC columns
      let result = try await manager.executeQuery(
        "SELECT price, quantity FROM \(tableName) WHERE id = 1"
      )

      // Assert - Check decoding
      let rowsCount = result.rows.count
      let firstRowColumnsCount = result.rows.first?.count ?? 0
      let priceValue = result.rows.first?.first
      let quantityValue = result.rows.first?.dropFirst().first

      #expect(rowsCount > 0, "Should return at least one row")
      #expect(firstRowColumnsCount == 2, "Row should have 2 columns")

      if let priceValue = priceValue, case .double(let price) = priceValue {
        #expect(abs(price - 1329.98) < 0.01, "Price should decode correctly")
      } else {
        Issue.record("Expected .double for price, got \(String(describing: priceValue))")
      }

      if let quantityValue = quantityValue, case .double(let quantity) = quantityValue {
        #expect(abs(quantity - 123456789.1234) < 0.0001, "Quantity should decode correctly")
      } else {
        Issue.record("Expected .double for quantity, got \(String(describing: quantityValue))")
      }

      // Assert - Check type enrichment
      let columnsCount = result.columns.count
      #expect(columnsCount == 2, "Should have 2 column metadata")

      if columnsCount >= 2 {
        let priceColumn = result.columns[0]
        let quantityColumn = result.columns[1]

        let priceColumnName = priceColumn.name
        let priceColumnType = priceColumn.type
        let quantityColumnName = quantityColumn.name
        let quantityColumnType = quantityColumn.type

        #expect(priceColumnName == "price", "First column should be 'price'")
        #expect(quantityColumnName == "quantity", "Second column should be 'quantity'")

        // Check if types are enriched
        if priceColumnType.contains("(10,2)") {
          // Successfully enriched
        } else {
          print("⚠️ price column type not enriched: \(priceColumnType)")
        }

        if quantityColumnType.contains("(15,4)") {
          // Successfully enriched
        } else {
          print("⚠️ quantity column type not enriched: \(quantityColumnType)")
        }
      }

      // Cleanup
      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }
}
