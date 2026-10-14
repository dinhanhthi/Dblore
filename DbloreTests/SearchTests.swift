// SearchTests.swift
// Unit tests for Global Search functionality
// Tests search highlighting, match finding, and navigation

import Foundation
import Testing

@testable import Dblore

@Suite("Global Search Tests")
@MainActor
struct SearchTests {

  // MARK: - SearchHighlighter Tests

  // MARK: - SearchState Tests

  // MARK: - SearchMatch Tests

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
    let cell = NotebookCell(cellType: .sql, content: "SELECT SELECT SELECT")
    viewModel.notebook.cells = [cell]

    await viewModel.performSearch(query: "SELECT", caseSensitive: false)
    try? await Task.sleep(for: .milliseconds(100))

    let initialIndex = viewModel.searchState.currentMatchIndex

    // Act
    viewModel.navigateToNextMatch()

    // Assert
    #expect(viewModel.searchState.currentMatchIndex == initialIndex + 1)
  }

}
