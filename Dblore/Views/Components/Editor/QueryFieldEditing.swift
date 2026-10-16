//
//  QueryFieldEditing.swift
//  Dblore
//
//  Editing rules of the MongoDB query field: bracket and quote pairing, stepping over a closer,
//  deleting an empty pair, and new line indent. Pure text rules on UTF-16 offsets, no text view.
//

import Foundation

nonisolated enum QueryFieldEditing {
  /// A key the field hands to the rules before the text view handles it
  enum Key: Equatable {
    case character(Character)
    case backspace
    case newline
  }

  /// Replace `range` with `replacement`, then put the caret at `caret` (UTF-16, absolute after the edit)
  struct Edit: Equatable {
    let range: NSRange
    let replacement: String
    let caret: Int
  }

  static let indentUnit = "  "

  private static let pairs: [Character: Character] = ["{": "}", "[": "]", "\"": "\"", "'": "'"]
  private static let closers: Set<Character> = ["}", "]", "\"", "'"]
  private static let quotes: Set<Character> = ["\"", "'"]
  /// Characters an opener or quote may pair in front of (besides end of text and whitespace)
  private static let pairsBefore: Set<Character> = ["}", "]", ")", ",", ":"]

  /// The edit for `key`, or nil when the text view should handle the key itself
  static func edit(for key: Key, in text: String, selection: NSRange) -> Edit? {
    let ns = text as NSString
    switch key {
    case .character(let character):
      guard selection.length == 0 else { return nil }
      return characterEdit(character, in: ns, caret: selection.location)
    case .backspace:
      guard selection.length == 0 else { return nil }
      return backspaceEdit(in: ns, caret: selection.location)
    case .newline:
      return newlineEdit(in: ns, selection: selection)
    }
  }

  /// The caret after replacing `range` of `text` with `replacement` (an accepted suggestion),
  /// with `caret` the caret before. The suggestion replaces the whole word around the caret, so
  /// the rest of the word is skipped first; when the text of `range` after it (the closers of an
  /// auto-closed pair, e.g. `}`) also ends the replacement, the caret stays before it; otherwise
  /// it goes to the end of the replacement. UTF-16 offsets.
  static func caretAfterReplacing(
    _ range: NSRange, in text: String, caret: Int, with replacement: String
  ) -> Int {
    let end = range.location + replacement.utf16.count
    guard range.location <= caret, caret <= NSMaxRange(range),
      NSMaxRange(range) <= (text as NSString).length
    else { return end }
    let ns = text as NSString
    var tailStart = caret
    while tailStart < NSMaxRange(range), isWordPart(ns.character(at: tailStart)) {
      tailStart += 1
    }
    let tail = ns.substring(
      with: NSRange(location: tailStart, length: NSMaxRange(range) - tailStart))
    guard !tail.isEmpty, replacement.hasSuffix(tail) else { return end }
    return end - tail.utf16.count
  }

  // MARK: - Rules

  private static func characterEdit(_ character: Character, in ns: NSString, caret: Int) -> Edit? {
    // Step over the same closer first, so a closing quote after a word still steps over
    if closers.contains(character), self.character(after: caret, in: ns) == character {
      // An escaped quote types itself (and pairs nothing)
      if quotes.contains(character), isEscaped(caret, in: ns) {
        return nil
      }
      let closer = String(character)
      return Edit(
        range: NSRange(location: caret, length: closer.utf16.count), replacement: closer,
        caret: caret + closer.utf16.count)
    }
    guard let closer = pairs[character] else { return nil }
    // Text right after the caret: the opener types alone
    if let next = self.character(after: caret, in: ns), !next.isWhitespace,
      !pairsBefore.contains(next)
    {
      return nil
    }
    if quotes.contains(character), let previous = self.character(before: caret, in: ns),
      previous == "\\" || isWordCharacter(previous)
    {
      return nil
    }
    let opener = String(character)
    return Edit(
      range: NSRange(location: caret, length: 0), replacement: opener + String(closer),
      caret: caret + opener.utf16.count)
  }

  private static func backspaceEdit(in ns: NSString, caret: Int) -> Edit? {
    guard let previous = character(before: caret, in: ns),
      let next = character(after: caret, in: ns),
      pairs[previous] == next
    else { return nil }
    let start = caret - String(previous).utf16.count
    let length = String(previous).utf16.count + String(next).utf16.count
    return Edit(range: NSRange(location: start, length: length), replacement: "", caret: start)
  }

  private static func newlineEdit(in ns: NSString, selection: NSRange) -> Edit {
    let caret = selection.location
    let indent = leadingWhitespace(ofLineAt: caret, in: ns)
    let previous = character(before: caret, in: ns)
    let opensBlock = previous == "{" || previous == "["
    let inner = opensBlock ? indent + indentUnit : indent
    var replacement = "\n" + inner
    let caretAfter = caret + replacement.utf16.count
    if opensBlock, let previous,
      character(after: NSMaxRange(selection), in: ns) == pairs[previous]
    {
      replacement += "\n" + indent
    }
    return Edit(range: selection, replacement: replacement, caret: caretAfter)
  }

  // MARK: - Text helpers

  private static func character(before offset: Int, in ns: NSString) -> Character? {
    guard offset > 0, offset <= ns.length else { return nil }
    let range = ns.rangeOfComposedCharacterSequence(at: offset - 1)
    return ns.substring(with: range).first
  }

  private static func character(after offset: Int, in ns: NSString) -> Character? {
    guard offset >= 0, offset < ns.length else { return nil }
    let range = ns.rangeOfComposedCharacterSequence(at: offset)
    return ns.substring(with: range).first
  }

  /// True when an odd run of backslashes ends at `offset`, so the next character is escaped
  private static func isEscaped(_ offset: Int, in ns: NSString) -> Bool {
    var index = offset
    while index > 0, ns.character(at: index - 1) == 0x5C { index -= 1 }
    return (offset - index) % 2 == 1
  }

  /// A word character of the mongosh suggestions (ASCII letters, digits, `_`, `$`), the word a
  /// suggestion replaces
  private static func isWordPart(_ unit: unichar) -> Bool {
    (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit)
      || unit == 0x5F || unit == 0x24
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  /// Spaces and tabs at the start of the line holding `offset`, up to `offset`
  private static func leadingWhitespace(ofLineAt offset: Int, in ns: NSString) -> String {
    let before = NSRange(location: 0, length: offset)
    let newline = ns.range(of: "\n", options: .backwards, range: before)
    var index = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
    let start = index
    while index < offset {
      let unit = ns.character(at: index)
      guard unit == 0x20 || unit == 0x09 else { break }
      index += 1
    }
    return ns.substring(with: NSRange(location: start, length: index - start))
  }
}
