// SQLSyntaxHighlighterIncrementalTests.swift
// Pure incremental invalidation: blockSpans, dirtyRange and rehighlight.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SQLNotebook

@Suite("SQL Syntax Highlighter Incremental Tests")
@MainActor
struct SQLSyntaxHighlighterIncrementalTests {
  typealias H = SQLSyntaxHighlighter

  // MARK: - Helpers

  private func same(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    guard let l = lhs.usingColorSpace(.sRGB), let r = rhs.usingColorSpace(.sRGB) else {
      return false
    }
    return abs(l.redComponent - r.redComponent) < 0.001
      && abs(l.greenComponent - r.greenComponent) < 0.001
      && abs(l.blueComponent - r.blueComponent) < 0.001
      && abs(l.alphaComponent - r.alphaComponent) < 0.001
  }

  /// Replaces `range` of `old` with `replacement`, then returns the dirty range in the new text
  private func dirty(
    old: String, range: NSRange, with replacement: String
  ) -> (
    new: String, dirty: NSRange
  ) {
    let oldNS = old as NSString
    let new = oldNS.replacingCharacters(in: range, with: replacement)
    let newNS = new as NSString
    let edited = NSRange(location: range.location, length: (replacement as NSString).length)
    let result = H.dirtyRange(
      text: newNS, edited: edited, changeInLength: newNS.length - oldNS.length,
      oldSpans: H.blockSpans(in: oldNS), newSpans: H.blockSpans(in: newNS))
    return (new, result)
  }

  private func substring(_ text: String, _ r: NSRange) -> String {
    (text as NSString).substring(with: r)
  }

  /// First mismatch between two attributed strings (foreground color and font), or nil
  private func mismatch(_ a: NSAttributedString, _ b: NSAttributedString) -> Int? {
    guard a.length == b.length else { return -1 }
    for i in 0..<a.length {
      let x = a.attributes(at: i, effectiveRange: nil)
      let y = b.attributes(at: i, effectiveRange: nil)
      if !same(x[.foregroundColor] as? NSColor, y[.foregroundColor] as? NSColor) { return i }
      if (x[.font] as? NSFont) != (y[.font] as? NSFont) { return i }
    }
    return nil
  }

  // MARK: - Spans

  @Test("blockSpans finds multi-line comments, strings and dollar quotes")
  func spans() {
    let text = "a /* x\ny */ 'b' $$ c\nd $$ -- e\nf"
    let spans = H.blockSpans(in: text as NSString)
    #expect(spans.map { substring(text, $0) } == ["/* x\ny */", "'b'", "$$ c\nd $$", "-- e"])
  }

  // MARK: - Dirty range

  @Test("typing inside a line dirties only that paragraph")
  func typingInsideLine() {
    let old = "SELECT 1;\nSELECT 2;\nSELECT 3;"
    let r = dirty(old: old, range: NSRange(location: 17, length: 0), with: "x")
    #expect(substring(r.new, r.dirty) == "SELECT x2;\n")
  }

  @Test("opening /* dirties through the next */")
  func openingComment() {
    let old = "a\nb\nc */\nd\ne"
    let r = dirty(old: old, range: NSRange(location: 2, length: 0), with: "/*")
    #expect(substring(r.new, r.dirty) == "/*b\nc */\n")
  }

  @Test("opening /* without a close dirties only its paragraph (unclosed is not a comment)")
  func openingCommentUnclosed() {
    let old = "a\nb\nc\nd"
    let r = dirty(old: old, range: NSRange(location: 2, length: 0), with: "/*")
    #expect(substring(r.new, r.dirty) == "/*b\n")
  }

  @Test("closing $$ dirties the former span")
  func closingDollarQuote() {
    let old = "x\n$$ body\nmore\n$$ y\nz"
    // Break the closing "$$" so the span runs on; then restore it
    let broken = dirty(old: old, range: NSRange(location: 16, length: 1), with: "")
    #expect(substring(broken.new, broken.dirty).hasPrefix("$$ body\nmore\n$ y"))
    let closed = dirty(old: broken.new, range: NSRange(location: 16, length: 0), with: "$")
    #expect(substring(closed.new, closed.dirty) == "$$ body\nmore\n$$ y\n")
  }

  @Test("multi-line delete including a comment start")
  func multiLineDelete() {
    let old = "a\nb /* c\nd\ne */ f\ng\nh"
    // Delete from inside line b through the middle of line d (removes the "/*")
    let r = dirty(old: old, range: NSRange(location: 3, length: 7), with: "")
    #expect(r.new == "a\nb\ne */ f\ng\nh")
    #expect(substring(r.new, r.dirty) == "b\ne */ f\n")
  }

  @Test("deleting the first character dirties the whole paragraph and repaints it")
  func deleteAtOffsetZero() {
    withSyntaxHighlightingEnabled {
      let old = "xSELECT 1"
      let storage = NSMutableAttributedString(attributedString: H.highlight(old))
      let r = dirty(old: old, range: NSRange(location: 0, length: 1), with: "")
      #expect(r.new == "SELECT 1")
      #expect(r.dirty == NSRange(location: 0, length: 8))
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
      H.rehighlight(storage: storage, range: r.dirty, palette: H.Palette())
      #expect(mismatch(storage, H.highlight(r.new)) == nil)
    }
  }

  @Test("deleting everything does not crash and dirties nothing")
  func deleteEverything() {
    let r = dirty(old: "x", range: NSRange(location: 0, length: 1), with: "")
    #expect(r.new == "")
    #expect(r.dirty == NSRange(location: 0, length: 0))
  }

  /// Time both same-length and +1 edits at the head of a 100k-span chain behind `prefix`
  private func expectFastChain(prefix: String) {
    let chain = String(repeating: "a/*\n*/b", count: 100_000)
    let old = prefix + chain
    let oldNS = old as NSString
    let head = (prefix as NSString).length
    let oldSpans = H.blockSpans(in: oldNS)
    #expect(oldSpans.count == 100_000)

    var start = Date()
    var result = H.dirtyRange(
      text: oldNS, edited: NSRange(location: head, length: 1), changeInLength: 0,
      oldSpans: oldSpans, newSpans: oldSpans)
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(NSMaxRange(result) == oldNS.length)

    let new = oldNS.replacingCharacters(in: NSRange(location: head, length: 0), with: "x")
    let newNS = new as NSString
    let newSpans = H.blockSpans(in: newNS)
    start = Date()
    result = H.dirtyRange(
      text: newNS, edited: NSRange(location: head, length: 1), changeInLength: 1,
      oldSpans: oldSpans, newSpans: newSpans)
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(NSMaxRange(result) == newNS.length)
  }

  @Test("dirtyRange stays fast behind 500k newlines", .timeLimit(.minutes(1)))
  func adversarialNewlines() {
    expectFastChain(prefix: String(repeating: "\n", count: 500_000))
  }

  @Test("dirtyRange stays fast behind 500k spaces", .timeLimit(.minutes(1)))
  func adversarialSpaces() {
    expectFastChain(prefix: String(repeating: " ", count: 500_000))
  }

  @Test("dirtyRange stays fast behind one 500k word", .timeLimit(.minutes(1)))
  func adversarialWord() {
    expectFastChain(prefix: String(repeating: "w", count: 500_000) + " \n")
  }

  // MARK: - Property

  @Test(
    "dirtyRange stays fast on a long chain of multi-line spans",
    .timeLimit(.minutes(1)))
  func chainedSpansAreNotQuadratic() {
    let old = String(repeating: "a/*\n*/b", count: 100_000)
    let oldNS = old as NSString
    let oldSpans = H.blockSpans(in: oldNS)
    #expect(oldSpans.count == 100_000)

    // Same-length edit inside the first span
    var start = Date()
    var result = H.dirtyRange(
      text: oldNS, edited: NSRange(location: 3, length: 1), changeInLength: 0,
      oldSpans: oldSpans, newSpans: oldSpans)
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(result.location == 0 && NSMaxRange(result) == oldNS.length)

    // One inserted character inside the first span
    let new = oldNS.replacingCharacters(in: NSRange(location: 3, length: 0), with: "x")
    let newNS = new as NSString
    start = Date()
    result = H.dirtyRange(
      text: newNS, edited: NSRange(location: 3, length: 1), changeInLength: 1,
      oldSpans: oldSpans, newSpans: H.blockSpans(in: newNS))
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(result.location == 0 && NSMaxRange(result) == newNS.length)
  }

  /// Applies one edit incrementally to `storage`; returns a failure description, or nil when the
  /// result equals a fresh full highlight
  private func applyAndCompare(
    _ storage: NSMutableAttributedString, range: NSRange, replacement: String,
    palette: H.Palette, label: String
  ) -> String? {
    let old = storage.string as NSString
    let oldSpans = H.blockSpans(in: old)
    storage.replaceCharacters(in: range, with: replacement)
    let text = storage.string
    let new = text as NSString
    let edited = NSRange(location: range.location, length: (replacement as NSString).length)
    let dirtyRange = H.dirtyRange(
      text: new, edited: edited, changeInLength: new.length - old.length,
      oldSpans: oldSpans, newSpans: H.blockSpans(in: new))
    H.rehighlight(storage: storage, range: dirtyRange, palette: palette)
    guard let at = mismatch(storage, H.highlight(text)) else { return nil }
    return
      "mismatch at utf16 \(at) after \(label): range \(range), replacement \(replacement.debugDescription), dirty \(dirtyRange)"
  }

  /// Deterministic edits at the offsets most likely to break (start, end, span edges)
  private func boundaryEdits(in text: NSString) -> [(String, NSRange, String)] {
    let spans = H.blockSpans(in: text)
    let n = text.length
    var edits: [(String, NSRange, String)] = [
      ("delete at 0", NSRange(location: 0, length: 1), ""),
      ("insert at 0", NSRange(location: 0, length: 0), "x"),
      ("delete last", NSRange(location: n - 1, length: 1), ""),
      ("insert at end", NSRange(location: n, length: 0), "x"),
      ("insert quote at 0", NSRange(location: 0, length: 0), "'"),
      ("insert newline at end", NSRange(location: n, length: 0), "\n"),
    ]
    for (name, span) in [
      ("first", spans.first), ("middle", spans.isEmpty ? nil : spans[spans.count / 2]),
    ] {
      guard let span else { continue }
      let end = NSMaxRange(span)
      let cur = text.length
      edits += [
        ("\(name) span: delete first char", NSRange(location: span.location, length: 1), ""),
        ("\(name) span: insert at start", NSRange(location: span.location, length: 0), "-"),
        ("\(name) span: delete last char", NSRange(location: end - 1, length: 1), ""),
        ("\(name) span: insert at end", NSRange(location: end, length: 0), "'"),
        ("\(name) span: delete char after", NSRange(location: min(end, cur - 1), length: 1), ""),
        (
          "\(name) span: delete char before",
          NSRange(location: max(0, span.location - 1), length: 1), ""
        ),
      ]
    }
    return edits
  }

  @Test("edits on tiny and empty texts equal a full highlight")
  func tinyTexts() {
    withSyntaxHighlightingEnabled {
      let palette = H.Palette()
      let cases: [(String, NSRange, String)] = [
        ("xSELECT 1", NSRange(location: 0, length: 1), ""),
        ("x", NSRange(location: 0, length: 1), ""),
        ("SELECT 1", NSRange(location: 0, length: 8), ""),
        ("", NSRange(location: 0, length: 0), "SELECT 1"),
        ("", NSRange(location: 0, length: 0), "'"),
        ("a\n", NSRange(location: 2, length: 0), "b"),
        ("/* a */", NSRange(location: 0, length: 1), ""),
        ("count (1)", NSRange(location: 5, length: 1), ""),
      ]
      for (i, c) in cases.enumerated() {
        let storage = NSMutableAttributedString(attributedString: H.highlight(c.0))
        if let failure = applyAndCompare(
          storage, range: c.1, replacement: c.2, palette: palette, label: "tiny case \(i)")
        {
          Issue.record(Comment(rawValue: failure))
        }
      }
    }
  }

  @Test("incremental equals full highlight after boundary and 200 seeded random edits")
  func incrementalEqualsFull() {
    withSyntaxHighlightingEnabled {
      let seed: UInt64 = 0xC0FFEE
      var rng = SeededGenerator(seed: seed)
      let lines = PerfFixtures.sql2kLines().components(separatedBy: "\n")
      let text = lines.prefix(300).joined(separator: "\n")
      let palette = H.Palette()
      let storage = NSMutableAttributedString(attributedString: H.highlight(text))
      let alphabet = Array("'-/*$\n\n abcSELECTcount(  )019;😀\\").map { String($0) }

      var boundaryIndex = 0
      while true {
        // Positions are recomputed on the current text after every edit
        let edits = boundaryEdits(in: storage.string as NSString)
        guard boundaryIndex < edits.count else { break }
        let (label, range, replacement) = edits[boundaryIndex]
        boundaryIndex += 1
        if let failure = applyAndCompare(
          storage, range: range, replacement: replacement, palette: palette,
          label: "boundary edit \(label)")
        {
          Issue.record(Comment(rawValue: failure))
          return
        }
      }

      for editIndex in 0..<200 {
        let old = storage.string as NSString
        var location = Int(rng.next() % UInt64(old.length + 1))
        if editIndex % 3 == 0 {
          // Bias toward the start, the end and span edges
          let spans = H.blockSpans(in: old)
          var anchors = [0, old.length]
          if let span = spans.isEmpty ? nil : spans[Int(rng.next() % UInt64(spans.count))] {
            anchors += [span.location, NSMaxRange(span)]
          }
          location = anchors[Int(rng.next() % UInt64(anchors.count))]
        }
        location = old.length == 0 ? 0 : composedStart(old, location)
        var range = NSRange(location: location, length: 0)
        var replacement = ""
        if rng.next() % 3 == 0, old.length > 0 {
          let want = Int(rng.next() % 60) + 1
          let end = composedStart(old, min(old.length, location + want))
          range.length = max(0, end - location)
        }
        if range.length == 0 || rng.next() % 4 == 0 {
          let n = Int(rng.next() % 3) + 1
          for _ in 0..<n { replacement += alphabet[Int(rng.next() % UInt64(alphabet.count))] }
        }

        if let failure = applyAndCompare(
          storage, range: range, replacement: replacement, palette: palette,
          label: "edit \(editIndex) (seed \(seed))")
        {
          Issue.record(Comment(rawValue: failure))
          return
        }
      }
    }
  }

  /// Start of the composed character sequence containing `index` (index itself when aligned)
  private func composedStart(_ s: NSString, _ index: Int) -> Int {
    guard index < s.length else { return s.length }
    return s.rangeOfComposedCharacterSequence(at: index).location
  }
}
