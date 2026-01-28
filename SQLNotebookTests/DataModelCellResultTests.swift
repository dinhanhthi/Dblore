// DataModelCellResultTests.swift
// Unit tests for CellResult data model

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Data Model - CellResult Tests")
@MainActor
struct DataModelCellResultTests {

  // MARK: - CellResult with all CellValue types

  @Test("CellResult with all CellValue types")
  func cellResultWithAllValueTypes() throws {
    // Arrange - Test all CellValue types
    let result = CellResult(
      columns: [
        ColumnInfo(name: "str_col", type: "text"),
        ColumnInfo(name: "int_col", type: "integer"),
        ColumnInfo(name: "double_col", type: "double precision"),
        ColumnInfo(name: "bool_col", type: "boolean"),
        ColumnInfo(name: "null_col", type: "text"),
        ColumnInfo(name: "json_col", type: "jsonb"),
        ColumnInfo(name: "date_col", type: "timestamp"),
        ColumnInfo(name: "data_col", type: "bytea"),
      ],
      rows: [
        [
          .string("test"),
          .int(42),
          .double(3.14159),
          .bool(true),
          .null,
          .json("{\"key\":\"value\"}"),
          .date(Date()),
          .data(Data([0x01, 0x02, 0x03])),
        ]
      ],
      executionTime: 0.05,
      rowCount: 1,
      timestamp: Date()
    )

    // Act - Encode and decode
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(result)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CellResult.self, from: data)

    // Assert
    #expect(decoded.columns.count == 8)
    #expect(decoded.rows.count == 1)
    #expect(decoded.rows[0].count == 8)

    // Verify each value type
    if case .string(let str) = decoded.rows[0][0] {
      #expect(str == "test")
    } else {
      Issue.record("Expected string value")
    }

    if case .int(let num) = decoded.rows[0][1] {
      #expect(num == 42)
    } else {
      Issue.record("Expected int value")
    }

    if case .double(let num) = decoded.rows[0][2] {
      #expect(abs(num - 3.14159) < 0.00001)
    } else {
      Issue.record("Expected double value")
    }

    if case .bool(let flag) = decoded.rows[0][3] {
      #expect(flag == true)
    } else {
      Issue.record("Expected bool value")
    }

    if case .null = decoded.rows[0][4] {
      #expect(Bool(true))
    } else {
      Issue.record("Expected null value")
    }

    if case .json(let json) = decoded.rows[0][5] {
      #expect(json == "{\"key\":\"value\"}")
    } else {
      Issue.record("Expected json value")
    }

    if case .date = decoded.rows[0][6] {
      #expect(Bool(true))
    } else {
      Issue.record("Expected date value")
    }

    if case .data(let bytes) = decoded.rows[0][7] {
      #expect(bytes == Data([0x01, 0x02, 0x03]))
    } else {
      Issue.record("Expected data value")
    }
  }

  @Test("CellResult error result factory method")
  func cellResultErrorFactory() {
    // Act
    let errorResult = CellResult.errorResult(
      "Connection timeout",
      executionTime: 30.0,
      sourceQuery: "SELECT * FROM slow_table"
    )

    // Assert
    #expect(errorResult.error == "Connection timeout")
    #expect(errorResult.executionTime == 30.0)
    #expect(errorResult.sourceQuery == "SELECT * FROM slow_table")
    #expect(errorResult.columns.count == 0)
    #expect(errorResult.rows.count == 0)
  }

  @Test("CellResult with modification query metadata")
  func cellResultModificationQuery() throws {
    // Arrange - Test UPDATE/DELETE metadata
    let result = CellResult(
      columns: [],
      rows: [],
      executionTime: 0.05,
      rowCount: 0,
      timestamp: Date(),
      sourceQuery: "UPDATE users SET active = true WHERE id > 100",
      affectedRows: 42
    )

    // Act - Encode and decode
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(result)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CellResult.self, from: data)

    // Assert
    #expect(decoded.affectedRows == 42)
    #expect(decoded.columns.count == 0)
    #expect(decoded.rows.count == 0)
  }

  @Test("CellResult with row limit metadata")
  func cellResultRowLimitMetadata() throws {
    // Arrange
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: [[.int(1)], [.int(2)]],
      executionTime: 0.01,
      rowCount: 2,
      timestamp: Date(),
      wasLimited: true,
      userLimitExceeded: true,
      userRequestedLimit: 10000
    )

    // Act - Round-trip
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(CellResult.self, from: data)

    // Assert
    #expect(decoded.wasLimited == true)
    #expect(decoded.userLimitExceeded == true)
    #expect(decoded.userRequestedLimit == 10000)
  }

  @Test("CellResult - User LIMIT exceeds maxRows but database has fewer rows than maxRows")
  func cellResultUserLimitExceedsButFewerActualRows() throws {
    // Scenario: Database has 36 rows, maxRows setting is 100, user query has LIMIT 130
    // Expected: No warning should be shown because actual rows (36) < maxRows (100)

    // Arrange - Simulate 36 rows returned
    let rows = (1...36).map { [CellValue.int($0)] }
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: rows,
      executionTime: 0.01,
      rowCount: 36,
      timestamp: Date(),
      wasLimited: false,
      userLimitExceeded: false,
      userRequestedLimit: nil
    )

    // Act - Round-trip encoding/decoding
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(CellResult.self, from: data)

    // Assert - No warning should be shown
    #expect(decoded.userLimitExceeded == false)
    #expect(decoded.userRequestedLimit == nil)
    #expect(decoded.rowCount == 36)
  }

  @Test("CellResult - User LIMIT exceeds maxRows AND database returns maxRows")
  func cellResultUserLimitExceedsAndMaxRowsReturned() throws {
    // Scenario: Database has 200 rows, maxRows setting is 100, user query has LIMIT 130
    // Expected: Warning should be shown because actual rows returned = maxRows (100)

    // Arrange - Simulate 100 rows returned (capped at maxRows)
    let rows = (1...100).map { [CellValue.int($0)] }
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: rows,
      executionTime: 0.01,
      rowCount: 100,
      timestamp: Date(),
      wasLimited: false,
      userLimitExceeded: true,
      userRequestedLimit: 100
    )

    // Act - Round-trip encoding/decoding
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(CellResult.self, from: data)

    // Assert - Warning should be shown
    #expect(decoded.userLimitExceeded == true)
    #expect(decoded.userRequestedLimit == 100)
    #expect(decoded.rowCount == 100)
  }
}
