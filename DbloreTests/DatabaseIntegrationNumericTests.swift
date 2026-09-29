// DatabaseIntegrationNumericTests.swift
// Integration tests for NUMERIC type decoding
// Requires a running PostgreSQL instance

import Foundation
import Testing

@testable import Dblore

@Suite("Database Integration - NUMERIC Tests (Requires PostgreSQL)")
@MainActor
struct DatabaseIntegrationNumericTests {

  // MARK: - Test Configuration

  static let testConfig = ConnectionConfig(
    host: TestDatabase.host,
    port: TestDatabase.port,
    database: TestDatabase.database,
    username: TestDatabase.username,
    password: TestDatabase.password,
    sslMode: .disable,
    timeoutSeconds: 30
  )

  // MARK: - Setup Helpers

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
    _ = try await manager.executeInternal(createTableSQL)
  }

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
    _ = try await manager.executeInternal(insertSQL)
  }

  func dropNumericTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_numeric_values"
  ) async throws {
    let dropTableSQL = "DROP TABLE IF EXISTS \(tableName);"
    _ = try await manager.executeInternal(dropTableSQL)
  }

  // MARK: - NUMERIC Decoding Integration Tests

  @Test("NUMERIC(10,2) values decode correctly to Double - Integration Test")
  func numericDecimalDecodesToDoubleIntegration() async throws {
    let manager = DatabaseConnectionManager()
    let tableName = "test_numeric_decimal_\(UUID().uuidString.prefix(8))"

    do {
      try await manager.connect(config: Self.testConfig)
      try await createNumericTestTable(manager: manager, tableName: tableName)
      try await insertNumericTestData(manager: manager, tableName: tableName)

      let result = try await manager.executeInternal("SELECT price FROM \(tableName) WHERE id = 1")

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

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
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

      let result = try await manager.executeInternal(
        "SELECT quantity FROM \(tableName) WHERE id = 1")

      let rowsCount = result.rows.count
      let quantityValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let quantityValue = quantityValue, case .double(let quantity) = quantityValue {
        #expect(abs(quantity - 123456789.1234) < 0.0001, "NUMERIC(15,4) should decode correctly")
      } else {
        Issue.record("Expected .double value, got \(String(describing: quantityValue))")
      }

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

      let result = try await manager.executeInternal("SELECT price FROM \(tableName) WHERE id = 4")

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

      let result = try await manager.executeInternal(
        "SELECT negative_value FROM \(tableName) WHERE id = 1")

      let rowsCount = result.rows.count
      let negativeValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let negativeValue = negativeValue, case .double(let value) = negativeValue {
        #expect(abs(value - (-1329.98)) < 0.01, "Negative NUMERIC should decode correctly")
        #expect(value < 0, "Value should be negative")
      } else {
        Issue.record("Expected .double value, got \(String(describing: negativeValue))")
      }

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

      let result = try await manager.executeInternal("SELECT price FROM \(tableName) WHERE id = 3")

      let rowsCount = result.rows.count
      let priceValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let priceValue = priceValue, case .double(let value) = priceValue {
        #expect(abs(value - 0.0) < 0.0001, "Zero NUMERIC should decode to 0.0")
      } else {
        Issue.record("Expected .double value, got \(String(describing: priceValue))")
      }

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

      let result = try await manager.executeInternal(
        "SELECT large_number FROM \(tableName) WHERE id = 1")

      let rowsCount = result.rows.count
      let largeValue = result.rows.first?.first

      #expect(rowsCount > 0, "Should return at least one row")

      if let largeValue = largeValue, case .double(let value) = largeValue {
        #expect(
          value > 99999999999998.0,
          "Very large NUMERIC should decode (may lose precision in Double)")
        #expect(
          value <= 100000000000001.0,
          "Very large NUMERIC should be in expected range (allowing for rounding)")
      } else {
        Issue.record("Expected .double value, got \(String(describing: largeValue))")
      }

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }
}
