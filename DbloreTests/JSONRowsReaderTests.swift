// JSONRowsReaderTests.swift
// JSON rows are an array of objects or NDJSON. Column order is first-seen keys.

import Foundation
import Testing

@testable import Dblore

@Suite("JSON rows reader")
struct JSONRowsReaderTests {
  @Test("An array of objects unions keys in first-seen order")
  func arrayOfObjects() throws {
    let json = """
      [
      {"b":1,"a":"caf\\u00e9"},
      {"a":"y","c":{"z":true},"b":null},
      {"d":[1,"x"],"a":false}
      ]
      """
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data(json.utf8))
    let table = try JSONRowsReader.read(data)
    #expect(table.columns == ["b", "a", "c", "d"])
    #expect(
      table.rows == [
        ["1", "café", nil, nil],
        [nil, "y", "{\"z\":true}", nil],
        [nil, "false", nil, "[1,\"x\"]"],
      ])
  }

  @Test("NDJSON skips blank lines and keeps the same key union")
  func ndjson() throws {
    let json = "{\"a\":1,\"b\":\"x\"}\r\n\r\n{\"b\":\"y\",\"c\":[2]}\r\n{\"a\":null}\r\n"
    let table = try JSONRowsReader.read(Data(json.utf8))
    #expect(table.columns == ["a", "b", "c"])
    #expect(
      table.rows == [
        ["1", "x", nil],
        [nil, "y", "[2]"],
        [nil, nil, nil],
      ])
  }

  @Test("The row limit keeps only the first objects and their keys")
  func rowLimit() throws {
    let json = "[{\"a\":1,\"b\":2},{\"c\":3},{\"a\":4}]"
    let table = try JSONRowsReader.read(Data(json.utf8), options: .init(rowLimit: 1))
    #expect(table.columns == ["a", "b"])
    #expect(table.rows == [["1", "2"]])
  }

  @Test("An empty array has no columns")
  func emptyArray() throws {
    let table = try JSONRowsReader.read(Data("[]".utf8))
    #expect(table.columns.isEmpty)
    #expect(table.rows.isEmpty)
  }

  @Test("Broken JSON is invalid")
  func invalidJSON() {
    #expect(throws: JSONRowsError.invalidJSON) {
      try JSONRowsReader.read(Data("{".utf8))
    }
  }

  @Test("A top-level array must contain objects")
  func expectedObject() {
    #expect(throws: JSONRowsError.expectedObject) {
      try JSONRowsReader.read(Data("[1]".utf8))
    }
  }

  @Test("Excessively nested JSON fails cleanly, including in a capped preview")
  func nestingLimit() {
    let nested =
      String(repeating: "[", count: 256) + "0"
      + String(repeating: "]", count: 256)
    let data = Data("[{\"deep\":\(nested)}]".utf8)
    #expect(throws: JSONRowsError.invalidJSON) {
      try JSONRowsReader.read(data)
    }
    #expect(throws: JSONRowsError.invalidJSON) {
      try JSONRowsReader.read(data, options: .init(rowLimit: 1))
    }
  }
}
