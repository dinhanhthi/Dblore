// HighlightedTextEditorInitialTextTests.swift
// An editor with a fixed height (the MongoDB document editor sheet) shows the text it opens with:
// it is created before it is in a window, and nothing redraws it afterwards.

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("Highlighted text editor - initial text")
@MainActor
struct HighlightedTextEditorInitialTextTests {
  private final class Box {
    var text: String
    var ref: SQLTextView?
    var isEmpty = false
    init(_ text: String) { self.text = text }
  }

  private static func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? [] + view.subviews.flatMap(textViews(in:))
  }

  @Test("A fixed-height editor shows its initial text without any later update")
  func fixedHeightEditorShowsItsInitialText() throws {
    let box = Box("{ city: \"Paris\" }")
    let editor = HighlightedTextEditor(
      text: Binding(get: { box.text }, set: { box.text = $0 }),
      textViewRef: Binding(get: { box.ref }, set: { box.ref = $0 }),
      isEmpty: Binding(get: { box.isEmpty }, set: { box.isEmpty = $0 }),
      maxHeight: 300, dialect: .mongodb)
    let host = NSHostingView(rootView: editor.frame(width: 568, height: 300))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    for _ in 0..<5 {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let textView = try #require(Self.textViews(in: host).first)
    #expect(textView.string == "{ city: \"Paris\" }")
    #expect(box.text == "{ city: \"Paris\" }")
  }
}
