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

}
