//
//  SQLTextView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

// MARK: - SQL Text View (handles keyboard shortcuts)

class SQLTextView: NSTextView {
  var onFocus: (() -> Void)?
  var onBlur: ((String) -> Void)?  // Callback with current text when losing focus
  var autocompleteProvider: SQLAutocompleteProvider?

  // Autocomplete state
  private var autocompleteSuggestions: [AutocompleteSuggestion] = []
  private var autocompleteSelectedIndex: Int = 0
  private var autocompletePopover: NSPopover?

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      onFocus?()
      // Notify that this editor is now focused
      NotificationCenter.default.post(name: .editorFocused, object: self)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    // Capture the string before calling super to avoid accessing potentially deallocated state
    let currentText = string
    let result = super.resignFirstResponder()
    if result {
      // Update binding when losing focus
      onBlur?(currentText)
      // Notify that this editor is no longer focused
      NotificationCenter.default.post(name: .editorUnfocused, object: self)
      // Hide autocomplete
      hideAutocomplete()
    }
    return result
  }

  override func keyDown(with event: NSEvent) {
    // Check autocomplete navigation first (if popup is visible)
    if !autocompleteSuggestions.isEmpty, handleAutocompleteNavigation(with: event) {
      return  // Handled, don't pass to super
    }

    if handleCellShortcut(with: event) {
      return  // Handled, don't pass to super
    }
    if handleCommentShortcut(with: event) {
      return  // Handled, don't pass to super
    }
    if handleArrowNavigation(with: event) {
      return  // Handled, don't pass to super
    }
    super.keyDown(with: event)
  }

  override func didChangeText() {
    super.didChangeText()
    // Update autocomplete suggestions when text changes
    updateAutocompleteSuggestions()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleCellShortcut(with: event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Returns true if the event was handled as a cell shortcut
  private func handleCellShortcut(with event: NSEvent) -> Bool {
    let isEnter = event.keyCode == 36
    guard isEnter else { return false }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasControl = flags.contains(.control)
    let hasShift = flags.contains(.shift)
    let hasOption = flags.contains(.option)
    let hasCommand = flags.contains(.command)

    // Cmd+Shift+Enter -> Run All Cells
    if hasCommand && hasShift && !hasControl && !hasOption {
      NotificationCenter.default.post(name: .runAllCells, object: nil)
      return true
    }

    // Ctrl+Enter -> Run current cell (stay on current cell)
    if hasControl && !hasShift && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCell, object: nil)
      return true
    }

    // Shift+Enter -> Run cell and move to next (create new if last)
    if hasShift && !hasControl && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndSelectNext, object: nil)
      return true
    }

    // Alt/Option+Enter -> Run cell and insert new cell below
    if hasOption && !hasControl && !hasShift && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndInsertBelow, object: nil)
      return true
    }

    return false
  }

  /// Handles up/down arrow navigation between cells
  /// Returns true if the event was handled as a navigation action
  private func handleArrowNavigation(with event: NSEvent) -> Bool {
    let isUpArrow = event.keyCode == 126
    let isDownArrow = event.keyCode == 125

    guard isUpArrow || isDownArrow else { return false }

    // Check for actual modifier keys (Cmd, Ctrl, Alt, Shift) - ignore function key flag
    let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

    if hasModifiers {
      return false
    }

    let text = string
    let cursorPosition = selectedRange().location

    if isUpArrow {
      // Navigate to previous cell only if cursor is at the first line
      // Check if there's a newline before the cursor position
      let textBeforeCursor = text.prefix(cursorPosition)
      if !textBeforeCursor.contains("\n") {
        // No newline before cursor, we're on the first line
        NotificationCenter.default.post(name: .selectPreviousCell, object: nil)
        return true
      }
    } else if isDownArrow {
      // Navigate to next cell only if cursor is at the last line
      // Check if there's a newline after the cursor position
      let textAfterCursor = text.suffix(text.count - cursorPosition)
      if !textAfterCursor.contains("\n") {
        // No newline after cursor, we're on the last line
        NotificationCenter.default.post(name: .selectNextCell, object: nil)
        return true
      }
    }

    return false
  }

  /// Handle Cmd+/ shortcut for comment/uncomment
  /// Returns true if the event was handled
  private func handleCommentShortcut(with event: NSEvent) -> Bool {
    // Check for Cmd+/ (keyCode 44 is the "/" key)
    let isSlash = event.keyCode == 44
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasCommand = flags.contains(.command)
    let hasNoOtherModifiers =
      !flags.contains(.shift) && !flags.contains(.control) && !flags.contains(.option)

    if isSlash && hasCommand && hasNoOtherModifiers {
      toggleComment()
      return true
    }

    return false
  }

  /// Toggle SQL comment (--) for selected lines
  private func toggleComment() {
    guard let textStorage = textStorage else { return }

    let selectedRange = selectedRange()
    let text = textStorage.string as NSString

    // Find the line range containing the selection
    let lineRange = text.lineRange(for: selectedRange)

    // Get the selected text (full lines)
    let selectedText = text.substring(with: lineRange)

    // Split into lines
    let lines = selectedText.components(separatedBy: .newlines)

    // Determine if we should comment or uncomment
    // If ALL non-empty lines start with "--", we uncomment; otherwise we comment
    let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let shouldUncomment =
      !nonEmptyLines.isEmpty
      && nonEmptyLines.allSatisfy { line in
        line.trimmingCharacters(in: .whitespaces).hasPrefix("--")
      }

    // Process each line
    var newLines: [String] = []
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Skip empty lines
      if trimmed.isEmpty {
        newLines.append(line)
        continue
      }

      if shouldUncomment {
        // Remove "-- " or "--" from the start
        if let range = line.range(of: "--") {
          var uncommented = line
          // Remove "-- " (with space) if present, otherwise just "--"
          if line[range.upperBound...].hasPrefix(" ") {
            let endIndex = line.index(range.upperBound, offsetBy: 1)
            uncommented.removeSubrange(range.lowerBound..<endIndex)
          } else {
            uncommented.removeSubrange(range)
          }
          newLines.append(uncommented)
        } else {
          newLines.append(line)
        }
      } else {
        // Add "-- " at the beginning
        newLines.append("-- " + line)
      }
    }

    // Join lines back together
    let newText = newLines.joined(separator: "\n")

    // Replace the text
    if shouldChangeText(in: lineRange, replacementString: newText) {
      textStorage.replaceCharacters(in: lineRange, with: newText)
      didChangeText()

      // Restore selection (adjust for text length change)
      let lengthDelta = (newText as NSString).length - lineRange.length
      let newSelectedRange = NSRange(
        location: selectedRange.location,
        length: selectedRange.length + lengthDelta
      )
      setSelectedRange(newSelectedRange)
    }
  }

  // MARK: - Autocomplete Methods

  /// Update autocomplete suggestions based on current cursor position
  private func updateAutocompleteSuggestions() {
    guard let provider = autocompleteProvider else {
      hideAutocomplete()
      return
    }

    // Early check: if text is empty, hide autocomplete
    if string.isEmpty {
      hideAutocomplete()
      return
    }

    let cursorPosition = selectedRange().location
    let suggestions = provider.getSuggestions(for: string, at: cursorPosition)

    if suggestions.isEmpty {
      hideAutocomplete()
    } else {
      autocompleteSuggestions = suggestions
      autocompleteSelectedIndex = 0

      // Show NSPopover at cursor position
      showAutocompletePopover()
    }
  }

  /// Hide autocomplete popup
  private func hideAutocomplete() {
    autocompleteSuggestions = []
    autocompleteSelectedIndex = 0
    autocompletePopover?.close()
    autocompletePopover = nil
  }

  /// Show NSPopover with autocomplete suggestions at cursor position
  private func showAutocompletePopover() {
    guard !autocompleteSuggestions.isEmpty else { return }
    guard let layoutManager = self.layoutManager,
      let textContainer = self.textContainer
    else { return }

    // Get cursor position
    let cursorPosition = selectedRange().location

    // IMPORTANT: Force layout manager to update layout for current text
    // Without this, glyph rects may be stale after text changes
    layoutManager.ensureLayout(for: textContainer)

    // Get rect for cursor in text view's local coordinate system
    var localRect: CGRect

    if cursorPosition == 0 || string.isEmpty {
      // Special case: cursor at start of text or empty text
      localRect = CGRect(
        x: textContainerInset.width, y: textContainerInset.height, width: 1, height: 20)
    } else {
      // Get the glyph index for the character BEFORE cursor (to position popup after typed text)
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, cursorPosition - 1))

      // Get bounding rect for the glyph in text container coordinates
      let glyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        in: textContainer
      )

      // Position popup at the END of the character (right side)
      localRect = CGRect(
        x: glyphRect.maxX + textContainerInset.width,
        y: glyphRect.origin.y + textContainerInset.height,
        width: 1,  // Thin cursor line
        height: glyphRect.height > 0 ? glyphRect.height : 20  // Use line height or default
      )
    }

    // If popover is already shown, just update position (more efficient)
    if let popover = autocompletePopover, popover.isShown {
      // Update content first
      let contentView = AutocompletePopupView(
        suggestions: Array(autocompleteSuggestions.prefix(20)),
        selectedIndex: autocompleteSelectedIndex,
        onSelect: { _ in }
      )
      let hostingController = NSHostingController(rootView: contentView)
      hostingController.view.wantsLayer = true

      let itemHeight: CGFloat = 28
      let maxHeight: CGFloat = 400
      let calculatedHeight = min(CGFloat(autocompleteSuggestions.count) * itemHeight + 4, maxHeight)
      hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

      popover.contentViewController = hostingController

      // Reposition popover
      popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
      return
    }

    // Create new popover
    let popover = NSPopover()
    popover.behavior = .semitransient
    autocompletePopover = popover

    // Create SwiftUI content view with suggestions
    let contentView = AutocompletePopupView(
      suggestions: Array(autocompleteSuggestions.prefix(20)),  // Limit to 20 items
      selectedIndex: autocompleteSelectedIndex,
      onSelect: { _ in
        // Selection handled by keyboard events
      }
    )

    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.wantsLayer = true

    // Calculate size based on number of suggestions
    let itemHeight: CGFloat = 28
    let maxHeight: CGFloat = 400
    let calculatedHeight = min(CGFloat(autocompleteSuggestions.count) * itemHeight + 4, maxHeight)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

    popover.contentViewController = hostingController

    // Show popover below cursor
    popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
  }

  /// Handle keyboard navigation in autocomplete popup
  /// Returns true if the event was handled
  private func handleAutocompleteNavigation(with event: NSEvent) -> Bool {
    let isUpArrow = event.keyCode == 126
    let isDownArrow = event.keyCode == 125
    let isTab = event.keyCode == 48
    let isEnter = event.keyCode == 36
    let isEscape = event.keyCode == 53

    // Check for modifiers
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasModifiers =
      flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
      || flags.contains(.shift)

    // Escape -> hide autocomplete
    if isEscape {
      hideAutocomplete()
      return true
    }

    // Tab or Enter (without modifiers) -> accept selected suggestion
    if (isTab || isEnter) && !hasModifiers {
      acceptSelectedSuggestion()
      return true
    }

    // Up arrow -> select previous suggestion (with circular navigation)
    if isUpArrow && !hasModifiers {
      if autocompleteSelectedIndex == 0 {
        // Wrap around to last item
        autocompleteSelectedIndex = autocompleteSuggestions.count - 1
      } else {
        autocompleteSelectedIndex -= 1
      }
      // Update popover to show new selection
      updatePopoverSelection()
      return true
    }

    // Down arrow -> select next suggestion (with circular navigation)
    if isDownArrow && !hasModifiers {
      if autocompleteSelectedIndex == autocompleteSuggestions.count - 1 {
        // Wrap around to first item
        autocompleteSelectedIndex = 0
      } else {
        autocompleteSelectedIndex += 1
      }
      // Update popover to show new selection
      updatePopoverSelection()
      return true
    }

    return false
  }

  /// Accept the currently selected suggestion
  private func acceptSelectedSuggestion() {
    guard
      autocompleteSelectedIndex >= 0 && autocompleteSelectedIndex < autocompleteSuggestions.count
    else {
      hideAutocomplete()
      return
    }

    let suggestion = autocompleteSuggestions[autocompleteSelectedIndex]

    // Find the token being completed
    let cursorPosition = selectedRange().location

    // Replace token with suggestion
    if let tokenRange = findTokenRange(in: string, at: cursorPosition) {
      setSelectedRange(tokenRange)
      insertText(suggestion.text, replacementRange: tokenRange)
    }

    // Hide autocomplete after accepting
    hideAutocomplete()
  }

  /// Extract the current token being typed at cursor position
  private func extractCurrentToken(from text: String, at position: Int) -> String {
    guard position > 0, position <= text.count else { return "" }

    let beforeCursor = String(text.prefix(position))
    let afterCursor = String(text.suffix(text.count - position))

    // Find start of token (word boundary) - search backwards in beforeCursor
    var tokenStart = 0
    for (index, char) in beforeCursor.enumerated().reversed() {
      if char.isWhitespace || "(),;".contains(char) {
        tokenStart = index + 1
        break
      }
    }

    // Find end of token in afterCursor
    var tokenEndInAfter = afterCursor.count
    for (index, char) in afterCursor.enumerated() {
      if char.isWhitespace || "(),;".contains(char) {
        tokenEndInAfter = index
        break
      }
    }

    let tokenInBefore = String(beforeCursor.suffix(beforeCursor.count - tokenStart))
    let tokenInAfter = String(afterCursor.prefix(tokenEndInAfter))

    let token = tokenInBefore + tokenInAfter
    return token.trimmingCharacters(in: CharacterSet.whitespaces)
  }

  /// Find the NSRange of the current token at cursor position
  private func findTokenRange(in text: String, at position: Int) -> NSRange? {
    guard position > 0, position <= text.count else { return nil }

    let nsText = text as NSString
    let beforeCursor = String(text.prefix(position))

    // Find start of token - search backwards
    var tokenStart = 0
    for (index, char) in beforeCursor.enumerated().reversed() {
      if char.isWhitespace || "(),;".contains(char) {
        tokenStart = index + 1
        break
      }
    }

    // Find end of token - search forwards from tokenStart
    var tokenEnd = position
    for index in position..<nsText.length {
      let char = Character(UnicodeScalar(nsText.character(at: index))!)
      if char.isWhitespace || "(),;".contains(char) {
        tokenEnd = index
        break
      }
      tokenEnd = index + 1
    }

    return NSRange(location: tokenStart, length: tokenEnd - tokenStart)
  }

  /// Update NSPopover content to reflect new selection
  private func updatePopoverSelection() {
    guard let popover = autocompletePopover,
      popover.isShown,
      !autocompleteSuggestions.isEmpty
    else { return }

    // Create new content view with updated selection
    let contentView = AutocompletePopupView(
      suggestions: Array(autocompleteSuggestions.prefix(20)),
      selectedIndex: autocompleteSelectedIndex,
      onSelect: { _ in
        // Selection handled by keyboard events
      }
    )

    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.wantsLayer = true

    // Keep same size
    let itemHeight: CGFloat = 28
    let maxHeight: CGFloat = 400
    let calculatedHeight = min(CGFloat(autocompleteSuggestions.count) * itemHeight + 4, maxHeight)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

    popover.contentViewController = hostingController
  }
}
