//
//  SQLTextView+Formatting.swift
//  Dblore
//
//  SQL formatting for the SQL text view
//

import AppKit

// MARK: - Formatting Extension

extension SQLTextView {

  /// Format SQL applies to SQL dialects only; mongosh and Redis text is not SQL
  nonisolated static func canFormat(dialect: SQLDialect) -> Bool {
    dialect.language == .sql
  }

  /// Replace the whole text with its formatted version (undoable). When the formatter refuses,
  /// a toast says why; already formatted text changes nothing and shows nothing.
  func formatDocument() {
    guard Self.canFormat(dialect: dialect), let textStorage = textStorage else { return }
    let options = AppSettings.shared.formatterOptions
    let outcome = SQLFormatter.formatOutcome(textStorage.string, dialect: dialect, options: options)
    if let refusal = outcome.refusal {
      WorkspaceWindowManager.shared.showToast(
        "Format left the text unchanged: \(refusal.message)", type: .warning)
      return
    }
    replaceDocument(with: outcome.text)
  }

  /// Replace the whole text with `newText` (undoable), as a format does
  func replaceDocument(with newText: String) {
    guard let textStorage = textStorage, newText != textStorage.string else { return }

    let caret = selectedRange().location
    let fullRange = NSRange(location: 0, length: textStorage.length)

    // Set flag to prevent autocomplete from showing during formatting
    setProgrammaticEditFlag(true)
    defer { setProgrammaticEditFlag(false) }

    if shouldChangeText(in: fullRange, replacementString: newText) {
      textStorage.replaceCharacters(in: fullRange, with: newText)
      didChangeText()
      // Keep the caret near where it was
      let location = min(caret, (newText as NSString).length)
      setSelectedRange(NSRange(location: location, length: 0))
    }
  }
}
