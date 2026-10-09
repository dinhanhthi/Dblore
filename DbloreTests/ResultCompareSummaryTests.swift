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

  @Test func noChanges() {
    #expect(ResultCompareSummary.text(diff()) == "Current vs pinned: no changes")
  }

  @Test func singularParts() {
    let text = ResultCompareSummary.text(
      diff(added: [0], removed: [1], changed: 1, addedColumns: ["a"], removedColumns: ["b"]))
    #expect(
      text
        == "Current vs pinned: +1 row, \u{2212}1 row, 1 changed, 1 column added, 1 column removed")
  }

  @Test func pluralParts() {
    let text = ResultCompareSummary.text(diff(added: [0, 1, 2], removed: [3, 4], changed: 2))
    #expect(text == "Current vs pinned: +3 rows, \u{2212}2 rows, 2 changed")
  }

  @Test func columnsOnly() {
    #expect(
      ResultCompareSummary.text(diff(addedColumns: ["a", "b"]))
        == "Current vs pinned: 2 columns added")
  }

  @Test func planSummary() {
    let changed = ExplainPlanDiff(
      paired: [], added: [.init(path: [0], nodeType: "Seq Scan", relationName: "t")],
      removed: [], nodeTypeChanges: [], rootTotalCostDelta: nil, rootActualTotalTimeDelta: nil)
    let same = ExplainPlanDiff(
      paired: [], added: [], removed: [], nodeTypeChanges: [], rootTotalCostDelta: nil,
      rootActualTotalTimeDelta: nil)
    #expect(ResultCompareSummary.text(.plan(changed)) == "Current vs pinned: plan changed")
    #expect(ResultCompareSummary.text(.plan(same)) == "Current vs pinned: no changes")
  }

  @Test func signedDeltas() {
    #expect(ExplainPlanCompareRows.signed(12) == "+12")
    #expect(ExplainPlanCompareRows.signed(-3) == "\u{2212}3")
    #expect(ExplainPlanCompareRows.signed(0) == "0")
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
