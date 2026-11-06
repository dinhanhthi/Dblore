//
//  NotebookViewModel+LineBookmarks.swift
//  Dblore
//
//  Line bookmarks of a SQL editor tab: toggle, next / previous, edits moving them, and their
//  saved form in the workspace tab entry.
//

import AppKit
import Foundation

extension NotebookViewModel {
  /// Only a SQL editor tab takes bookmarks: not a notebook, note, data viewer or object source
  var acceptsLineBookmarks: Bool {
    viewMode == .editor && dataViewer == nil && !isReadOnlySource
  }

  /// The saved form for the workspace tab entry (nil without bookmarks)
  var savedLineBookmarks: [LineBookmarks.Entry]? {
    guard acceptsLineBookmarks, !lineBookmarks.isEmpty else { return nil }
    return lineBookmarks.entries(in: editorContent)
  }

  /// Places saved bookmarks on the tab's loaded text (`editorContent`), each on the line its
  /// anchor matches. Not a user change: nothing is saved.
  func restoreLineBookmarks(_ entries: [LineBookmarks.Entry]?) {
    lineBookmarks = LineBookmarks(restoring: entries ?? [], in: editorContent)
  }

  /// Replaces the text from outside the editor (a reload from disk), keeping each bookmark on
  /// its line's text
  func replaceEditorContentKeepingBookmarks(_ content: String) {
    let entries = lineBookmarks.entries(in: editorContent)
    editorContent = content
    guard !entries.isEmpty else { return }
    let restored = LineBookmarks(restoring: entries, in: content)
    guard restored != lineBookmarks else { return }
    lineBookmarks = restored
    onLineBookmarksChanged?()
  }

  func toggleLineBookmark(line: Int) {
    guard acceptsLineBookmarks else { return }
    lineBookmarks.toggle(line: line)
    onLineBookmarksChanged?()
  }

  /// Toggle Bookmark: the caret's line (nothing without this tab's editor)
  func toggleLineBookmarkAtCaret() {
    guard acceptsLineBookmarks, let line = caretLine else { return }
    toggleLineBookmark(line: line)
  }

  /// Next Bookmark: moves the caret to the next marked line, wrapping to the first
  func goToNextLineBookmark() {
    guard acceptsLineBookmarks, let line = lineBookmarks.next(after: caretLine ?? 0) else { return }
    moveCaret(toLine: line)
  }

  /// Previous Bookmark: moves the caret to the previous marked line, wrapping to the last
  func goToPreviousLineBookmark() {
    guard acceptsLineBookmarks,
      let line = lineBookmarks.previous(before: caretLine ?? Int.max)
    else { return }
    moveCaret(toLine: line)
  }

  /// An edit the editor is about to make: `range` of `text` (still the old text) becomes
  /// `replacement`
  func applyLineBookmarkEdit(replacing range: NSRange, in text: NSString, with replacement: String)
  {
    guard !lineBookmarks.isEmpty else { return }
    let before = lineBookmarks
    lineBookmarks.applyEdit(replacing: range, in: text, with: replacement)
    if lineBookmarks != before { onLineBookmarksChanged?() }
  }

  /// The editor showing this tab's text (nil while it shows another text)
  private var lineBookmarkTextView: SQLTextView? {
    guard let textView = editorTextView, textView.string == editorContent else { return nil }
    return textView
  }

  /// 1-based line of the caret (nil without this tab's editor)
  private var caretLine: Int? {
    guard let textView = lineBookmarkTextView else { return nil }
    return LineBookmarks.line(
      at: textView.selectedRange().location, in: textView.string as NSString)
  }

  private func moveCaret(toLine line: Int) {
    guard let textView = lineBookmarkTextView,
      let offset = LineBookmarks.startOffset(ofLine: line, in: textView.string as NSString)
    else { return }
    let caret = NSRange(location: offset, length: 0)
    textView.setSelectedRange(caret)
    textView.scrollRangeToVisible(caret)
    textView.window?.makeFirstResponder(textView)
  }
}
