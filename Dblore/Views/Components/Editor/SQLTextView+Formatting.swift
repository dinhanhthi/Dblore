//
//  SQLTextView+Formatting.swift
//  Dblore
//
//  SQL formatting for the SQL text view
//

import AppKit

// MARK: - Formatting Extension

extension SQLTextView {

  /// Replace the whole text with its formatted version (undoable)
  func formatDocument() {
    guard let textStorage = textStorage else { return }

    let caret = selectedRange().location
    let fullRange = NSRange(location: 0, length: textStorage.length)
    let newText = SQLFormatter.format(textStorage.string, dialect: dialect)
    guard newText != textStorage.string else { return }

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
