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

  @Test("Unpin clears the pin and the comparison")
  func unpinClears() async {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    await viewModel.refreshComparison(cellID: id).value
    #expect(viewModel.cellComparisons[id] != nil)

    viewModel.unpinResult(cellID: id)

    #expect(viewModel.notebook.cells[0].pinnedResult == nil)
    #expect(viewModel.cellComparisons[id] == nil)
    #expect(await viewModel.comparison(for: id) == nil)
  }

  @Test("Pinning is refused without a successful result")
  func pinRequiresSuccessfulResult() {
    let (viewModel, id) = makeViewModel(result: nil)
    #expect(!viewModel.pinResult(cellID: id))
    viewModel.notebook.cells[0].result = .errorResult("boom", sourceQuery: "SELECT")
    #expect(!viewModel.pinResult(cellID: id))
    #expect(viewModel.notebook.cells[0].pinnedResult == nil)
  }

  @Test("Compare toggles per cell and is not part of the document")
  func compareToggle() {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    #expect(!viewModel.isComparing(cellID: id))
    viewModel.toggleCompare(cellID: id)
    #expect(viewModel.isComparing(cellID: id))
    viewModel.toggleCompare(cellID: id)
    #expect(!viewModel.isComparing(cellID: id))
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

  @Test("Pin and unpin mark the document as changed")
  func pinningMarksDirty() {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    var changes = 0
    viewModel.onDocumentChanged = { changes += 1 }

    viewModel.pinResult(cellID: id)
    viewModel.unpinResult(cellID: id)

    #expect(changes == 2)
  }

  @Test("The editor pin is session-only and survives a new result")
  func editorPinIsSessionOnly() async throws {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    var changes = 0
    viewModel.onDocumentChanged = { changes += 1 }
    #expect(!viewModel.pinEditorResult())

    viewModel.editorResult = rows([(1, "a")])
    #expect(viewModel.pinEditorResult())
    viewModel.toggleEditorCompare()
    viewModel.editorResult = rows([(2, "b")])
    await viewModel.refreshEditorComparison().value

    #expect(viewModel.editorPinnedResult?.result.rows.count == 1)
    #expect(viewModel.isEditorComparing)
    guard case .rows(let diff) = viewModel.displayedEditorComparison else {
      Issue.record("expected a row diff")
      return
    }
    #expect(diff.addedRows == [0])
    #expect(diff.removedRows == [0])
    #expect(changes == 0)
    #expect(viewModel.notebook.cells.allSatisfy { $0.pinnedResult == nil })
    let data = try DocumentCoder.encode(viewModel.notebook, includeResultsOnSave: true)
    #expect(!String(decoding: data, as: UTF8.self).contains("pinnedResult"))

    viewModel.unpinEditorResult()
    #expect(viewModel.editorPinnedResult == nil)
    #expect(viewModel.displayedEditorComparison == nil)
  }

  @Test("A new cell result hides the previous comparison until its own is ready")
  func newResultHidesStaleComparison() async {
    let (viewModel, id) = makeViewModel(
      result: rows([(1, "a")], at: Date(timeIntervalSince1970: 1)))
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    await viewModel.refreshComparison(cellID: id).value
    #expect(viewModel.displayedComparison(cellID: id) != nil)

    viewModel.notebook.cells[0].result = rows(
      [(1, "a"), (2, "b")], at: Date(timeIntervalSince1970: 2))
    #expect(viewModel.displayedComparison(cellID: id) == nil)
    let refresh = viewModel.refreshComparison(cellID: id)
    #expect(viewModel.cellComparisons[id] == nil)
    #expect(viewModel.displayedComparison(cellID: id) == nil)
    await refresh.value

    guard case .rows(let diff) = viewModel.displayedComparison(cellID: id) else {
      Issue.record("expected a row diff")
      return
    }
    #expect(diff.addedRows == [1])
  }

  @Test("A new editor result hides the previous comparison until its own is ready")
  func newEditorResultHidesStaleComparison() async {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.editorResult = rows([(1, "a")], at: Date(timeIntervalSince1970: 1))
    viewModel.pinEditorResult()
    viewModel.toggleEditorCompare()
    await viewModel.refreshEditorComparison().value
    #expect(viewModel.displayedEditorComparison != nil)

    viewModel.editorResult = rows([(1, "a"), (2, "b")], at: Date(timeIntervalSince1970: 2))
    #expect(viewModel.displayedEditorComparison == nil)
    await viewModel.refreshEditorComparison().value

    guard case .rows(let diff) = viewModel.displayedEditorComparison else {
      Issue.record("expected a row diff")
      return
    }
    #expect(diff.addedRows == [1])
  }

  @Test("Turning compare off clears the cell comparison")
  func compareOffClears() async {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    await viewModel.refreshComparison(cellID: id).value
    #expect(viewModel.cellComparisons[id] != nil)

    viewModel.toggleCompare(cellID: id)

    #expect(viewModel.cellComparisons[id] == nil)
    #expect(viewModel.displayedComparison(cellID: id) == nil)
  }

  @Test("Deleting a cell drops its compare state")
  func deleteCellPrunesCompareState() async {
    let (viewModel, id) = makeViewModel(result: rows([(1, "a")]))
    viewModel.addCell(type: .sql)
    viewModel.pinResult(cellID: id)
    viewModel.toggleCompare(cellID: id)
    await viewModel.refreshComparison(cellID: id).value

    viewModel.deleteCell(id: id)

    #expect(!viewModel.comparingCellIds.contains(id))
    #expect(viewModel.cellComparisons[id] == nil)
    #expect(viewModel.comparisonGenerations[id] == nil)
  }

  @Test(
    "The pin note follows the workspace results-on-save override",
    arguments: [true, false])
  func resultsSavedWithFileUsesWorkspaceOverride(override: Bool) throws {
    let manager = WorkspaceManager(
      workspace: Workspace(settings: WorkspaceSettings(includeResultsOnSave: override)),
      restoreTabs: false)
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])

    #expect(viewModel.resultsSavedWithFile() == override)
    #expect((CellResultPinControls.pinNote(for: viewModel) == nil) == override)
  }

  @Test("Without a workspace override the pin note follows the app setting")
  func resultsSavedWithFileFallsBackToAppSetting() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let tabId = manager.newNotebook()
    let viewModel = try #require(manager.viewModels[tabId])
    let appSetting = AppSettings.shared.includeResultsOnSave

    #expect(viewModel.resultsSavedWithFile() == appSetting)
    #expect(NotebookViewModel().resultsSavedWithFile() == appSetting)
  }
}
