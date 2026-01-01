//
//  HighlightedTextEditor.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

// MARK: - Highlighted Text Editor

struct HighlightedTextEditor: View {
  @Binding var text: String
  var onFocus: (() -> Void)?
  @Binding var textViewRef: SQLTextView?
  @Binding var isEmpty: Bool
  @State private var height: CGFloat = 40

  var body: some View {
    HighlightedTextEditorRepresentable(
      text: $text,
      height: $height,
      isEmpty: $isEmpty,
      onFocus: onFocus,
      textViewRef: $textViewRef
    )
    .frame(height: height)
  }
}

struct HighlightedTextEditorRepresentable: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  @Binding var isEmpty: Bool
  var onFocus: (() -> Void)?
  @Binding var textViewRef: SQLTextView?

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    let textView = SQLTextView()

    textView.delegate = context.coordinator
    textView.onFocus = onFocus

    // Setup onBlur callback to update binding when editor loses focus
    textView.onBlur = { [weak coordinator = context.coordinator] newText in
      coordinator?.text.wrappedValue = newText
    }

    // Store reference to textView
    DispatchQueue.main.async {
      textViewRef = textView
    }
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

    // Configure text container to expand vertically
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
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

    // Only update text from external source if different
    // Don't update if textView is first responder (user is typing)
    if textView.string != text && textView.window?.firstResponder != textView {
      // Apply syntax highlighting when updating from external source
      context.coordinator.applyHighlighting(to: textView, text: text)

      DispatchQueue.main.async {
        context.coordinator.updateHeight(textView: textView)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, height: $height, isEmpty: $isEmpty)
  }

  class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var height: Binding<CGFloat>
    var isEmpty: Binding<Bool>

    init(text: Binding<String>, height: Binding<CGFloat>, isEmpty: Binding<Bool>) {
      self.text = text
      self.height = height
      self.isEmpty = isEmpty
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

      // DO NOT update text binding here - it causes undo/redo issues!
      // The text binding will be updated when editor loses focus (see onBlur callback in resignFirstResponder)
    }

    @MainActor
    func applyHighlighting(to textView: NSTextView, text: String) {
      let attributed = SQLSyntaxHighlighter.highlight(text)

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

      let attributed = SQLSyntaxHighlighter.highlight(text)

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

      // Set minimum height
      let minHeight: CGFloat = 28
      let newHeight = max(requiredHeight, minHeight)

      // Update SwiftUI binding to trigger view update
      if abs(height.wrappedValue - newHeight) > 1 {
        height.wrappedValue = newHeight
      }

      // Update frame
      var frame = textView.frame
      frame.size.height = newHeight
      textView.frame = frame
    }
  }
}
