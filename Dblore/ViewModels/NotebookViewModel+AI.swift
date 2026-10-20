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
      text = aiEditorSelection?.text ?? editorContent
    } else {
      text = aiSelectedCell?.content ?? ""
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  /// Range of the editor selection `aiCurrentSQL` reads, nil when it reads the whole editor
  /// or a cell
  var aiCurrentSelection: NSRange? {
    guard viewMode == .editor, aiCurrentSQL != nil else { return nil }
    return aiEditorSelection?.range
  }

  /// The editor's non-blank selection
  private var aiEditorSelection: (text: String, range: NSRange)? {
    guard let textView = editorTextView,
      let range = Range(textView.selectedRange(), in: textView.string),
      !textView.string[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return (String(textView.string[range]), textView.selectedRange())
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

  /// Plan of the selected statement's result (else the whole result) in the editor or selected
  /// cell, when it is an EXPLAIN result the plan view reads and it explained `sql`: the text it
  /// ran is `sql` or `sql` behind one of the prefixes Explain adds
  func aiShownPlan(for sql: String) -> ExplainPlan? {
    let statements: [StatementResult]
    let index: Int
    let result: CellResult?
    if viewMode == .editor {
      (statements, index, result) = (editorStatementResults, selectedStatementIndex, editorResult)
    } else if let cell = aiSelectedCell {
      (statements, index, result) = (
        cell.statementResults, cell.selectedStatementIndex, cell.result
      )
    } else {
      return nil
    }
    let statement = statements.indices.contains(index) ? statements[index] : nil
    guard let shown = statement?.result ?? result,
      let ran = statement?.queryText ?? shown.sourceQuery
    else { return nil }
    let body = Self.aiStatementBody(sql)
    var explained = [body]
    for analyze in [false, true] {
      for format in [nil, "json"] {
        explained.append(
          sqlDialect.explainPrefix(analyze: analyze, buffers: analyze, format: format) + " "
            + body)
      }
    }
    guard explained.contains(Self.aiStatementBody(ran)) else { return nil }
    return ExplainResultPlan.parse(shown)
  }

  /// `sql` trimmed without one trailing `;`, as `ExplainRequest` keeps the statement
  private static func aiStatementBody(_ sql: String) -> String {
    var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(";") {
      text.removeLast()
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }

  /// The MongoDB collection screen shown in this tab, nil unless it is a collection data viewer.
  /// Names and section only: the filter and pipeline text never go into a prompt.
  var aiMongoScreen: AIMongoAssist.Screen? {
    guard let model = mongoCollection else { return nil }
    return AIMongoAssist.Screen(
      database: model.database, collection: model.collection,
      showsAggregations: model.section == .aggregations)
  }

  /// Ghost text controller of the editor tab (`cellId` nil) or one SQL cell, created once per
  /// editor. Nil where ghost text never goes: MongoDB (mongosh tabs and cells), read-only source
  /// tabs and Markdown notes. Creating one drops the controllers of deleted cells.
  func aiInlineCompletion(cellId: UUID?) -> AIInlineCompletionController? {
    guard aiInlineSource != nil else { return nil }
    let key = cellId ?? id
    if let controller = aiInlineCompletions[key] { return controller }
    pruneAIInlineCompletions()
    let controller = AIInlineCompletionController()
    controller.isAllowed = { [weak self] in self?.isAIAllowed() ?? false }
    controller.source = { [weak self] in self?.aiInlineSource }
    controller.schema = { [weak self] prefix in await self?.aiInlineSchema(prefix) }
    aiInlineCompletions[key] = controller
    return controller
  }

  /// Drops the controllers of cells no longer in the notebook; the editor tab's stays. Run when
  /// a controller is created, so the map never outgrows the cells shown; a deleted cell's
  /// controller is idle until then (its editor dismissed it on teardown).
  private func pruneAIInlineCompletions() {
    let cellIds = Set(notebook.cells.map(\.id))
    for (key, controller) in aiInlineCompletions where key != id && !cellIds.contains(key) {
      controller.dismiss()
      aiInlineCompletions[key] = nil
    }
  }

  /// Dialect of the ghost text prompt; nil on MongoDB, a read-only source tab or a Markdown
  /// note, so nothing is sent from them
  var aiInlineSource: (dialect: SQLDialect, isReadOnlySource: Bool)? {
    guard sqlDialect != .mongodb, !isReadOnlySource, viewMode != .markdown else { return nil }
    return (sqlDialect, isReadOnlySource)
  }

  enum AIReviewApplyResult: Equatable {
    case applied
    case refused(String)
  }

  /// Replaces the reviewed SQL with `sql`, as one undo step: a cell on this tab's undo stack
  /// (Edit > Undo, or Cmd+Z outside a text field, like the other cell operations), the editor
  /// on its text view's own stack (the text view is focused so Cmd+Z undoes it). Refused once
  /// the target is gone or its text changed: the whole cell or editor must still equal
  /// `sourceSQL`, a reviewed editor selection must still hold it at the same range.
  func applyAIReview(_ request: AIReviewRequest, sql: String) -> AIReviewApplyResult {
    guard request.notebookId == id else {
      return .refused("The tab this query came from is not the active tab.")
    }
    guard !isReadOnlySource else {
      return .refused("This tab shows read-only source text, which cannot be changed.")
    }
    // The model saw only the start of a longer query: its rewrite would drop the rest
    guard request.sourceSQL.count <= AIPrompts.maxInputChars else {
      return .refused("The query is too long to apply: the review saw only its start.")
    }
    let current: String
    if let cellId = request.cellId {
      guard let cell = notebook.cells.first(where: { $0.id == cellId }) else {
        return .refused("The cell this query came from no longer exists.")
      }
      current = cell.content
    } else {
      current = editorTextView?.string ?? editorContent
    }
    let target: Range<String.Index>
    if let selection = request.selection {
      guard let range = Range(selection, in: current), current[range] == request.sourceSQL else {
        return .refused("The query changed since the review. Run the review again.")
      }
      target = range
    } else {
      guard current == request.sourceSQL else {
        return .refused("The query changed since the review. Run the review again.")
      }
      target = current.startIndex..<current.endIndex
    }

    if let cellId = request.cellId {
      setAICellContent(id: cellId, to: current.replacingCharacters(in: target, with: sql))
    } else if let textView = editorTextView, let textStorage = textView.textStorage {
      let range = NSRange(target, in: current)
      textView.setProgrammaticEditFlag(true)
      defer { textView.setProgrammaticEditFlag(false) }
      guard textView.shouldChangeText(in: range, replacementString: sql) else {
        return .refused("The editor did not accept the change.")
      }
      textStorage.replaceCharacters(in: range, with: sql)
      textView.didChangeText()
      textView.window?.makeFirstResponder(textView)
    } else {
      // No text view (not shown): nothing to undo through
      editorContent = current.replacingCharacters(in: target, with: sql)
    }
    return .applied
  }

  /// Sets a cell's text on the undo stack; undo runs this again, so redo comes with it. Typing
  /// after Apply goes to the text view's own stack, so undo and redo act only while the cell
  /// still holds the text this step set, and are dropped otherwise (the typing is kept).
  private func setAICellContent(id: UUID, to content: String) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    let previous = notebook.cells[index].content
    notebook.cells[index].content = content
    undoManager.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        guard target.notebook.cells.first(where: { $0.id == id })?.content == content else {
          return
        }
        target.setAICellContent(id: id, to: previous)
      }
    }
    undoManager.setActionName("Apply AI Suggestion")
    onDocumentChanged?()
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
