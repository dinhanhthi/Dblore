//
//  HighlightedTextEditor.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

// MARK: - Passthrough Scroll View

/// Custom NSScrollView that forwards scroll events to parent when content doesn't need scrolling
class PassthroughScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    guard let textView = documentView as? NSTextView else {
      super.scrollWheel(with: event)
      return
    }

    let contentHeight = textView.frame.height
    let visibleHeight = contentView.bounds.height

    // If content doesn't need scrolling, forward to parent (SwiftUI List)
    if contentHeight <= visibleHeight {
      nextResponder?.scrollWheel(with: event)
      return
    }

    // Content needs scrolling - check boundaries
    let currentY = contentView.bounds.origin.y
    let maxY = max(0, contentHeight - visibleHeight)

    let isAtTop = currentY <= 0
    let isAtBottom = currentY >= maxY - 1  // Small tolerance
    let scrollingUp = event.scrollingDeltaY > 0
    let scrollingDown = event.scrollingDeltaY < 0

    // Forward to parent when at boundary and scrolling in that direction
    if (isAtTop && scrollingUp) || (isAtBottom && scrollingDown) {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}

// MARK: - Highlighted Text Editor

struct HighlightedTextEditor: View {
  @Binding var text: String
  var onFocus: (() -> Void)?
  @Binding var textViewRef: SQLTextView?
  @Binding var isEmpty: Bool
  @State private var height: CGFloat = 40

  var autocompleteProvider: SQLAutocompleteProvider?
  var cellId: UUID?  // For search highlighting
  var viewModelId: UUID?  // ID of the viewModel (for scoped search)
  var maxHeight: CGFloat?  // Optional max height - if set, enables scrolling
  var isEditorMode: Bool = false  // True when used in Editor mode (IDE-like arrow behavior)
  var wordWrapEnabled: Bool = true  // Word wrap setting

  var body: some View {
    HighlightedTextEditorRepresentable(
      text: $text,
      height: $height,
      isEmpty: $isEmpty,
      onFocus: onFocus,
      textViewRef: $textViewRef,
      autocompleteProvider: autocompleteProvider,
      cellId: cellId,
      viewModelId: viewModelId,
      maxHeight: maxHeight,
      isEditorMode: isEditorMode,
      wordWrapEnabled: wordWrapEnabled
    )
    .frame(height: maxHeight ?? height)
  }
}

struct HighlightedTextEditorRepresentable: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  @Binding var isEmpty: Bool
  var onFocus: (() -> Void)?
  @Binding var textViewRef: SQLTextView?
  var autocompleteProvider: SQLAutocompleteProvider?
  var cellId: UUID?
  var viewModelId: UUID?
  var maxHeight: CGFloat?
  var isEditorMode: Bool = false
  var wordWrapEnabled: Bool = true

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = PassthroughScrollView()
    let textView = SQLTextView()

    textView.delegate = context.coordinator
    textView.onFocus = onFocus

    // Setup onBlur callback to update binding when editor loses focus
    textView.onBlur = { [weak coordinator = context.coordinator] newText in
      coordinator?.text.wrappedValue = newText
    }

    // Setup autocomplete
    textView.autocompleteProvider = autocompleteProvider

    // Set editor mode
    textView.isEditorMode = isEditorMode

    // Store reference to textView
    DispatchQueue.main.async {
      textViewRef = textView
    }

    // Store weak reference in coordinator for search highlighting
    context.coordinator.textView = textView
    context.coordinator.cellId = cellId
    context.coordinator.viewModelId = viewModelId
    textView.viewModelId = viewModelId
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = NSColor(Color.foreground)
    textView.backgroundColor = NSColor.clear
    textView.drawsBackground = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.allowsUndo = true

    // Enable continuous undo grouping for better undo/redo behavior
    textView.isContinuousSpellCheckingEnabled = false
    if let undoManager = textView.undoManager {
      undoManager.groupsByEvent = true
    }

    textView.textContainerInset = NSSize(width: 4, height: 2)
    textView.textContainer?.lineFragmentPadding = 0

    // Configure text container based on word wrap setting
    if wordWrapEnabled {
      // Word wrap enabled: text wraps at container width
      textView.textContainer?.widthTracksTextView = true
      textView.textContainer?.containerSize = NSSize(
        width: 0,  // Will be set by widthTracksTextView
        height: CGFloat.greatestFiniteMagnitude
      )
      textView.isHorizontallyResizable = false
    } else {
      // Word wrap disabled: text extends horizontally, enable horizontal scroll
      textView.textContainer?.widthTracksTextView = false
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      textView.isHorizontallyResizable = true
    }
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = wordWrapEnabled ? [.width] : [.width, .height]

    scrollView.documentView = textView
    // Enable scrolling when maxHeight is set (editor mode)
    scrollView.hasVerticalScroller = maxHeight != nil
    scrollView.hasHorizontalScroller = !wordWrapEnabled  // Enable horizontal scroll when word wrap disabled
    scrollView.drawsBackground = false

    // Set initial text with highlighting
    context.coordinator.applyHighlighting(to: textView, text: text)

    // Update height after setting text
    DispatchQueue.main.async {
      context.coordinator.updateHeight(textView: textView)
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? SQLTextView else { return }

    // Update callbacks
    textView.onFocus = onFocus

    // Setup onBlur callback to update binding when editor loses focus
    textView.onBlur = { [weak coordinator = context.coordinator] newText in
      coordinator?.text.wrappedValue = newText
    }

    // Update autocomplete provider
    textView.autocompleteProvider = autocompleteProvider

    // Update editor mode
    textView.isEditorMode = isEditorMode

    // Update word wrap setting when it changes
    if wordWrapEnabled {
      textView.textContainer?.widthTracksTextView = true
      textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentView.bounds.width,
        height: CGFloat.greatestFiniteMagnitude
      )
      textView.isHorizontallyResizable = false
      textView.autoresizingMask = [.width]
      scrollView.hasHorizontalScroller = false
    } else {
      textView.textContainer?.widthTracksTextView = false
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      textView.isHorizontallyResizable = true
      textView.autoresizingMask = [.width, .height]
      scrollView.hasHorizontalScroller = true
    }

    // Force layout update after word wrap change
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

    // Only update text from external source if different
    // Note: We allow update even when first responder for external file reload scenarios
    if textView.string != text {
      // Apply syntax highlighting when updating from external source
      context.coordinator.applyHighlighting(to: textView, text: text)

      DispatchQueue.main.async {
        context.coordinator.updateHeight(textView: textView)
      }
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    // Cleanup when view is removed (e.g., cell scrolls off-screen)
    guard let textView = scrollView.documentView as? SQLTextView else { return }

    // Clear delegate to prevent retain cycles
    textView.delegate = nil

    // Clear callbacks
    textView.onFocus = nil
    textView.onBlur = nil

    // Clear text storage to free memory
    textView.textStorage?.setAttributedString(NSAttributedString())
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text, height: $height, isEmpty: $isEmpty
    )
  }

  @MainActor
  class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var height: Binding<CGFloat>
    var isEmpty: Binding<Bool>

    // Weak reference to text view for search highlighting
    weak var textView: NSTextView?
    var cellId: UUID?
    var viewModelId: UUID?  // ID of the viewModel (for scoped search)

    // Search state
    private var searchQuery: String = ""
    private var isCaseSensitive: Bool = false
    private var currentMatchId: UUID?
    private var currentMatchRange: NSRange?
    private var isSearchActive: Bool = false

    // Notification observers
    private var highlightObserver: NSObjectProtocol?
    private var clearObserver: NSObjectProtocol?
    private var unfocusObserver: NSObjectProtocol?
    private var syntaxHighlightObserver: NSObjectProtocol?

    init(
      text: Binding<String>, height: Binding<CGFloat>, isEmpty: Binding<Bool>
    ) {
      self.text = text
      self.height = height
      self.isEmpty = isEmpty
      super.init()

      // Setup notification observers
      setupNotificationObservers()
    }

    deinit {
      // Observers will be automatically removed when this object deallocates
      // NotificationCenter holds weak references
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }

      // Safety check: ensure textView is still valid and attached to a window
      guard textView.window != nil else { return }

      // Apply syntax highlighting without affecting undo stack
      applyHighlightingWithoutUndo(to: textView, text: textView.string)

      // Update height to fit content
      updateHeight(textView: textView)

      // Update isEmpty state for placeholder reactivity (this is safe and doesn't affect undo)
      isEmpty.wrappedValue = textView.string.isEmpty

      // Update text binding IMMEDIATELY for document persistence
      // This is critical for ReferenceFileDocument to have the latest content when saving
      text.wrappedValue = textView.string
    }

    @MainActor
    func applyHighlighting(to textView: NSTextView, text: String) {
      let attributed: NSAttributedString
      if isSearchActive {
        // Get current match range from NotebookViewModel's search state
        let currentMatchRange = getCurrentMatchRange(for: textView.string)
        attributed = SQLSyntaxHighlighter.highlightWithSearch(
          text,
          searchQuery: searchQuery,
          isCaseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
      } else {
        attributed = SQLSyntaxHighlighter.highlight(text)
      }

      // Disable undo registration for programmatic text changes
      let undoManager = textView.undoManager
      undoManager?.disableUndoRegistration()

      textView.textStorage?.beginEditing()
      textView.textStorage?.setAttributedString(attributed)
      textView.textStorage?.endEditing()

      // Re-enable undo registration
      undoManager?.enableUndoRegistration()
    }

    /// Apply syntax highlighting without creating undo operations
    /// This prevents undo/redo lag when typing
    @MainActor
    func applyHighlightingWithoutUndo(to textView: NSTextView, text: String) {
      guard let textStorage = textView.textStorage else { return }

      let attributed: NSAttributedString
      if isSearchActive {
        // Get current match range from NotebookViewModel's search state
        let currentMatchRange = getCurrentMatchRange(for: text)
        attributed = SQLSyntaxHighlighter.highlightWithSearch(
          text,
          searchQuery: searchQuery,
          isCaseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
      } else {
        attributed = SQLSyntaxHighlighter.highlight(text)
      }

      // Only apply if the text content matches (same length)
      guard textStorage.length == attributed.length else { return }

      let fullRange = NSRange(location: 0, length: textStorage.length)

      // Disable undo registration while applying syntax highlighting
      // This prevents syntax highlighting from interfering with text editing undo/redo
      let undoManager = textView.undoManager
      undoManager?.disableUndoRegistration()

      textStorage.beginEditing()

      // Remove all attributes first
      textStorage.setAttributes([:], range: fullRange)

      // Apply new attributes from syntax highlighting
      attributed.enumerateAttributes(
        in: NSRange(location: 0, length: attributed.length), options: []
      ) { attrs, range, _ in
        textStorage.addAttributes(attrs, range: range)
      }

      textStorage.endEditing()

      // Re-enable undo registration
      undoManager?.enableUndoRegistration()
    }

    @MainActor
    func updateHeight(textView: NSTextView) {
      guard let textContainer = textView.textContainer,
        let layoutManager = textView.layoutManager
      else { return }

      // Force layout
      layoutManager.ensureLayout(for: textContainer)

      // Calculate the required height
      let usedRect = layoutManager.usedRect(for: textContainer)
      let insets = textView.textContainerInset
      let requiredHeight = usedRect.height + insets.height * 2

      // Set minimum height - increased to allow more clickable area when empty
      let minHeight: CGFloat = 40
      let newHeight = max(requiredHeight, minHeight)

      // Update SwiftUI binding to trigger view update (only when not using maxHeight)
      // When maxHeight is set, the frame is fixed and we rely on scrolling
      if abs(height.wrappedValue - newHeight) > 1 {
        height.wrappedValue = newHeight
      }

      // Update frame - textView can expand freely within scrollView
      var frame = textView.frame
      frame.size.height = newHeight
      textView.frame = frame
    }

    // MARK: - Search Highlighting

    private func setupNotificationObservers() {
      // Listen for unfocus editor notification
      unfocusObserver = NotificationCenter.default.addObserver(
        forName: .unfocusEditor,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self, let textView = self.textView else { return }
          // Unfocus the text view by resigning first responder
          textView.window?.makeFirstResponder(nil)
        }
      }

      // Listen for highlight search match notification
      highlightObserver = NotificationCenter.default.addObserver(
        forName: .highlightSearchMatch,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard self != nil else { return }

        // Extract notification data before entering MainActor context
        guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID,
          let match = notification.userInfo?["match"] as? SearchMatch
        else { return }

        // Check match type (must be done before Task to avoid actor isolation issues)
        let isSQLContent: Bool
        switch match.matchType {
        case .sqlContent:
          isSQLContent = true
        default:
          isSQLContent = false
        }

        let matchId = match.id
        let matchCellId = match.cellId
        let matchRange = match.matchRange
        let query = notification.userInfo?["query"] as? String ?? ""
        let caseSensitive = notification.userInfo?["caseSensitive"] as? Bool ?? false

        Task { @MainActor [weak self] in
          guard let self = self else { return }

          // Only respond if this notification is for our viewModel instance
          // Note: Check viewModelId here (inside MainActor) to avoid actor isolation warning
          guard notificationViewModelId == self.viewModelId else { return }

          // Update search state for ALL cells (to show yellow highlights)
          self.searchQuery = query
          self.isCaseSensitive = caseSensitive
          self.isSearchActive = true

          // In editor mode, cellId is nil - accept all SQL content matches
          // In notebook mode, only accept matches for this cell
          let isEditorMode = self.cellId == nil
          let matchesThisCell = isEditorMode || matchCellId == self.cellId

          // Only set currentMatchRange for the cell with the current match (orange highlight)
          if isSQLContent && matchesThisCell {
            // This cell has the current match - highlight it orange
            guard let textView = self.textView else { return }
            let nsRange = NSRange(matchRange, in: textView.string)
            self.currentMatchId = matchId
            self.currentMatchRange = nsRange

            // Scroll to make the match visible
            textView.scrollRangeToVisible(nsRange)
          } else {
            // This cell doesn't have current match - clear orange highlight
            self.currentMatchId = nil
            self.currentMatchRange = nil
          }

          // Reapply highlighting with search
          self.reapplyHighlighting()
        }
      }

      // Listen for clear search highlights notification
      clearObserver = NotificationCenter.default.addObserver(
        forName: .clearSearchHighlights,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard self != nil else { return }

        // Extract notification data before entering MainActor context
        guard let notificationViewModelId = notification.userInfo?["viewModelId"] as? UUID
        else { return }

        Task { @MainActor [weak self] in
          guard let self = self else { return }

          // Only respond if this notification is for our viewModel instance
          // Note: Check viewModelId here (inside MainActor) to avoid actor isolation warning
          guard notificationViewModelId == self.viewModelId else { return }

          // Clear search state
          self.searchQuery = ""
          self.isCaseSensitive = false
          self.currentMatchId = nil
          self.currentMatchRange = nil
          self.isSearchActive = false

          // Reapply highlighting without search
          self.reapplyHighlighting()
        }
      }

      // Listen for syntax highlighting setting changes
      syntaxHighlightObserver = NotificationCenter.default.addObserver(
        forName: .syntaxHighlightingChanged,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          // Reapply highlighting with new setting
          self.reapplyHighlighting()
        }
      }
    }

    @MainActor
    private func reapplyHighlighting() {
      guard let textView = textView else { return }
      applyHighlightingWithoutUndo(to: textView, text: textView.string)
    }

    /// Get NSRange of current match if this cell has the active match
    @MainActor
    private func getCurrentMatchRange(for text: String) -> NSRange? {
      return currentMatchRange
    }
  }
}
