// AIQueryResultTests.swift
// Tests for the query result stored in an AI chat entry

import Foundation
import Testing

@testable import Dblore

@Suite("AI Query Result")
@MainActor
struct AIQueryResultTests {

  private func source(rows: Int, wasLimited: Bool = false) -> QueryResult {
    QueryResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "note", type: "text")],
      rows: (0..<rows).map { [.int($0), .string("n\($0)")] }, rowCount: rows, executionTime: 0,
      wasLimited: wasLimited)
  }

  @Test("make keeps at most maxRows and flags rows that were not kept")
  func makeCapsRows() {
    let capped = AIQueryResult.make(from: source(rows: 5), maxRows: 3)
    #expect(capped.columns == [.init(name: "id", type: "int4"), .init(name: "note", type: "text")])
    #expect(capped.rows == [["0", "n0"], ["1", "n1"], ["2", "n2"]])
    #expect(capped.rowsTruncated)

    #expect(!AIQueryResult.make(from: source(rows: 3), maxRows: 3).rowsTruncated)
    #expect(AIQueryResult.make(from: source(rows: 3, wasLimited: true), maxRows: 3).rowsTruncated)
    var truncated = source(rows: 3)
    truncated.truncated = true
    #expect(AIQueryResult.make(from: truncated, maxRows: 3).rowsTruncated)
  }

  @Test("make maps NULL to nil and cuts long text")
  func makeCells() {
    let long = String(repeating: "x", count: MCPResultEncoder.maxCellCharacters + 500)
    let result = QueryResult(
      columns: [ColumnInfo(name: "a", type: "text"), ColumnInfo(name: "b", type: "text")],
      rows: [[.null, .string(long)]], rowCount: 1, executionTime: 0)
    let made = AIQueryResult.make(from: result, maxRows: 10)
    #expect(made.rows[0][0] == nil)
    #expect(made.rows[0][1]?.count == MCPResultEncoder.maxCellCharacters + 1)
    #expect(made.rowCount == 1)
  }

  @Test("encoding drops row values, decoding gives empty rows with the count")
  func codingDropsRows() throws {
    let result = AIQueryResult(
      columns: [.init(name: "email", type: "text")], rows: [["secret-cell-9f3"], [nil]],
      rowCount: 2, rowsTruncated: true)
    let data = try JSONEncoder().encode(result)
    #expect(!String(decoding: data, as: UTF8.self).contains("secret-cell-9f3"))

    let decoded = try JSONDecoder().decode(AIQueryResult.self, from: data)
    #expect(decoded.rows.isEmpty)
    #expect(decoded.columns == result.columns)
    #expect(decoded.rowCount == 2)
    #expect(decoded.rowsTruncated)
  }
}
