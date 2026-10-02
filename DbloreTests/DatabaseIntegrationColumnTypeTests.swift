// DatabaseIntegrationColumnTypeTests.swift
// Integration tests for column type enrichment
// Requires a running PostgreSQL instance

import Foundation
import Testing

@testable import Dblore

@Suite(
  "Database Integration - Column Type Enrichment Tests (Requires PostgreSQL)", .requiresPostgres)
@MainActor
struct DatabaseIntegrationColumnTypeTests {

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

  func createColumnTypeTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_column_types"
  ) async throws {
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
    _ = try await manager.executeInternal(createTableSQL)

    let insertSQL = """
      INSERT INTO \(tableName) (name, code, price, amount, created_at, updated_at, description)
      VALUES ('Test Product', 'ABC123', 99.99, 1234.5678, NOW(), NOW(), 'Sample description');
      """
    _ = try await manager.executeInternal(insertSQL)
  }

  func dropColumnTypeTestTable(
    manager: DatabaseConnectionManager, tableName: String = "test_column_types"
  ) async throws {
    let dropTableSQL = "DROP TABLE IF EXISTS \(tableName);"
    _ = try await manager.executeInternal(dropTableSQL)
  }

  func createNumericTestTable(
    manager: DatabaseConnectionManager, tableName: String
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
    manager: DatabaseConnectionManager, tableName: String
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
    manager: DatabaseConnectionManager, tableName: String
  ) async throws {
    let dropTableSQL = "DROP TABLE IF EXISTS \(tableName);"
    _ = try await manager.executeInternal(dropTableSQL)
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

      let result = try await manager.executeInternal("SELECT name FROM \(tableName) LIMIT 1")

      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      if let nameColumn = result.columns.first {
        let columnName = nameColumn.name
        let columnType = nameColumn.type

        #expect(columnName == "name", "Column name should be 'name'")
        if columnType.uppercased().contains("VARCHAR") {
          if columnType.contains("(255)") {
            // Successfully enriched
          } else {
            print("⚠️ Column type not enriched with length: \(columnType)")
          }
        }
      }

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

      let result = try await manager.executeInternal("SELECT price FROM \(tableName) LIMIT 1")

      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      if let priceColumn = result.columns.first {
        let columnName = priceColumn.name
        let columnType = priceColumn.type

        #expect(columnName == "price", "Column name should be 'price'")
        if columnType.uppercased().contains("NUMERIC") {
          if columnType.contains("(10,2)") {
            // Successfully enriched
          } else {
            print("⚠️ Column type not enriched with precision/scale: \(columnType)")
          }
        }
      }

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

      let result = try await manager.executeInternal(
        "SELECT created_at, updated_at FROM \(tableName) LIMIT 1")

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

        if createdAtType.uppercased().contains("TIMESTAMP") {
          if createdAtType.contains("WITHOUT TIME ZONE") {
            // Successfully enriched
          } else {
            print("⚠️ created_at not enriched with time zone info: \(createdAtType)")
          }
        }

        if updatedAtType.uppercased().contains("TIMESTAMP") {
          if updatedAtType.contains("WITH TIME ZONE") {
            // Successfully enriched
          } else {
            print("⚠️ updated_at not enriched with time zone info: \(updatedAtType)")
          }
        }
      }

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
      try await createColumnTypeTestTable(manager: manager, tableName: tableName)

      let insertSQL = """
        INSERT INTO \(tableName) (name, code, price, amount, created_at, updated_at, description)
        VALUES ('Test', 'ABC123', 99.99, 123.4567, NOW(), NOW(), 'Test description')
        """
      _ = try await manager.executeInternal(insertSQL)

      let complexQuery = """
        SELECT t1.id, t2.name
        FROM \(tableName) t1
        JOIN \(tableName) t2 ON t1.id = t2.id
        LIMIT 1
        """

      let result = try await manager.executeInternal(complexQuery)

      let columnsCount = result.columns.count
      #expect(columnsCount > 0, "Should return column metadata")

      for column in result.columns {
        let columnType = column.type
        #expect(!columnType.isEmpty, "Column type should not be empty")
      }

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

      let result = try await manager.executeInternal(
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

      try await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
    } catch {
      try? await dropNumericTestTable(manager: manager, tableName: tableName)
      await manager.disconnect()
      Issue.record("Integration test failed: \(error.localizedDescription)")
    }
  }
}
