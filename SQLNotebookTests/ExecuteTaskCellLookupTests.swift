// ExecuteTaskCellLookupTests.swift
// A Run All cell waits for its batch admission (an actor hop) before it runs: the cell list may
// change meanwhile, so the cell is looked up again after it (no database needed: the manager
// is never connected, the statement fails with "not connected").

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
struct ExecuteTaskCellLookupTests {
  private func viewModel(_ cells: [NotebookCell]) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = cells
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.connectionState = .connected
    return viewModel
  }

  /// Runs the Run All task of `cellId` and removes the first cell while the task awaits its
  /// batch admission. An attempt where the task had already started running when the cell was
  /// removed (the hop may return first under load) is repeated; nil if every attempt did.
  private func removeFirstCellDuringAdmission(
    of cellId: UUID, in cells: [NotebookCell]
  ) async -> (viewModel: NotebookViewModel, result: CellResult?)? {
    let task = ExecutionTask(cellId: cellId, query: "SELECT 2", batchId: UUID())
    for _ in 0..<20 {
      let viewModel = viewModel(cells)
      let running = Task { await viewModel.executeTask(task) }
      await Task.yield()
      let started = viewModel.notebook.cells.contains { $0.isRunning || $0.result != nil }
      viewModel.notebook.cells.removeFirst()
      let result = await running.value
      if !started { return (viewModel, result) }
    }
    return nil
  }

  @Test("A cell removed before it while admitted: the result lands on the cell itself")
  func resultLandsOnTheTaskCell() async throws {
    let first = NotebookCell(cellType: .sql, content: "SELECT 1")
    let target = NotebookCell(cellType: .sql, content: "SELECT 2")
    let last = NotebookCell(cellType: .sql, content: "SELECT 3")
    let run = try #require(
      await removeFirstCellDuringAdmission(of: target.id, in: [first, target, last]))

    #expect(run.result?.error != nil)
    let cells = run.viewModel.notebook.cells
    #expect(cells.first { $0.id == target.id }?.result?.error == run.result?.error)
    #expect(cells.first { $0.id == last.id }?.result == nil)
  }

  @Test("The cell deleted while admitted: nothing runs")
  func deletedCellDoesNotRun() async throws {
    let target = NotebookCell(cellType: .sql, content: "SELECT 2")
    let other = NotebookCell(cellType: .sql, content: "SELECT 3")
    let run = try #require(
      await removeFirstCellDuringAdmission(of: target.id, in: [target, other]))

    #expect(run.result == nil)
    #expect(run.viewModel.notebook.cells.first?.result == nil)
    #expect(run.viewModel.notebook.cells.first?.isRunning == false)
  }
}
