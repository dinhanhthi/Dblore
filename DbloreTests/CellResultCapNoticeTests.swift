// CellResultCapNoticeTests.swift
// C2: a capped QueryResult carries its truncation / session reset onto the CellResult (session
// only, never persisted) and the result views show one notice built from it.

import Foundation
import Testing

@testable import Dblore

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

  @Test("A byte stop and cut cells carry onto the CellResult and into the notice")
  func byteStopAndCutCellsNotice() {
    var stopped = queryResult(rows: 120, truncated: true)
    stopped.stoppedAtByteBudget = true
    stopped.cutCells = [CellPosition(row: 0, column: 0), CellPosition(row: 3, column: 0)]
    let cell = cellResult(stopped)
    #expect(cell.stoppedAtByteBudget)
    #expect(cell.cutCells == stopped.cutCells)
    #expect(
      cell.capNotice
        == "Showing first 120 rows. Stopped at 256 MiB of values. 2 values were cut at 1 MiB.")
  }

  @Test("Cut cells alone: one notice, singular for one value")
  func cutCellsAloneNotice() {
    var whole = queryResult(rows: 3, truncated: false)
    whole.cutCells = [CellPosition(row: 1, column: 0)]
    #expect(cellResult(whole).capNotice == "1 value was cut at 1 MiB.")
  }
}
