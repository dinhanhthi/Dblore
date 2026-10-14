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
}
