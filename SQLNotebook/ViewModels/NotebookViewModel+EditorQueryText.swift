//
//  NotebookViewModel+EditorQueryText.swift
//  SQLNotebook
//
//  The SQL an editor run executes: the selection, the whole content, or (Simple Mode) the line
//  at the cursor.
//

import AppKit
import Foundation

extension NotebookViewModel {
  /// Get selected text from editor, or content based on Simple Mode setting
  /// - Simple Mode OFF: Return entire content if no selection
  /// - Simple Mode ON: Return query at cursor position if no selection
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

    // No selection - behavior depends on Simple Mode setting
    if AppSettings.shared.editorSimpleMode {
      // Simple Mode: Return query at cursor position
      return getQueryAtCursor()
    } else {
      // Normal Mode: Return entire content
      return editorContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// Get the SQL query(ies) on the current line where cursor is positioned
  /// Returns the content of the current line (may contain multiple statements)
  /// Returns nil if the line is empty or contains only comments/whitespace
  func getQueryAtCursor() -> String? {
    guard let textView = editorTextView,
      let textStorage = textView.textStorage
    else {
      return nil
    }

    let fullText = textStorage.string
    guard !fullText.isEmpty else { return nil }

    let cursorPosition = textView.selectedRange().location
    guard cursorPosition <= fullText.count else { return nil }

    // Get the line range containing the cursor
    let nsString = fullText as NSString
    let lineRange = nsString.lineRange(for: NSRange(location: cursorPosition, length: 0))
    let lineContent = nsString.substring(with: lineRange)

    // Trim and check if line has executable content (not just comments/whitespace)
    let trimmed = lineContent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Check if the line contains only comments
    if connectionManager?.isCommentOnlyStatement(trimmed) == true {
      return nil
    }

    return trimmed
  }
}
