//
//  LineNumberGutterView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// A view that displays line numbers synchronized with a text view's scroll position
struct LineNumberGutterView: NSViewRepresentable {
  let text: String
  let textView: NSTextView?
  let gutterWidth: CGFloat

  func makeNSView(context: Context) -> LineNumberGutterNSView {
    let gutterView = LineNumberGutterNSView()
    gutterView.gutterWidth = gutterWidth
    return gutterView
  }

  func updateNSView(_ gutterView: LineNumberGutterNSView, context: Context) {
    gutterView.gutterWidth = gutterWidth
    gutterView.updateLineNumbers(text: text, textView: textView)
  }

  static func dismantleNSView(_ gutterView: LineNumberGutterNSView, coordinator: ()) {
    gutterView.cleanupObservers()
  }
}

/// Custom NSView that draws line numbers aligned with text lines
@MainActor
class LineNumberGutterNSView: NSView {
  var gutterWidth: CGFloat = 40

  private var lineNumbers: [(number: Int, yPosition: CGFloat, height: CGFloat)] = []
  private var scrollObserver: NSObjectProtocol?
  private var boundsObserver: NSObjectProtocol?
  private var selectionObserver: NSObjectProtocol?
  private weak var observedClipView: NSClipView?
  private weak var observedTextView: NSTextView?

  // Current line tracking
  private var currentLineNumber: Int = 1

  // Top offset to align with text editor
  // SwiftUI padding (8) + textContainerInset.height (2) - 2 (adjustment) = 8
  private let topOffset: CGFloat = 8

  // Cache NSColors for drawing
  private var backgroundColor: NSColor = .clear
  private var borderColor: NSColor = .clear
  private var textColor: NSColor = .gray
  private var highlightedTextColor: NSColor = .white
  private var lineHighlightColor: NSColor = .clear

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    wantsLayer = true
    updateColors()
  }

  private func updateColors() {
    // Use dedicated gutter background that's always lighter than editor
    backgroundColor = NSColor(Color.gutterBackground)
    borderColor = NSColor(Color.border)
    textColor = NSColor(Color.foregroundSubtle)
    highlightedTextColor = NSColor(Color.foreground)
    lineHighlightColor = NSColor(Color.inputBackground)
    layer?.backgroundColor = backgroundColor.cgColor
  }

  func cleanupObservers() {
    if let observer = scrollObserver {
      NotificationCenter.default.removeObserver(observer)
      scrollObserver = nil
    }
    if let observer = boundsObserver {
      NotificationCenter.default.removeObserver(observer)
      boundsObserver = nil
    }
    if let observer = selectionObserver {
      NotificationCenter.default.removeObserver(observer)
      selectionObserver = nil
    }
    observedClipView = nil
    observedTextView = nil
  }

  private func removeScrollObserver() {
    cleanupObservers()
  }

  /// Update the current line number based on cursor position
  private func updateCurrentLine() {
    guard let textView = observedTextView else {
      currentLineNumber = 1
      needsDisplay = true
      return
    }

    let cursorPosition = textView.selectedRange().location
    let text = textView.string as NSString

    // Handle empty text
    if text.length == 0 {
      if currentLineNumber != 1 {
        currentLineNumber = 1
        needsDisplay = true
      }
      return
    }

    // Find which line the cursor is on by getting the line range at cursor position
    // Use min to handle cursor at end of text
    let safePosition = min(cursorPosition, max(0, text.length - 1))
    let cursorLineRange = text.lineRange(for: NSRange(location: safePosition, length: 0))

    // Count lines up to the cursor's line
    var lineNumber = 1
    var characterIndex = 0

    while characterIndex < cursorLineRange.location {
      let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
      lineNumber += 1
      characterIndex = lineRange.location + lineRange.length
    }

    if currentLineNumber != lineNumber {
      currentLineNumber = lineNumber
      needsDisplay = true
    }
  }

  func updateLineNumbers(text: String, textView: NSTextView?) {
    guard let textView = textView,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else {
      lineNumbers = []
      needsDisplay = true
      return
    }

    // Setup scroll observer if needed
    if let scrollView = textView.enclosingScrollView,
      observedClipView !== scrollView.contentView
    {
      removeScrollObserver()
      observedClipView = scrollView.contentView

      // Observe bounds changes for scroll sync
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        // Already on main queue, use DispatchQueue for immediate execution
        DispatchQueue.main.async {
          self?.needsDisplay = true
        }
      }

      // Also observe frame changes - important for word-wrap layout recalculation
      boundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification,
        object: textView,
        queue: .main
      ) { [weak self, weak textView] _ in
        DispatchQueue.main.async {
          guard let self = self, let textView = textView else { return }
          // When frame changes with word-wrap, line positions change
          // Need to recalculate line numbers, not just redraw
          self.updateLineNumbers(text: textView.string, textView: textView)
        }
      }
    }

    // Setup selection observer for current line highlighting
    if observedTextView !== textView {
      if let observer = selectionObserver {
        NotificationCenter.default.removeObserver(observer)
      }
      observedTextView = textView

      selectionObserver = NotificationCenter.default.addObserver(
        forName: NSTextView.didChangeSelectionNotification,
        object: textView,
        queue: .main
      ) { [weak self] _ in
        DispatchQueue.main.async {
          self?.updateCurrentLine()
        }
      }

      // Initial update
      updateCurrentLine()
    }

    // Ensure layout is up to date
    layoutManager.ensureLayout(for: textContainer)

    // Calculate line positions
    var newLineNumbers: [(number: Int, yPosition: CGFloat, height: CGFloat)] = []

    let nsString = text as NSString
    var lineNumber = 1
    var characterIndex = 0

    while characterIndex < nsString.length {
      let lineRange = nsString.lineRange(for: NSRange(location: characterIndex, length: 0))

      // Get the glyph range for this line
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: lineRange, actualCharacterRange: nil)

      if glyphRange.length > 0 {
        // Get the bounding rect for this line
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        // Add text container inset
        let yPosition = lineRect.origin.y + textView.textContainerInset.height

        newLineNumbers.append((lineNumber, yPosition, lineRect.height))
      } else {
        // Empty line - use previous line's bottom or default
        let previousBottom =
          newLineNumbers.last.map { $0.yPosition + $0.height } ?? textView.textContainerInset.height
        let defaultHeight: CGFloat = 17  // Approximate line height
        newLineNumbers.append((lineNumber, previousBottom, defaultHeight))
      }

      lineNumber += 1
      characterIndex = lineRange.location + lineRange.length
    }

    // Handle empty text or trailing newline
    if text.isEmpty {
      newLineNumbers = [(1, textView.textContainerInset.height, 17)]
    } else if text.hasSuffix("\n") {
      let previousBottom =
        newLineNumbers.last.map { $0.yPosition + $0.height } ?? textView.textContainerInset.height
      newLineNumbers.append((lineNumber, previousBottom, 17))
    }

    lineNumbers = newLineNumbers
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Update colors in case theme changed
    updateColors()

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Draw background
    context.setFillColor(backgroundColor.cgColor)
    context.fill(bounds)

    // Draw right border
    context.setStrokeColor(borderColor.cgColor)
    context.setLineWidth(1)
    context.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
    context.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.height))
    context.strokePath()

    // Get scroll offset from observed text view
    let scrollOffset = observedClipView?.bounds.origin.y ?? 0

    // Draw line numbers
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right

    let normalAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]

    let highlightedAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: highlightedTextColor,
      .paragraphStyle: paragraphStyle,
    ]

    for (number, yPosition, height) in lineNumbers {
      // In flipped coordinate system, y increases downward from top
      // yPosition is relative to text container origin, scrollOffset moves the visible area
      // Add topOffset to align with SwiftUI padding + textContainerInset
      let adjustedY = yPosition - scrollOffset + topOffset

      // Only draw if visible
      if adjustedY + height < 0 || adjustedY > bounds.height {
        continue
      }

      let isCurrentLine = number == currentLineNumber

      // Draw highlight background for current line
      if isCurrentLine {
        let highlightRect = CGRect(
          x: 0,
          y: adjustedY,
          width: bounds.width,
          height: height
        )
        context.setFillColor(lineHighlightColor.cgColor)
        context.fill(highlightRect)
      }

      let numberString = "\(number)"
      let textRect = CGRect(
        x: 0,
        y: adjustedY,
        width: gutterWidth - 8,  // Padding from right edge
        height: height
      )

      // Use highlighted color for current line number
      let attributes = isCurrentLine ? highlightedAttributes : normalAttributes

      // Top-align the line number (important for word-wrapped lines)
      let textSize = numberString.size(withAttributes: attributes)
      let topAlignedRect = CGRect(
        x: textRect.origin.x,
        y: textRect.origin.y,
        width: textRect.width,
        height: textSize.height
      )

      numberString.draw(in: topAlignedRect, withAttributes: attributes)
    }
  }

  override var isFlipped: Bool {
    return true  // Use flipped coordinate system (origin at top-left) to match NSTextView
  }
}

// MARK: - Preview

#Preview("Line Number Gutter") {
  HStack(spacing: 0) {
    LineNumberGutterView(
      text: "SELECT\n    u.id,\n    u.name\nFROM users;",
      textView: nil,
      gutterWidth: 40
    )
    .frame(width: 40)

    Text("SELECT\n    u.id,\n    u.name\nFROM users;")
      .font(.system(size: 13, design: .monospaced))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color.inputBackground)
  }
  .frame(width: 400, height: 200)
  .preferredColorScheme(.dark)
}
