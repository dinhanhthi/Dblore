//
//  NotebookViewModel+AI.swift
//  Dblore
//

import AppKit
import Foundation

// MARK: - AI Assistant Bridge

/// Bridge between the AI chat panel and the active tab. The assistant never executes SQL:
/// insertion only places text.
extension NotebookViewModel {
  /// Place AI-suggested SQL in the tab: at the cursor in editor mode (appended when there is
  /// no text view), as a new SQL cell after the selected one in notebook mode
  func insertAISQL(_ sql: String) {
    if viewMode == .editor {
      if editorTextView != nil {
        insertTextIntoSelectedCell(sql)
      } else {
        editorContent = editorContent.isEmpty ? sql : editorContent + "\n" + sql
      }
      return
    }

    addCell(type: .sql, after: selectedCellId)
    guard let id = selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == id })
    else { return }
    notebook.cells[index].content = sql
    onDocumentChanged?()
  }

  /// SQL the quick actions work on: editor selection (else whole editor) or the selected cell
  var aiCurrentSQL: String? {
    let text: String
    if viewMode == .editor {
      if let textView = editorTextView,
        let range = Range(textView.selectedRange(), in: textView.string),
        !textView.string[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        text = String(textView.string[range])
      } else {
        text = editorContent
      }
    } else {
      text = aiSelectedCell?.content ?? ""
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  /// Error of the selected statement (else the whole result) in the editor or selected cell
  var aiLastError: String? {
    let error: String?
    if viewMode == .editor {
      error = Self.aiError(
        statements: editorStatementResults, index: selectedStatementIndex, result: editorResult)
    } else if let cell = aiSelectedCell {
      error = Self.aiError(
        statements: cell.statementResults, index: cell.selectedStatementIndex,
        result: cell.result)
    } else {
      error = nil
    }
    guard let error, !error.isEmpty else { return nil }
    return error
  }

  private var aiSelectedCell: NotebookCell? {
    notebook.cells.first { $0.id == selectedCellId }
  }

  private static func aiError(
    statements: [StatementResult], index: Int, result: CellResult?
  ) -> String? {
    let statementError =
      statements.indices.contains(index) ? statements[index].result.error : nil
    return statementError ?? result?.error
  }
}
