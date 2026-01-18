//
//  NotebookViewModel+EditorMode.swift
//  SQLNotebook
//

import AppKit
import Foundation

// MARK: - Editor Mode

extension NotebookViewModel {
  /// Get selected text from editor, or entire content if no selection
  func getEditorQueryText() -> String? {
    // Try to get selected text from editor
    if let textView = editorTextView {
      let selectedRange = textView.selectedRange()
      if selectedRange.length > 0, let textStorage = textView.textStorage {
        let selectedText = textStorage.string as NSString
        return selectedText.substring(with: selectedRange)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    // No selection, return entire content
    return editorContent.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Run query in editor mode (selection if any, otherwise all content)
  func runEditorQuery() async {
    guard let query = getEditorQueryText(), !query.isEmpty else { return }
    guard connectionState == .connected else {
      showToast("Not connected to database", type: .error)
      return
    }

    // Check for modification queries and show confirmation if needed
    let isModification = isModificationQuery(query)
    if isModification && !AppSettings.shared.bypassDestructiveQueryConfirmation {
      // Show confirmation dialog
      pendingQuery = query
      pendingQueryCellId = nil  // No cell ID in editor mode
      showQueryConfirmationDialog = true
      return
    }

    await executeEditorQuery(query)
  }

  /// Execute the pending editor query after confirmation
  func executeConfirmedEditorQuery() async {
    guard !pendingQuery.isEmpty else { return }
    await executeEditorQuery(pendingQuery)
    pendingQuery = ""
    pendingQueryCellId = nil
  }

  /// Execute query in editor mode (internal)
  private func executeEditorQuery(_ query: String) async {
    let startTime = Date()

    do {
      let result = try await connectionManager.executeQuery(query)

      let executionTime = Date().timeIntervalSince(startTime)

      editorResult = CellResult(
        columns: result.columns,
        rows: result.rows,
        executionTime: executionTime,
        rowCount: result.rows.count,
        timestamp: Date(),
        error: nil,
        wasLimited: result.wasLimited,
        sourceQuery: query,
        tableName: nil,  // Not available from QueryResult
        primaryKeyColumns: [],
        rowIdentifiers: result.rowIdentifiers,
        userLimitExceeded: result.userLimitExceeded,
        userRequestedLimit: result.userRequestedLimit,
        affectedRows: result.affectedRows
      )

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime
      )
    }
  }

}
