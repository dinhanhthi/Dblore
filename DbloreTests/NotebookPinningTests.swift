// NotebookPinningTests.swift
// Pin a result, then compare later runs against it (cells and the .sql editor result)

import Foundation
import Testing

@testable import Dblore

@Suite("Notebook result pinning")
@MainActor
struct NotebookPinningTests {
  private func rows(_ values: [(Int, String)], at timestamp: Date = Date()) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "id", type: "integer"), ColumnInfo(name: "name", type: "text")],
      rows: values.map { [.int($0.0), .string($0.1)] },
      rowCount: values.count,
      timestamp: timestamp,
      sourceQuery: "SELECT id, name FROM users"
    )
  }

  private func plan(cost: Double) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "QUERY PLAN", type: "json")],
      rows: [[.json("[{\"Plan\":{\"Node Type\":\"Seq Scan\",\"Total Cost\":\(cost)}}]")]],
      rowCount: 1,
      sourceQuery: "EXPLAIN (FORMAT JSON) SELECT 1"
    )
  }

  /// One SQL cell holding `result`
  private func makeViewModel(result: CellResult?) -> (NotebookViewModel, UUID) {
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells[0].content = "SELECT id, name FROM users"
    viewModel.notebook.cells[0].result = result
    return (viewModel, viewModel.notebook.cells[0].id)
  }

  @Test("A re-run keeps the pin and the comparison shows the new rows")
  func rerunKeepsPinAndDiffs() async throws {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    #expect(viewModel.pinResult(cellID: id))
    viewModel.toggleCompare(cellID: id)

    viewModel.notebook.cells[0].result = rows([(1, "a"), (2, "b")])
    await viewModel.refreshComparison(cellID: id).value

    let pin = try #require(viewModel.notebook.cells[0].pinnedResult)
    #expect(pin.result.rows.count == 1)
    #expect(pin.sourceQuery == "SELECT id, name FROM users")
    guard case .rows(let diff) = viewModel.displayedComparison(cellID: id) else {
      Issue.record("expected a row diff")
      return
    }
    #expect(diff.addedRows == [1])
    #expect(await viewModel.comparison(for: id) == .rows(diff))
  }

  @Test("Two EXPLAIN JSON plans compare as plans")
  func explainPairComparesPlans() async {
    let (viewModel, id) = makeViewModel(result: plan(cost: 10))
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    viewModel.notebook.cells[0].result = plan(cost: 25)
    await viewModel.refreshComparison(cellID: id).value

    guard case .plan(let diff) = viewModel.displayedComparison(cellID: id) else {
      Issue.record("expected a plan diff")
      return
    }
    #expect(diff.rootTotalCostDelta == 15)
  }

  @Test("A comparison started for an older result does not overwrite a newer one")
  func staleComparisonDropped() async {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    await viewModel.refreshComparison(cellID: id).value

    viewModel.notebook.cells[0].result = rows([(1, "a"), (2, "b")])
    let older = viewModel.refreshComparison(cellID: id)
    viewModel.notebook.cells[0].result = rows([(1, "a"), (3, "c"), (4, "d")])
    let newer = viewModel.refreshComparison(cellID: id)
    await newer.value
    await older.value

    guard case .rows(let diff) = viewModel.displayedComparison(cellID: id) else {
      Issue.record("expected a row diff")
      return
    }
    #expect(diff.addedRows == [1, 2])
  }

}
