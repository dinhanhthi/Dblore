// NotebookViewModelAITests.swift
// AI assistant bridge on NotebookViewModel: insert, current SQL, last error, review Apply

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Notebook ViewModel AI Bridge Tests")
@MainActor
struct NotebookViewModelAITests {
  private static let config = ConnectionConfig(host: "h", database: "d")
  /// Error results are offered to Fix only on the connection they came from
  private static let key = AIAccessGate.sessionKey(for: config)

  private func makeViewModel(contents: [String] = ["SELECT 1", "SELECT 2"]) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = Self.config
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

    viewModel.notebook.cells[0].result = CellResult(
      error: "relation \"x\" does not exist", aiSessionKey: Self.key)
    #expect(viewModel.aiLastError == "relation \"x\" does not exist")
  }

  @Test("aiLastError prefers the selected statement result error")
  func lastErrorStatement() {
    let viewModel = makeViewModel()
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].statementResults = [
      StatementResult(queryText: "a", result: CellResult(), statementIndex: 0),
      StatementResult(
        queryText: "b", result: CellResult(error: "boom", aiSessionKey: Self.key), statementIndex: 1
      ),
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
    viewModel.editorResult = CellResult(error: "legacy", aiSessionKey: Self.key)
    #expect(viewModel.aiLastError == "legacy")
    viewModel.editorStatementResults = [
      StatementResult(
        queryText: "a", result: CellResult(error: "first", aiSessionKey: Self.key),
        statementIndex: 0)
    ]
    #expect(viewModel.aiLastError == "first")
  }

  // MARK: - Review Apply

  private func reviewRequest(
    _ viewModel: NotebookViewModel, source: String, cellIndex: Int? = 0,
    selection: NSRange? = nil
  ) -> AIReviewRequest {
    AIReviewRequest(
      kind: .optimize, sourceSQL: source, notebookId: viewModel.id,
      cellId: cellIndex.map { viewModel.notebook.cells[$0].id }, selection: selection)
  }

  @Test("Apply to a cell replaces its text and one undo restores it")
  func applyReviewCell() {
    let viewModel = makeViewModel(contents: ["SELECT * FROM t", "SELECT 2"])
    var changes = 0
    viewModel.onDocumentChanged = { changes += 1 }
    let request = reviewRequest(viewModel, source: "SELECT * FROM t")

    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    #expect(viewModel.notebook.cells[0].content == "SELECT id FROM t")
    #expect(changes >= 1)

    viewModel.undoManager.undo()
    #expect(viewModel.notebook.cells[0].content == "SELECT * FROM t")
    #expect(!viewModel.undoManager.canUndo)
    viewModel.undoManager.redo()
    #expect(viewModel.notebook.cells[0].content == "SELECT id FROM t")
  }

  @Test("Apply is refused once the cell text changed, even when it still holds the source")
  func applyReviewChangedCell() {
    let viewModel = makeViewModel()
    let request = reviewRequest(viewModel, source: "SELECT 1")
    for edited in ["SELECT 42", "SELECT 10", "SELECT 1\nWHERE id = 1"] {
      viewModel.notebook.cells[0].content = edited
      #expect(viewModel.applyAIReview(request, sql: "SELECT 3") != .applied, "\(edited)")
      #expect(viewModel.notebook.cells[0].content == edited)
    }
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("a second Apply is refused, even when the rewrite holds the source")
  func applyReviewTwice() {
    let viewModel = makeViewModel(contents: ["SELECT * FROM t", "SELECT 2"])
    let request = reviewRequest(viewModel, source: "SELECT * FROM t")

    #expect(viewModel.applyAIReview(request, sql: "SELECT * FROM t WHERE x") == .applied)
    #expect(viewModel.applyAIReview(request, sql: "SELECT * FROM t WHERE x") != .applied)
    #expect(viewModel.notebook.cells[0].content == "SELECT * FROM t WHERE x")
  }

  @Test("undo after the cell was edited keeps the user's text")
  func applyReviewUndoAfterEdit() {
    let viewModel = makeViewModel(contents: ["SELECT * FROM t", "SELECT 2"])
    let request = reviewRequest(viewModel, source: "SELECT * FROM t")
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    viewModel.notebook.cells[0].content = "SELECT id FROM t WHERE id = 1"

    viewModel.undoManager.undo()
    #expect(viewModel.notebook.cells[0].content == "SELECT id FROM t WHERE id = 1")
    #expect(!viewModel.undoManager.canRedo)
  }

  @Test("Apply is refused for another tab or a deleted cell")
  func applyReviewTargetGone() {
    let viewModel = makeViewModel()
    let request = reviewRequest(viewModel, source: "SELECT 1")
    let other = makeViewModel()

    #expect(other.applyAIReview(request, sql: "SELECT 3") != .applied)
    viewModel.notebook.cells.removeFirst()
    #expect(viewModel.applyAIReview(request, sql: "SELECT 3") != .applied)
  }

  @Test("Apply to the whole editor needs it unchanged")
  func applyReviewEditor() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = "SELECT * FROM t"
    let request = reviewRequest(viewModel, source: "SELECT * FROM t", cellIndex: nil)

    viewModel.editorContent = "SELECT * FROM t;\nSELECT 2;"
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") != .applied)
    viewModel.editorContent = "SELECT * FROM t"
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    #expect(viewModel.editorContent == "SELECT id FROM t")
  }

  @Test("Apply is refused for a query longer than the review prompt held")
  func applyReviewRefusesOverCap() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    let long = String(repeating: "x", count: AIPrompts.maxInputChars + 1)
    viewModel.editorContent = long
    let request = reviewRequest(viewModel, source: long, cellIndex: nil)

    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") != .applied)
    #expect(viewModel.editorContent == long)
  }

  @Test("Apply to an editor selection replaces that range only, once")
  func applyReviewEditorSelection() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = "SELECT * FROM t;\nSELECT * FROM t;"
    let request = reviewRequest(
      viewModel, source: "SELECT * FROM t", cellIndex: nil,
      selection: NSRange(location: 17, length: 15))

    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    #expect(viewModel.editorContent == "SELECT * FROM t;\nSELECT id FROM t;")
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") != .applied)
    #expect(viewModel.editorContent == "SELECT * FROM t;\nSELECT id FROM t;")
  }

  /// An editor tab whose live text view holds `text`
  private func liveEditor(_ text: String) -> (NotebookViewModel, SQLTextView) {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    let textView = SQLTextView(frame: .zero)
    textView.string = text
    viewModel.editorTextView = textView
    viewModel.editorContent = text
    return (viewModel, textView)
  }

  @Test("Apply to the whole editor writes through the text view, once")
  func applyReviewLiveEditor() {
    let (viewModel, textView) = liveEditor("SELECT * FROM t")
    let request = reviewRequest(viewModel, source: "SELECT * FROM t", cellIndex: nil)

    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    #expect(textView.string == "SELECT id FROM t")
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") != .applied)
    #expect(textView.string == "SELECT id FROM t")
  }

  @Test("Apply to an editor selection writes that range through the text view, once")
  func applyReviewLiveEditorSelection() {
    let (viewModel, textView) = liveEditor("SELECT * FROM t;\nSELECT * FROM t;")
    let request = reviewRequest(
      viewModel, source: "SELECT * FROM t", cellIndex: nil,
      selection: NSRange(location: 17, length: 15))

    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") == .applied)
    #expect(textView.string == "SELECT * FROM t;\nSELECT id FROM t;")
    #expect(viewModel.applyAIReview(request, sql: "SELECT id FROM t") != .applied)
    #expect(textView.string == "SELECT * FROM t;\nSELECT id FROM t;")
  }

  @Test("Review records the editor selection range; the whole editor records none")
  func currentSelection() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    let textView = SQLTextView(frame: .zero)
    textView.string = "SELECT 1;\nSELECT 2;"
    viewModel.editorTextView = textView
    viewModel.editorContent = textView.string
    #expect(viewModel.aiCurrentSelection == nil)

    textView.setSelectedRange(NSRange(location: 10, length: 8))
    #expect(viewModel.aiCurrentSQL == "SELECT 2")
    #expect(viewModel.aiCurrentSelection == NSRange(location: 10, length: 8))
  }

  @Test("the shown plan is attached only when it explained the reviewed statement")
  func shownPlanMatchesStatement() {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    let sql = "SELECT * FROM t"
    func plan(_ query: String) -> CellResult {
      CellResult(
        columns: [ColumnInfo(name: "QUERY PLAN", type: "json")],
        rows: [[.json(ExplainFixtures.seqScan)]], rowCount: 1, sourceQuery: query)
    }

    viewModel.editorResult = plan("EXPLAIN (FORMAT JSON) SELECT * FROM t")
    #expect(viewModel.aiShownPlan(for: sql + ";\n") != nil)
    viewModel.editorResult = plan("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM t")
    #expect(viewModel.aiShownPlan(for: sql) != nil)
    viewModel.editorResult = plan("EXPLAIN (FORMAT JSON) SELECT * FROM u")
    #expect(viewModel.aiShownPlan(for: sql) == nil)
    viewModel.editorResult = plan("EXPLAIN (FORMAT JSON) SELECT * FROM t")
    #expect(viewModel.aiShownPlan(for: "t") == nil)
  }
}
