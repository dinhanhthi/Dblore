// CellUndoTests.swift
// Notebook-level undo/redo of cell operations (NotebookViewModel.undoManager)

import Foundation
import Testing

@testable import Dblore

@Suite("Cell Undo Tests")
@MainActor
struct CellUndoTests {
  /// View model whose undo manager records each call as its own group
  private func makeViewModel() -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.undoManager.groupsByEvent = false
    return viewModel
  }

  private func grouped(_ viewModel: NotebookViewModel, _ action: () -> Void) {
    viewModel.undoManager.beginUndoGrouping()
    action()
    viewModel.undoManager.endUndoGrouping()
  }

  @Test("Redo of Add Cell brings back the same cell with its content")
  func redoAddKeepsCell() throws {
    let viewModel = makeViewModel()
    grouped(viewModel) { viewModel.addCell(type: .sql) }
    let added = try #require(viewModel.selectedCellId)
    let index = try #require(viewModel.notebook.cells.firstIndex { $0.id == added })
    viewModel.notebook.cells[index].content = "SELECT 1"

    viewModel.undoCellChange()
    #expect(!viewModel.notebook.cells.contains { $0.id == added })
    viewModel.redoCellChange()

    let restored = viewModel.notebook.cells.first { $0.id == added }
    #expect(restored?.content == "SELECT 1")
    #expect(viewModel.notebook.cells.firstIndex { $0.id == added } == index)
  }

  @Test("Undo of Move Cell Up moves that cell back even after the selection changed")
  func undoMoveUpUsesMovedCell() throws {
    let viewModel = makeViewModel()
    grouped(viewModel) { viewModel.addCell(type: .sql) }
    grouped(viewModel) { viewModel.addCell(type: .sql) }
    let before = viewModel.notebook.cells.map(\.id)
    viewModel.selectedCellId = before[2]
    grouped(viewModel) { viewModel.moveSelectedCellUp() }

    viewModel.selectedCellId = before[0]
    viewModel.undoCellChange()

    #expect(viewModel.notebook.cells.map(\.id) == before)
  }

  @Test("Undo and redo mark the document as changed")
  func undoRedoMarkDirty() {
    let viewModel = makeViewModel()
    grouped(viewModel) { viewModel.addCell(type: .sql) }
    var changes = 0
    viewModel.onDocumentChanged = { changes += 1 }

    viewModel.undoCellChange()
    viewModel.redoCellChange()

    #expect(changes == 2)
  }

  @Test("The undo manager keeps at most 100 levels")
  func undoLevelsAreCapped() {
    let viewModel = makeViewModel()
    #expect(viewModel.undoManager.levelsOfUndo == 100)
    let originalCount = viewModel.notebook.cells.count

    for _ in 0..<101 {
      grouped(viewModel) { viewModel.addCell(type: .sql) }
    }
    for _ in 0..<100 {
      viewModel.undoCellChange()
    }

    #expect(!viewModel.undoManager.canUndo)
    #expect(viewModel.notebook.cells.count == originalCount + 1)
  }
}
