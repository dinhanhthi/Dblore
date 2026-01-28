//
//  EditorModeView+Helpers.swift
//  SQLNotebook
//
//  Helper functions for editor mode view
//

import SwiftUI

// MARK: - Helpers Extension

extension EditorModeView {

  // MARK: - Actions

  func clearResult() {
    viewModel.editorResult = nil
    viewModel.editorStatementResults = []
    viewModel.selectedStatementIndex = 0
  }

  func copyErrorToClipboard(error: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(error, forType: .string)

    // Show checkmark feedback
    setIsErrorCopied(true)

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      setIsErrorCopied(false)
    }
  }

  // MARK: - Query Formatting

  /// Truncate long query text for display in dropdown menu
  func truncateQuery(_ query: String, maxLength: Int = 60) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxLength {
      return trimmed
    }
    return String(trimmed.prefix(maxLength)) + "..."
  }

  /// Format execution time with appropriate unit
  /// - If time >= 1 second: show in seconds with 2 decimal places (e.g., "1.23s")
  /// - If time < 1 second: show in milliseconds with 0 decimal places (e.g., "450ms")
  func formatExecutionTime(_ seconds: Double) -> String {
    if seconds >= 1.0 {
      return String(format: "%.2fs", seconds)
    } else {
      let milliseconds = seconds * 1000
      return String(format: "%.0fms", milliseconds)
    }
  }

  /// Determine color for affected rows text based on query type
  /// - Green for INSERT/UPDATE queries with affected rows > 0
  /// - Red for DELETE queries with affected rows > 0
  /// - Subtle gray for SELECT, 0 affected rows, or when no query info available
  func affectedRowsColor(for result: CellResult) -> Color {
    let affectedRows = result.affectedRows ?? 0

    // If no rows affected, use default gray color
    guard affectedRows > 0, let query = result.sourceQuery else {
      return .foregroundSubtle
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    if trimmed.hasPrefix("DELETE") {
      return .red
    } else if trimmed.hasPrefix("INSERT") || trimmed.hasPrefix("UPDATE") {
      return .green
    } else {
      return .foregroundSubtle
    }
  }

  /// Get the actual query that was executed (with LIMIT replaced if needed)
  func getActualExecutedQuery(result: CellResult) -> String {
    guard let sourceQuery = result.sourceQuery else {
      return ""
    }

    // If user's LIMIT was capped (even if no limiting occurred in result)
    // Show the actual query that was sent to database
    if result.limitWasCapped, let actualLimit = result.actualLimitUsed {
      // Replace LIMIT in query with actual limit used
      return viewModel.connectionManager.replaceLimitInQuery(sourceQuery, newLimit: actualLimit)
    }

    // Return original query
    return sourceQuery
  }
}
