// DatabaseIntegrationNumericTests.swift
// Integration tests for NUMERIC type decoding
// Requires a running PostgreSQL instance

import Foundation
import Testing

@testable import Dblore

@Suite("Database Integration - NUMERIC Tests (Requires PostgreSQL)", .requiresPostgres)
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

  @Test("NUMERIC(10,2) values decode to their exact text - Integration Test")
  func numericDecimalDecodesExactIntegration() async throws {
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

      #expect(priceValue == .decimal("1329.98"), "NUMERIC(10,2) 1329.98 should decode exactly")

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("NUMERIC(15,4) high precision values decode exactly - Integration Test")
  func numericHighPrecisionDecodesExactIntegration() async throws {
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

      #expect(quantityValue == .decimal("123456789.1234"), "NUMERIC(15,4) should decode exactly")

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

  @Test("Negative NUMERIC values decode exactly - Integration Test")
  func negativeNumericDecodesExactIntegration() async throws {
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

      #expect(negativeValue == .decimal("-1329.98"), "Negative NUMERIC should decode exactly")

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Zero NUMERIC value decodes to 0.00, its scale kept - Integration Test")
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

      #expect(priceValue == .decimal("0.00"), "Zero NUMERIC(10,2) should decode to 0.00")

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }

  @Test("Very large NUMERIC values decode exactly - Integration Test")
  func veryLargeNumericDecodesExactIntegration() async throws {
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

      #expect(
        largeValue == .decimal("99999999999999.99"), "Very large NUMERIC should decode exactly")

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }
}
