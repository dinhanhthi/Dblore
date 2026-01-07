//
//  NotebookViewModel+Search.swift
//  SQLNotebook
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

// MARK: - Global Search

extension NotebookViewModel {
  /// Perform global search across all cells
  @MainActor
  func performSearch(query: String, caseSensitive: Bool) async {
    searchState.isSearching = true
    searchState.query = query
    searchState.isCaseSensitive = caseSensitive
    searchState.matches = []
    searchState.currentMatchIndex = 0

    guard !query.isEmpty else {
      searchState.isSearching = false
      // Clear highlights when query is empty
      NotificationCenter.default.post(name: .clearSearchHighlights, object: nil)
      return
    }

    // Build search index and find matches (async on background)
    let matches = await buildSearchMatches(query: query, caseSensitive: caseSensitive)

    await MainActor.run {
      searchState.matches = matches
      searchState.isSearching = false

      // Auto-navigate to first match
      if !matches.isEmpty {
        navigateToMatch(at: 0)
      } else {
        // Clear highlights when no matches found
        NotificationCenter.default.post(name: .clearSearchHighlights, object: nil)
      }
    }
  }

  /// Build search matches from all cells (async for performance)
  private func buildSearchMatches(query: String, caseSensitive: Bool) async -> [SearchMatch] {
    var allMatches: [SearchMatch] = []

    for cell in notebook.cells {
      // 1. Search in SQL content
      allMatches.append(contentsOf: searchInSQLContent(cell: cell, query: query, caseSensitive: caseSensitive))

      // 2. Search in result data
      if let result = cell.result {
        // Search in column names
        allMatches.append(contentsOf: searchInColumnNames(cell: cell, result: result, query: query, caseSensitive: caseSensitive))

        // Search in table data
        allMatches.append(contentsOf: searchInTableData(cell: cell, result: result, query: query, caseSensitive: caseSensitive))

        // Search in error messages
        if let error = result.error {
          allMatches.append(contentsOf: searchInErrorMessage(cell: cell, error: error, query: query, caseSensitive: caseSensitive))
        }
      }
    }

    return allMatches
  }

  /// Navigate to next match
  @MainActor
  func navigateToNextMatch() {
    guard !searchState.matches.isEmpty else { return }

    let newIndex = (searchState.currentMatchIndex + 1) % searchState.matches.count
    navigateToMatch(at: newIndex)
  }

  /// Navigate to previous match
  @MainActor
  func navigateToPreviousMatch() {
    guard !searchState.matches.isEmpty else { return }

    let newIndex = searchState.currentMatchIndex == 0
      ? searchState.matches.count - 1
      : searchState.currentMatchIndex - 1
    navigateToMatch(at: newIndex)
  }

  /// Navigate to specific match index
  @MainActor
  private func navigateToMatch(at index: Int) {
    guard index >= 0, index < searchState.matches.count else { return }

    searchState.currentMatchIndex = index
    let match = searchState.matches[index]

    // Select the cell containing the match (triggers scroll via ScrollViewReader)
    selectedCellId = match.cellId

    // Wait for scroll to complete, then highlight
    Task {
      try? await Task.sleep(for: .milliseconds(200))

      await MainActor.run {
        // Post notification for highlight
        NotificationCenter.default.post(
          name: .highlightSearchMatch,
          object: nil,
          userInfo: [
            "match": match,
            "query": searchState.query,
            "caseSensitive": searchState.isCaseSensitive
          ]
        )
      }
    }
  }

  /// Close search panel
  @MainActor
  func closeSearch() {
    isSearchPanelVisible = false
    searchState = SearchState()

    // Clear all highlights
    NotificationCenter.default.post(name: .clearSearchHighlights, object: nil)
  }

  /// Open search panel
  @MainActor
  func openSearch() {
    // If panel is already visible, trigger re-focus
    if isSearchPanelVisible {
      searchFocusTrigger = UUID()
    } else {
      isSearchPanelVisible = true
    }
  }

  // MARK: - Helper Methods for Searching

  /// Search in SQL content của cell
  private func searchInSQLContent(cell: NotebookCell, query: String, caseSensitive: Bool) -> [SearchMatch] {
    var matches: [SearchMatch] = []
    let content = caseSensitive ? cell.content : cell.content.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    var searchStartIndex = content.startIndex
    while let range = content.range(of: searchQuery, range: searchStartIndex..<content.endIndex) {
      // Calculate line number
      let lineNumber = content[..<range.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + 1

      // Extract context (50 chars before + match + 50 chars after)
      let contextText = extractContext(from: content, around: range, maxLength: 50)

      matches.append(SearchMatch(
        cellId: cell.id,
        matchType: .sqlContent,
        matchRange: range,
        contextText: contextText,
        lineNumber: lineNumber
      ))

      searchStartIndex = range.upperBound
    }

    return matches
  }

  /// Search in column names
  private func searchInColumnNames(cell: NotebookCell, result: CellResult, query: String, caseSensitive: Bool) -> [SearchMatch] {
    var matches: [SearchMatch] = []

    for column in result.columns {
      let columnName = caseSensitive ? column.name : column.name.lowercased()
      let searchQuery = caseSensitive ? query : query.lowercased()

      if let range = columnName.range(of: searchQuery) {
        matches.append(SearchMatch(
          cellId: cell.id,
          matchType: .columnName(column.name),
          matchRange: range,
          contextText: column.name,
          lineNumber: nil
        ))
      }
    }

    return matches
  }

  /// Search in table data
  private func searchInTableData(cell: NotebookCell, result: CellResult, query: String, caseSensitive: Bool) -> [SearchMatch] {
    var matches: [SearchMatch] = []

    for (rowIndex, row) in result.rows.enumerated() {
      for (columnIndex, cellValue) in row.enumerated() {
        let columnName = result.columns[columnIndex].name
        let valueText = cellValue.displayString
        let searchText = caseSensitive ? valueText : valueText.lowercased()
        let searchQuery = caseSensitive ? query : query.lowercased()

        if let range = searchText.range(of: searchQuery) {
          matches.append(SearchMatch(
            cellId: cell.id,
            matchType: .tableData(rowIndex: rowIndex, columnName: columnName),
            matchRange: range,
            contextText: valueText,
            lineNumber: nil
          ))
        }
      }
    }

    return matches
  }

  /// Search in error message
  private func searchInErrorMessage(cell: NotebookCell, error: String, query: String, caseSensitive: Bool) -> [SearchMatch] {
    var matches: [SearchMatch] = []
    let errorText = caseSensitive ? error : error.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    var searchStartIndex = errorText.startIndex
    while let range = errorText.range(of: searchQuery, range: searchStartIndex..<errorText.endIndex) {
      let contextText = extractContext(from: errorText, around: range, maxLength: 100)

      matches.append(SearchMatch(
        cellId: cell.id,
        matchType: .errorMessage,
        matchRange: range,
        contextText: contextText,
        lineNumber: nil
      ))

      searchStartIndex = range.upperBound
    }

    return matches
  }

  /// Extract context around a match (N chars before + match + N chars after)
  private func extractContext(from text: String, around range: Range<String.Index>, maxLength: Int) -> String {
    let startOffset = max(0, text.distance(from: text.startIndex, to: range.lowerBound) - maxLength)
    let endOffset = min(text.count, text.distance(from: text.startIndex, to: range.upperBound) + maxLength)

    let startIndex = text.index(text.startIndex, offsetBy: startOffset)
    let endIndex = text.index(text.startIndex, offsetBy: endOffset)

    var context = String(text[startIndex..<endIndex])

    // Add ellipsis if truncated
    if startOffset > 0 {
      context = "..." + context
    }
    if endOffset < text.count {
      context = context + "..."
    }

    return context
  }
}
