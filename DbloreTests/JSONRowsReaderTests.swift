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

  @Test("Unique keys stop before dense rows exceed the cell budget")
  func uniqueKeyCellBudget() {
    let json = (0...1000).map { "{\"key_\($0)\":\($0)}" }.joined(separator: "\n")
    #expect(throws: JSONRowsError.cellLimitExceeded) {
      try JSONRowsReader.read(Data(json.utf8))
    }
  }

  @Test("Empty rows and duplicate object fields have independent budgets")
  func rawJSONBudgets() throws {
    #expect(throws: JSONRowsError.rowLimitExceeded) {
      try JSONRowsReader.read(Data("[{}, {}, {}]".utf8), options: .init(maxRows: 2))
    }
    #expect(throws: JSONRowsError.fieldLimitExceeded) {
      try JSONRowsReader.read(
        Data("[{\"x\":1,\"x\":2,\"x\":3}]".utf8),
        options: .init(maxFieldsPerObject: 2))
    }
    let preview = try JSONRowsReader.read(
      Data("[{}, {}]".utf8), options: .init(rowLimit: 1, maxRows: 1))
    #expect(preview.rows == [[]])
  }

  @Test("Cancelling a long number token stops the parser", .timeLimit(.minutes(1)))
  func longNumberCancellation() async throws {
    let data = Data(("[{\"n\":1" + String(repeating: "2", count: 16 * 1_024 * 1_024) + "}]").utf8)
    let parse = Task.detached { try JSONRowsReader.read(data) }
    try await Task.sleep(for: .milliseconds(30))
    parse.cancel()
    do {
      _ = try await parse.value
      Issue.record("Expected cancellation while parsing the number")
    } catch is CancellationError {
      // The parser polled cancellation within the token.
    }
  }
}
