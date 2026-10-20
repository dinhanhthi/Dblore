//
//  NotebookViewModel+Search.swift
//  Dblore
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

    // In editor mode, search in editorContent instead of notebook.cells
    // because editorContent is the live editing buffer
    let cellsToSearch: [NotebookCell]
    if dataViewer != nil {
      // A data viewer has no cell: search the loaded page under this view model's id
      cellsToSearch = [NotebookCell(id: id, result: editorResult)]
    } else if viewMode == .editor, let firstCell = notebook.cells.first {
      // Create a virtual cell with editorContent for searching
      var editorCell = firstCell
      editorCell.content = editorContent
      editorCell.result = editorResult
      cellsToSearch = [editorCell]
    } else {
      cellsToSearch = notebook.cells
    }
    let rowCap = effectiveRowCap
    let wholeWord = searchState.isWholeWord

    // Performance tracking
    let start = CFAbsoluteTimeGetCurrent()

    searchTask = Task {
      // The scan runs off the main actor on a snapshot of the cells
      let matches = await Self.buildSearchMatches(
        in: cellsToSearch, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord,
        rowCap: rowCap)

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

  /// Build search matches from all cells, off the main actor
  /// Optimized with limits to prevent performance issues with large notebooks
  @concurrent private nonisolated static func buildSearchMatches(
    in cellsToSearch: [NotebookCell], query: String, caseSensitive: Bool, wholeWord: Bool,
    rowCap: Int
  ) async -> [SearchMatch] {
    var allMatches: [SearchMatch] = []
    let maxMatchesPerCell = 50  // Limit matches per cell for performance
    let maxTotalMatches = 1000  // Stop after 1000 total matches

    for cell in cellsToSearch {
      // Check cancellation frequently
      if Task.isCancelled { break }

      // 1. Search in SQL content (with limit)
      let sqlMatches = searchInSQLContent(
        cell: cell,
        query: query,
        caseSensitive: caseSensitive,
        wholeWord: wholeWord,
        maxMatches: maxMatchesPerCell
      )
      allMatches.append(contentsOf: sqlMatches)

      // 2. Search in result data (in editor mode the snapshot cell carries editorResult)
      if let result = cell.result {
        if Task.isCancelled { break }

        // Search in column names
        allMatches.append(
          contentsOf: searchInColumnNames(
            cell: cell,
            result: result,
            query: query,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord
          ))

        // Search in table data (limit rows for performance)
        // Only search first rowCap rows to avoid scanning huge result sets
        let limitedRows = Array(result.rows.prefix(rowCap))
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
            wholeWord: wholeWord,
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
              wholeWord: wholeWord,
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
            "wholeWord": searchState.isWholeWord,
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
    } else if isMongoDataViewer, dataViewerDisplayMode == .json, isSearchAvailable {
      // The JSON view searches its text with the find bar; the grid search has nothing to match
      mongoJSONFindRequest += 1
    } else if isSearchAvailable {
      // Save current first responder before opening search (like VSCode)
      previousFirstResponder = NSApplication.shared.keyWindow?.firstResponder

      // Open search panel
      isSearchPanelVisible = true
    }
  }

  // MARK: - Replace

  /// Replace edits query text only: an editor tab (SQL or mongosh) or the notebook's cells. Never
  /// a data viewer (its search covers the loaded rows), a read-only source tab or a note.
  var isReplaceAvailable: Bool {
    dataViewer == nil && isSearchAvailable && !isReadOnlySource && viewMode != .markdown
  }

  /// Opens the search panel with its Replace row (Find and Replace…). Unlike `openSearch`, it
  /// never closes a panel already shown.
  func openFindReplace() {
    guard isReplaceAvailable else { return }
    if !isSearchPanelVisible {
      previousFirstResponder = NSApplication.shared.keyWindow?.firstResponder
      isSearchPanelVisible = true
    }
    searchState.isReplaceVisible = true
    searchFocusTrigger = UUID()
  }

  /// Replaces the current query-text match with `replacement`, then moves to the match after it.
  /// Matches in rows, column names and errors are never edited: from one of them, the next
  /// query-text match (wrapping) is replaced. False when refused, when nothing matched, or when
  /// the text changed since the search (the search runs again and nothing is edited).
  @discardableResult
  func replaceCurrentMatch(with replacement: String) async -> Bool {
    let matches = searchState.matches
    guard isReplaceAvailable, !searchState.query.isEmpty, !matches.isEmpty else { return false }
    let start = min(searchState.currentMatchIndex, matches.count - 1)
    let order = Array(matches.indices[start...]) + Array(matches.indices[..<start])
    guard let index = order.first(where: { matches[$0].matchType == .sqlContent }),
      let text = replaceSourceText(cellId: matches[index].cellId)
    else { return false }
    let match = matches[index]

    // Find the match again in the live text by its rank in the cell: the stored range indexes
    // the text the search saw
    let rank = matches[..<index].filter { $0.cellId == match.cellId && $0.matchType == .sqlContent }
      .count
    let ranges = sourceRanges(in: text, limit: rank + 1)
    guard ranges.count > rank,
      Self.extractContext(from: text, around: ranges[rank], maxLength: 25) == match.contextText
    else {
      await performSearch(query: searchState.query, caseSensitive: searchState.isCaseSensitive)
      return false
    }
    let range = ranges[rank]
    let resumeOffset =
      text.utf16.distance(from: text.startIndex, to: range.lowerBound) + replacement.utf16.count
    guard
      replaceSource(
        cellId: match.cellId, text: text, ranges: [range], with: replacement, actionName: "Replace")
    else { return false }

    await performSearch(query: searchState.query, caseSensitive: searchState.isCaseSensitive)
    navigateToSourceMatch(from: resumeOffset, in: match.cellId)
    return true
  }

  /// Replaces every query-text match of the editor or of all cells (no match cap) as one undo
  /// step. Rows, column names and errors are never edited. Returns the number replaced, 0 when
  /// refused.
  @discardableResult
  func replaceAllMatches(with replacement: String) async -> Int {
    guard isReplaceAvailable, !searchState.query.isEmpty else { return 0 }
    var count = 0
    if viewMode == .editor {
      let text = editorTextView?.string ?? editorContent
      let ranges = sourceRanges(in: text)
      guard !ranges.isEmpty,
        replaceSource(
          cellId: id, text: text, ranges: ranges, with: replacement, actionName: "Replace All")
      else { return 0 }
      count = ranges.count
    } else {
      var contents: [UUID: String] = [:]
      for cell in notebook.cells {
        let ranges = sourceRanges(in: cell.content)
        guard !ranges.isEmpty else { continue }
        contents[cell.id] = Self.replacing(ranges, in: cell.content, with: replacement)
        count += ranges.count
      }
      guard !contents.isEmpty else { return 0 }
      setReplacedCellContents(contents, actionName: "Replace All")
    }
    await performSearch(query: searchState.query, caseSensitive: searchState.isCaseSensitive)
    return count
  }

  /// Query-text matches of the current search options in `text`
  private func sourceRanges(in text: String, limit: Int = .max) -> [Range<String.Index>] {
    Self.sourceMatchRanges(
      in: text, query: searchState.query, caseSensitive: searchState.isCaseSensitive,
      wholeWord: searchState.isWholeWord, limit: limit)
  }

  /// Live query text a match was found in: the editor's text view (falling back to the editor
  /// buffer) or the cell's content
  private func replaceSourceText(cellId: UUID) -> String? {
    if viewMode == .editor { return editorTextView?.string ?? editorContent }
    return notebook.cells.first { $0.id == cellId }?.content
  }

  /// Replaces `ranges` (ascending) of `text` as one undo step: the editor through its text view
  /// (its own undo stack), a cell on this tab's undo stack
  private func replaceSource(
    cellId: UUID, text: String, ranges: [Range<String.Index>], with replacement: String,
    actionName: String
  ) -> Bool {
    guard let first = ranges.first, let last = ranges.last else { return false }
    let span = first.lowerBound..<last.upperBound
    let spanText = Self.replacing(ranges, in: text, span: span, with: replacement)
    guard viewMode == .editor else {
      setReplacedCellContents(
        [cellId: text.replacingCharacters(in: span, with: spanText)], actionName: actionName)
      return true
    }
    guard let textView = editorTextView, let textStorage = textView.textStorage,
      textView.string == text
    else {
      // No text view (not shown): nothing to undo through
      editorContent = text.replacingCharacters(in: span, with: spanText)
      return true
    }
    // One replacement over the span of all matches is one undo step
    let range = NSRange(span, in: text)
    textView.setProgrammaticEditFlag(true)
    defer { textView.setProgrammaticEditFlag(false) }
    guard textView.shouldChangeText(in: range, replacementString: spanText) else { return false }
    textStorage.replaceCharacters(in: range, with: spanText)
    textView.didChangeText()
    textView.undoManager?.setActionName(actionName)
    // The text view's delegate syncs the buffer; set it too where none is attached
    if editorContent != textView.string { editorContent = textView.string }
    return true
  }

  /// `text` from the start of `span` to its end, with each of `ranges` replaced
  private nonisolated static func replacing(
    _ ranges: [Range<String.Index>], in text: String, span: Range<String.Index>,
    with replacement: String
  ) -> String {
    var result = ""
    var cursor = span.lowerBound
    for range in ranges {
      result += text[cursor..<range.lowerBound]
      result += replacement
      cursor = range.upperBound
    }
    result += text[cursor..<span.upperBound]
    return result
  }

  /// `text` with each of `ranges` (ascending) replaced
  private nonisolated static func replacing(
    _ ranges: [Range<String.Index>], in text: String, with replacement: String
  ) -> String {
    replacing(ranges, in: text, span: text.startIndex..<text.endIndex, with: replacement)
  }

  /// Sets cells' text as one step on the undo stack; undo runs this again, so redo comes with it.
  /// Like Apply AI Suggestion, undo and redo act only while every cell still holds the text this
  /// step set (typing goes to the text view's own stack and is kept).
  private func setReplacedCellContents(_ contents: [UUID: String], actionName: String) {
    var previous: [UUID: String] = [:]
    for (cellId, content) in contents {
      guard let index = notebook.cells.firstIndex(where: { $0.id == cellId }) else { continue }
      previous[cellId] = notebook.cells[index].content
      notebook.cells[index].content = content
    }
    guard !previous.isEmpty else { return }
    let applied = contents.filter { previous[$0.key] != nil }
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        let unchanged = applied.allSatisfy { cellId, content in
          target.notebook.cells.first(where: { $0.id == cellId })?.content == content
        }
        guard unchanged else { return }
        target.setReplacedCellContents(previous, actionName: actionName)
      }
    }
    undoManager.setActionName(actionName)
    onDocumentChanged?()
  }

  /// Moves to the first query-text match at or after `offset` (UTF-16) in `cellId`'s text, else
  /// to the first one of a later cell, else to the first one
  private func navigateToSourceMatch(from offset: Int, in cellId: UUID) {
    let matches = searchState.matches
    let sourceIndices = matches.indices.filter { matches[$0].matchType == .sqlContent }
    guard let firstIndex = sourceIndices.first else { return }
    let cellIndices = sourceIndices.filter { matches[$0].cellId == cellId }
    let rank = replaceSourceText(cellId: cellId).flatMap { text in
      sourceRanges(in: text).firstIndex {
        text.utf16.distance(from: text.startIndex, to: $0.lowerBound) >= offset
      }
    }
    let cellOrder = { (id: UUID) in self.notebook.cells.firstIndex { $0.id == id } ?? -1 }
    let current = cellOrder(cellId)
    let target =
      rank.flatMap { cellIndices.indices.contains($0) ? cellIndices[$0] : nil }
      ?? sourceIndices.first { cellOrder(matches[$0].cellId) > current }
      ?? firstIndex
    navigateToMatch(at: target)
  }

  // MARK: - Helper Methods for Searching

  /// Search in SQL content của cell
  /// Optimized with match limit and shorter context for better performance
  private nonisolated static func searchInSQLContent(
    cell: NotebookCell,
    query: String,
    caseSensitive: Bool,
    wholeWord: Bool,
    maxMatches: Int = 50
  ) -> [SearchMatch] {
    let content = cell.content
    let ranges = sourceMatchRanges(
      in: content, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord,
      limit: maxMatches)
    return ranges.map { range in
      // Calculate line number
      let lineNumber = content[..<range.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + 1

      // Extract shorter context (25 chars instead of 50) for better memory usage
      let contextText = extractContext(from: content, around: range, maxLength: 25)

      return SearchMatch(
        cellId: cell.id,
        matchType: .sqlContent,
        matchRange: range,
        contextText: contextText,
        lineNumber: lineNumber
      )
    }
  }

  /// Ranges of `query` in query text, in order. Matched on `text` itself (not a lowercased copy),
  /// so the ranges index it and Replace can edit them. Whole word: the characters around a
  /// match are not letters, digits or `_`.
  nonisolated static func sourceMatchRanges(
    in text: String, query: String, caseSensitive: Bool, wholeWord: Bool, limit: Int = .max
  ) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
    var ranges: [Range<String.Index>] = []
    var start = text.startIndex
    while ranges.count < limit,
      let range = text.range(of: query, options: options, range: start..<text.endIndex)
    {
      if !wholeWord || isWholeWord(range, in: text) {
        ranges.append(range)
      }
      start = range.upperBound
    }
    return ranges
  }

  private nonisolated static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool
  {
    func isWordCharacter(_ character: Character) -> Bool {
      character.isLetter || character.isNumber || character == "_"
    }
    if range.lowerBound > text.startIndex,
      isWordCharacter(text[text.index(before: range.lowerBound)])
    {
      return false
    }
    if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
      return false
    }
    return true
  }

  /// Search in column names
  private nonisolated static func searchInColumnNames(
    cell: NotebookCell, result: CellResult, query: String, caseSensitive: Bool, wholeWord: Bool
  ) -> [SearchMatch] {
    var matches: [SearchMatch] = []

    for column in result.columns {
      if let range = sourceMatchRanges(
        in: column.name, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord,
        limit: 1
      ).first {
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
  private nonisolated static func searchInTableData(
    cell: NotebookCell,
    result: CellResult,
    query: String,
    caseSensitive: Bool,
    wholeWord: Bool,
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

        if let range = sourceMatchRanges(
          in: valueText, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord,
          limit: 1
        ).first {
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
  private nonisolated static func searchInErrorMessage(
    cell: NotebookCell,
    error: String,
    query: String,
    caseSensitive: Bool,
    wholeWord: Bool,
    maxMatches: Int = 50
  ) -> [SearchMatch] {
    let ranges = sourceMatchRanges(
      in: error, query: query, caseSensitive: caseSensitive, wholeWord: wholeWord,
      limit: maxMatches)
    return ranges.map { range in
      // Use shorter context (50 chars instead of 100) for better memory
      SearchMatch(
        cellId: cell.id,
        matchType: .errorMessage,
        matchRange: range,
        contextText: extractContext(from: error, around: range, maxLength: 50),
        lineNumber: nil
      )
    }
  }

  /// Extract context around a match (N chars before + match + N chars after)
  private nonisolated static func extractContext(
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

  // Note: Schema search is now handled at workspace level in WorkspaceManager
}
