// NotebookViewModelAITests.swift
// AI assistant bridge on NotebookViewModel: insert, current SQL, last error

import Foundation
import Testing

@testable import Dblore

@Suite("Notebook ViewModel AI Bridge Tests")
@MainActor
struct NotebookViewModelAITests {
  private func makeViewModel(contents: [String] = ["SELECT 1", "SELECT 2"]) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.cells = contents.map { NotebookCell(cellType: .sql, content: $0) }
    viewModel.selectedCellId = nil
    return viewModel
  }

  @Test("Notebook insert with a selected cell adds a SQL cell right after it and selects it")
  func insertAfterSelected() throws {
    let viewModel = makeViewModel()
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    var changes = 0
    viewModel.onDocumentChanged = { changes += 1 }

    viewModel.insertAISQL("SELECT 42")

    #expect(viewModel.notebook.cells.map(\.content) == ["SELECT 1", "SELECT 42", "SELECT 2"])
    #expect(viewModel.notebook.cells[1].cellType == .sql)
    #expect(viewModel.selectedCellId == viewModel.notebook.cells[1].id)
    #expect(changes >= 1)
    #expect(viewModel.undoManager.canUndo)
  }

  @Test("Notebook insert with no selection appends")
  func insertAppends() {
    let viewModel = makeViewModel()

    viewModel.insertAISQL("SELECT 42")

    #expect(viewModel.notebook.cells.map(\.content) == ["SELECT 1", "SELECT 2", "SELECT 42"])
  }

  @Test("aiCurrentSQL in notebook mode is the selected cell content, nil when empty")
  func currentSQLNotebook() {
    let viewModel = makeViewModel(contents: ["SELECT 1", "  "])
    #expect(viewModel.aiCurrentSQL == nil)
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    #expect(viewModel.aiCurrentSQL == "SELECT 1")
    viewModel.selectedCellId = viewModel.notebook.cells[1].id
    #expect(viewModel.aiCurrentSQL == nil)
  }

  @Test("aiLastError is nil without error and the message when the selected cell failed")
  func lastErrorNotebook() {
    let viewModel = makeViewModel()
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    #expect(viewModel.aiLastError == nil)

    viewModel.notebook.cells[0].result = CellResult(error: "relation \"x\" does not exist")
    #expect(viewModel.aiLastError == "relation \"x\" does not exist")
  }

  @Test("aiLastError prefers the selected statement result error")
  func lastErrorStatement() {
    let viewModel = makeViewModel()
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].statementResults = [
      StatementResult(queryText: "a", result: CellResult(), statementIndex: 0),
      StatementResult(queryText: "b", result: CellResult(error: "boom"), statementIndex: 1),
    ]
    viewModel.notebook.cells[0].selectedStatementIndex = 1
    #expect(viewModel.aiLastError == "boom")
  }

  @Test("Editor mode without a text view appends to editorContent on a new line")
  func editorAppendFallback() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    viewModel.insertAISQL("SELECT 1")
    #expect(viewModel.editorContent == "SELECT 1")
    viewModel.insertAISQL("SELECT 2")
    #expect(viewModel.editorContent == "SELECT 1\nSELECT 2")
    #expect(viewModel.aiCurrentSQL == "SELECT 1\nSELECT 2")
  }

  @Test("aiLastError in editor mode reads the selected statement result, then editorResult")
  func lastErrorEditor() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    #expect(viewModel.aiLastError == nil)
    viewModel.editorResult = CellResult(error: "legacy")
    #expect(viewModel.aiLastError == "legacy")
    viewModel.editorStatementResults = [
      StatementResult(queryText: "a", result: CellResult(error: "first"), statementIndex: 0)
    ]
    #expect(viewModel.aiLastError == "first")
  }
}
