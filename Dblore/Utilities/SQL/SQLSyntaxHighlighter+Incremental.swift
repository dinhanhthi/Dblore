//
//  SQLSyntaxHighlighter+Incremental.swift
//  Dblore
//
//  Pure helpers to re-highlight only the part of a text an edit can affect.
//

import Foundation

extension SQLSyntaxHighlighter {
  /// Sorted, disjoint ranges of every comment and string in `text` (multi-line included)
  static func blockSpans(in text: NSString, dialect: SQLDialect = .postgresql) -> [NSRange] {
    scanBlockSpans(in: text, range: NSRange(location: 0, length: text.length), dialect: dialect)
      .map(\.range)
  }

  /// The smallest paragraph-aligned range of the NEW `text` whose colors can differ after an
  /// edit. `edited` is the replaced range in the new text (zero-length for a pure deletion) and
  /// `changeInLength` is new length minus old length; `oldSpans` are in old coordinates.
  static func dirtyRange(
    text: NSString, edited: NSRange, changeInLength: Int, oldSpans: [NSRange],
    newSpans: [NSRange]
  ) -> NSRange {
    let length = text.length
    let editedEnd = NSMaxRange(edited)
    let oldEditEnd = editedEnd - changeInLength
    var lo = edited.location
    var hi = editedEnd
    func extend(_ r: NSRange) {
      lo = min(lo, r.location)
      hi = max(hi, NSMaxRange(r))
    }

    // Old spans mapped to new coordinates; the ones touching the edit count as changed
    var shifted: [NSRange] = []
    for span in oldSpans {
      if NSMaxRange(span) <= edited.location {
        shifted.append(span)
      } else if span.location >= oldEditEnd {
        shifted.append(NSRange(location: span.location + changeInLength, length: span.length))
      } else {
        let start = min(span.location, edited.location)
        let end = NSMaxRange(span) > oldEditEnd ? NSMaxRange(span) + changeInLength : editedEnd
        extend(NSRange(location: start, length: max(0, end - start)))
      }
    }

    // Symmetric difference of the two sorted span lists (linear merge)
    var i = 0
    var j = 0
    while i < shifted.count || j < newSpans.count {
      if i < shifted.count, j < newSpans.count, shifted[i] == newSpans[j] {
        i += 1
        j += 1
      } else if j == newSpans.count
        || (i < shifted.count && spanPrecedes(shifted[i], newSpans[j]))
      {
        extend(shifted[i])
        i += 1
      } else {
        extend(newSpans[j])
        j += 1
      }
    }

    // Grow to a fixpoint: whole paragraphs, whole spans that intersect, and the whitespace run
    // on either side (a function name is colored through the whitespace before its "(").
    // Spans are sorted and disjoint, so those intersecting [lo, hi) form one contiguous run,
    // found by binary search; each pass then widens the range, so passes are O(log n + line).
    // Every scan below depends on a single bound of the text, so its result is memoized on
    // that bound: passes that leave a bound unmoved do not rescan (long blank runs, long words).
    var startMemo = Memo()
    var endMemo = Memo()
    var backMemo = Memo()
    var forwardMemo = Memo()
    var range = NSRange(location: NSNotFound, length: 0)
    var next = clamp(lo, hi, length)
    while next != range {
      range = align(next, in: text, startMemo: &startMemo, endMemo: &endMemo)
      lo = range.location
      hi = NSMaxRange(range)
      let first = firstSpan(in: newSpans) { NSMaxRange($0) > lo }
      let end = firstSpan(in: newSpans) { $0.location >= hi }
      if first < end {
        lo = min(lo, newSpans[first].location)
        hi = max(hi, NSMaxRange(newSpans[end - 1]))
      }
      if let c = backMemo.cached(for: lo) {
        lo = c
      } else {
        var p = lo
        while p > 0, isBlank(text.character(at: p - 1)) { p -= 1 }
        let grown = p < lo && p > 0 && endsWithFunctionName(text, before: p) ? p - 1 : lo
        lo = backMemo.store(grown, for: lo)
      }
      if let c = forwardMemo.cached(for: hi) {
        hi = c
      } else {
        var q = hi
        while q < length, isBlank(text.character(at: q)) { q += 1 }
        let grown = q > hi && endsWithWord(text, before: hi) ? q : hi
        hi = forwardMemo.store(grown, for: hi)
      }
      next = align(
        clamp(lo, hi, length), in: text, startMemo: &startMemo, endMemo: &endMemo)
    }
    return range
  }

  /// Resets `range` to the default attributes, then highlights it
  static func rehighlight(
    storage: NSMutableAttributedString, range: NSRange, palette: Palette,
    dialect: SQLDialect = .postgresql
  ) {
    storage.addAttributes(palette.defaultAttributes, range: range)
    highlight(in: storage, range: range, palette: palette, dialect: dialect)
  }

  private static func spanPrecedes(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location != b.location ? a.location < b.location : a.length < b.length
  }

  /// Index of the first span satisfying `predicate` (false-then-true over the sorted spans)
  private static func firstSpan(in spans: [NSRange], where predicate: (NSRange) -> Bool) -> Int {
    var low = 0
    var high = spans.count
    while low < high {
      let mid = (low + high) / 2
      if predicate(spans[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
  }

  /// Grows `r` to whole paragraphs; the two bounds are memoized (see `dirtyRange`)
  private static func align(
    _ r: NSRange, in text: NSString, startMemo: inout Memo, endMemo: inout Memo
  ) -> NSRange {
    guard text.length > 0 else { return NSRange(location: 0, length: 0) }
    let start: Int
    if let c = startMemo.cached(for: r.location) {
      start = c
    } else {
      let paragraph = text.paragraphRange(for: NSRange(location: r.location, length: 0))
      start = startMemo.store(paragraph.location, for: r.location)
    }
    let last = r.length > 0 ? NSMaxRange(r) - 1 : r.location
    let end: Int
    if let c = endMemo.cached(for: last) {
      end = c
    } else {
      let paragraph = text.paragraphRange(for: NSRange(location: last, length: 0))
      end = endMemo.store(NSMaxRange(paragraph), for: last)
    }
    return NSRange(location: start, length: end - start)
  }

  private static func clamp(_ lo: Int, _ hi: Int, _ length: Int) -> NSRange {
    let l = max(0, min(lo, length))
    let h = max(l, min(hi, length))
    return NSRange(location: l, length: h - l)
  }

  /// Remembers the last computed (key, value) pair
  private struct Memo {
    private var lastKey = Int.min
    private var lastValue = 0
    func cached(for k: Int) -> Int? { k == lastKey ? lastValue : nil }
    mutating func store(_ value: Int, for k: Int) -> Int {
      lastKey = k
      lastValue = value
      return value
    }
  }

  private static let longestFunctionName = functions.map(\.utf16.count).max() ?? 0

  private static func isWordChar(_ c: unichar) -> Bool {
    (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F
  }

  /// The word ending right before `index` is a function name
  private static func endsWithFunctionName(_ text: NSString, before index: Int) -> Bool {
    var start = index
    while start > 0, isWordChar(text.character(at: start - 1)) {
      start -= 1
      // Longer than any function name: stop scanning, it cannot match
      if index - start > longestFunctionName { return false }
    }
    guard start < index else { return false }
    let word = text.substring(with: NSRange(location: start, length: index - start))
    return functions.contains(word.uppercased())
  }

  /// The last non-blank character before `index` is a word character
  private static func endsWithWord(_ text: NSString, before index: Int) -> Bool {
    var i = index
    while i > 0, isBlank(text.character(at: i - 1)) { i -= 1 }
    return i > 0 && isWordChar(text.character(at: i - 1))
  }

  private static func isBlank(_ c: unichar) -> Bool {
    c == 0x20 || (0x09...0x0D).contains(c) || c == 0x85 || c == 0xA0 || c == 0x2028 || c == 0x2029
  }
}
