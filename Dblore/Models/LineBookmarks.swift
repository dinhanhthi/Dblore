//
//  LineBookmarks.swift
//  Dblore
//

import CryptoKit
import Foundation

/// Bookmarked logical lines of a SQL editor tab, numbered from 1 as the gutter shows them. Word
/// wrap changes visual rows only, so a logical line number stays put under it. Edits move the
/// marks (`applyEdit`); a saved mark carries an anchor of its line's text, so it finds its line
/// again when the file changed outside the app (`init(restoring:in:)`).
nonisolated struct LineBookmarks: Equatable, Sendable {
  /// Sorted, without duplicates
  private(set) var lines: [Int] = []

  /// A saved mark: its line and the anchor of that line's text
  struct Entry: Codable, Equatable, Sendable {
    var line: Int
    var anchor: String
  }

  init() {}

  init(lines: some Sequence<Int>) {
    self.lines = Set(lines.filter { $0 >= 1 }).sorted()
  }

  var isEmpty: Bool { lines.isEmpty }

  func contains(_ line: Int) -> Bool {
    lines.contains(line)
  }

  mutating func toggle(line: Int) {
    guard line >= 1 else { return }
    if let index = lines.firstIndex(of: line) {
      lines.remove(at: index)
    } else {
      lines.append(line)
      lines.sort()
    }
  }

  /// The first mark below `line`, else the first one (wrap-around)
  func next(after line: Int) -> Int? {
    lines.first { $0 > line } ?? lines.first
  }

  /// The last mark above `line`, else the last one (wrap-around)
  func previous(before line: Int) -> Int? {
    lines.last { $0 < line } ?? lines.last
  }

  // MARK: - Edits

  /// Moves the marks for `range` of `text` (the text before the edit) replaced by `replacement`.
  /// A mark follows its line's remaining text: lines inserted or removed above move it, and a
  /// line whose whole text was removed loses its mark. A replacement with as many line breaks as
  /// it removes (toggle comment, Replace All) rewrites lines in place: every mark stays. A
  /// whole-text replacement that changes the line count (Format SQL) keeps the marks whose
  /// line's text is still there, on its new line; letter case is ignored and runs of spaces are
  /// collapsed, but spaces added where there were none (`x=1` to `x = 1`) change the line. A
  /// line the replacement splits or joins has no anchor left to match, so its mark goes.
  mutating func applyEdit(replacing range: NSRange, in text: NSString, with replacement: String) {
    guard !lines.isEmpty, NSMaxRange(range) <= text.length else { return }
    let start = range.location
    let end = NSMaxRange(range)
    let removed = Self.lineBreakCount(in: text, range: range)
    let replacementText = replacement as NSString
    let inserted = Self.lineBreakCount(
      in: replacementText, range: NSRange(location: 0, length: replacementText.length))
    if inserted == removed { return }
    if start == 0, end == text.length {
      self = Self(restoring: entries(in: text as String), in: replacement)
      return
    }
    let first = Self.line(at: start, in: text)
    let last = first + removed
    let startsLine = start == 0 || Self.isLineBreak(text.character(at: start - 1))
    // The removal ends at the start of `last` (that line's text is untouched)
    let endsAtLineStart = end == 0 || Self.isLineBreak(text.character(at: end - 1))
    let endsAtLineEnd = end >= text.length || Self.isLineBreak(text.character(at: end))

    let moved = lines.compactMap { mark -> Int? in
      if mark < first { return mark }
      if mark > last { return mark + inserted - removed }
      if mark == first {
        // Its start is kept unless the edit begins there
        if !startsLine { return first }
        return removed == 0 ? first + inserted : nil
      }
      if mark < last { return nil }
      // The last line: its head went; it is gone when the removal reached its end
      if !endsAtLineStart && endsAtLineEnd { return nil }
      return first + inserted
    }
    lines = Set(moved.filter { $0 >= 1 }).sorted()
  }

  // MARK: - Saving

  /// The marks with the anchors of their lines in `text`; marks past its end are left out
  func entries(in text: String) -> [Entry] {
    let texts = Self.lineTexts(of: text)
    return lines.filter { $0 <= texts.count }.map {
      Entry(line: $0, anchor: Self.anchor(of: texts[$0 - 1]))
    }
  }

  /// Saved marks placed on `text`: a mark keeps its line when that line's anchor still matches,
  /// else takes the nearest line with the same anchor (the upper one on a tie), else goes. A
  /// saved line below 1 goes; one past the end counts from just after the last line.
  init(restoring entries: [Entry], in text: String) {
    let texts = Self.lineTexts(of: text)
    var anchors: [String]?
    var restored = Set<Int>()
    for entry in entries {
      guard entry.line >= 1 else { continue }
      if entry.line <= texts.count, Self.anchor(of: texts[entry.line - 1]) == entry.anchor {
        restored.insert(entry.line)
        continue
      }
      // Clamped so the distances below cannot overflow on a hand-edited file
      let target = min(entry.line, texts.count + 1)
      let all = anchors ?? texts.map(Self.anchor(of:))
      anchors = all
      let nearest = all.indices.filter { all[$0] == entry.anchor }
        .min { (abs($0 + 1 - target), $0) < (abs($1 + 1 - target), $1) }
      if let nearest { restored.insert(nearest + 1) }
    }
    lines = restored.sorted()
  }

  /// Stable across launches: a SHA-256 hex prefix of the line text, lowercased, trimmed and
  /// with each whitespace run collapsed to one space, so Format's keyword case and indentation
  /// keep it; spaces added where there were none (`x=1` to `x = 1`) change it (Swift's
  /// `Hasher` is seeded per process, so `hashValue` would never match on the next launch)
  static func anchor(of lineText: String) -> String {
    let normalized = lineText.lowercased()
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Lines

  /// The logical lines of `text` without their breaks, as the gutter numbers them: a trailing
  /// line break adds an empty last line, and empty text is one empty line
  static func lineTexts(of text: String) -> [String] {
    let ns = text as NSString
    var texts: [String] = []
    var index = 0
    while index < ns.length {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(
        nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
      texts.append(ns.substring(with: NSRange(location: index, length: contentsEnd - index)))
      index = lineEnd
    }
    if ns.length == 0 || isLineBreak(ns.character(at: ns.length - 1)) {
      texts.append("")
    }
    return texts
  }

  /// The 1-based line holding the UTF-16 offset `location` of `text`
  static func line(at location: Int, in text: NSString) -> Int {
    lineBreakCount(in: text, range: NSRange(location: 0, length: min(location, text.length))) + 1
  }

  /// The UTF-16 offset where 1-based `line` starts in `text` (nil past the last line)
  static func startOffset(ofLine line: Int, in text: NSString) -> Int? {
    guard line >= 1 else { return nil }
    var current = 1
    var index = 0
    while current < line {
      guard index < text.length else { return nil }
      var lineEnd = 0
      text.getLineStart(
        nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: index, length: 0))
      // The last line has no break: there is no next line
      guard lineEnd > index, isLineBreak(text.character(at: lineEnd - 1)) else { return nil }
      index = lineEnd
      current += 1
    }
    return index
  }

  /// Line breaks in `range` of `text`; CR LF counts once
  static func lineBreakCount(in text: NSString, range: NSRange) -> Int {
    var count = 0
    var index = range.location
    let end = NSMaxRange(range)
    while index < end {
      let character = text.character(at: index)
      if isLineBreak(character) {
        count += 1
        if character == 0x0D, index + 1 < end, text.character(at: index + 1) == 0x0A {
          index += 1
        }
      }
      index += 1
    }
    return count
  }

  /// The line separators `NSString.lineRange(for:)` ends a line at
  static func isLineBreak(_ character: unichar) -> Bool {
    character == 0x0A || character == 0x0D || character == 0x85 || character == 0x2028
      || character == 0x2029
  }
}
