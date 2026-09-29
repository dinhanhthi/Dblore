// DataModelCellValueTests.swift
// Unit tests for CellValue data model

import Foundation
import Testing

@testable import Dblore

@Suite("Data Model - CellValue Tests")
@MainActor
struct DataModelCellValueTests {

  // MARK: - CellValue Encoding/Decoding Tests

  @Test("CellValue string encoding and decoding")
  func cellValueStringEncodingDecoding() throws {
    // Arrange
    let value = CellValue.string("Hello, World!")

    // Act
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)

    let decoder = JSONDecoder()
    let decodedValue = try decoder.decode(CellValue.self, from: data)

    // Assert
    if case .string(let str) = decodedValue {
      #expect(str == "Hello, World!")
    } else {
      Issue.record("Expected .string case")
    }
  }

  @Test("CellValue int encoding and decoding")
  func cellValueIntEncodingDecoding() throws {
    let value = CellValue.int(42)
    let data = try JSONEncoder().encode(value)
    let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

    if case .int(let num) = decodedValue {
      #expect(num == 42)
    } else {
      Issue.record("Expected .int case")
    }
  }

  @Test("CellValue double encoding and decoding")
  func cellValueDoubleEncodingDecoding() throws {
    let value = CellValue.double(3.14159)
    let data = try JSONEncoder().encode(value)
    let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

    if case .double(let num) = decodedValue {
      #expect(abs(num - 3.14159) < 0.00001)
    } else {
      Issue.record("Expected .double case")
    }
  }

  @Test("CellValue bool encoding and decoding")
  func cellValueBoolEncodingDecoding() throws {
    let value = CellValue.bool(true)
    let data = try JSONEncoder().encode(value)
    let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

    if case .bool(let flag) = decodedValue {
      #expect(flag == true)
    } else {
      Issue.record("Expected .bool case")
    }
  }

  @Test("CellValue null encoding and decoding")
  func cellValueNullEncodingDecoding() throws {
    let value = CellValue.null
    let data = try JSONEncoder().encode(value)
    let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

    if case .null = decodedValue {
      #expect(Bool(true))  // Success
    } else {
      Issue.record("Expected .null case")
    }
  }

  @Test("CellValue JSON encoding and decoding")
  func cellValueJSONEncodingDecoding() throws {
    let jsonString = "{\"name\":\"Alice\",\"age\":30}"
    let value = CellValue.json(jsonString)
    let data = try JSONEncoder().encode(value)
    let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

    if case .json(let str) = decodedValue {
      #expect(str == jsonString)
    } else {
      Issue.record("Expected .json case")
    }
  }

  // MARK: - CellValue Display Tests

  @Test("CellValue display strings")
  func cellValueDisplayStrings() {
    #expect(CellValue.string("test").displayString == "test")
    #expect(CellValue.int(42).displayString == "42")
    #expect(CellValue.double(3.14).displayString == "3.14")
    #expect(CellValue.bool(true).displayString == "true")
    #expect(CellValue.null.displayString == "NULL")
  }

  @Test("CellValue isNull property")
  func cellValueIsNull() {
    #expect(CellValue.null.isNull == true)
    #expect(CellValue.string("test").isNull == false)
    #expect(CellValue.int(0).isNull == false)
  }

  @Test("CellValue isJSON property")
  func cellValueIsJSON() {
    #expect(CellValue.json("{}").isJSON == true)
    #expect(CellValue.string("{}").isJSON == false)
    #expect(CellValue.null.isJSON == false)
  }
}
