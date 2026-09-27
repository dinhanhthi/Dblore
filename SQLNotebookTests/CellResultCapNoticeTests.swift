// CellResultCapNoticeTests.swift
// C2: a capped QueryResult carries its truncation / session reset onto the CellResult (session
// only, never persisted) and the result views show one notice built from it.

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
struct CellResultCapNoticeTests {
  private func queryResult(
    rows: Int, truncated: Bool, reset: Bool = false, skipped: [String] = []
  ) -> QueryResult {
    var result = QueryResult(
      columns: [ColumnInfo(name: "g", type: "INTEGER")],
      rows: Array(repeating: [.int(1)], count: rows), rowCount: rows, executionTime: 0,
      wasLimited: truncated)
    result.truncated = truncated
    result.sessionReset = reset
    result.skippedStatements = skipped
    return result
  }

  private func cellResult(_ result: QueryResult) -> CellResult {
    CellResult(
      columns: result.columns, rows: result.rows, rowCount: result.rowCount,
      wasLimited: result.wasLimited
    ).withCapInfo(from: result)
  }

  @Test("No notice when the result is complete")
  func completeResultHasNoNotice() {
    let cell = cellResult(queryResult(rows: 2, truncated: false))
    #expect(cell.capNotice == nil)
    #expect(!cell.sessionReset)
  }

  @Test("Truncated inside a kept session: only the row notice")
  func truncatedKeptSession() {
    let cell = cellResult(queryResult(rows: 100, truncated: true))
    #expect(cell.capNotice == "Showing first 100 rows")
  }

  @Test("Session reset: temp tables / SET / search_path lost")
  func sessionResetNotice() {
    let cell = cellResult(queryResult(rows: 100, truncated: true, reset: true))
    #expect(cell.sessionReset)
    #expect(
      cell.capNotice
        == "Showing first 100 rows. The statement was stopped on the server. Connection was "
        + "reset — temp tables, SET and search_path were lost.")
  }

  @Test("Session reset with statements not run")
  func sessionResetSkipped() {
    let cell = cellResult(
      queryResult(
        rows: 100, truncated: true, reset: true,
        skipped: ["UPDATE t SET v = 1", "DELETE FROM t"]))
    #expect(cell.skippedStatements.count == 2)
    let notice = cell.capNotice ?? ""
    #expect(notice.contains("2 statements after this one were not run."))
  }

  @Test("Session fields are not persisted; wasLimited carries the truncation")
  func sessionFieldsNotEncoded() throws {
    let cell = cellResult(
      queryResult(rows: 100, truncated: true, reset: true, skipped: ["X"]))
    let data = try JSONEncoder().encode(cell)
    let decoded = try JSONDecoder().decode(CellResult.self, from: data)
    #expect(decoded.wasLimited)
    #expect(!decoded.sessionReset)
    #expect(decoded.skippedStatements.isEmpty)
    #expect(decoded.capNotice == "Showing first 100 rows")
  }
}
