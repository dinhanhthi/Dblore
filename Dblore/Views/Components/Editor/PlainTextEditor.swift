//
//  PlainTextEditor.swift
//  Dblore
//
//  A simple text editor that disables macOS smart quotes and text replacement.
//  Use this for editing JSON, code, or any text that requires exact character input.
//

import AppKit
import SwiftUI

/// A SwiftUI wrapper around NSTextView that disables smart quotes and text replacement.
/// This ensures that straight quotes `"` are not converted to curly quotes `"` or `"`.
struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    let textView = NSTextView()

    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = NSColor(Color.foreground)
    textView.backgroundColor = NSColor.clear
    textView.drawsBackground = false

    // CRITICAL: Disable smart quotes and text replacement
    // This prevents macOS from converting " to " or "
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false

    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 4, height: 8)
    textView.textContainer?.lineFragmentPadding = 0

    // Configure text container to expand vertically
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true

    // Set initial text
    textView.string = text

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }

    // Only update if text has changed externally (not from user typing)
    if textView.string != text && !context.coordinator.isEditing {
      textView.string = text
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var isEditing = false

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidBeginEditing(_ notification: Notification) {
      isEditing = true
    }

    func textDidEndEditing(_ notification: Notification) {
      isEditing = false
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}

#Preview("PlainTextEditor") {
  @Previewable @State var text = """
    {"key": "value", "name": "test"}
    """

  VStack {
    Text("Type quotes here - they should stay straight:")
      .font(.caption)

    PlainTextEditor(text: $text)
      .frame(height: 200)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }
  .padding()
  .frame(width: 400)
}
