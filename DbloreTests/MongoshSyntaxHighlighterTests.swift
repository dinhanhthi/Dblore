// MongoshSyntaxHighlighterTests.swift
// Token categories of the mongosh highlighter, its delegation from SQLSyntaxHighlighter for
// the MongoDB dialect, and the Format SQL gate.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("Mongosh Syntax Highlighter Tests")
@MainActor
struct MongoshSyntaxHighlighterTests {
  typealias TokenType = SQLSyntaxHighlighter.TokenType

  // MARK: - Helpers

  private func tokens(_ text: String) -> [MongoshSyntaxHighlighter.Token] {
    let ns = text as NSString
    return MongoshSyntaxHighlighter.tokens(in: ns, range: NSRange(location: 0, length: ns.length))
  }

  /// Range of the `occurrence`-th occurrence of `needle`
  private func range(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
    let ns = text as NSString
    var location = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
      found = ns.range(
        of: needle, options: [], range: NSRange(location: location, length: ns.length - location))
      guard found.location != NSNotFound else { return found }
      location = NSMaxRange(found)
    }
    return found
  }

  /// Type of the single token that exactly covers `needle`, nil if none does
  private func type(
    of needle: String, in text: String, occurrence: Int = 0
  ) -> TokenType? {
    let target = range(of: needle, in: text, occurrence: occurrence)
    return tokens(text).first { $0.range == target }?.type
  }

  /// Type of the token containing the first character of `needle`
  private func typeAt(_ needle: String, in text: String) -> TokenType? {
    let location = range(of: needle, in: text).location
    return tokens(text).first { NSLocationInRange(location, $0.range) }?.type
  }

  private func same(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let l = lhs?.usingColorSpace(.sRGB), let r = rhs?.usingColorSpace(.sRGB) else {
      return false
    }
    return abs(l.redComponent - r.redComponent) < 0.001
      && abs(l.greenComponent - r.greenComponent) < 0.001
      && abs(l.blueComponent - r.blueComponent) < 0.001
      && abs(l.alphaComponent - r.alphaComponent) < 0.001
  }

  private func color(_ attributed: NSAttributedString, at offset: Int) -> NSColor? {
    attributed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
  }

  // MARK: - Token Categories

  @Test("Representative find cell")
  func representativeCell() {
    let text = #"db.orders.find({status: "A", qty: {$gt: 5}}).sort({_id: -1}) // c"#
    #expect(type(of: "db", in: text) == .keyword)
    #expect(type(of: "orders", in: text) == .identifier)
    #expect(type(of: "find", in: text) == .function)
    #expect(type(of: "sort", in: text) == .function)
    #expect(type(of: "\"A\"", in: text) == .string)
    #expect(type(of: "$gt", in: text) == .keyword)
    #expect(type(of: "5", in: text) == .number)
    #expect(type(of: "-1", in: text) == .number)
    #expect(type(of: "// c", in: text) == .comment)
    // Object keys stay in the default color
    #expect(typeAt("status", in: text) == nil)
    #expect(typeAt("_id", in: text) == nil)
  }

  @Test("Aggregate stages and operators")
  func aggregateStages() {
    let text = #"db.sales.aggregate([{$match: {n: {$in: [1, 2.5e3]}}}, {$group: {_id: "$k"}}])"#
    #expect(type(of: "aggregate", in: text) == .function)
    #expect(type(of: "$match", in: text) == .keyword)
    #expect(type(of: "$in", in: text) == .keyword)
    #expect(type(of: "$group", in: text) == .keyword)
    #expect(type(of: "2.5e3", in: text) == .number)
    #expect(type(of: "\"$k\"", in: text) == .string)
  }

  @Test("Constructors, literals and regex")
  func constructors() {
    let text =
      #"db.c.find({a: ObjectId('x\'y'), b: ISODate("2020"), c: NumberLong(1), d: NumberDecimal("1"), "#
      + #"e: NumberInt(2), f: new Date(), g: Timestamp(1, 2), h: BinData(0, ""), i: RegExp("a"), "#
      + #"j: MinKey, k: MaxKey, l: true, m: false, n: null, o: /ab\/c[/]d/i})"#
    for name in [
      "ObjectId", "ISODate", "NumberLong", "NumberDecimal", "NumberInt", "Timestamp", "BinData",
      "RegExp", "MinKey", "MaxKey",
    ] {
      #expect(type(of: name, in: text) == .type, "\(name)")
    }
    // The first "Date" is inside "ISODate"
    #expect(type(of: "Date", in: text, occurrence: 1) == .type)
    #expect(type(of: "new", in: text) == .keyword)
    #expect(type(of: "true", in: text) == .keyword)
    #expect(type(of: "false", in: text) == .keyword)
    #expect(type(of: "null", in: text) == .keyword)
    #expect(type(of: #"'x\'y'"#, in: text) == .string)
    #expect(type(of: #"/ab\/c[/]d/i"#, in: text) == .string)
  }

  @Test("Line and block comments")
  func comments() {
    let text = "/* head\n db.x */ db.c.find() // tail find\ndb.d.find()"
    #expect(type(of: "/* head\n db.x */", in: text) == .comment)
    #expect(type(of: "// tail find", in: text) == .comment)
    #expect(type(of: "db", in: text, occurrence: 2) == .keyword)
  }

  @Test("Unterminated string and comment run to the end")
  func unterminated() {
    let string = #"db.c.find({a: "open \" still"#
    #expect(type(of: #""open \" still"#, in: string) == .string)
    let comment = "db.c.find() /* open\nmore"
    #expect(type(of: "/* open\nmore", in: comment) == .comment)
    // Malformed fragments never crash
    for text in ["\"", "'\\", "/*", "/", "$", "-", ".", "db.", "1e", "/[", "new", "\\"] {
      _ = tokens(text)
    }
  }

  @Test("Large input completes quickly")
  func largeInput() {
    let line = #"db.orders.find({status: "A", qty: {$gt: 5}}).sort({_id: -1}) // c /x/"# + "\n"
    let weird = String(repeating: "/ ' \" /* $ - ", count: 2_000)
    let text = String(repeating: line, count: 2_800) + weird
    #expect((text as NSString).length > 200_000)
    let start = ContinuousClock.now
    let result = tokens(text)
    #expect(!result.isEmpty)
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  // MARK: - Delegation

  @Test("SQLSyntaxHighlighter delegates for the MongoDB dialect")
  func delegation() {
    let text = "db.c.find({a: 1}) -- not a comment\nSELECT"
    let attributed = withSyntaxHighlightingEnabled {
      SQLSyntaxHighlighter.highlight(text, dialect: .mongodb)
    }
    let ns = text as NSString
    #expect(attributed.length == ns.length)
    let find = ns.range(of: "find").location
    let dashes = ns.range(of: "--").location
    let select = ns.range(of: "SELECT").location
    #expect(same(color(attributed, at: find), NSColor(Color.syntaxFunction)))
    #expect(same(color(attributed, at: 0), NSColor(Color.syntaxKeyword)))
    #expect(!same(color(attributed, at: dashes + 3), NSColor(Color.syntaxComment)))
    #expect(!same(color(attributed, at: select), NSColor(Color.syntaxKeyword)))
  }

  @Test("Non-ASCII text keeps colors aligned to UTF-16")
  func utf16() {
    let text = #"db.c.find({name: "😀日本", n: 1})"#
    let attributed = withSyntaxHighlightingEnabled {
      SQLSyntaxHighlighter.highlight(text, dialect: .mongodb)
    }
    let ns = text as NSString
    #expect(attributed.length == ns.length)
    for i in 0..<ns.length {
      #expect(attributed.attribute(.font, at: i, effectiveRange: nil) != nil)
    }
    let literal = ns.range(of: #""😀日本""#)
    #expect(same(color(attributed, at: NSMaxRange(literal) - 1), NSColor(Color.syntaxString)))
    #expect(same(color(attributed, at: ns.range(of: "1").location), NSColor(Color.syntaxNumber)))
  }

  @Test("Block spans for MongoDB are mongosh strings and comments")
  func blockSpans() {
    let text = "db.c.find({a: \"x\"}) -- y // z"
    let spans = SQLSyntaxHighlighter.blockSpans(in: text as NSString, dialect: .mongodb)
    #expect(spans == [range(of: "\"x\"", in: text), range(of: "// z", in: text)])
  }

  @Test("Incremental rehighlight recolors the whole MongoDB text")
  func incrementalFullRehighlight() {
    let text = "db.c.find({a: 1})\ndb.d.find()"
    let storage = NSMutableAttributedString(string: text)
    withSyntaxHighlightingEnabled {
      let palette = SQLSyntaxHighlighter.Palette()
      storage.addAttributes(
        palette.defaultAttributes, range: NSRange(location: 0, length: storage.length))
      let lastLine = (text as NSString).range(of: "db.d.find()")
      SQLSyntaxHighlighter.rehighlight(
        storage: storage, range: lastLine, palette: palette, dialect: .mongodb)
    }
    #expect(same(color(storage, at: 0), NSColor(Color.syntaxKeyword)))
  }

  // MARK: - Format SQL Gate

  @Test("Format SQL is disabled for MongoDB only")
  func formatGate() {
    #expect(!SQLTextView.canFormat(dialect: .mongodb))
    #expect(SQLTextView.canFormat(dialect: .postgresql))
    #expect(SQLTextView.canFormat(dialect: .mysql))
    #expect(SQLTextView.canFormat(dialect: .sqlite))
  }
}
