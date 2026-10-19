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
    guard !isReadOnlySource else { return }
    if viewMode == .markdown { return }
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

  /// SQL the quick actions work on: editor selection (else whole editor) or the selected cell.
  /// Nil on a source tab: its text comes from the server and never goes into a prompt.
  var aiCurrentSQL: String? {
    if viewMode == .markdown || isReadOnlySource { return nil }
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

  /// `AIAccessGate.sessionKey` of the tab's connection, stamped on its error results
  var aiSessionKey: String? {
    notebook.connectionConfig.map(AIAccessGate.sessionKey(for:))
  }

  /// Error of the selected statement (else the whole result) in the editor or selected cell.
  /// Nil when it came from another connection than the tab's (a switch since it ran, a file).
  var aiLastError: String? {
    if viewMode == .markdown || isReadOnlySource { return nil }
    let error: String?
    let key = aiSessionKey
    if viewMode == .editor {
      error = Self.aiError(
        statements: editorStatementResults, index: selectedStatementIndex, result: editorResult,
        key: key)
    } else if let cell = aiSelectedCell {
      error = Self.aiError(
        statements: cell.statementResults, index: cell.selectedStatementIndex,
        result: cell.result, key: key)
    } else {
      error = nil
    }
    guard let error, !error.isEmpty else { return nil }
    return error
  }

  /// The MongoDB collection screen shown in this tab, nil unless it is a collection data viewer.
  /// Names and section only: the filter and pipeline text never go into a prompt.
  var aiMongoScreen: AIMongoAssist.Screen? {
    guard let model = mongoCollection else { return nil }
    return AIMongoAssist.Screen(
      database: model.database, collection: model.collection,
      showsAggregations: model.section == .aggregations)
  }

  private var aiSelectedCell: NotebookCell? {
    notebook.cells.first { $0.id == selectedCellId }
  }

  private static func aiError(
    statements: [StatementResult], index: Int, result: CellResult?, key: String?
  ) -> String? {
    let statement = statements.indices.contains(index) ? statements[index].result : nil
    guard let failed = [statement, result].compactMap({ $0 }).first(where: { $0.error != nil }),
      let key, failed.aiSessionKey == key
    else { return nil }
    return failed.error
  }
}
