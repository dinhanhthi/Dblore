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
  var isEditorMode: Bool = false  // True when used in Editor mode (IDE-like arrow behavior)

  // Autocomplete state
  private var autocompleteSuggestions: [AutocompleteSuggestion] = []
  private var autocompleteSelectedIndex: Int = 0
  private var autocompletePopover: NSPopover?
  private var isAcceptingSuggestion = false  // Flag to prevent retriggering autocomplete
  private var isProgrammaticEdit = false  // Flag to prevent autocomplete during programmatic edits

  // Custom pasteboard type for line copy metadata
  private static let lineCopyType = NSPasteboard.PasteboardType("com.sqlnotebook.copy-type")

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
    if handleWordWrapShortcut(with: event) {
      return  // Handled, don't pass to super
    }
    if handleArrowNavigation(with: event) {
      return  // Handled, don't pass to super
    }
    super.keyDown(with: event)
  }

  override func didChangeText() {
    super.didChangeText()
    // Skip autocomplete update if we're accepting a suggestion or doing programmatic edits
    guard !isAcceptingSuggestion && !isProgrammaticEdit else { return }
    // Update autocomplete suggestions when text changes
    updateAutocompleteSuggestions()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleCellShortcut(with: event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  // MARK: - Copy/Paste overrides

  @objc override func copy(_ sender: Any?) {
    print("DEBUG: copy() called, sender: \(String(describing: sender))")
    copyLine()
  }

  override func writeSelection(
    to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
  ) -> Bool {
    print("DEBUG: writeSelection(to:types:) called")

    // Manually handle copy through our copyLine logic
    copyLine()

    // Return true to indicate we handled it
    return true
  }

  @objc override func paste(_ sender: Any?) {
    print("DEBUG: paste() called, sender: \(String(describing: sender))")
    pasteLine()
  }

  nonisolated override func responds(to aSelector: Selector!) -> Bool {
    if aSelector == #selector(copy(_:)) || aSelector == #selector(paste(_:)) {
      print("DEBUG: responds(to:) called for \(aSelector!)")
      return true
    }
    return super.responds(to: aSelector)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) {
      print("DEBUG: validateUserInterfaceItem for copy:")
      return true
    }
    if item.action == #selector(paste(_:)) {
      print("DEBUG: validateUserInterfaceItem for paste:")
      return NSPasteboard.general.string(forType: .string) != nil
    }
    return super.validateUserInterfaceItem(item)
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

  /// Handles up/down arrow navigation between cells (notebook mode) or line boundaries (editor mode)
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
      // Check if cursor is at the first line (no newline before cursor)
      let textBeforeCursor = text.prefix(cursorPosition)
      if !textBeforeCursor.contains("\n") {
        // We're on the first line
        if isEditorMode {
          // Editor mode: Move cursor to beginning of line (IDE-like behavior)
          setSelectedRange(NSRange(location: 0, length: 0))
          return true
        } else {
          // Notebook mode: Navigate to previous cell
          NotificationCenter.default.post(name: .selectPreviousCell, object: nil)
          return true
        }
      }
    } else if isDownArrow {
      // Check if cursor is at the last line (no newline after cursor)
      let textAfterCursor = text.suffix(text.count - cursorPosition)
      if !textAfterCursor.contains("\n") {
        // We're on the last line
        if isEditorMode {
          // Editor mode: Move cursor to end of line (IDE-like behavior)
          setSelectedRange(NSRange(location: text.count, length: 0))
          return true
        } else {
          // Notebook mode: Navigate to next cell
          NotificationCenter.default.post(name: .selectNextCell, object: nil)
          return true
        }
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

  /// Handle Option+Z shortcut for toggle word wrap
  /// Returns true if the event was handled
  private func handleWordWrapShortcut(with event: NSEvent) -> Bool {
    // Check for Option+Z (keyCode 6 is the "Z" key)
    let isZ = event.keyCode == 6
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasOption = flags.contains(.option)
    let hasNoOtherModifiers =
      !flags.contains(.shift) && !flags.contains(.control) && !flags.contains(.command)

    if isZ && hasOption && hasNoOtherModifiers {
      // Toggle word wrap setting
      Task { @MainActor in
        AppSettings.shared.wordWrapEnabled.toggle()
      }
      return true
    }

    return false
  }

  /// Copy current line (if no selection) or selected text
  private func copyLine() {
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
  private func pasteLine() {
    let pasteboard = NSPasteboard.general
    guard let pasteText = pasteboard.string(forType: .string) else { return }
    guard let textStorage = textStorage else { return }

    // Set flag to prevent autocomplete from showing during paste
    isProgrammaticEdit = true
    defer { isProgrammaticEdit = false }

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
    } else {
      // Regular paste (not a line copy) -> paste at cursor position
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

  /// Toggle SQL comment (--) for selected lines
  private func toggleComment() {
    guard let textStorage = textStorage else { return }

    // Set flag to prevent autocomplete from showing during comment toggle
    isProgrammaticEdit = true
    defer { isProgrammaticEdit = false }

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
    // Check if autocomplete is enabled in settings
    Task { @MainActor in
      let isEnabled = AppSettings.shared.isAutoCompleteEnabled
      guard isEnabled else {
        hideAutocomplete()
        return
      }

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
        onSelect: { [weak self] suggestion in
          self?.acceptSuggestion(suggestion)
        }
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
      onSelect: { [weak self] suggestion in
        self?.acceptSuggestion(suggestion)
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
    acceptSuggestion(suggestion)
  }

  /// Accept a specific suggestion (used for both keyboard and mouse selection)
  private func acceptSuggestion(_ suggestion: AutocompleteSuggestion) {
    // Set flag to prevent autocomplete from retriggering during text insertion
    isAcceptingSuggestion = true
    
    // Find the token being completed
    let cursorPosition = selectedRange().location

    // Replace token with suggestion
    if let tokenRange = findTokenRange(in: string, at: cursorPosition) {
      setSelectedRange(tokenRange)
      insertText(suggestion.text, replacementRange: tokenRange)
    }

    // Hide autocomplete after accepting
    hideAutocomplete()
    
    // Reset flag after a short delay to allow text insertion to complete
    DispatchQueue.main.async { [weak self] in
      self?.isAcceptingSuggestion = false
    }
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
      onSelect: { [weak self] suggestion in
        self?.acceptSuggestion(suggestion)
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
