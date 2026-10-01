//
//  SQLTextView+Autocomplete.swift
//  Dblore
//
//  Autocomplete system for SQL text view
//

import AppKit
import SwiftUI

// MARK: - Autocomplete Extension

extension SQLTextView {

  /// Update autocomplete suggestions based on current cursor position (debounced)
  func updateAutocompleteSuggestions() {
    autocompleteTask?.cancel()
    autocompleteTask = nil

    // Empty text: hide right away, no delay
    if string.isEmpty {
      hideAutocomplete()
      return
    }

    autocompleteTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.autocompleteDebounce)
      guard !Task.isCancelled, let self else { return }
      self.computeAutocompleteSuggestions()
    }
  }

  private func computeAutocompleteSuggestions() {
    // The debounce gap may have overlapped an accept/format/paste: stay quiet
    guard !isAutocompleteSuppressed else { return }

    // Check if autocomplete is enabled in settings
    guard AppSettings.shared.isAutoCompleteEnabled else {
      hideAutocomplete()
      return
    }

    guard let provider = autocompleteProvider else {
      hideAutocomplete()
      return
    }

    if string.isEmpty {
      hideAutocomplete()
      return
    }

    let cursorPosition = selectedRange().location
    let suggestions = provider.getSuggestions(for: string, at: cursorPosition, dialect: dialect)

    if suggestions.isEmpty {
      hideAutocomplete()
    } else {
      setAutocompleteSuggestions(suggestions)
      setAutocompleteSelectedIndex(0)

      // Show NSPopover at cursor position
      showAutocompletePopover()
    }
  }

  /// Hide autocomplete popup and cancel any pending computation
  func hideAutocomplete() {
    autocompleteTask?.cancel()
    autocompleteTask = nil
    setAutocompleteSuggestions([])
    setAutocompleteSelectedIndex(0)
    closeAutocompletePopover()
  }

  /// Show NSPopover with autocomplete suggestions at cursor position
  func showAutocompletePopover() {
    let suggestions = getAutocompleteSuggestions()
    guard !suggestions.isEmpty else { return }
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
    if let popover = getAutocompletePopover(), popover.isShown {
      updateExistingPopover(popover, localRect: localRect)
      return
    }

    // Create new popover
    createAndShowNewPopover(localRect: localRect)
  }

  /// Update existing popover with new content
  private func updateExistingPopover(_ popover: NSPopover, localRect: CGRect) {
    let suggestions = getAutocompleteSuggestions()
    let selectedIndex = getAutocompleteSelectedIndex()

    let contentView = AutocompletePopupView(
      suggestions: Array(suggestions.prefix(20)),
      selectedIndex: selectedIndex,
      onSelect: { [weak self] suggestion in
        self?.acceptSuggestion(suggestion)
      }
    )
    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.wantsLayer = true

    let itemHeight: CGFloat = 28
    let maxHeight: CGFloat = 400
    let calculatedHeight = min(CGFloat(suggestions.count) * itemHeight + 4, maxHeight)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

    popover.contentViewController = hostingController

    // Reposition popover
    popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
  }

  /// Create and show a new autocomplete popover
  private func createAndShowNewPopover(localRect: CGRect) {
    let suggestions = getAutocompleteSuggestions()
    let selectedIndex = getAutocompleteSelectedIndex()

    let popover = NSPopover()
    popover.behavior = .semitransient
    setAutocompletePopover(popover)

    // Create SwiftUI content view with suggestions
    let contentView = AutocompletePopupView(
      suggestions: Array(suggestions.prefix(20)),  // Limit to 20 items
      selectedIndex: selectedIndex,
      onSelect: { [weak self] suggestion in
        self?.acceptSuggestion(suggestion)
      }
    )

    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.wantsLayer = true

    // Calculate size based on number of suggestions
    let itemHeight: CGFloat = 28
    let maxHeight: CGFloat = 400
    let calculatedHeight = min(CGFloat(suggestions.count) * itemHeight + 4, maxHeight)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

    popover.contentViewController = hostingController

    // Show popover below cursor
    popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
  }

  /// Handle keyboard navigation in autocomplete popup
  /// Returns true if the event was handled
  func handleAutocompleteNavigation(with event: NSEvent) -> Bool {
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

    let suggestions = getAutocompleteSuggestions()
    var selectedIndex = getAutocompleteSelectedIndex()

    // Up arrow -> select previous suggestion (with circular navigation)
    if isUpArrow && !hasModifiers {
      if selectedIndex == 0 {
        // Wrap around to last item
        selectedIndex = suggestions.count - 1
      } else {
        selectedIndex -= 1
      }
      setAutocompleteSelectedIndex(selectedIndex)
      // Update popover to show new selection
      updatePopoverSelection()
      return true
    }

    // Down arrow -> select next suggestion (with circular navigation)
    if isDownArrow && !hasModifiers {
      if selectedIndex == suggestions.count - 1 {
        // Wrap around to first item
        selectedIndex = 0
      } else {
        selectedIndex += 1
      }
      setAutocompleteSelectedIndex(selectedIndex)
      // Update popover to show new selection
      updatePopoverSelection()
      return true
    }

    return false
  }

  /// Accept the currently selected suggestion
  func acceptSelectedSuggestion() {
    let suggestions = getAutocompleteSuggestions()
    let selectedIndex = getAutocompleteSelectedIndex()

    guard selectedIndex >= 0 && selectedIndex < suggestions.count else {
      hideAutocomplete()
      return
    }

    let suggestion = suggestions[selectedIndex]
    acceptSuggestion(suggestion)
  }

  /// Accept a specific suggestion (used for both keyboard and mouse selection)
  func acceptSuggestion(_ suggestion: AutocompleteSuggestion) {
    // Set flag to prevent autocomplete from retriggering during text insertion
    setAcceptingSuggestionFlag(true)

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
      self?.setAcceptingSuggestionFlag(false)
    }
  }

  /// Extract the current token being typed at cursor position
  func extractCurrentToken(from text: String, at position: Int) -> String {
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
  func findTokenRange(in text: String, at position: Int) -> NSRange? {
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
  func updatePopoverSelection() {
    guard let popover = getAutocompletePopover(),
      popover.isShown
    else { return }

    let suggestions = getAutocompleteSuggestions()
    guard !suggestions.isEmpty else { return }

    let selectedIndex = getAutocompleteSelectedIndex()

    // Create new content view with updated selection
    let contentView = AutocompletePopupView(
      suggestions: Array(suggestions.prefix(20)),
      selectedIndex: selectedIndex,
      onSelect: { [weak self] suggestion in
        self?.acceptSuggestion(suggestion)
      }
    )

    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.wantsLayer = true

    // Keep same size
    let itemHeight: CGFloat = 28
    let maxHeight: CGFloat = 400
    let calculatedHeight = min(CGFloat(suggestions.count) * itemHeight + 4, maxHeight)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 400, height: calculatedHeight)

    popover.contentViewController = hostingController
  }
}
