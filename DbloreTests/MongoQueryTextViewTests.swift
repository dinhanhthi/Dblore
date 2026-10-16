// MongoQueryTextViewTests.swift
// The MongoDB query field's text view: a suggestion accepted inside an auto-closed pair goes
// through the inherited accept path and leaves the caret before the closers.

import AppKit
import Testing

@testable import Dblore

@Suite("Mongo query text view")
@MainActor
struct MongoQueryTextViewTests {
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled],
    backing: .buffered, defer: false)

  @Test("accepting a suggestion inside a pair keeps the caret before the closer")
  func acceptKeepsCaretBeforeCloser() {
    let textView = MongoQueryTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    textView.isRichText = false
    window.contentView?.addSubview(textView)
    window.makeFirstResponder(textView)
    textView.string = "{sta}"
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    textView.acceptSuggestion(
      AutocompleteSuggestion(text: "{status}", type: .keyword, description: nil))

    #expect(textView.string == "{status}")
    #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
  }
}
