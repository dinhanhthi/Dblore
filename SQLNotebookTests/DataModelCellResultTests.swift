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

  @Test("CellResult drops the LIMIT-rewrite / ctid fields but still decodes JSON carrying them")
  func cellResultLegacyLimitKeys() throws {
    let legacyKeys = [
      "rowIdentifiers", "userLimitExceeded", "userRequestedLimit", "limitWasCapped",
      "actualLimitUsed",
    ]
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")], rows: [[.int(1)], [.int(2)]],
      rowCount: 2, wasLimited: true)
    let data = try JSONEncoder().encode(result)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in legacyKeys { #expect(dict[key] == nil, "\(key) still encoded") }

    // Old JSON carrying the legacy keys still decodes
    dict["rowIdentifiers"] = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode([CellValue.string("(0,1)"), .string("(0,2)")]))
    dict["userLimitExceeded"] = true
    dict["userRequestedLimit"] = 500
    dict["limitWasCapped"] = true
    dict["actualLimitUsed"] = 100
    let legacy = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(CellResult.self, from: legacy)
    #expect(decoded.rowCount == 2)
    #expect(decoded.wasLimited)
    #expect(decoded.rows == [[.int(1)], [.int(2)]])
  }
}
