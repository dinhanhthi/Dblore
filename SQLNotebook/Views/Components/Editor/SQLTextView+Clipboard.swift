//
//  SQLTextView+Clipboard.swift
//  SQLNotebook
//
//  Copy/Paste handling with smart line operations for SQL text view
//

import AppKit

// MARK: - Clipboard Extension

extension SQLTextView {

  /// Copy current line (if no selection) or selected text
  func copyLine() {
    print("DEBUG: copyLine() called")
    guard let textStorage = textStorage else {
      print("DEBUG: textStorage is nil")
      return
    }
    let text = textStorage.string as NSString
    let selectedRange = selectedRange()
    print("DEBUG: selectedRange: \(selectedRange)")

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    // If there's a selection, copy selected text (no line copy marker)
    if selectedRange.length > 0 {
      let selectedText = text.substring(with: selectedRange)
      print("DEBUG: Copying selection: '\(selectedText)'")
      pasteboard.setString(selectedText, forType: .string)
      return
    }

    // No selection -> copy the entire line
    let lineRange = text.lineRange(for: selectedRange)
    let lineText = text.substring(with: lineRange)
    print("DEBUG: Copying line: '\(lineText)'")

    // Copy to pasteboard
    pasteboard.setString(lineText, forType: .string)

    // Store metadata to indicate this is a line copy (for smart paste behavior)
    pasteboard.setString("line", forType: Self.lineCopyType)
    print("DEBUG: Line copy marker set")
  }

  /// Paste text with smart line handling
  func pasteLine() {
    let pasteboard = NSPasteboard.general
    guard let pasteText = pasteboard.string(forType: .string) else { return }
    guard let textStorage = textStorage else { return }

    // Set flag to prevent autocomplete from showing during paste
    setProgrammaticEditFlag(true)
    defer { setProgrammaticEditFlag(false) }

    let selectedRange = selectedRange()
    let text = textStorage.string as NSString

    // Check if this was a line copy
    let isLineCopy = pasteboard.string(forType: Self.lineCopyType) == "line"

    // If there's a selection, replace it with pasted text
    if selectedRange.length > 0 {
      if shouldChangeText(in: selectedRange, replacementString: pasteText) {
        textStorage.replaceCharacters(in: selectedRange, with: pasteText)
        didChangeText()

        // Position cursor at end of pasted text
        let newCursorPosition = selectedRange.location + (pasteText as NSString).length
        setSelectedRange(NSRange(location: newCursorPosition, length: 0))
      }
      return
    }

    // No selection -> smart line paste
    if isLineCopy {
      pasteLineSmartly(text: text, selectedRange: selectedRange, pasteText: pasteText)
    } else {
      // Regular paste (not a line copy) -> paste at cursor position
      pasteAtCursor(selectedRange: selectedRange, pasteText: pasteText)
    }
  }

  /// Smart line paste - handles empty and non-empty lines differently
  private func pasteLineSmartly(text: NSString, selectedRange: NSRange, pasteText: String) {
    guard let textStorage = textStorage else { return }

    // Get the current line range
    let lineRange = text.lineRange(for: selectedRange)
    let lineText = text.substring(with: lineRange)
    let isEmptyLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if isEmptyLine {
      // Empty line -> paste at current position (replace the line)
      if shouldChangeText(in: lineRange, replacementString: pasteText) {
        textStorage.replaceCharacters(in: lineRange, with: pasteText)
        didChangeText()

        // Position cursor at end of pasted text (before final newline if exists)
        let pasteLength = (pasteText as NSString).length
        let cursorOffset = pasteText.hasSuffix("\n") ? pasteLength - 1 : pasteLength
        let newCursorPosition = lineRange.location + cursorOffset
        setSelectedRange(NSRange(location: newCursorPosition, length: 0))
      }
    } else {
      // Non-empty line -> insert new line below (regardless of cursor position on the line)
      pasteAsBelowLine(text: text, lineRange: lineRange, pasteText: pasteText)
    }
  }

  /// Paste as a new line below the current line
  private func pasteAsBelowLine(text: NSString, lineRange: NSRange, pasteText: String) {
    guard let textStorage = textStorage else { return }

    let lineEnd = lineRange.location + lineRange.length

    // Check if current line ends with newline
    let currentLineEndsWithNewline =
      lineEnd > 0 && lineEnd <= text.length
      && text.substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"

    // Build text to insert:
    // 1. Start with newline if current line doesn't have one
    // 2. Add pasted content (without trailing newline if it has one)
    // 3. End with newline to position cursor on empty line below
    var textToInsert = ""

    // Step 1: Add leading newline if needed
    if !currentLineEndsWithNewline {
      textToInsert = "\n"
    }

    // Step 2: Add pasted content (clean up trailing newline first)
    var cleanPasteText = pasteText
    if cleanPasteText.hasSuffix("\n") {
      cleanPasteText = String(cleanPasteText.dropLast())
    }
    textToInsert += cleanPasteText

    // Step 3: Add trailing newline for cursor position
    textToInsert += "\n"

    let insertRange = NSRange(location: lineEnd, length: 0)
    if shouldChangeText(in: insertRange, replacementString: textToInsert) {
      textStorage.replaceCharacters(in: insertRange, with: textToInsert)
      didChangeText()

      // Position cursor at the end of the pasted line (before the trailing newline)
      // Calculate: lineEnd + leading newline (if added) + cleaned paste text length
      let leadingNewlineLength = currentLineEndsWithNewline ? 0 : 1
      let pastedTextLength = (cleanPasteText as NSString).length
      let newCursorPosition = lineEnd + leadingNewlineLength + pastedTextLength
      setSelectedRange(NSRange(location: newCursorPosition, length: 0))
    }
  }

  /// Regular paste at cursor position
  private func pasteAtCursor(selectedRange: NSRange, pasteText: String) {
    guard let textStorage = textStorage else { return }

    let cursorPosition = selectedRange.location
    let insertRange = NSRange(location: cursorPosition, length: 0)

    if shouldChangeText(in: insertRange, replacementString: pasteText) {
      textStorage.replaceCharacters(in: insertRange, with: pasteText)
      didChangeText()

      // Position cursor at end of pasted text
      let newCursorPosition = cursorPosition + (pasteText as NSString).length
      setSelectedRange(NSRange(location: newCursorPosition, length: 0))
    }
  }
}
