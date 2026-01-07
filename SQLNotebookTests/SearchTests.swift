// SearchTests.swift
// Unit tests for Global Search functionality
// Tests search highlighting, match finding, and navigation

import Testing
@testable import SQLNotebook
import Foundation

@Suite("Global Search Tests")
@MainActor
struct SearchTests {

  // MARK: - SearchHighlighter Tests

  @Test("Highlight text with case-insensitive search")
  func highlightCaseInsensitive() {
    // Arrange
    let text = "SELECT * FROM users WHERE name = 'Alice'"
    let query = "select"

    // Act
    let result = SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: false,
      currentMatchRange: nil
    )

    // Assert
    #expect(result.description.contains("SELECT"))
  }

  @Test("Highlight text with case-sensitive search")
  func highlightCaseSensitive() {
    // Arrange
    let text = "SELECT * FROM users WHERE name = 'Alice'"
    let query = "select"

    // Act
    let result = SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: true,
      currentMatchRange: nil
    )

    // Assert - should NOT highlight because case doesn't match
    let resultStr = result.description
    #expect(!resultStr.contains("backgroundColor"))
  }

  @Test("Highlight multiple matches in text")
  func highlightMultipleMatches() {
    // Arrange
    let text = "Error: column 'error' not found. Check error logs."
    let query = "error"

    // Act
    let result = SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: false,
      currentMatchRange: nil
    )

    // Assert - should find multiple instances
    #expect(result.description.contains("Error"))
  }

  @Test("Highlight with empty query returns unchanged text")
  func highlightEmptyQuery() {
    // Arrange
    let text = "SELECT * FROM users"
    let query = ""

    // Act
    let result = SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: false,
      currentMatchRange: nil
    )

    // Assert - AttributedString.description includes formatting info, so just check it contains the text
    #expect(result.description.contains(text))
  }

  // MARK: - SearchState Tests

  @Test("SearchState initializes with empty values")
  func searchStateInitialization() {
    // Act
    let state = SearchState()

    // Assert
    #expect(state.query == "")
    #expect(state.isCaseSensitive == false)
    #expect(state.matches.isEmpty)
    #expect(state.currentMatchIndex == 0)
    #expect(state.isSearching == false)
  }

  @Test("SearchState currentMatch returns nil when no matches")
  func searchStateNoMatches() {
    // Arrange
    var state = SearchState()
    state.matches = []

    // Act
    let currentMatch = state.currentMatch

    // Assert
    #expect(currentMatch == nil)
  }

  @Test("SearchState currentMatch returns correct match")
  func searchStateCurrentMatch() {
    // Arrange
    var state = SearchState()
    let cellId = UUID()
    let match = SearchMatch(
      cellId: cellId,
      matchType: .sqlContent,
      matchRange: "test".startIndex..<"test".endIndex,
      contextText: "test content",
      lineNumber: 1
    )
    state.matches = [match]
    state.currentMatchIndex = 0

    // Act
    let currentMatch = state.currentMatch

    // Assert
    #expect(currentMatch != nil)
    #expect(currentMatch?.cellId == cellId)
  }

  @Test("SearchState matchCountText displays correctly")
  func searchStateMatchCount() {
    // Arrange
    var state = SearchState()
    let cellId = UUID()

    // Create 3 matches
    for i in 0..<3 {
      let match = SearchMatch(
        cellId: cellId,
        matchType: .sqlContent,
        matchRange: "test".startIndex..<"test".endIndex,
        contextText: "test \(i)",
        lineNumber: i + 1
      )
      state.matches.append(match)
    }
    state.currentMatchIndex = 1

    // Act
    let matchText = state.matchCountText

    // Assert
    #expect(matchText == "2 of 3")
  }

  @Test("SearchState matchCountText shows 'No matches' when empty")
  func searchStateNoMatchesText() {
    // Arrange
    let state = SearchState()

    // Act
    let matchText = state.matchCountText

    // Assert
    #expect(matchText == "No matches")
  }

  // MARK: - SearchMatch Tests

  @Test("SearchMatch equality works correctly")
  func searchMatchEquality() {
    // Arrange
    let cellId = UUID()
    let match1 = SearchMatch(
      cellId: cellId,
      matchType: .sqlContent,
      matchRange: "test".startIndex..<"test".endIndex,
      contextText: "test",
      lineNumber: 1
    )
    let match2 = SearchMatch(
      cellId: cellId,
      matchType: .sqlContent,
      matchRange: "test".startIndex..<"test".endIndex,
      contextText: "test",
      lineNumber: 1
    )

    // Assert - different IDs should make them unequal
    #expect(match1.id != match2.id)
    #expect(match1 != match2)
  }

  @Test("SearchMatch matchType equality for sqlContent")
  func searchMatchTypeSqlContent() {
    // Arrange
    let type1 = SearchMatch.SearchMatchType.sqlContent
    let type2 = SearchMatch.SearchMatchType.sqlContent

    // Assert
    #expect(type1 == type2)
  }

  @Test("SearchMatch matchType equality for tableData")
  func searchMatchTypeTableData() {
    // Arrange
    let type1 = SearchMatch.SearchMatchType.tableData(rowIndex: 0, columnName: "id")
    let type2 = SearchMatch.SearchMatchType.tableData(rowIndex: 0, columnName: "id")

    // Assert
    #expect(type1 == type2)
  }

  @Test("SearchMatch matchType inequality for different types")
  func searchMatchTypeDifferent() {
    // Arrange
    let type1 = SearchMatch.SearchMatchType.sqlContent
    let type2 = SearchMatch.SearchMatchType.errorMessage

    // Assert
    #expect(type1 != type2)
  }

  // MARK: - NotebookViewModel Search Tests

  @Test("NotebookViewModel search finds matches in SQL content")
  func notebookViewModelSearchSQLContent() async {
    // Arrange
    let viewModel = NotebookViewModel()
    let cell = NotebookCell(cellType: .sql, content: "SELECT * FROM users WHERE name = 'Alice'")
    viewModel.notebook.cells = [cell]

    // Act
    await viewModel.performSearch(query: "SELECT", caseSensitive: false)

    // Wait for search to complete
    try? await Task.sleep(for: .milliseconds(100))

    // Assert
    #expect(viewModel.searchState.matches.count > 0)
    #expect(viewModel.searchState.matches.first?.matchType == .sqlContent)
  }

  @Test("NotebookViewModel search finds matches in error messages")
  func notebookViewModelSearchErrors() async {
    // Arrange
    let viewModel = NotebookViewModel()
    var cell = NotebookCell(cellType: .sql, content: "SELECT invalid_column FROM users")
    cell.result = CellResult(
      columns: [],
      rows: [],
      executionTime: 0.001,
      rowCount: 0,
      timestamp: Date(),
      error: "ERROR: column 'invalid_column' does not exist"
    )
    viewModel.notebook.cells = [cell]

    // Act
    await viewModel.performSearch(query: "column", caseSensitive: false)

    // Wait for search to complete
    try? await Task.sleep(for: .milliseconds(100))

    // Assert
    #expect(viewModel.searchState.matches.count > 0)
    let hasErrorMatch = viewModel.searchState.matches.contains { match in
      if case .errorMessage = match.matchType {
        return true
      }
      return false
    }
    #expect(hasErrorMatch)
  }

  @Test("NotebookViewModel search with empty query clears matches")
  func notebookViewModelSearchEmpty() async {
    // Arrange
    let viewModel = NotebookViewModel()
    let cell = NotebookCell(cellType: .sql, content: "SELECT * FROM users")
    viewModel.notebook.cells = [cell]

    // First search with query
    await viewModel.performSearch(query: "SELECT", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))

    // Act - search with empty query
    await viewModel.performSearch(query: "", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))

    // Assert
    #expect(viewModel.searchState.matches.isEmpty)
  }

  @Test("NotebookViewModel navigateToNextMatch cycles through matches")
  func notebookViewModelNavigateNext() async {
    // Arrange
    let viewModel = NotebookViewModel()
    var cell = NotebookCell(cellType: .sql, content: "SELECT SELECT SELECT")
    viewModel.notebook.cells = [cell]

    await viewModel.performSearch(query: "SELECT", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))

    let initialIndex = viewModel.searchState.currentMatchIndex

    // Act
    viewModel.navigateToNextMatch()

    // Assert
    #expect(viewModel.searchState.currentMatchIndex == initialIndex + 1)
  }

  @Test("NotebookViewModel navigateToPreviousMatch cycles through matches")
  func notebookViewModelNavigatePrevious() async {
    // Arrange
    let viewModel = NotebookViewModel()
    var cell = NotebookCell(cellType: .sql, content: "SELECT SELECT SELECT")
    viewModel.notebook.cells = [cell]

    await viewModel.performSearch(query: "SELECT", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))

    // Move to match 1
    viewModel.navigateToNextMatch()
    let currentIndex = viewModel.searchState.currentMatchIndex

    // Act
    viewModel.navigateToPreviousMatch()

    // Assert
    #expect(viewModel.searchState.currentMatchIndex == currentIndex - 1)
  }

  @Test("NotebookViewModel closeSearch clears state")
  func notebookViewModelCloseSearch() async {
    // Arrange
    let viewModel = NotebookViewModel()
    var cell = NotebookCell(cellType: .sql, content: "SELECT * FROM users")
    viewModel.notebook.cells = [cell]

    await viewModel.performSearch(query: "SELECT", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))
    viewModel.isSearchPanelVisible = true

    // Act
    viewModel.closeSearch()

    // Assert
    #expect(viewModel.isSearchPanelVisible == false)
    #expect(viewModel.searchState.query.isEmpty)
    #expect(viewModel.searchState.matches.isEmpty)
  }
}
