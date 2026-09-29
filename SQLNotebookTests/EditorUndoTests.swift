// EditorUndoTests.swift
// Undo/redo isolation of the SQL editor (HighlightedTextEditor coordinator)

import AppKit
import SwiftUI
import Testing

@testable import SQLNotebook

@Suite("Editor Undo Tests")
@MainActor
struct EditorUndoTests {
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
    backing: .buffered, defer: false)

  /// Text view wired like `makeNSView` does, with the coordinator as delegate
  private func makeEditor(
    y: CGFloat
  ) -> (SQLTextView, HighlightedTextEditorRepresentable.Coordinator) {
    let coordinator = HighlightedTextEditorRepresentable.Coordinator(
      text: .constant(""), height: .constant(40), isEmpty: .constant(true), onTextChanged: nil)
    let textView = SQLTextView(frame: NSRect(x: 0, y: y, width: 600, height: 200))
    textView.delegate = coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    coordinator.textView = textView
    window.contentView?.addSubview(textView)
    return (textView, coordinator)
  }

  /// Type `text` as one undo group
  private func type(_ text: String, in textView: NSTextView) {
    window.makeFirstResponder(textView)
    let undoManager = textView.undoManager
    undoManager?.groupsByEvent = false
    undoManager?.beginUndoGrouping()
    textView.insertText(text, replacementRange: textView.selectedRange())
    undoManager?.endUndoGrouping()
  }

  @Test("Undo in one editor does not change another editor")
  func undoIsPerEditor() {
    let (a, _) = makeEditor(y: 0)
    let (b, _) = makeEditor(y: 200)
    type("SELECT 1", in: a)

    window.makeFirstResponder(b)
    #expect(b.undoManager?.canUndo == false)
    b.undoManager?.undo()

    #expect(a.string == "SELECT 1")
  }

  @Test("Undo and redo restore the editor's own text")
  func undoRedoOwnText() {
    let (a, _) = makeEditor(y: 0)
    type("SELECT 1", in: a)
    type(" + 2", in: a)

    a.undoManager?.undo()
    #expect(a.string == "SELECT 1")
    a.undoManager?.redo()
    #expect(a.string == "SELECT 1 + 2")
  }

  @Test("Replacing the whole text from outside clears the undo history")
  func externalReplaceClearsHistory() {
    let (a, coordinator) = makeEditor(y: 0)
    type("SELECT 1", in: a)

    coordinator.applyHighlighting(to: a, text: "SELECT 42")

    #expect(a.undoManager?.canUndo == false)
    #expect(a.string == "SELECT 42")
  }
}
