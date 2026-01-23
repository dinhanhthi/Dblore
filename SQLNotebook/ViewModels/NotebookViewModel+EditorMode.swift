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
      // Check if this is a multi-statement query
      if connectionManager.hasMultipleStatements(query) {
        // Execute all statements and get detailed results
        let (statementResults, totalTime) =
          try await connectionManager
          .executeMultipleStatementsDetailed(query)

        totalExecutionTime = totalTime

        // Convert to StatementResult array
        editorStatementResults = statementResults.enumerated().map { index, tuple in
          StatementResult(
            queryText: tuple.queryText,
            result: CellResult(
              columns: tuple.result.columns,
              rows: tuple.result.rows,
              executionTime: tuple.result.executionTime,
              rowCount: tuple.result.rows.count,
              timestamp: Date(),
              error: nil,
              wasLimited: tuple.result.wasLimited,
              sourceQuery: tuple.queryText,
              tableName: nil,
              primaryKeyColumns: [],
              rowIdentifiers: tuple.result.rowIdentifiers,
              userLimitExceeded: tuple.result.userLimitExceeded,
              userRequestedLimit: tuple.result.userRequestedLimit,
              affectedRows: tuple.result.affectedRows
            ),
            statementIndex: index
          )
        }

        // Select the last statement by default (psql behavior)
        selectedStatementIndex = editorStatementResults.count - 1

        // Set editorResult to the selected statement's result for backward compatibility
        if !editorStatementResults.isEmpty {
          editorResult = editorStatementResults[selectedStatementIndex].result
        }

      } else {
        // Single statement - use existing logic
        let result = try await connectionManager.executeQuery(query)

        let executionTime = Date().timeIntervalSince(startTime)

        // Clear multi-statement state
        editorStatementResults = []
        selectedStatementIndex = 0
        totalExecutionTime = executionTime

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
      }

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      // Clear multi-statement state on error
      editorStatementResults = []
      selectedStatementIndex = 0
      totalExecutionTime = executionTime

      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime,
        sourceQuery: query
      )
    }
  }

  /// Select a specific statement result in editor mode
  func selectEditorStatement(at index: Int) {
    guard index >= 0 && index < editorStatementResults.count else { return }
    selectedStatementIndex = index
    editorResult = editorStatementResults[index].result
  }

}
