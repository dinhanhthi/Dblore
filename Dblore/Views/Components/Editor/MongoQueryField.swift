//
//  MongoQueryField.swift
//  Dblore
//
//  MongoDB query field: a filter or stage body editor of one to five lines. Return submits,
//  Shift+Return adds an indented line, brackets and quotes pair (rules in QueryFieldEditing),
//  field names complete through the inherited SQLTextView popover, and the text is colored as
//  mongosh.
//

import AppKit
import SwiftUI

// MARK: - Field

/// The field callers place in a bar. Apply `.inputStyle()` around it (a capsule would turn into a
/// tall pill at several lines). The height follows the hard line count of `text` (1 to 5 lines,
/// then the field scrolls), never measured layout: lines do not wrap, long ones scroll sideways.
struct MongoQueryField: View {
  @Binding var text: String
  var placeholder: String = ""
  /// Usually a `MongoDocumentAutocompleteProvider` for the shown collection
  var autocompleteProvider: SQLAutocompleteProvider?
  var onSubmit: () -> Void = {}

  /// The NSFont of `Font.monoSmall` (footnote, monospaced)
  static let font = NSFont.monospacedSystemFont(
    ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
  static let maxLines = 5
  static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

  /// Height for `text`: hard lines (`\n` count + 1) clamped to 1...maxLines, times the line height
  static func height(for text: String) -> CGFloat {
    let lines = text.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    return CGFloat(min(max(lines, 1), maxLines)) * lineHeight
  }

  /// Height of a one-line field inside `.inputStyle()` (its `Spacing.sm` padding on both sides).
  /// Controls beside the field sit centered in this height in a top-aligned row: centered next
  /// to one line, level with the first line once the field grows.
  static let styledLineHeight = lineHeight + 2 * Spacing.sm

  var body: some View {
    MongoQueryFieldRepresentable(
      text: $text, autocompleteProvider: autocompleteProvider, onSubmit: onSubmit
    )
    .frame(height: Self.height(for: text))
    .overlay(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .allowsHitTesting(false)
      }
    }
  }
}

// MARK: - Text View

/// SQLTextView with the query field keys. `viewModelId` stays nil, so the notebook cell
/// shortcuts and arrow navigation of the base class are off.
final class MongoQueryTextView: SQLTextView {
  var onSubmit: (() -> Void)?

  private static let pairKeys: Set<Character> = ["{", "[", "\"", "'", "}", "]"]
  /// Set while `apply` inserts its edit, so that insertion is not taken as typing again
  private var isApplyingEdit = false
  /// The caret when accepting a suggestion selects its token (before inserting the suggestion
  /// over it), so the insertion still knows where the caret was in the token
  private var acceptCaret: Int?
  /// Mirrors the base class's accept flag, which is private there
  private var isAcceptingSuggestion = false

  override func setAcceptingSuggestionFlag(_ value: Bool) {
    isAcceptingSuggestion = value
    super.setAcceptingSuggestionFlag(value)
  }

  override func keyDown(with event: NSEvent) {
    acceptCaret = nil
    // Composing (IME, dead keys): Return commits the composition, no pairing
    if hasMarkedText() {
      super.keyDown(with: event)
      return
    }
    // Suggestions shown: Return / Tab / arrows go to the popover first. Escape never gets here:
    // the workspace key monitor turns it into `.unfocusEditor`, which the coordinator handles
    if !getAutocompleteSuggestions().isEmpty, handleAutocompleteNavigation(with: event) {
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    // The editor's Cmd+/ (SQL line comment) and Option+Z (word wrap) do not apply here
    if (event.keyCode == 44 && flags == .command) || (event.keyCode == 6 && flags == .option) {
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      if flags.isEmpty {
        hideAutocomplete()
        onSubmit?()
        return
      }
      if flags == .shift, apply(.newline) {
        return
      }
    }
    super.keyDown(with: event)
  }

  /// Pairing and stepping over closers, for a typed character whatever keys the layout uses.
  /// Only one pair character replacing the selection counts as typing: an autocomplete accept
  /// inserts a whole word, and the composition commit (marked text) inserts as is. An accepted
  /// suggestion inside an auto-closed pair keeps the caret before the closers.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string
    let caretBeforeAccept = acceptCaret
    acceptCaret = nil
    let typed =
      replacementRange.location == NSNotFound || replacementRange == selectedRange()
    if !isApplyingEdit, !hasMarkedText(), typed, let text, text.count == 1,
      let character = text.first, Self.pairKeys.contains(character),
      apply(.character(character))
    {
      return
    }
    if !isApplyingEdit, !hasMarkedText(), let caretBeforeAccept, let text,
      replacementRange.location != NSNotFound
    {
      let caret = QueryFieldEditing.caretAfterReplacing(
        replacementRange, in: self.string, caret: caretBeforeAccept, with: text)
      super.insertText(string, replacementRange: replacementRange)
      setSelectedRange(NSRange(location: caret, length: 0))
      return
    }
    super.insertText(string, replacementRange: replacementRange)
  }

  /// Notes the caret when accepting a suggestion selects its token: the accept flag is set
  /// before that selection, and the caret has no length yet
  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    let current = selectedRange()
    if isAcceptingSuggestion, !isApplyingEdit, current.length == 0, ranges.count == 1,
      ranges[0].rangeValue.length > 0
    {
      acceptCaret = current.location
    }
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
  }

  override func deleteBackward(_ sender: Any?) {
    if hasMarkedText() || !apply(.backspace) {
      super.deleteBackward(sender)
    }
  }

  /// Resets the whole text to the field face and colors it as mongosh. Attribute-only edits with
  /// undo registration off, so the undo stack and the selection stay as they are. The palette's
  /// colors are dynamic, so light/dark follows without a re-run. Skipped while composing (IME):
  /// resetting would drop the marked text underline; the commit runs it again.
  func applyHighlighting() {
    guard let textStorage, !hasMarkedText() else { return }
    let palette = SQLSyntaxHighlighter.Palette()
    let defaults: [NSAttributedString.Key: Any] = [
      .font: MongoQueryField.font, .foregroundColor: palette.foreground,
    ]
    let full = NSRange(location: 0, length: textStorage.length)
    if full.length > 0 {
      undoManager?.disableUndoRegistration()
      textStorage.beginEditing()
      textStorage.setAttributes(defaults, range: full)
      if AppSettings.shared.syntaxHighlightingEnabled {
        SQLSyntaxHighlighter.highlight(
          in: textStorage, range: full, palette: palette, dialect: .mongodb)
      }
      textStorage.endEditing()
      undoManager?.enableUndoRegistration()
    }
    typingAttributes = defaults
  }

  /// Applies the rule for `key` through insertText (undo and didChangeText), then moves the caret.
  /// Stepping over a closer only moves the caret: replacing it with itself would add an undo step
  /// that changes nothing.
  private func apply(_ key: QueryFieldEditing.Key) -> Bool {
    guard let edit = QueryFieldEditing.edit(for: key, in: string, selection: selectedRange())
    else { return false }
    if (string as NSString).substring(with: edit.range) == edit.replacement {
      // No text change, so didChangeText will not refresh the suggestions of the old caret
      hideAutocomplete()
      setSelectedRange(NSRange(location: edit.caret, length: 0))
      return true
    }
    isApplyingEdit = true
    insertText(edit.replacement, replacementRange: edit.range)
    isApplyingEdit = false
    setSelectedRange(NSRange(location: edit.caret, length: edit.selectionLength))
    return true
  }
}

// MARK: - Representable

struct MongoQueryFieldRepresentable: NSViewRepresentable {
  @Binding var text: String
  var autocompleteProvider: SQLAutocompleteProvider?
  var onSubmit: () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    let textView = MongoQueryTextView()

    textView.delegate = context.coordinator
    textView.dialect = .mongodb
    textView.autocompleteProvider = autocompleteProvider
    textView.onSubmit = onSubmit

    textView.isRichText = false
    textView.usesRuler = false
    textView.font = MongoQueryField.font
    textView.typingAttributes[.font] = MongoQueryField.font
    textView.textColor = NSColor(Color.foreground)
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.allowsUndo = true
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0

    // No soft wrap, so the hard-line height stays exact: long lines scroll sideways
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false

    textView.string = text
    textView.applyHighlighting()
    context.coordinator.observeNotifications(of: textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? MongoQueryTextView else { return }
    context.coordinator.text = $text
    textView.autocompleteProvider = autocompleteProvider
    textView.onSubmit = onSubmit
    // Only an outside change: setting `string` does not fire textDidChange, so no loop
    if textView.string != text {
      textView.string = text
      textView.applyHighlighting()
      // The old history points at text that no longer exists
      context.coordinator.undoManager.removeAllActions()
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    guard let textView = scrollView.documentView as? MongoQueryTextView else { return }
    textView.delegate = nil
    textView.hideAutocomplete()
    textView.onSubmit = nil
    coordinator.stopObservingNotifications()
    coordinator.undoManager.removeAllActions()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    /// Own stack: the window's would mix this field's edits with the notebook's
    let undoManager = UndoManager()
    private var observers: [NSObjectProtocol] = []

    init(text: Binding<String>) {
      self.text = text
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      undoManager
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
      (textView as? MongoQueryTextView)?.applyHighlighting()
    }

    /// The keyword color follows the accent and highlighting can be turned off in Settings.
    /// Escape arrives as `.unfocusEditor` (the workspace key monitor swallows the key): the
    /// focused field resigns, which also hides the suggestions.
    func observeNotifications(of textView: MongoQueryTextView) {
      observers = [Notification.Name.accentColorChanged, .syntaxHighlightingChanged].map {
        NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) {
          [weak textView] _ in
          Task { @MainActor [weak textView] in
            textView?.applyHighlighting()
          }
        }
      }
      observers.append(
        NotificationCenter.default.addObserver(forName: .unfocusEditor, object: nil, queue: .main) {
          [weak textView] _ in
          Task { @MainActor [weak textView] in
            guard let textView, textView.window?.firstResponder === textView else { return }
            textView.window?.makeFirstResponder(nil)
          }
        })
    }

    func stopObservingNotifications() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
    }
  }
}
