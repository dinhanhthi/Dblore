// ResultCompareViewTests.swift
// Columns each compare pane shows: side-only (added or removed) columns lead, so their tinted
// header is visible without scrolling.

import Foundation
import Testing

@testable import Dblore

@Suite("Result compare view")
struct ResultCompareViewTests {
  private func diff(added: [String] = [], removed: [String] = []) -> ResultDiff {
    ResultDiff(
      mode: .primaryKey(["id"]),
      addedColumns: added,
      removedColumns: removed,
      sharedColumns: ["id", "name", "score"],
      addedRows: [],
      removedRows: [],
      changedRows: [],
      unchangedCount: 4,
      truncated: false
    )
  }

  @Test func addedColumnLeadsCurrentPane() {
    let columns = ResultComparePaneColumns(diff(added: ["note"]), side: .current)
    #expect(columns.names == ["note", "id", "name", "score"])
    #expect(columns.sideOnly == ["note"])
    let pinned = ResultComparePaneColumns(diff(added: ["note"]), side: .baseline)
    #expect(pinned.names == ["id", "name", "score"])
    #expect(pinned.sideOnly.isEmpty)
  }

  @Test("A date shows the grid text of its column: naive the wall clock (regression A5)")
  func dateShowsTheGridText() {
    let noon = Date(timeIntervalSince1970: 1_792_065_600)  // 2026-10-15 12:00:00 UTC
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      #expect(ResultComparePane.text(.date(noon), wallClock: true) == "2026-10-15 12:00:00")
      #expect(
        ResultComparePane.text(.date(noon), wallClock: false) == "2026-10-15 19:00:00+07:00")
    }
    // JSON keeps its text (the grid shows a `{...}` preview)
    #expect(ResultComparePane.text(.json("{\"a\":1}"), wallClock: false) == "{\"a\":1}")
  }
}
