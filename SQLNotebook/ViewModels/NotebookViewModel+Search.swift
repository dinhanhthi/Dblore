//
//  NotebookViewModel+Search.swift
//  SQLNotebook
//
//

import AppKit
import Foundation

// MARK: - Global Search

extension NotebookViewModel {
  /// Perform global search across all cells
  @MainActor
  func performSearch(query: String, caseSensitive: Bool) async {
    // Cancel previous search if still running
    searchTask?.cancel()

    // Clear AttributedString cache when search query changes for better memory usage
    SearchHighlighter.clearCache()

    searchState.isSearching = true
    searchState.query = query
    searchState.isCaseSensitive = caseSensitive
    searchState.matches = []
    searchState.currentMatchIndex = 0

    guard !query.isEmpty else {
      searchState.isSearching = false
      // Clear highlights when query is empty (include viewModel ID)
      NotificationCenter.default.post(
        name: .clearSearchHighlights,
        object: nil,
        userInfo: ["viewModelId": id]
      )
      return
    }

    // Build search index and find matches (async on background)
    // Performance tracking
    let start = CFAbsoluteTimeGetCurrent()

    searchTask = Task {
      let matches = await buildSearchMatches(query: query, caseSensitive: caseSensitive)

      // Check if search was cancelled
      guard !Task.isCancelled else {
        await AppLogger.shared.log("Search cancelled", level: .debug, category: "Search")
        return
      }

      let duration = CFAbsoluteTimeGetCurrent() - start
      await AppLogger.shared.log(
        "Search completed in \(String(format: "%.3f", duration))s, found \(matches.count) matches",
        level: .info, category: "Performance")

      await MainActor.run {
        searchState.matches = matches
        searchState.isSearching = false

        // Auto-navigate to first match
        if !matches.isEmpty {
          navigateToMatch(at: 0)
        } else {
          // Clear highlights when no matches found (include viewModel ID)
          NotificationCenter.default.post(
            name: .clearSearchHighlights,
            object: nil,
            userInfo: ["viewModelId": id]
          )
        }
      }
    }

    await searchTask?.value
  }

  /// Build search matches from all cells (async for performance)
  /// Optimized with limits to prevent performance issues with large notebooks
  private func buildSearchMatches(query: String, caseSensitive: Bool) async -> [SearchMatch] {
    var allMatches: [SearchMatch] = []
    let maxMatchesPerCell = 50  // Limit matches per cell for performance
    let maxTotalMatches = 1000  // Stop after 1000 total matches

    // In editor mode, search in editorContent instead of notebook.cells
    // because editorContent is the live editing buffer
    let cellsToSearch: [NotebookCell]
    if viewMode == .editor, let firstCell = notebook.cells.first {
      // Create a virtual cell with editorContent for searching
      var editorCell = firstCell
      editorCell.content = editorContent
      cellsToSearch = [editorCell]
    } else {
      cellsToSearch = notebook.cells
    }

    for cell in cellsToSearch {
      // Check cancellation frequently
      if Task.isCancelled { break }

      // 1. Search in SQL content (with limit)
      let sqlMatches = searchInSQLContent(
        cell: cell,
        query: query,
        caseSensitive: caseSensitive,
        maxMatches: maxMatchesPerCell
      )
      allMatches.append(contentsOf: sqlMatches)

      // 2. Search in result data
      // In editor mode, use editorResult instead of cell.result
      let resultToSearch = viewMode == .editor ? editorResult : cell.result
      if let result = resultToSearch {
        if Task.isCancelled { break }

        // Search in column names
        allMatches.append(
          contentsOf: searchInColumnNames(
            cell: cell,
            result: result,
            query: query,
            caseSensitive: caseSensitive
          ))

        // Search in table data (limit rows for performance)
        // Only search first maxRowLimit rows to avoid scanning huge result sets
        let limitedRows = Array(
          result.rows.prefix(await MainActor.run { AppSettings.shared.maxRowLimit }))
        let limitedResult = CellResult(
          columns: result.columns,
          rows: limitedRows,
          executionTime: result.executionTime,
          rowCount: result.rowCount,
          timestamp: result.timestamp
        )

        allMatches.append(
          contentsOf: searchInTableData(
            cell: cell,
            result: limitedResult,
            query: query,
            caseSensitive: caseSensitive,
            maxMatches: maxMatchesPerCell
          ))

        // Search in error messages
        if let error = result.error {
          allMatches.append(
            contentsOf: searchInErrorMessage(
              cell: cell,
              error: error,
              query: query,
              caseSensitive: caseSensitive,
              maxMatches: maxMatchesPerCell
            ))
        }
      }

      // Early exit if we have enough matches
      if allMatches.count >= maxTotalMatches {
        // Stop search to prevent performance issues
        break
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

    let newIndex =
      searchState.currentMatchIndex == 0
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

    // Cancel previous navigation task to debounce rapid navigation (10.1.3 optimization)
    searchNavigationTask?.cancel()

    // Wait for scroll to complete, then highlight (debounced)
    searchNavigationTask = Task {
      try? await Task.sleep(for: .milliseconds(200))

      // Check if cancelled during sleep (debouncing)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        // Post notification for highlight (include viewModel ID to scope to this window)
        NotificationCenter.default.post(
          name: .highlightSearchMatch,
          object: nil,
          userInfo: [
            "match": match,
            "query": searchState.query,
            "caseSensitive": searchState.isCaseSensitive,
            "viewModelId": id,
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

    // Clear AttributedString cache to free memory
    SearchHighlighter.clearCache()

    // Clear all highlights (include viewModel ID)
    NotificationCenter.default.post(
      name: .clearSearchHighlights,
      object: nil,
      userInfo: ["viewModelId": id]
    )

    // Restore focus to previous responder (like VSCode)
    if let previousResponder = previousFirstResponder {
      NSApplication.shared.keyWindow?.makeFirstResponder(previousResponder)
      previousFirstResponder = nil
    }
  }

  /// Toggle search panel (open/close)
  @MainActor
  func openSearch() {
    if isSearchPanelVisible {
      // Close search if already open
      closeSearch()
    } else {
      // Save current first responder before opening search (like VSCode)
      previousFirstResponder = NSApplication.shared.keyWindow?.firstResponder

      // Open search panel
      isSearchPanelVisible = true
    }
  }

  // MARK: - Helper Methods for Searching

  /// Search in SQL content của cell
  /// Optimized with match limit and shorter context for better performance
  private func searchInSQLContent(
    cell: NotebookCell,
    query: String,
    caseSensitive: Bool,
    maxMatches: Int = 50
  ) -> [SearchMatch] {
    var matches: [SearchMatch] = []
    let content = caseSensitive ? cell.content : cell.content.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    var searchStartIndex = content.startIndex
    while let range = content.range(of: searchQuery, range: searchStartIndex..<content.endIndex) {
      // Early exit if we have enough matches for this cell
      if matches.count >= maxMatches {
        // Note: Logging inside hot loop can be expensive, skip for now
        break
      }

      // Calculate line number
      let lineNumber = content[..<range.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + 1

      // Extract shorter context (25 chars instead of 50) for better memory usage
      let contextText = extractContext(from: content, around: range, maxLength: 25)

      matches.append(
        SearchMatch(
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
  private func searchInColumnNames(
    cell: NotebookCell, result: CellResult, query: String, caseSensitive: Bool
  ) -> [SearchMatch] {
    var matches: [SearchMatch] = []

    for column in result.columns {
      let columnName = caseSensitive ? column.name : column.name.lowercased()
      let searchQuery = caseSensitive ? query : query.lowercased()

      if let range = columnName.range(of: searchQuery) {
        matches.append(
          SearchMatch(
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
  /// Optimized with match limit to prevent scanning huge datasets
  private func searchInTableData(
    cell: NotebookCell,
    result: CellResult,
    query: String,
    caseSensitive: Bool,
    maxMatches: Int = 50
  ) -> [SearchMatch] {
    var matches: [SearchMatch] = []

    for (rowIndex, row) in result.rows.enumerated() {
      // Check cancellation in inner loop for faster response (10.1.9 optimization)
      if Task.isCancelled {
        return matches
      }

      for (columnIndex, cellValue) in row.enumerated() {
        // Early exit if we have enough matches
        if matches.count >= maxMatches {
          return matches
        }

        let columnName = result.columns[columnIndex].name
        let valueText = cellValue.displayString
        let searchText = caseSensitive ? valueText : valueText.lowercased()
        let searchQuery = caseSensitive ? query : query.lowercased()

        if let range = searchText.range(of: searchQuery) {
          matches.append(
            SearchMatch(
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
  /// Optimized with match limit and shorter context
  private func searchInErrorMessage(
    cell: NotebookCell,
    error: String,
    query: String,
    caseSensitive: Bool,
    maxMatches: Int = 50
  ) -> [SearchMatch] {
    var matches: [SearchMatch] = []
    let errorText = caseSensitive ? error : error.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    var searchStartIndex = errorText.startIndex
    while let range = errorText.range(of: searchQuery, range: searchStartIndex..<errorText.endIndex)
    {
      // Early exit if we have enough matches
      if matches.count >= maxMatches {
        break
      }

      // Use shorter context (50 chars instead of 100) for better memory
      let contextText = extractContext(from: errorText, around: range, maxLength: 50)

      matches.append(
        SearchMatch(
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
  private func extractContext(
    from text: String, around range: Range<String.Index>, maxLength: Int
  ) -> String {
    let startOffset = max(0, text.distance(from: text.startIndex, to: range.lowerBound) - maxLength)
    let endOffset = min(
      text.count, text.distance(from: text.startIndex, to: range.upperBound) + maxLength)

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
