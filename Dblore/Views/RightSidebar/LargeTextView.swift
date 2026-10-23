//
//  LargeTextView.swift
//  Dblore
//
//  Read-only, selectable monospaced text for cell values too large for a SwiftUI Text.
//  Non-contiguous layout lays out only the visible part, so a multi-MB value opens at once.
//

import AppKit
import SwiftUI

struct LargeTextView: NSViewRepresentable {
  let text: String
  let wrapsLines: Bool

  /// Last text and wrap mode applied, so an update compares these instead of bridging the text
  /// view's (possibly large) string
  final class Coordinator {
    var text: String?
    var wrapsLines: Bool?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    scrollView.hasVerticalScroller = true

    // TextKit 1, so the layout manager exists and lays out lazily
    let textView = NSTextView(usingTextLayoutManager: false)
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = NSColor(Color.foreground)
    textView.textContainerInset = NSSize(width: Spacing.sm, height: Spacing.sm)
    textView.isVerticallyResizable = true
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.heightTracksTextView = false
    scrollView.documentView = textView

    apply(wrapsLines: wrapsLines, to: textView, in: scrollView)
    textView.string = text
    context.coordinator.text = text
    context.coordinator.wrapsLines = wrapsLines
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    if context.coordinator.wrapsLines != wrapsLines {
      apply(wrapsLines: wrapsLines, to: textView, in: scrollView)
      context.coordinator.wrapsLines = wrapsLines
    }
    if context.coordinator.text != text {
      textView.string = text
      context.coordinator.text = text
    }
  }

  private func apply(wrapsLines: Bool, to textView: NSTextView, in scrollView: NSScrollView) {
    scrollView.hasHorizontalScroller = !wrapsLines
    textView.isHorizontallyResizable = !wrapsLines
    textView.autoresizingMask = wrapsLines ? [.width] : []
    textView.textContainer?.widthTracksTextView = wrapsLines
    if wrapsLines {
      let width = scrollView.contentSize.width
      textView.frame.size.width = width
      textView.textContainer?.containerSize = NSSize(
        width: max(width - 2 * textView.textContainerInset.width, 0),
        height: CGFloat.greatestFiniteMagnitude)
    } else {
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
  }
}
