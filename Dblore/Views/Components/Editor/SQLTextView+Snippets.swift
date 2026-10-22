//
//  SQLTextView+Snippets.swift
//  Dblore
//
//  SQL snippets in the editor: inserting an accepted snippet and moving through its tab stops
//

import AppKit

/// The tab stops of the snippet being filled in, as editor (UTF-16) ranges
nonisolated struct SnippetSession: Equatable, Sendable {
  /// Stops in visiting order; the last one is the final caret
  var stops: [NSRange]
  /// Where each stop was written in the text, as `SQLSnippet.Expansion.textOrder`
  var textOrder: [Int]
  /// The stop being edited
  var index = 0

  var current: NSRange { stops[index] }
  var isAtFinalStop: Bool { index == stops.count - 1 }

  /// Follows an edit of `editedRange` (new-text coordinates) that changed the length by `delta`.
  /// Only an edit inside the current stop keeps the session: the stop grows or shrinks, and the
  /// stops after it in the text move. A stop right at its end moves only when it was written
  /// after it (`${1}${2}`: typing in stop 2 leaves stop 1). False when the edit falls outside it.
  mutating func apply(editedRange: NSRange, delta: Int) -> Bool {
    let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
    let stop = current
    let end = NSMaxRange(stop)
    guard old.length >= 0, old.location >= stop.location, NSMaxRange(old) <= end
    else { return false }
    for other in stops.indices where other != index {
      let location = stops[other].location
      guard location > end || (location == end && textOrder[other] > textOrder[index])
      else { continue }
      stops[other].location += delta
    }
    stops[index].length += delta
    return true
  }

  /// True when `selection` lies within the current stop, its ends included
  func contains(_ selection: NSRange) -> Bool {
    selection.location >= current.location && NSMaxRange(selection) <= NSMaxRange(current)
  }
}

extension SQLTextView {

  /// Replaces `range` with the expanded `body` as one undo step, then selects its first stop.
  /// A body with stops starts a session that Tab moves through (see `handleSnippetKey`).
  func insertSnippet(_ body: String, replacing range: NSRange) {
    endSnippetSession()
    guard isEditable else { return }
    let expansion = SQLSnippet.expand(body)
    // Typing coalesces into one undo step: keep the snippet a step of its own
    breakUndoCoalescing()
    insertText(expansion.text, replacementRange: range)
    breakUndoCoalescing()
    let stops = expansion.stops.map {
      NSRange(location: range.location + $0.location, length: $0.length)
    }
    guard stops.count > 1 else {
      // The insert may have been refused: keep the caret within the text
      if let caret = stops.last {
        setSelectedRange(
          NSRange(location: min(caret.location, (string as NSString).length), length: 0))
      }
      return
    }
    snippetSession = SnippetSession(stops: stops, textOrder: expansion.textOrder)
    observeSnippetEdits()
    selectSnippetStop()
  }

  /// Tab goes to the next stop, Shift-Tab to the previous one; reaching the final caret ends
  /// the session
  func moveSnippetStop(by step: Int) {
    guard var session = snippetSession else { return }
    session.index = min(max(session.index + step, 0), session.stops.count - 1)
    snippetSession = session
    selectSnippetStop()
    if session.isAtFinalStop { endSnippetSession() }
  }

  func endSnippetSession() {
    if let observer = snippetEditObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    snippetEditObserver = nil
    snippetSession = nil
  }

  /// A selection outside the current stop (a click, an arrow key) ends the session
  func snippetSelectionDidChange() {
    guard let session = snippetSession, !isSelectingSnippetStop else { return }
    if !session.contains(selectedRange()) { endSnippetSession() }
  }

  private func selectSnippetStop() {
    guard let session = snippetSession else { return }
    guard NSMaxRange(session.current) <= (string as NSString).length else {
      endSnippetSession()
      return
    }
    isSelectingSnippetStop = true
    setSelectedRange(session.current)
    scrollRangeToVisible(session.current)
    isSelectingSnippetStop = false
  }

  /// Follows the character edits of the text storage while the session lasts. The highlighter
  /// only changes attributes, which leave the stops as they are.
  private func observeSnippetEdits() {
    guard let textStorage else { return }
    snippetEditObserver = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.snippetTextDidEdit() }
    }
  }

  private func snippetTextDidEdit() {
    guard var session = snippetSession, let textStorage,
      textStorage.editedMask.contains(.editedCharacters)
    else { return }
    if session.apply(editedRange: textStorage.editedRange, delta: textStorage.changeInLength) {
      snippetSession = session
    } else {
      endSnippetSession()
    }
  }
}
