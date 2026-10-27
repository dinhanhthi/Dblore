//
//  SQLTextView+Formatting.swift
//  Dblore
//
//  SQL formatting for the SQL text view
//

import AppKit

// MARK: - Formatting Extension

extension SQLTextView {

  /// Format SQL applies to SQL dialects only; mongosh cells are not SQL
  nonisolated static func canFormat(dialect: SQLDialect) -> Bool {
    dialect != .mongodb
  }

  /// Replace the whole text with its formatted version (undoable)
  func formatDocument() {
    guard Self.canFormat(dialect: dialect), let textStorage = textStorage else { return }
    let options = AppSettings.shared.formatterOptions
    replaceDocument(
      with: SQLFormatter.format(textStorage.string, dialect: dialect, options: options))
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
