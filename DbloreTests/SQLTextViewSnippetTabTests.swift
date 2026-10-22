// SQLTextViewSnippetTabTests.swift
// What Tab does in the SQL editor when an autocomplete popup, a snippet session and ghost text
// may all be there at once

import AppKit
import Testing

@testable import Dblore

/// Replies at once with `reply` to every ghost text request
nonisolated private final class SnippetTabInlineClient: AIChatClient, @unchecked Sendable {
  let reply: String

  init(reply: String) { self.reply = reply }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIStreamEvent.self)
    continuation.yield(.text(reply))
    continuation.finish()
    return stream
  }

  func listModels() async throws -> [String] { [] }
}

/// The editor's own undo stack, as the editor's coordinator vends it. The coordinator itself
/// stays out: it blurs its text view on every `.unfocusEditor`, which any test running a cell
/// posts while these tests wait for ghost text.
@MainActor private final class SnippetTabUndoDelegate: NSObject, NSTextViewDelegate {
  let undoManager = UndoManager()

  func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
}

@Suite("SQL Text View Snippet Tab")
@MainActor
struct SQLTextViewSnippetTabTests {
  private static let ghost = "orders"
  /// Stop 1 is empty at the end of the text, so ghost text shows there; stop 2 is the `*`
  private static let body = "SELECT ${2:*} FROM ${1}"
  private static let expanded = "SELECT * FROM "

  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
    backing: .buffered, defer: false)

  private func makeController() -> AIInlineCompletionController {
    let config = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      inlineEnabled: true)
    let client = SnippetTabInlineClient(reply: Self.ghost)
    let controller = AIInlineCompletionController(
      configuration: { config }, makeClient: { _ in client }, sleep: { _ in })
    controller.isAllowed = { true }
    controller.source = { (.postgresql, false) }
    return controller
  }

  /// Focused editor with its own undo stack. Keep the delegate alive while the editor is used:
  /// the text view does not retain it.
  private func makeEditor(
    _ controller: AIInlineCompletionController?
  ) -> (SQLTextView, SnippetTabUndoDelegate) {
    let delegate = SnippetTabUndoDelegate()
    let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    textView.delegate = delegate
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    window.contentView?.addSubview(textView)
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    textView.inlineCompletion = controller
    return (textView, delegate)
  }

  /// Asks for ghost text at the caret, as an edit would
  private func askGhost(_ textView: SQLTextView, _ controller: AIInlineCompletionController) async {
    controller.textDidChange(text: textView.string, caret: textView.selectedRange().location)
    await controller.task?.value
  }

  /// One undo group, as one key event makes (the editor does not group by event)
  private func group(_ textView: NSTextView, _ body: () -> Void) {
    textView.undoManager?.beginUndoGrouping()
    body()
    textView.undoManager?.endUndoGrouping()
  }

  private func pressTab(_ textView: SQLTextView, shift: Bool = false) throws {
    let tab = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
        isARepeat: false, keyCode: 48))
    group(textView) { textView.keyDown(with: tab) }
  }

  @Test("Tab: the popup accepts, else the snippet moves on, else ghost text, else indent")
  func tabPrecedence() async throws {
    // 1. Popup open over a snippet session and ghost text: Tab accepts the suggestion
    let popupController = makeController()
    let (popup, popupDelegate) = makeEditor(popupController)
    group(popup) { popup.insertSnippet(Self.body, replacing: NSRange(location: 0, length: 0)) }
    await askGhost(popup, popupController)
    #expect(popup.visibleGhostText == Self.ghost)
    popup.setAutocompleteSuggestions([
      AutocompleteSuggestion(text: "users", type: .table, description: nil)
    ])
    try pressTab(popup)
    #expect(popup.string == Self.expanded + "users")
    popup.hideAutocomplete()

    // 2. Snippet session and ghost text: Tab goes to the next stop, the ghost stays out
    let sessionController = makeController()
    let (session, sessionDelegate) = makeEditor(sessionController)
    group(session) {
      session.insertSnippet(Self.body, replacing: NSRange(location: 0, length: 0))
    }
    #expect(session.selectedRange() == NSRange(location: 14, length: 0))
    await askGhost(session, sessionController)
    #expect(session.visibleGhostText == Self.ghost)
    try pressTab(session)
    #expect(session.string == Self.expanded)
    #expect(session.selectedRange() == NSRange(location: 7, length: 1))
    #expect(session.snippetSession != nil)
    try pressTab(session)
    #expect(session.selectedRange() == NSRange(location: 14, length: 0))
    #expect(session.snippetSession == nil)

    // 3. Ghost text only: Tab accepts it
    let ghostController = makeController()
    let (ghost, ghostDelegate) = makeEditor(ghostController)
    group(ghost) {
      ghost.insertText(Self.expanded, replacementRange: NSRange(location: 0, length: 0))
    }
    await askGhost(ghost, ghostController)
    try pressTab(ghost)
    #expect(ghost.string == Self.expanded + Self.ghost)

    // 4. Nothing else: Tab indents
    let (plain, plainDelegate) = makeEditor(nil)
    group(plain) { plain.insertText("SELECT", replacementRange: NSRange(location: 0, length: 0)) }
    try pressTab(plain)
    #expect(plain.string == "SELECT\t")
    // The text views keep their delegate unretained
    withExtendedLifetime((popupDelegate, sessionDelegate, ghostDelegate, plainDelegate)) {}
  }

  /// Types `text` at the selection, one undo group per character as keystrokes make
  private func type(_ text: String, in textView: SQLTextView) {
    for character in text {
      group(textView) {
        textView.insertText(String(character), replacementRange: textView.selectedRange())
      }
    }
  }

  @Test("stops follow typing in the current stop; an edit outside it ends the session")
  func stopsFollowEdits() throws {
    let (editor, editorDelegate) = makeEditor(nil)
    group(editor) {
      editor.insertSnippet(
        "SELECT ${1:a} FROM ${2:t} WHERE 1", replacing: NSRange(location: 0, length: 0))
    }
    #expect(editor.selectedRange() == NSRange(location: 7, length: 1))
    type("xyz", in: editor)
    #expect(editor.string == "SELECT xyz FROM t WHERE 1")
    try pressTab(editor)
    #expect(editor.selectedRange() == NSRange(location: 16, length: 1))
    #expect(editor.snippetSession != nil)
    // An edit away from the stop, which leaves the selection as it is
    editor.textStorage?.replaceCharacters(
      in: NSRange(location: (editor.string as NSString).length, length: 0), with: ";")
    #expect(editor.snippetSession == nil)

    // Adjacent empty stops: typing in stop 2 leaves stop 1, written before it, in place
    let (adjacent, adjacentDelegate) = makeEditor(nil)
    group(adjacent) {
      adjacent.insertSnippet("(${1}${2})", replacing: NSRange(location: 0, length: 0))
    }
    try pressTab(adjacent)
    type("b", in: adjacent)
    try pressTab(adjacent, shift: true)
    #expect(adjacent.string == "(b)")
    #expect(adjacent.selectedRange() == NSRange(location: 1, length: 0))
    #expect(adjacent.snippetSession?.index == 0)
    withExtendedLifetime((editorDelegate, adjacentDelegate)) {}
  }
}
