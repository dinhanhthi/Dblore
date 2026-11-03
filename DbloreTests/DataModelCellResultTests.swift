// DataModelCellResultTests.swift
// Unit tests for CellResult data model

import Foundation
import Testing

@testable import Dblore

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

  // MARK: - Decimal order

  @Test("Decimals order by exact value, beside ints and doubles, NULL last")
  func decimalOrderCore() {
    #expect(CellValue.decimal("-0.5") < .decimal("0.25"))
    #expect(CellValue.decimal("9") < .decimal("10"))
    #expect(CellValue.decimal("1.25") < .decimal("1.5"))
    #expect(!(CellValue.decimal("1.50") < .decimal("1.5")))
    #expect(!(CellValue.decimal("1.5") < .decimal("1.50")))
    #expect(CellValue.decimal("-10") < .decimal("-9.99"))
    // Past Double: these two share one Double
    #expect(CellValue.decimal("9007199254740993") > .decimal("9007199254740992"))
    #expect(CellValue.decimal("0.1") < .decimal("0.10000000000000000001"))
    #expect(CellValue.decimal("1") < .null)
    #expect(!(CellValue.null < .decimal("1")))
    // Mixed with integers and doubles (a double by its shortest text)
    #expect(CellValue.int(2) < .decimal("2.5"))
    #expect(CellValue.decimal("2.5") < .int(3))
    #expect(CellValue.decimal("0.1") < .double(0.2))
    #expect(!(CellValue.decimal("0.1") < .double(0.1)))
    #expect(!(CellValue.double(0.1) < .decimal("0.1")))
    #expect(CellValue.double(1e-7) < .decimal("0.0000002"))
    #expect(CellValue.decimal("100000000000000000001") > .double(1e20))
    // PostgreSQL's order of the special values: -Infinity < numbers < Infinity < NaN
    #expect(CellValue.decimal("-Infinity") < .int(Int.min))
    #expect(CellValue.double(.greatestFiniteMagnitude) < .decimal("Infinity"))
    #expect(CellValue.decimal("Infinity") < .decimal("NaN"))
    #expect(CellValue.double(.infinity) < .double(.nan))
    #expect(!(CellValue.decimal("NaN") < .double(.nan)))
    // Numbers sort before text, so a decimal is never compared as text
    #expect(CellValue.decimal("99") < .string("1"))
  }

  @Test("Mixed numbers, special values and other types keep a strict weak order")
  func mixedOrderIsStrictWeak() {
    let values: [CellValue] = [
      .decimal("1.50"), .decimal("1.5"), .double(1.5), .int(1), .decimal("-0"), .double(-0.0),
      .int(0), .decimal("0.30000000000000004"), .double(0.1 + 0.2), .decimal("0.3"),
      .int(1_152_921_504_606_846_976), .double(1_152_921_504_606_846_976),
      .decimal("1152921504606847000"), .double(.nan), .decimal("NaN"), .double(.infinity),
      .decimal("-Infinity"), .double(-.infinity), .decimal("abc"), .string("1"), .bool(true),
      .null,
    ]
    for a in values {
      #expect(!(a < a), "irreflexive: \(a)")
      for b in values {
        if a < b { #expect(!(b < a), "asymmetric: \(a), \(b)") }
        for c in values {
          if a < b && b < c { #expect(a < c, "transitive: \(a), \(b), \(c)") }
          let ab = !(a < b) && !(b < a)
          let bc = !(b < c) && !(c < b)
          if ab && bc {
            #expect(!(a < c) && !(c < a), "equivalence is transitive: \(a), \(b), \(c)")
          }
        }
      }
    }
  }
}
