// ResultCompareSummaryTests.swift
// Summary line of a pinned-vs-current row diff and the plan compare rows/number text.

import Foundation
import Testing

@testable import Dblore

@Suite("Result compare summary")
@MainActor
struct ResultCompareSummaryTests {
  private func diff(
    added: [Int] = [], removed: [Int] = [], changed: Int = 0,
    addedColumns: [String] = [], removedColumns: [String] = []
  ) -> ResultDiff {
    ResultDiff(
      mode: .multiset,
      addedColumns: addedColumns,
      removedColumns: removedColumns,
      sharedColumns: ["id"],
      addedRows: added,
      removedRows: removed,
      changedRows: (0..<changed).map {
        ResultDiff.ChangedRow(baselineIndex: $0, currentIndex: $0, changedColumns: ["v"])
      },
      unchangedCount: 0,
      truncated: false
    )
  }

  @Test func typeChangeReplacesAddedAndRemovedAtItsPath() {
    let plan = ExplainPlanDiff(
      paired: [
        .init(
          path: [], nodeType: "Sort", relationName: nil, totalCostDelta: 1,
          actualTotalTimeDelta: nil, actualRowsDelta: nil)
      ],
      added: [
        .init(path: [0], nodeType: "Index Scan", relationName: "t"),
        .init(path: [1], nodeType: "Seq Scan", relationName: "u"),
      ],
      removed: [.init(path: [0], nodeType: "Seq Scan", relationName: "t")],
      nodeTypeChanges: [
        .init(path: [0], baselineNodeType: "Seq Scan", currentNodeType: "Index Scan")
      ],
      rootTotalCostDelta: 1,
      rootActualTotalTimeDelta: nil
    )
    let entries = ExplainPlanCompareRows.entries(plan)
    #expect(entries.map(\.path) == [[], [0], [1]])
    #expect(entries[1].kind == .typeChange(baseline: "Seq Scan", current: "Index Scan"))
    #expect(entries[2].kind == .added(plan.added[1]))
  }
}
