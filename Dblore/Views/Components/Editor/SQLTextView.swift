//
//  SQLTextView.swift
//  Dblore
//
//  Custom NSTextView for SQL editing with keyboard shortcuts, autocomplete, and smart clipboard
//

import AppKit
import SwiftUI

// MARK: - SQL Text View

class SQLTextView: NSTextView {

  // MARK: - Public Properties

  var onFocus: (() -> Void)?
  var onBlur: ((String) -> Void)?  // Callback with current text when losing focus
  var autocompleteProvider: SQLAutocompleteProvider?
  var isEditorMode: Bool = false  // True when used in Editor mode (IDE-like arrow behavior)
  var viewModelId: UUID?  // ID of the viewModel that owns this text view (for scoped search)

  // MARK: - Internal State (for extensions)

  // Autocomplete state
  private var autocompleteSuggestions: [AutocompleteSuggestion] = []
  private var autocompleteSelectedIndex: Int = 0
  private var autocompletePopover: NSPopover?
  /// Pending debounced suggestion computation (cancelled by newer edits and by hide)
  var autocompleteTask: Task<Void, Never>?
  /// Delay between the last edit and the suggestion computation
  static var autocompleteDebounce: Duration = .milliseconds(80)
  private var isAcceptingSuggestion = false  // Flag to prevent retriggering autocomplete
  private var isProgrammaticEdit = false  // Flag to prevent autocomplete during programmatic edits

  // Custom pasteboard type for line copy metadata
  static let lineCopyType = NSPasteboard.PasteboardType("ace.thi.dblore.copy-type")

  // MARK: - State Accessors (for extensions)

  func getAutocompleteSuggestions() -> [AutocompleteSuggestion] {
    autocompleteSuggestions
  }

  func setAutocompleteSuggestions(_ suggestions: [AutocompleteSuggestion]) {
    autocompleteSuggestions = suggestions
  }

  func getAutocompleteSelectedIndex() -> Int {
    autocompleteSelectedIndex
  }

  func setAutocompleteSelectedIndex(_ index: Int) {
    autocompleteSelectedIndex = index
  }

  func getAutocompletePopover() -> NSPopover? {
    autocompletePopover
  }

  func setAutocompletePopover(_ popover: NSPopover?) {
    autocompletePopover = popover
  }

  func closeAutocompletePopover() {
    autocompletePopover?.close()
    autocompletePopover = nil
  }

  func setAcceptingSuggestionFlag(_ value: Bool) {
    isAcceptingSuggestion = value
  }

  func setProgrammaticEditFlag(_ value: Bool) {
    isProgrammaticEdit = value
  }

  /// True while autocomplete must stay quiet (accepting a suggestion or a programmatic edit)
  var isAutocompleteSuppressed: Bool {
    isAcceptingSuggestion || isProgrammaticEdit
  }

  // MARK: - First Responder

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

  // MARK: - Current Line Highlight

  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    if isEditorMode { needsDisplay = true }
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard isEditorMode, selectedRange().length == 0,
      let layoutManager, let textContainer,
      let lineRect = currentLineRect(layoutManager, textContainer)
    else { return }
    NSColor(Color.inputBackground).setFill()
    NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()
  }

  /// Rect (view coordinates) of the logical line containing the caret, including wrapped fragments.
  private func currentLineRect(
    _ layoutManager: NSLayoutManager, _ textContainer: NSTextContainer
  ) -> NSRect? {
    let text = string as NSString
    let caret = selectedRange().location
    var rect: NSRect
    if caret >= text.length && (text.length == 0 || text.character(at: text.length - 1) == 10) {
      rect = layoutManager.extraLineFragmentRect
      if rect.isEmpty { return nil }
    } else {
      let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length - 1), length: 0))
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: lineRange, actualCharacterRange: nil)
      rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }
    rect.origin.y += textContainerOrigin.y
    return rect
  }

  // MARK: - Key Events

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

  // MARK: - Copy/Paste Overrides

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
}
