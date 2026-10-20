//
//  SQLTextView+GhostText.swift
//  Dblore
//
//  AI ghost text: the inline suggestion drawn after the caret, never written into the text
//  storage until Tab accepts it
//

import AppKit
import SwiftUI

extension SQLTextView {

  /// The suggestion shown after the caret: only at its caret, with nothing selected and no
  /// composition in progress, cut to the width the editor shows (see `fitGhostText`). Tab
  /// inserts exactly this text.
  var visibleGhostText: String? { ghostText()?.text }

  // MARK: - Editor events

  /// An edit of the focused editor; programmatic edits of an unfocused one never ask. With
  /// ghost text off, the text is never read.
  func ghostTextDidChangeText() {
    guard let inlineCompletion else { return }
    guard inlineCompletion.isEnabled else {
      inlineCompletion.dismiss()
      return
    }
    guard window?.firstResponder === self else { return }
    inlineCompletion.textDidChange(text: string, caret: selectedRange().location)
  }

  /// A caret move cancels the request; a selection hides the suggestion
  func ghostTextSelectionDidChange() {
    guard let inlineCompletion else { return }
    let selection = selectedRange()
    if selection.length > 0 {
      inlineCompletion.dismiss()
    } else {
      inlineCompletion.selectionDidChange(caret: selection.location)
    }
  }

  /// Watches every clip view around the editor (its own scroll view and any outer one, such as
  /// the notebook's) while it is in a window: a scroll dismisses the suggestion, as a caret move
  /// does. What shows depends on the visible rect, and a scroll redraws only the strip it
  /// exposes. Typing scrolls before a suggestion arrives, so a pending request is kept.
  func observeGhostTextScrolling() {
    let center = NotificationCenter.default
    for observer in ghostTextScrollObservers { center.removeObserver(observer) }
    ghostTextScrollObservers = []
    guard window != nil else { return }
    var view = superview
    while let current = view {
      if let clipView = current as? NSClipView {
        clipView.postsBoundsChangedNotifications = true
        ghostTextScrollObservers.append(
          center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
          ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ghostTextDidScroll() }
          })
      }
      view = current.superview
    }
  }

  private func ghostTextDidScroll() {
    guard let inlineCompletion, inlineCompletion.suggestion != nil else { return }
    inlineCompletion.dismiss()
  }

  /// Inserts the suggestion at the caret through the typing path, as one undo step. False when
  /// none is shown.
  @discardableResult
  func acceptGhostText() -> Bool {
    guard let text = visibleGhostText, inlineCompletion?.accept() != nil else { return false }
    let caret = selectedRange()
    // Typing coalesces into one undo step: keep the accepted text a step of its own
    breakUndoCoalescing()
    setAcceptingSuggestionFlag(true)
    insertText(text, replacementRange: caret)
    setAcceptingSuggestionFlag(false)
    breakUndoCoalescing()
    return true
  }

  /// Hides the suggestion. False when none is shown.
  @discardableResult
  func dismissGhostText() -> Bool {
    guard visibleGhostText != nil else { return false }
    inlineCompletion?.dismiss()
    return true
  }

  // MARK: - Drawing

  /// Draws the suggestion from the caret in the editor font and the subtle text token. Lines
  /// after the first start at the left edge of the text, over blank lines of the text (see
  /// `AIInlineCompletion.context`).
  func drawGhostText() {
    guard let ghost = ghostText() else { return }
    let (text, line) = ghost
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, part) in lines.enumerated() {
      let point = NSPoint(
        x: index == 0 ? line.x : line.left, y: line.y + CGFloat(index) * line.height)
      (String(part) as NSString).draw(at: point, withAttributes: ghostAttributes)
    }
  }

  private var ghostAttributes: [NSAttributedString.Key: Any] {
    [
      .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
      .foregroundColor: NSColor(Color.foregroundSubtle),
    ]
  }

  /// The visible suggestion and the caret line it is drawn from
  private func ghostText() -> (text: String, line: GhostLine)? {
    guard let suggestion = inlineCompletion?.suggestion, !hasMarkedText() else { return nil }
    let selection = selectedRange()
    guard selection.length == 0, selection.location == suggestion.caret,
      let layoutManager, let textContainer,
      let line = ghostCaretLine(layoutManager, textContainer),
      let text = fitGhostText(suggestion.text, line: line)
    else { return nil }
    return (text, line)
  }

  /// `text` with each line cut to the width left for it: the first from the caret, the next ones
  /// from the left edge of the text. Nothing past the right edge would show (wrap on clips it,
  /// wrap off has no room to scroll to), so a cut line ends the text, as do the lines past
  /// `line.lines`. Nil when nothing but whitespace fits.
  private func fitGhostText(_ text: String, line: GhostLine) -> String? {
    var fitted: [String] = []
    for (index, part) in text.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      if index >= line.lines { break }
      let part = String(part) as NSString
      let length = Self.ghostFittingLength(
        part, width: line.right - (index == 0 ? line.x : line.left), attributes: ghostAttributes)
      fitted.append(part.substring(to: length))
      if length < part.length { break }
    }
    var text = fitted.joined(separator: "\n")
    while text.last?.isWhitespace == true { text.removeLast() }
    return text.allSatisfy(\.isWhitespace) ? nil : text
  }

  /// UTF-16 length of the start of `line` that fits in `width`, never cutting a character
  private static func ghostFittingLength(
    _ line: NSString, width: CGFloat, attributes: [NSAttributedString.Key: Any]
  ) -> Int {
    guard line.length > 0, width > 0 else { return 0 }
    let string = NSAttributedString(string: line as String, attributes: attributes)
    let typesetter = CTTypesetterCreateWithAttributedString(string)
    let length = CTTypesetterSuggestClusterBreak(typesetter, 0, Double(width))
    // The first character always comes back, even when it does not fit
    let first = line.rangeOfComposedCharacterSequence(at: 0)
    guard length == first.length else { return length }
    return string.attributedSubstring(from: first).size().width <= width ? length : 0
  }

  /// Where ghost text goes, in view coordinates: the caret x, the top and height of its line
  /// fragment, the left and right edges of the text, and how many lines show
  private struct GhostLine {
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat
    let left: CGFloat
    let right: CGFloat
    let lines: Int
  }

  /// The caret's line fragment as a `GhostLine`; nil when the caret is outside the visible rect.
  /// The right edge is the fragment's, within the view's frame and the visible rect: with wrap
  /// off the container is far wider than the frame, and the frame as wide as the widest line.
  /// Lines after the first show only when the left edge of the text is in view, down to the last
  /// one fully inside the visible rect.
  private func ghostCaretLine(
    _ layoutManager: NSLayoutManager, _ textContainer: NSTextContainer
  ) -> GhostLine? {
    let text = string as NSString
    let caret = selectedRange().location
    let origin = textContainerOrigin
    let padding = textContainer.lineFragmentPadding
    let left = origin.x + padding
    let visible = visibleRect
    func line(x: CGFloat, fragment: NSRect) -> GhostLine? {
      let y = fragment.minY + origin.y
      guard fragment.height > 0, visible.contains(NSPoint(x: x, y: y + fragment.height / 2))
      else { return nil }
      let right = min(
        fragment.maxX + origin.x - padding, bounds.maxX - textContainerInset.width - padding,
        visible.maxX - padding)
      // A small tolerance keeps a line that ends exactly at the bottom edge
      let fullLines = Int(((visible.maxY - y) / fragment.height + 0.001).rounded(.down))
      return GhostLine(
        x: x, y: y, height: fragment.height, left: left, right: right,
        lines: left >= visible.minX ? max(1, fullLines) : 1)
    }
    if caret >= text.length && (text.length == 0 || string.last?.isNewline == true) {
      let rect = layoutManager.extraLineFragmentRect
      if !rect.isEmpty { return line(x: rect.minX + padding + origin.x, fragment: rect) }
      guard text.length > 0 else { return nil }
    }
    let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, text.length - 1))
    let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let x =
      caret < text.length
      ? fragment.minX + layoutManager.location(forGlyphAt: glyph).x
      : layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
      ).maxX
    return line(x: x + origin.x, fragment: fragment)
  }
}
