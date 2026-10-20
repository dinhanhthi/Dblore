// NotebookSearchReplaceTests.swift
// Replace in the search panel: edits query text (editor tab or notebook cells) only, with case
// and whole-word options, Replace All as one undo step, refused in a data viewer and on a
// read-only source tab.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("Notebook Search Replace Tests")
@MainActor
struct NotebookSearchReplaceTests {
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
    backing: .buffered, defer: false)

  /// Notebook whose undo manager records each call as its own group
  private func makeNotebook(_ contents: [String]) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.undoManager.groupsByEvent = false
    viewModel.notebook.cells = contents.map { NotebookCell(cellType: .sql, content: $0) }
    return viewModel
  }

  /// Editor tab holding `text`
  private func makeEditor(_ text: String) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.cells = [NotebookCell(cellType: .sql, content: "")]
    viewModel.editorContent = text
    return viewModel
  }

  /// Text view wired like the editor's `makeNSView`, attached as the tab's editor. Keep the
  /// coordinator alive: it is the text view's delegate and owns its undo stack.
  private func attachTextView(
    to viewModel: NotebookViewModel
  ) -> (SQLTextView, HighlightedTextEditorRepresentable.Coordinator) {
    let coordinator = HighlightedTextEditorRepresentable.Coordinator(
      text: .constant(""), height: .constant(40), isEmpty: .constant(true), onTextChanged: nil)
    let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    textView.delegate = coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    coordinator.textView = textView
    window.contentView?.addSubview(textView)
    textView.string = viewModel.editorContent
    viewModel.editorTextView = textView
    return (textView, coordinator)
  }

  private func search(
    _ viewModel: NotebookViewModel, _ query: String, caseSensitive: Bool = false,
    wholeWord: Bool = false
  ) async {
    viewModel.searchState.isWholeWord = wholeWord
    await viewModel.performSearch(query: query, caseSensitive: caseSensitive)
  }

  private func grouped<T>(_ undoManager: UndoManager?, _ action: () async -> T) async -> T {
    undoManager?.beginUndoGrouping()
    let value = await action()
    undoManager?.endUndoGrouping()
    return value
  }

  /// Waits up to about 2 seconds for `condition` (the highlight is posted after a debounce)
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  /// UTF-16 offsets of `textView` drawn with a search highlight background
  private func highlightedOffsets(_ textView: NSTextView) -> [Int] {
    guard let storage = textView.textStorage else { return [] }
    return (0..<storage.length).filter {
      storage.attribute(.backgroundColor, at: $0, effectiveRange: nil) != nil
    }
  }

  // MARK: - Replace current

  @Test("Replace edits the current match only, then moves to the next one")
  func replaceCurrentAdvances() async {
    let viewModel = makeNotebook(["SELECT a FROM t", "SELECT b FROM t"])
    await search(viewModel, "from")

    let replaced = await grouped(viewModel.undoManager) {
      await viewModel.replaceCurrentMatch(with: "FROM public.")
    }

    #expect(replaced)
    #expect(
      viewModel.notebook.cells.map(\.content) == ["SELECT a FROM public. t", "SELECT b FROM t"])
    #expect(viewModel.searchState.currentMatch?.cellId == viewModel.notebook.cells[1].id)
  }

  @Test("Replace after the text changed since the search edits nothing and searches again")
  func replaceCurrentStaleMatch() async {
    let viewModel = makeNotebook(["SELECT a FROM t"])
    await search(viewModel, "from")
    // Same rank, other context: the stored match no longer points at what the search saw
    viewModel.notebook.cells[0].content = "SELECT bb FROM t"

    let replaced = await grouped(viewModel.undoManager) {
      await viewModel.replaceCurrentMatch(with: "X")
    }

    #expect(!replaced)
    #expect(viewModel.notebook.cells[0].content == "SELECT bb FROM t")
    #expect(viewModel.searchState.matches.count == 1)
    #expect(viewModel.searchState.matches.first?.contextText.contains("bb") == true)
  }

  @Test("Replace with text that contains the query moves past the replacement")
  func replaceCurrentSkipsReplacement() async {
    let viewModel = makeNotebook(["a b a"])
    await search(viewModel, "a")

    _ = await grouped(viewModel.undoManager) { await viewModel.replaceCurrentMatch(with: "aa") }
    _ = await grouped(viewModel.undoManager) { await viewModel.replaceCurrentMatch(with: "aa") }

    #expect(viewModel.notebook.cells[0].content == "aa b aa")
  }

  // MARK: - Replace All

  @Test("Replace All edits every cell and one undo restores them all")
  func replaceAllOneUndo() async {
    let viewModel = makeNotebook(["SELECT * FROM users", "SELECT 1", "DELETE FROM users"])
    await search(viewModel, "users")

    let count = await grouped(viewModel.undoManager) {
      await viewModel.replaceAllMatches(with: "people")
    }

    #expect(count == 2)
    #expect(
      viewModel.notebook.cells.map(\.content) == [
        "SELECT * FROM people", "SELECT 1", "DELETE FROM people",
      ])
    #expect(viewModel.searchState.matches.isEmpty)

    viewModel.undoManager.undo()
    #expect(
      viewModel.notebook.cells.map(\.content) == [
        "SELECT * FROM users", "SELECT 1", "DELETE FROM users",
      ])
    viewModel.undoManager.redo()
    #expect(viewModel.notebook.cells[2].content == "DELETE FROM people")
  }

  @Test("Replace All is not limited by the search's match cap")
  func replaceAllUncapped() async {
    let viewModel = makeNotebook([String(repeating: "x ", count: 120)])
    await search(viewModel, "x")

    let count = await grouped(viewModel.undoManager) {
      await viewModel.replaceAllMatches(with: "y")
    }

    #expect(count == 120)
    #expect(!viewModel.notebook.cells[0].content.contains("x"))
  }

  @Test("Case sensitive Replace All skips other cases; insensitive replaces them")
  func replaceAllCase() async {
    let sensitive = makeNotebook(["Foo foo FOO"])
    await search(sensitive, "foo", caseSensitive: true)
    let sensitiveCount = await grouped(sensitive.undoManager) {
      await sensitive.replaceAllMatches(with: "bar")
    }
    #expect(sensitiveCount == 1)
    #expect(sensitive.notebook.cells[0].content == "Foo bar FOO")

    let insensitive = makeNotebook(["Foo foo FOO"])
    await search(insensitive, "foo")
    let insensitiveCount = await grouped(insensitive.undoManager) {
      await insensitive.replaceAllMatches(with: "bar")
    }
    #expect(insensitiveCount == 3)
    #expect(insensitive.notebook.cells[0].content == "bar bar bar")
  }

  @Test("Whole word matches only standalone words")
  func replaceAllWholeWord() async {
    let viewModel = makeNotebook(["id, idx, user_id, (id)"])
    await search(viewModel, "id", wholeWord: true)
    #expect(viewModel.searchState.matches.count == 2)

    let count = await grouped(viewModel.undoManager) {
      await viewModel.replaceAllMatches(with: "pk")
    }

    #expect(count == 2)
    #expect(viewModel.notebook.cells[0].content == "pk, idx, user_id, (pk)")
  }

  @Test("Whole word counts only standalone words in column names, rows and errors too")
  func wholeWordCountsResults() async {
    let viewModel = makeNotebook(["SELECT id, idx FROM t"])
    viewModel.notebook.cells[0].result = CellResult(
      columns: [ColumnInfo(name: "user_id", type: "int"), ColumnInfo(name: "id", type: "int")],
      rows: [[.string("idx"), .string("id")]], executionTime: 0, rowCount: 1,
      timestamp: Date(), error: "idx id")

    await search(viewModel, "id")
    #expect(viewModel.searchState.matches.count == 8)

    await search(viewModel, "id", wholeWord: true)
    #expect(
      viewModel.searchState.matches.map(\.matchType) == [
        .sqlContent, .columnName("id"), .tableData(rowIndex: 0, columnName: "id"), .errorMessage,
      ])
  }

  @Test("Whole word highlights in the editor only the matches Replace edits")
  func wholeWordHighlights() async {
    let viewModel = makeEditor("id, idx, user_id, (id)")
    let (textView, coordinator) = attachTextView(to: viewModel)
    coordinator.viewModelId = viewModel.id

    await search(viewModel, "id", wholeWord: true)
    await waitUntil { coordinator.isSearchActive }

    #expect(coordinator.isWholeWord)
    #expect(highlightedOffsets(textView) == [0, 1, 19, 20])
  }

  /// Each highlighted run of `string`: its text and whether it is on the current-match color
  private func highlightRuns(_ string: NSAttributedString) -> [(String, Bool)] {
    var runs: [(String, Bool)] = []
    string.enumerateAttribute(
      .backgroundColor, in: NSRange(location: 0, length: string.length)
    ) { value, range, _ in
      guard let color = value as? NSColor else { return }
      runs.append(
        (
          string.attributedSubstring(from: range).string,
          color == ResultGridCoordinator.currentMatchColor
        ))
    }
    return runs
  }

  @Test("Whole word grid cells highlight standalone words; the current one is the counted one")
  func wholeWordGridCell() {
    let partial = ResultGridCoordinator.highlighted(
      "idx id", query: "id", caseSensitive: false, textColor: .black, isCurrentMatch: true)
    #expect(highlightRuns(partial).map(\.0) == ["id", "id"])
    #expect(highlightRuns(partial).map(\.1) == [true, false])

    let whole = ResultGridCoordinator.highlighted(
      "idx id", query: "id", caseSensitive: false, wholeWord: true, textColor: .black,
      isCurrentMatch: true)
    let runs = highlightRuns(whole)
    #expect(runs.count == 1)
    #expect(runs.first?.1 == true)
    #expect(whole.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil)
    #expect(whole.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
  }

  @Test("Whole word column headers highlight only names that are the word")
  func wholeWordGridHeader() {
    let columns = [ColumnInfo(name: "user_id", type: "int"), ColumnInfo(name: "id", type: "int")]
    let result = CellResult(
      columns: columns, rows: [], executionTime: 0, rowCount: 0, timestamp: Date())
    let highlighted = columns.map {
      ResultGridCoordinator.headerContent(
        for: $0, result: result, hideColumnTypes: false, searchQuery: "id",
        caseSensitive: false, wholeWord: true, currentMatch: nil
      ).isHighlighted
    }
    #expect(highlighted == [false, true])

    // The option alone changes what the grid draws: it reloads
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, searchQuery: "id")
    let header = tableView.tableColumns.dropFirst().first?.headerCell as? ResultGridHeaderCell
    #expect(header?.content.isHighlighted == true)
    #expect(
      coordinator.update(
        tableView, result: result, sortColumn: nil, ascending: true, searchQuery: "id",
        wholeWord: true))
    #expect(header?.content.isHighlighted == false)
    #expect(header?.content.wholeWord == true)
  }

  @Test("Error text highlights whole words on its own text, after non-ASCII characters too")
  func wholeWordErrorText() {
    let text = "İstanbul é 😀: id idx id"
    let ranges = NotebookViewModel.sourceMatchRanges(
      in: text, query: "id", caseSensitive: false, wholeWord: true)
    #expect(ranges.count == 2)

    let attributed = SearchHighlighter.highlight(
      text: text, query: "ID", caseSensitive: false, wholeWord: true,
      currentMatchRange: ranges.last)
    let runs = attributed.runs.compactMap { run -> (String, Bool)? in
      guard let color = run[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self]
      else { return nil }
      return (
        String(attributed[run.range].characters), color == SearchHighlighter.currentMatchColor
      )
    }
    #expect(runs.map(\.0) == ["id", "id"])
    #expect(runs.map(\.1) == [false, true])
  }

  @Test("Replace never edits rows, column names or errors")
  func replaceNeverTouchesResults() async throws {
    let viewModel = makeNotebook(["SELECT name FROM t"])
    viewModel.notebook.cells[0].result = CellResult(
      columns: [ColumnInfo(name: "name", type: "text")], rows: [[.string("name")]],
      executionTime: 0, rowCount: 1, timestamp: Date(), error: "name is ambiguous")
    await search(viewModel, "name")
    // Current match on a row value: Replace edits the next query-text match instead
    let rowMatch = try #require(
      viewModel.searchState.matches.firstIndex {
        if case .tableData = $0.matchType { return true }
        return false
      })
    viewModel.searchState.currentMatchIndex = rowMatch

    let replaced = await grouped(viewModel.undoManager) {
      await viewModel.replaceCurrentMatch(with: "label")
    }
    let count = await grouped(viewModel.undoManager) {
      await viewModel.replaceAllMatches(with: "label")
    }

    #expect(replaced)
    #expect(count == 0)
    let cell = viewModel.notebook.cells[0]
    #expect(cell.content == "SELECT label FROM t")
    #expect(cell.result?.columns.map(\.name) == ["name"])
    #expect(cell.result?.rows == [[.string("name")]])
    #expect(cell.result?.error == "name is ambiguous")
  }

  // MARK: - Editor tabs

  @Test("Replace All in a mongosh .js tab is one undo step on the text view")
  func replaceAllEditorUndo() async {
    let viewModel = makeEditor("db.users.find({}); db.users.countDocuments()")
    viewModel.notebook.connectionConfig = ConnectionConfig(
      databaseType: .mongodb, host: "h", port: 27017, database: "db")
    let (textView, coordinator) = attachTextView(to: viewModel)
    defer { withExtendedLifetime(coordinator) {} }
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    await search(viewModel, "users")

    let count = await grouped(textView.undoManager) {
      await viewModel.replaceAllMatches(with: "people")
    }

    #expect(count == 2)
    #expect(textView.string == "db.people.find({}); db.people.countDocuments()")
    #expect(viewModel.editorContent == textView.string)

    textView.undoManager?.undo()
    #expect(textView.string == "db.users.find({}); db.users.countDocuments()")
  }

  @Test("Undo and redo of Replace All never open autocomplete; typing still does")
  func replaceUndoSkipsAutocomplete() async {
    let viewModel = makeEditor("SELECT 1 UNION SELECT 2 UNION SELECT 3")
    let (textView, coordinator) = attachTextView(to: viewModel)
    defer { withExtendedLifetime(coordinator) {} }
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    await search(viewModel, "UNION", caseSensitive: true)

    let count = await grouped(textView.undoManager) {
      await viewModel.replaceAllMatches(with: "union")
    }
    #expect(count == 2)
    #expect(textView.autocompleteTask == nil)

    textView.undoManager?.undo()
    #expect(textView.string == "SELECT 1 UNION SELECT 2 UNION SELECT 3")
    #expect(textView.autocompleteTask == nil)
    textView.undoManager?.redo()
    #expect(textView.string == "SELECT 1 union SELECT 2 union SELECT 3")
    #expect(textView.autocompleteTask == nil)

    textView.undoManager?.beginUndoGrouping()
    textView.insertText(" U", replacementRange: textView.selectedRange())
    textView.undoManager?.endUndoGrouping()
    #expect(textView.autocompleteTask != nil)
    textView.hideAutocomplete()
  }

  @Test("Replace in the editor after multi-byte text edits the right characters")
  func replaceAfterMultiByteText() async {
    let viewModel = makeEditor("café 😀 İ SELECT x; SELECT y")
    let (textView, coordinator) = attachTextView(to: viewModel)
    defer { withExtendedLifetime(coordinator) {} }
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    await search(viewModel, "select")

    let replaced = await grouped(textView.undoManager) {
      await viewModel.replaceCurrentMatch(with: "pick")
    }
    #expect(replaced)
    #expect(textView.string == "café 😀 İ pick x; SELECT y")

    let count = await grouped(textView.undoManager) {
      await viewModel.replaceAllMatches(with: "pick")
    }
    #expect(count == 1)
    #expect(textView.string == "café 😀 İ pick x; pick y")
  }

  @Test("Replace in an editor tab without a shown text view edits the buffer")
  func replaceCurrentEditorBuffer() async {
    let viewModel = makeEditor("SELECT 1; SELECT 2")
    await search(viewModel, "select", caseSensitive: true)
    #expect(viewModel.searchState.matches.isEmpty)
    await search(viewModel, "SELECT")

    let replaced = await viewModel.replaceCurrentMatch(with: "select")

    #expect(replaced)
    #expect(viewModel.editorContent == "select 1; SELECT 2")
  }

  // MARK: - Refused

  @Test("Replace is refused in a data viewer and its rows stay unchanged")
  func refusedInDataViewer() async {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.dataViewer = DataViewerState(
      schema: "db", name: "users", orderColumns: ["_id"], databaseType: .mongodb)
    let rows: [[CellValue]] = [[.string("a1"), .string("Bob")]]
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(name: "_id", type: "objectId"), ColumnInfo(name: "name", type: "string"),
      ],
      rows: rows, executionTime: 0, rowCount: 1, timestamp: Date())
    await search(viewModel, "bob")
    #expect(!viewModel.searchState.matches.isEmpty)

    #expect(!viewModel.isReplaceAvailable)
    #expect(await viewModel.replaceCurrentMatch(with: "Ann") == false)
    #expect(await viewModel.replaceAllMatches(with: "Ann") == 0)
    #expect(viewModel.editorResult?.rows == rows)

    viewModel.openFindReplace()
    #expect(!viewModel.isSearchPanelVisible)
    #expect(!viewModel.searchState.isReplaceVisible)
  }

  @Test("Replace is refused on a read-only source tab")
  func refusedOnReadOnlySource() async {
    let viewModel = makeEditor("CREATE VIEW v AS SELECT 1")
    viewModel.objectSourceLoad = .loaded
    await search(viewModel, "SELECT")
    #expect(!viewModel.searchState.matches.isEmpty)

    #expect(!viewModel.isReplaceAvailable)
    #expect(await viewModel.replaceCurrentMatch(with: "x") == false)
    #expect(await viewModel.replaceAllMatches(with: "x") == 0)
    #expect(viewModel.editorContent == "CREATE VIEW v AS SELECT 1")
  }

  // MARK: - Panel

  @Test("Find and Replace opens the panel with its Replace row and never closes it")
  func openFindReplaceKeepsPanel() {
    let viewModel = makeNotebook(["SELECT 1"])

    viewModel.openFindReplace()
    #expect(viewModel.isSearchPanelVisible)
    #expect(viewModel.searchState.isReplaceVisible)

    viewModel.openFindReplace()
    #expect(viewModel.isSearchPanelVisible)

    viewModel.closeSearch()
    #expect(!viewModel.searchState.isReplaceVisible)
  }
}
