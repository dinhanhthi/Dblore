// SQLTextViewGhostTextTests.swift
// AI ghost text in the SQL editor: opt-in, overlay only, Tab/Esc, and where it is wired

import AppKit
import SwiftUI
import Testing

@testable import Dblore

/// Replies at once with `reply` to every request
nonisolated private final class ImmediateInlineClient: AIChatClient, @unchecked Sendable {
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

@Suite("SQL Text View Ghost Text")
@MainActor
struct SQLTextViewGhostTextTests {
  private static let typed = "SELECT * FROM "
  private static let suggestion = "orders"

  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
    backing: .buffered, defer: false)

  private func makeController(
    reply: String = suggestion, enabled: Bool = true
  ) -> AIInlineCompletionController {
    let config = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      inlineEnabled: enabled)
    let client = ImmediateInlineClient(reply: reply)
    let controller = AIInlineCompletionController(
      configuration: { config }, makeClient: { _ in client }, sleep: { _ in })
    controller.isAllowed = { true }
    controller.source = { (.postgresql, false) }
    return controller
  }

  /// Focused text view in a window with the editor's own undo stack, as `makeNSView` wires it
  private func makeEditor(
    _ controller: AIInlineCompletionController?, width: CGFloat = 600
  ) -> (SQLTextView, HighlightedTextEditorRepresentable.Coordinator) {
    let coordinator = HighlightedTextEditorRepresentable.Coordinator(
      text: .constant(""), height: .constant(40), isEmpty: .constant(true), onTextChanged: nil)
    let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
    textView.delegate = coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    coordinator.textView = textView
    window.contentView?.addSubview(textView)
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    textView.inlineCompletion = controller
    return (textView, coordinator)
  }

  /// Focused text view in a 200-point wide scroll view of `height`, with word wrap off as
  /// `configureWordWrapIfNeeded` sets it: its frame grows to the widest line, past the visible
  /// rect
  private func makeScrolledEditor(
    _ controller: AIInlineCompletionController, height: CGFloat = 200
  ) -> (SQLTextView, NSScrollView) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
    window.contentView?.addSubview(scrollView)
    let (textView, coordinator) = makeEditor(controller, width: 200)
    textView.textContainerInset = NSSize(width: 4, height: 2)
    textView.textContainer?.lineFragmentPadding = 0
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    scrollView.documentView = textView
    coordinator.configureWordWrapIfNeeded(false, scrollView: scrollView, textView: textView)
    // A scroller would take part of the height, more or less with the system's scroller style
    scrollView.hasHorizontalScroller = false
    window.makeFirstResponder(textView)
    return (textView, scrollView)
  }

  /// Sets the text and the caret, then asks for a suggestion as an edit would
  private func show(
    _ text: String, caret: Int, in textView: SQLTextView,
    controller: AIInlineCompletionController
  ) async {
    textView.string = text
    textView.setSelectedRange(NSRange(location: caret, length: 0))
    textView.sizeToFit()
    await ask(textView, controller: controller)
  }

  /// Asks for a suggestion at the caret as an edit would
  private func ask(_ textView: SQLTextView, controller: AIInlineCompletionController) async {
    controller.textDidChange(text: textView.string, caret: textView.selectedRange().location)
    await controller.task?.value
  }

  private func scroll(_ scrollView: NSScrollView, to point: NSPoint) {
    scrollView.contentView.scroll(to: point)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// Caret x and the width of `ghost` in the editor font, in view coordinates
  private func ghostSpan(_ ghost: String, in textView: SQLTextView) throws -> ClosedRange<CGFloat> {
    let layoutManager = try #require(textView.layoutManager)
    let textContainer = try #require(textView.textContainer)
    let caret = textView.selectedRange().location
    let caretX =
      textView.textContainerOrigin.x
      + layoutManager.boundingRect(
        forGlyphRange: layoutManager.glyphRange(
          forCharacterRange: NSRange(location: caret - 1, length: 1), actualCharacterRange: nil),
        in: textContainer
      ).maxX
    let font = try #require(textView.font)
    return caretX...(caretX + (ghost as NSString).size(withAttributes: [.font: font]).width)
  }

  /// Types `text` as one undo group, then waits for the typing pause and the reply
  private func type(
    _ text: String, in textView: SQLTextView, controller: AIInlineCompletionController
  ) async {
    group(textView) { textView.insertText(text, replacementRange: textView.selectedRange()) }
    await controller.task?.value
  }

  /// One undo group, as one key event makes
  private func group(_ textView: NSTextView, _ body: () -> Void) {
    textView.undoManager?.beginUndoGrouping()
    body()
    textView.undoManager?.endUndoGrouping()
  }

  private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
  }

  private func draw(_ textView: NSTextView) {
    guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
      Issue.record("no bitmap")
      return
    }
    textView.cacheDisplay(in: textView.bounds, to: bitmap)
  }

  // MARK: - Opt-in

  @Test("ghost text is off unless the editor opts in")
  func defaultsOff() {
    let editor = HighlightedTextEditor(
      text: .constant(""), textViewRef: .constant(nil), isEmpty: .constant(true))
    #expect(editor.inlineCompletion == nil)
    let cellEditor = SQLEditorView(
      content: .constant(""), isSelected: true, isFocused: true, textViewRef: .constant(nil))
    #expect(cellEditor.inlineCompletion == nil)
    #expect(SQLTextView().inlineCompletion == nil)
  }

  @Test("a MongoDB query field or a read-only editor never takes ghost text")
  func neverOnMongoOrReadOnly() {
    let controller = makeController()
    let mongo = MongoQueryTextView()
    mongo.inlineCompletion = controller
    #expect(mongo.inlineCompletion == nil)

    var representable = HighlightedTextEditorRepresentable(
      text: .constant(""), height: .constant(40), isEmpty: .constant(true),
      textViewRef: .constant(nil), mongoQueryEditing: true, inlineCompletion: controller)
    #expect(representable.shownInlineCompletion == nil)
    representable.mongoQueryEditing = false
    representable.isEditable = false
    #expect(representable.shownInlineCompletion == nil)
    representable.isEditable = true
    #expect(representable.shownInlineCompletion === controller)
  }

  // MARK: - Overlay

  @Test("typing in the focused editor asks once the typing pause ends")
  func typingRequests() async {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)
    #expect(textView.visibleGhostText == Self.suggestion)
  }

  @Test("an edit of an unfocused editor never asks")
  func unfocusedEditDoesNotRequest() {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    window.makeFirstResponder(nil)
    group(textView) { textView.insertText(Self.typed, replacementRange: textView.selectedRange()) }
    #expect(controller.task == nil)
    #expect(textView.visibleGhostText == nil)
  }

  @Test("the overlay never changes the text or the undo stack")
  func overlayDoesNotMutate() async {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    textView.string = Self.typed
    textView.setSelectedRange(NSRange(location: (Self.typed as NSString).length, length: 0))
    controller.textDidChange(text: textView.string, caret: textView.selectedRange().location)
    await controller.task?.value
    #expect(textView.visibleGhostText == Self.suggestion)

    draw(textView)

    #expect(textView.string == Self.typed)
    #expect(textView.textStorage?.string == Self.typed)
    #expect(textView.undoManager?.canUndo == false)
  }

  @Test("a multi-line suggestion draws over the blank lines below without touching the text")
  func multiLineOverlay() async {
    let controller = makeController(reply: "orders\nWHERE id = 1")
    let (textView, _) = makeEditor(controller)
    textView.string = "\n\n"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    await type(Self.typed, in: textView, controller: controller)
    #expect(textView.visibleGhostText == "orders\nWHERE id = 1")
    draw(textView)
    #expect(textView.string == Self.typed + "\n\n")
  }

  @Test("text on a line below cuts the suggestion to its first line; Tab inserts only that")
  func textBelowKeepsOneLine() async throws {
    let controller = makeController(reply: "orders\nWHERE id = 1")
    let (textView, _) = makeEditor(controller)
    textView.string = "\nSELECT 2"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    await type(Self.typed, in: textView, controller: controller)
    #expect(textView.visibleGhostText == "orders")

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }
    #expect(textView.string == Self.typed + "orders\nSELECT 2")
  }

  @Test("a suggestion wider than the room left is cut to what shows; Tab inserts only that")
  func narrowEditorCutsToWhatFits() async throws {
    let reply = "orders WHERE status = 'paid' ORDER BY created_at DESC\nLIMIT 10"
    let controller = makeController(reply: reply)
    let (textView, _) = makeEditor(controller, width: 200)
    // Blank lines below let the second line through; the cut first line drops it
    textView.string = "\n\n"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    await type(Self.typed, in: textView, controller: controller)
    #expect(controller.suggestion?.text == reply)
    let visible = try #require(textView.visibleGhostText)
    #expect(reply.hasPrefix(visible) && visible.count < reply.count && !visible.contains("\n"))

    let layoutManager = try #require(textView.layoutManager)
    let textContainer = try #require(textView.textContainer)
    let caretX =
      textView.textContainerOrigin.x
      + layoutManager.boundingRect(
        forGlyphRange: layoutManager.glyphRange(
          forCharacterRange: NSRange(location: 0, length: Self.typed.utf16.count),
          actualCharacterRange: nil), in: textContainer
      ).maxX
    let font = try #require(textView.font)
    let right = textView.bounds.maxX - textContainer.lineFragmentPadding
    #expect(caretX + (visible as NSString).size(withAttributes: [.font: font]).width <= right)
    draw(textView)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }
    #expect(textView.string == Self.typed + visible + "\n\n")
  }

  @Test("with wrap off and a wider line below, the suggestion is cut at the visible edge")
  func wrapOffCutsAtVisibleEdge() async throws {
    let reply = "orders WHERE status = 'paid' ORDER BY created_at DESC"
    let controller = makeController(reply: reply)
    let (textView, scrollView) = makeScrolledEditor(controller)
    let below = "\n-- " + String(repeating: "x", count: 60)
    await show(
      Self.typed + below, caret: Self.typed.utf16.count, in: textView, controller: controller)
    try #require(textView.frame.width > scrollView.contentView.bounds.width)
    let visible = try #require(textView.visibleGhostText)
    #expect(reply.hasPrefix(visible) && visible.count < reply.count)
    #expect(try ghostSpan(visible, in: textView).upperBound <= textView.visibleRect.maxX)
    draw(textView)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }
    #expect(textView.string == Self.typed + visible + below)
  }

  @Test("with wrap off and the editor scrolled right, only the caret line shows; Tab inserts it")
  func wrapOffScrolledRightKeepsCaretLine() async throws {
    let controller = makeController(reply: "orders\nWHERE id = 1")
    let (textView, scrollView) = makeScrolledEditor(controller)
    let above = "-- " + String(repeating: "x", count: 60) + "\n"
    let caret = (above + Self.typed).utf16.count
    await show(above + Self.typed + "\n\n", caret: caret, in: textView, controller: controller)
    #expect(textView.visibleGhostText == "orders\nWHERE id = 1")

    // Scrolled past the caret, the suggestion that arrives shows nothing (Tab is a plain tab)
    scroll(scrollView, to: NSPoint(x: 150, y: 0))
    await ask(textView, controller: controller)
    #expect(controller.suggestion != nil)
    #expect(textView.visibleGhostText == nil)

    scroll(scrollView, to: NSPoint(x: 50, y: 0))
    try #require(textView.visibleRect.minX == 50)
    await ask(textView, controller: controller)
    let visible = try #require(textView.visibleGhostText)
    #expect(visible == "orders")
    let span = try ghostSpan(visible, in: textView)
    #expect(span.lowerBound >= textView.visibleRect.minX)
    #expect(span.upperBound <= textView.visibleRect.maxX)
    draw(textView)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }
    #expect(textView.string == above + Self.typed + "orders\n\n")
  }

  @Test("lines below the visible rect are not shown; Tab inserts only the lines that show")
  func linesBelowVisibleRectDropped() async throws {
    let controller = makeController(reply: "orders\nWHERE id = 1\nLIMIT 10")
    let (textView, _) = makeScrolledEditor(controller, height: 42)
    await show(
      Self.typed + "\n\n", caret: Self.typed.utf16.count, in: textView, controller: controller)
    let layoutManager = try #require(textView.layoutManager)
    let line = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let top = line.minY + textView.textContainerOrigin.y
    // Two full lines fit in the visible rect, the third is cut by its bottom edge
    try #require(top + 2 * line.height <= textView.visibleRect.maxY)
    try #require(top + 3 * line.height > textView.visibleRect.maxY)
    #expect(textView.visibleGhostText == "orders\nWHERE id = 1")
    draw(textView)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }
    #expect(textView.string == Self.typed + "orders\nWHERE id = 1\n\n")
  }

  @Test("a scroll dismisses the suggestion, so no ghost text is left from before it")
  func scrollDismisses() async throws {
    let controller = makeController()
    let (textView, scrollView) = makeScrolledEditor(controller, height: 40)
    await show(
      Self.typed + "\n\n\n\n", caret: Self.typed.utf16.count, in: textView,
      controller: controller)
    #expect(textView.visibleGhostText == Self.suggestion)
    draw(textView)

    scroll(scrollView, to: NSPoint(x: 0, y: 5))
    #expect(controller.suggestion == nil)
    #expect(textView.visibleGhostText == nil)
    #expect(textView.string == Self.typed + "\n\n\n\n")
  }

  @Test("a scroll before the suggestion arrives keeps the request, as typing scrolls")
  func scrollKeepsPendingRequest() async {
    let controller = makeController()
    let (textView, scrollView) = makeScrolledEditor(controller, height: 40)
    textView.string = Self.typed + "\n\n\n\n"
    textView.setSelectedRange(NSRange(location: Self.typed.utf16.count, length: 0))
    textView.sizeToFit()
    controller.textDidChange(text: textView.string, caret: textView.selectedRange().location)
    scroll(scrollView, to: NSPoint(x: 0, y: 5))
    scroll(scrollView, to: .zero)
    await controller.task?.value
    #expect(textView.visibleGhostText == Self.suggestion)
  }

  @Test("after a final line break of any kind the suggestion starts on the new line")
  func finalLineBreakOfAnyKind() async {
    for lineBreak in ["\r", "\u{2028}"] {
      let controller = makeController(reply: "WHERE id = 1")
      let (textView, _) = makeEditor(controller, width: 200)
      let text = "SELECT * FROM orders" + lineBreak
      await show(text, caret: text.utf16.count, in: textView, controller: controller)
      #expect(textView.visibleGhostText == "WHERE id = 1", "\(lineBreak.unicodeScalars.first!)")
    }
  }

  @Test("typing with text after the caret on its line asks nothing")
  func midLineDoesNotRequest() async {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    textView.string = "* FROM orders"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    await type("SELECT ", in: textView, controller: controller)
    #expect(controller.suggestion == nil)
    #expect(textView.visibleGhostText == nil)
  }

  @Test("with ghost text off, an edit sends nothing")
  func disabledEditDoesNotRequest() {
    let controller = makeController(enabled: false)
    let (textView, _) = makeEditor(controller)
    group(textView) { textView.insertText(Self.typed, replacementRange: textView.selectedRange()) }
    #expect(controller.task == nil)
    #expect(controller.version == 0)
  }

  @Test("moving the caret hides the suggestion")
  func caretMoveHides() async {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(textView.visibleGhostText == nil)
    #expect(controller.suggestion == nil)
  }

  // MARK: - Keys

  @Test("Tab accepts the suggestion as one undo step")
  func tabAccepts() async throws {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }

    #expect(textView.string == Self.typed + Self.suggestion)
    #expect(textView.selectedRange().location == (textView.string as NSString).length)
    #expect(textView.visibleGhostText == nil)
    textView.undoManager?.undo()
    #expect(textView.string == Self.typed)
    textView.undoManager?.redo()
    #expect(textView.string == Self.typed + Self.suggestion)
  }

  @Test("Tab with the autocomplete popup open does not accept the suggestion")
  func tabWithPopupDoesNotAccept() async throws {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)
    textView.setAutocompleteSuggestions([
      AutocompleteSuggestion(text: "users", type: .table, description: nil)
    ])
    #expect(textView.handleGhostTextKey(with: try key(48, "\t")) == false)

    let tab = try key(48, "\t")
    group(textView) { textView.keyDown(with: tab) }

    #expect(!textView.string.contains(Self.suggestion))
    textView.hideAutocomplete()
  }

  @Test("Tab without a suggestion keeps its usual behavior")
  func tabWithoutSuggestion() throws {
    let (textView, _) = makeEditor(makeController())
    #expect(textView.handleGhostTextKey(with: try key(48, "\t")) == false)
  }

  @Test("Esc dismisses the suggestion and keeps the text")
  func escapeDismisses() async throws {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)

    let escape = try key(53, "\u{1b}")
    group(textView) { textView.keyDown(with: escape) }

    #expect(textView.visibleGhostText == nil)
    #expect(controller.suggestion == nil)
    #expect(textView.string == Self.typed)
    #expect(textView.handleGhostTextKey(with: try key(53, "\u{1b}")) == false)
  }

  @Test("focus loss drops the suggestion")
  func focusLossDrops() async {
    let controller = makeController()
    let (textView, _) = makeEditor(controller)
    await type(Self.typed, in: textView, controller: controller)
    window.makeFirstResponder(nil)
    #expect(textView.visibleGhostText == nil)
  }

  // MARK: - Wiring

  private func makeViewModel(_ databaseType: DatabaseType) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = ConnectionConfig(
      databaseType: databaseType, host: "h", port: 1, database: "d", username: "u")
    return viewModel
  }

  @Test("SQL tabs and cells get one controller each, gated by the workspace")
  func wiringForSQL() throws {
    let viewModel = makeViewModel(.postgresql)
    let cellId = UUID()
    let cell = try #require(viewModel.aiInlineCompletion(cellId: cellId))
    #expect(viewModel.aiInlineCompletion(cellId: cellId) === cell)
    let editor = try #require(viewModel.aiInlineCompletion(cellId: nil))
    #expect(editor !== cell)
    #expect(cell.source()?.dialect == .postgresql)
    #expect(cell.isAllowed() == false)
    viewModel.isAIAllowed = { true }
    #expect(cell.isAllowed())
  }

  @Test("MongoDB and read-only source tabs get no ghost text")
  func wiringNeverForMongoOrSource() {
    let mongo = makeViewModel(.mongodb)
    #expect(mongo.aiInlineSource == nil)
    #expect(mongo.aiInlineCompletion(cellId: nil) == nil)
    #expect(mongo.aiInlineCompletion(cellId: UUID()) == nil)

    let source = makeViewModel(.postgresql)
    source.objectSourceLoad = .loaded
    #expect(source.aiInlineSource == nil)
    #expect(source.aiInlineCompletion(cellId: nil) == nil)
  }

  @Test("without a workspace the schema closure sends no schema")
  func wiringSchemaNeedsWorkspace() async throws {
    let viewModel = makeViewModel(.postgresql)
    viewModel.databaseTables = [DatabaseTable(schema: "public", name: "invoices", columns: [])]
    let controller = try #require(viewModel.aiInlineCompletion(cellId: nil))
    #expect(await controller.schema("SELECT * FROM inv") == nil)
  }

  /// A workspace on an allowed connection with one table loaded, and its notebook tab's editor
  /// ghost text controller
  private func makeWorkspace() -> (WorkspaceManager, AIInlineCompletionController?) {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "h.example", port: 1, database: "db", username: "u")
    config.aiAccess = .always
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    let gate = AIAccessGate()
    manager.aiAccessSource = { [weak manager] in
      manager?.workspace.connectionConfig.map {
        AIAccessContext(config: $0, savedPolicies: [], gate: gate)
      }
    }
    manager.databaseTables = [DatabaseTable(schema: "public", name: "invoices", columns: [])]
    manager.newNotebook()
    return (manager, manager.activeViewModel?.aiInlineCompletion(cellId: nil))
  }

  @Test("no schema until the current connection's schema load lands, then its tables")
  func wiringSchemaAfterLoad() async throws {
    let (manager, controller) = makeWorkspace()
    let ghost = try #require(controller)
    manager.schemaConnectionEpoch = nil
    #expect(await ghost.schema("SELECT * FROM inv") == nil)
    manager.schemaConnectionEpoch = 1
    #expect(await ghost.schema("SELECT * FROM inv") == "public.invoices()")
  }

  @Test("the schema is dropped when the connection's schema changes while it is built")
  func wiringSchemaEpochChanges() async throws {
    let (manager, controller) = makeWorkspace()
    let ghost = try #require(controller)
    manager.schemaConnectionEpoch = 1
    let source = manager.aiAccessSource
    var reads = 0
    // The first gate read is before the build: the schema of another connection lands then
    manager.aiAccessSource = { [weak manager] in
      reads += 1
      if reads == 1 { manager?.schemaConnectionEpoch = 2 }
      return source()
    }
    #expect(await ghost.schema("SELECT * FROM inv") == nil)
  }

  @Test("a deleted cell's controller is dropped with the next one made; the editor tab's stays")
  func deletedCellControllerPruned() throws {
    let viewModel = makeViewModel(.postgresql)
    viewModel.addCell(type: .sql, after: nil)
    viewModel.addCell(type: .sql, after: nil)
    let cells = viewModel.notebook.cells.map(\.id)
    let deleted = try #require(cells.last)
    let kept = try #require(cells.first)
    _ = viewModel.aiInlineCompletion(cellId: deleted)
    let editor = viewModel.aiInlineCompletion(cellId: nil)
    viewModel.deleteCell(id: deleted)
    _ = viewModel.aiInlineCompletion(cellId: kept)
    #expect(viewModel.aiInlineCompletions[deleted] == nil)
    #expect(viewModel.aiInlineCompletions[viewModel.id] === editor)
    #expect(viewModel.aiInlineCompletions.count == 2)
  }

  @Test("a controller made for a SQL tab sends nothing once it shows a read-only source")
  func sourceTurnsReadOnly() throws {
    let viewModel = makeViewModel(.postgresql)
    let controller = try #require(viewModel.aiInlineCompletion(cellId: nil))
    viewModel.objectSourceLoad = .loading
    #expect(controller.source() == nil)
  }
}
