// ResultComparisonTests.swift
// Row and column diff of a pinned result against a later run.

import Foundation
import Testing

@testable import Dblore

@Suite("Result comparison")
struct ResultComparisonTests {
  private func result(
    _ columns: [String], _ rows: [[CellValue]], primaryKey: [String] = []
  ) -> CellResult {
    CellResult(
      columns: columns.map { ColumnInfo(name: $0, type: "TEXT") },
      rows: rows,
      rowCount: rows.count,
      primaryKeyColumns: primaryKey
    )
  }

  @Test("Rows keyed by primary key report added, removed and changed cells")
  func primaryKeyDiff() {
    let baseline = result(
      ["id", "name", "qty"],
      [
        [.int(1), .string("a"), .int(10)],
        [.int(2), .string("b"), .int(20)],
        [.int(3), .string("c"), .int(30)],
      ],
      primaryKey: ["id"]
    )
    let current = result(
      ["id", "name", "qty"],
      [
        [.int(1), .string("a"), .int(10)],
        [.int(3), .string("C"), .int(31)],
        [.int(4), .string("d"), .int(40)],
      ],
      primaryKey: ["id"]
    )

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.mode == .primaryKey(["id"]))
    #expect(diff.addedRows == [2])
    #expect(diff.removedRows == [1])
    #expect(
      diff.changedRows == [
        ResultDiff.ChangedRow(baselineIndex: 2, currentIndex: 1, changedColumns: ["name", "qty"])
      ])
    #expect(diff.unchangedCount == 1)
    #expect(diff.truncated == false)
    #expect(diff.hasChanges)
  }

  @Test("Different primary keys on the two sides fall back to a multiset diff")
  func differentPrimaryKeysUseMultiset() {
    let baseline = result(["id"], [[.int(1)]], primaryKey: ["id"])
    let current = result(["id"], [[.int(1)]], primaryKey: [])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.mode == .multiset)
    #expect(diff.hasChanges == false)
  }

  @Test("Duplicate primary key values fall back to a multiset diff instead of dropping rows")
  func duplicateKeysUseMultiset() {
    let baseline = result(
      ["id", "v"], [[.int(1), .string("a")], [.int(1), .string("b")]], primaryKey: ["id"])
    let current = result(["id", "v"], [[.int(1), .string("a")]], primaryKey: ["id"])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.mode == .multiset)
    #expect(diff.removedRows == [1])
    #expect(diff.addedRows.isEmpty)
  }

  @Test("Multiset diff counts duplicates: one removed and one added")
  func multisetWithDuplicates() {
    let baseline = result(["v"], [[.string("a")], [.string("a")], [.string("b")]])
    let current = result(["v"], [[.string("a")], [.string("b")], [.string("b")]])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.mode == .multiset)
    #expect(diff.removedRows == [1])
    #expect(diff.addedRows == [2])
    #expect(diff.changedRows.isEmpty)
    #expect(diff.unchangedCount == 2)
  }

  @Test("Columns match by name: reorder is no change, added and removed are reported")
  func columnsAddedAndRemoved() {
    let baseline = result(["a", "b", "c"], [[.int(1), .int(2), .int(3)]])
    let current = result(["c", "a", "d"], [[.int(3), .int(1), .int(9)]])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.addedColumns == ["d"])
    #expect(diff.removedColumns == ["b"])
    #expect(diff.sharedColumns == ["a", "c"])
    // Rows compare over shared columns only
    #expect(diff.addedRows.isEmpty)
    #expect(diff.removedRows.isEmpty)
    #expect(diff.unchangedCount == 1)
    #expect(diff.hasChanges)
  }

  @Test("NULL equals NULL and differs from a value")
  func nullHandling() {
    let baseline = result(
      ["id", "v"], [[.int(1), .null], [.int(2), .null]], primaryKey: ["id"])
    let current = result(
      ["id", "v"], [[.int(1), .null], [.int(2), .string("x")]], primaryKey: ["id"])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.unchangedCount == 1)
    #expect(
      diff.changedRows == [
        ResultDiff.ChangedRow(baselineIndex: 1, currentIndex: 1, changedColumns: ["v"])
      ])

    let multiset = ResultComparison.compare(
      baseline: result(["v"], [[.null]]), current: result(["v"], [[.null], [.string("")]]))
    #expect(multiset.unchangedCount == 1)
    #expect(multiset.addedRows == [1])
  }

  @Test("Rows past the cap are not compared and the diff is marked truncated")
  func truncationAtCap() {
    let baseline = result(["v"], [[.int(1)], [.int(2)], [.int(3)]])
    let current = result(["v"], [[.int(1)], [.int(2)]])

    let diff = ResultComparison.compare(baseline: baseline, current: current, rowCap: 2)

    #expect(diff.truncated)
    #expect(diff.removedRows.isEmpty)
    #expect(diff.unchangedCount == 2)

    let notCapped = ResultComparison.compare(baseline: current, current: current, rowCap: 2)
    #expect(notCapped.truncated == false)
  }

  @Test("Empty results produce an empty diff")
  func emptyResults() {
    let diff = ResultComparison.compare(baseline: CellResult(), current: CellResult())

    #expect(diff.hasChanges == false)
    #expect(diff.addedColumns.isEmpty && diff.removedColumns.isEmpty)
    #expect(diff.unchangedCount == 0)

    let fromEmpty = ResultComparison.compare(
      baseline: result(["v"], []), current: result(["v"], [[.int(1)]]))
    #expect(fromEmpty.addedRows == [0])
  }

  @Test("Background compare returns the same diff")
  func backgroundCompare() async {
    let baseline = result(["v"], [[.int(1)]])
    let current = result(["v"], [[.int(2)]])

    let diff = await ResultComparison.compareInBackground(baseline: baseline, current: current)

    #expect(diff == ResultComparison.compare(baseline: baseline, current: current))
  }

  @Test("When columns were added, the panes list every row so the new column shows")
  func addedColumnListsAllRows() {
    let rows: [[CellValue]] = (1...4).map { [.int($0), .string("n\($0)"), .int($0 * 10)] }
    let baseline = result(["id", "name", "score"], rows, primaryKey: ["id"])
    let current = result(
      ["id", "name", "score", "note"], rows.map { $0 + [.null] }, primaryKey: ["id"])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(diff.addedColumns == ["note"])
    #expect(diff.addedRows.isEmpty && diff.removedRows.isEmpty && diff.changedRows.isEmpty)
    let expected = (0..<4).map { ResultCompareRow(index: $0, kind: .unchanged) }
    #expect(diff.paneRows(side: .current, rowCount: 4) == expected)
    #expect(diff.paneRows(side: .baseline, rowCount: 4) == expected)
  }

  @Test("With the same columns, the panes list only differing rows")
  func sameColumnsListDifferencesOnly() {
    let baseline = result(
      ["id", "v"], [[.int(1), .int(1)], [.int(2), .int(2)]], primaryKey: ["id"])
    let current = result(
      ["id", "v"], [[.int(1), .int(1)], [.int(2), .int(3)], [.int(4), .int(4)]],
      primaryKey: ["id"])

    let diff = ResultComparison.compare(baseline: baseline, current: current)

    #expect(
      diff.paneRows(side: .current, rowCount: 3) == [
        ResultCompareRow(index: 1, kind: .changed(["v"])),
        ResultCompareRow(index: 2, kind: .sideOnly),
      ])
    #expect(
      diff.paneRows(side: .baseline, rowCount: 2) == [
        ResultCompareRow(index: 1, kind: .changed(["v"]))
      ])
  }
}
