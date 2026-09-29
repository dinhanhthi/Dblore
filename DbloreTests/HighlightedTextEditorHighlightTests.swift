// HighlightedTextEditorHighlightTests.swift
// The editor's incremental highlighting path, on a real SQLTextView in an offscreen window.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Highlighted Text Editor Highlight Tests")
@MainActor
struct HighlightedTextEditorHighlightTests {
  private let base = """
    SELECT count(id), name FROM users WHERE id > 10; -- note
    /* block
    comment */
    SELECT 'it''s' AS s, now() FROM orders;
    UPDATE items SET total = 5 WHERE status = 'open';
    """

  private func same(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    guard let l = lhs.usingColorSpace(.sRGB), let r = rhs.usingColorSpace(.sRGB) else {
      return false
    }
    return abs(l.redComponent - r.redComponent) < 0.001
      && abs(l.greenComponent - r.greenComponent) < 0.001
      && abs(l.blueComponent - r.blueComponent) < 0.001
  }

  /// Every UTF-16 unit of the storage has the foreground color and font of a fresh full highlight
  private func matchesFullHighlight(_ host: OffscreenEditorHost) -> Bool {
    let storage = host.textView.textStorage!
    let expected = SQLSyntaxHighlighter.highlight(storage.string)
    guard expected.length == storage.length else { return false }
    for i in 0..<storage.length {
      let a = storage.attributes(at: i, effectiveRange: nil)
      let e = expected.attributes(at: i, effectiveRange: nil)
      if !same(a[.foregroundColor] as? NSColor, e[.foregroundColor] as? NSColor) { return false }
      if (a[.font] as? NSFont) != (e[.font] as? NSFont) { return false }
    }
    return true
  }

  private func type(_ string: String, at location: Int, in host: OffscreenEditorHost) {
    host.textView.setSelectedRange(NSRange(location: location, length: 0))
    host.textView.insertText(string, replacementRange: NSRange(location: location, length: 0))
    host.fireTextDidChange()
  }

  @Test("typed text ends with the same attributes as a full highlight")
  func typedTextMatchesFullHighlight() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      let ns = host.textView.string as NSString
      type("SELECT ", at: ns.range(of: "UPDATE").location, in: host)
      type("/*", at: (host.textView.string as NSString).range(of: "'it").location, in: host)
      #expect(matchesFullHighlight(host))
      type("*/", at: (host.textView.string as NSString).range(of: " AS s").location, in: host)
      #expect(matchesFullHighlight(host))
    }
  }

  @Test("paste of a multi-line comment recolors the following lines")
  func pasteMultiLineComment() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      // the pasted "/*" is closed by the existing "*/" three lines below
      type("/* one\ntwo\n", at: 0, in: host)
      #expect(matchesFullHighlight(host))
      // the first SELECT now sits inside a comment
      let update = (host.textView.string as NSString).range(of: "SELECT").location
      let color =
        host.textView.textStorage!.attribute(.foregroundColor, at: update, effectiveRange: nil)
        as? NSColor
      #expect(same(color, SQLSyntaxHighlighter.Palette().comment))
    }
  }

  @Test("two edits before one highlight pass take the full path and end correct")
  func twoEditsBeforeOnePass() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      let storage = host.textView.textStorage!
      let ns = storage.string as NSString
      let before = host.coordinator.fullFallbackCount
      storage.replaceCharacters(
        in: NSRange(location: ns.range(of: "UPDATE").location, length: 0), with: "/*")
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- ")
      host.fireTextDidChange()
      #expect(host.coordinator.fullFallbackCount == before + 1)
      #expect(matchesFullHighlight(host))
    }
  }

  @Test("a pass without a window invalidates pending edits so the next pass is full")
  func windowlessPassInvalidatesPending() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      let storage = host.textView.textStorage!
      host.window.contentView = nil
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
      host.coordinator.applyIncrementalHighlighting(to: host.textView)  // no window: early return
      host.window.contentView = host.scrollView
      let before = host.coordinator.fullFallbackCount
      storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: " x")
      host.fireTextDidChange()
      #expect(host.coordinator.fullFallbackCount == before + 1)
      #expect(matchesFullHighlight(host))
    }
  }

  @Test(
    "highlighting registers no undo: type, undo restores prior text, canUndo false after one undo")
  func highlightingRegistersNoUndo() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      let undoManager = host.textView.undoManager!
      undoManager.removeAllActions()
      undoManager.groupsByEvent = false
      let before = host.textView.string
      undoManager.beginUndoGrouping()
      type("SELECT ", at: 0, in: host)
      undoManager.endUndoGrouping()
      #expect(host.textView.string != before)
      undoManager.undo()
      #expect(host.textView.string == before)
      #expect(!undoManager.canUndo)
    }
  }

  @Test("search-active path keeps search backgrounds")
  func searchActiveKeepsBackgrounds() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: base)
      defer { host.close() }
      host.coordinator.searchQuery = "users"
      host.coordinator.isSearchActive = true
      type("x", at: 0, in: host)
      let storage = host.textView.textStorage!
      let ns = storage.string as NSString
      let match = ns.range(of: "users")
      let bg = storage.attribute(.backgroundColor, at: match.location, effectiveRange: nil)
      #expect(bg != nil)
      let none = storage.attribute(.backgroundColor, at: 0, effectiveRange: nil)
      #expect(none == nil)
    }
  }

  @Test("updateNSView with unchanged wrap does not reconfigure the container")
  func unchangedWrapDoesNotReconfigure() {
    let host = OffscreenEditorHost(text: base)
    defer { host.close() }
    let c = host.coordinator
    c.configureWordWrapIfNeeded(true, scrollView: host.scrollView, textView: host.textView)
    #expect(c.wordWrapReconfigureCount == 1)
    c.configureWordWrapIfNeeded(true, scrollView: host.scrollView, textView: host.textView)
    #expect(c.wordWrapReconfigureCount == 1)
    c.configureWordWrapIfNeeded(false, scrollView: host.scrollView, textView: host.textView)
    #expect(c.wordWrapReconfigureCount == 2)
    #expect(host.textView.textContainer?.widthTracksTextView == false)
    #expect(host.scrollView.hasHorizontalScroller)
  }
}
