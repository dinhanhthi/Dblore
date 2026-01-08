//
//  NotebookViewModel+EditorMode.swift
//  SQLNotebook
//

import Foundation

// MARK: - Editor Mode

extension NotebookViewModel {
  /// Run query in editor mode
  func runEditorQuery() async {
    guard !editorContent.isEmpty else { return }
    guard connectionState == .connected else {
      showToast("Not connected to database", type: .error)
      return
    }

    let query = editorContent.trimmingCharacters(in: .whitespacesAndNewlines)

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

      // Show success toast
      if let affectedRows = result.affectedRows {
        showToast("\(affectedRows) row\(affectedRows == 1 ? "" : "s") affected", type: .success)
      } else {
        showToast("\(result.rows.count) row\(result.rows.count == 1 ? "" : "s") returned", type: .success)
      }

    } catch {
      let executionTime = Date().timeIntervalSince(startTime)

      editorResult = CellResult.errorResult(
        error.localizedDescription,
        executionTime: executionTime
      )

      showToast("Query failed", type: .error)
    }
  }

  /// Toggle view mode
  func toggleViewMode() {
    viewMode = viewMode == .notebook ? .editor : .notebook

    // If switching to editor mode and there's content in cells, suggest copying
    if viewMode == .editor && !notebook.cells.isEmpty && editorContent.isEmpty {
      // Get first non-empty cell content
      if let firstCell = notebook.cells.first(where: { !$0.content.isEmpty }) {
        editorContent = firstCell.content
      }
    }

    // If switching to notebook mode and editor has content, suggest creating cell
    if viewMode == .notebook && !editorContent.isEmpty && notebook.cells.isEmpty {
      // Create a new cell with editor content
      let newCell = NotebookCell(content: editorContent)
      notebook.cells.append(newCell)
      selectedCellId = newCell.id
    }
  }
}
