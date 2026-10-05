// SQLSyntaxHighlighterCharacterizationTests.swift
// Pins the CURRENT foreground-color behavior of SQLSyntaxHighlighter on a small ASCII-only
// corpus (safety net for the Phase 2 rewrite). ASCII only so the tests stay valid before and
// after the UTF-16 length fix.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("SQL Syntax Highlighter Characterization Tests")
@MainActor
struct SQLSyntaxHighlighterCharacterizationTests {
  typealias Token = SQLSyntaxHighlighter.TokenType

  private let defaultColor = NSColor(Color.foreground)

  // MARK: - Helpers

  private func highlight(_ text: String) -> NSAttributedString {
    withSyntaxHighlightingEnabled { SQLSyntaxHighlighter.highlight(text) }
  }

  /// Color equality by resolved sRGB components. `Color.syntaxKeyword` is a computed property
  /// that builds a new dynamic NSColor on every access, so `==` on it compares identity.
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

  /// Foreground color at a UTF-16 offset
  private func color(_ attributed: NSAttributedString, at offset: Int) -> NSColor? {
    attributed.attributes(at: offset, effectiveRange: nil)[.foregroundColor] as? NSColor
  }

  /// Distinct foreground colors over every character of the n-th occurrence of `needle`
  private func colors(
    of needle: String, in attributed: NSAttributedString, occurrence: Int = 0
  ) -> [NSColor] {
    let ns = attributed.string as NSString
    var searchRange = NSRange(location: 0, length: ns.length)
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
      found = ns.range(of: needle, options: [], range: searchRange)
      guard found.location != NSNotFound else { return [] }
      let next = found.location + found.length
      searchRange = NSRange(location: next, length: ns.length - next)
    }
    var result: [NSColor] = []
    for offset in found.location..<(found.location + found.length) {
      if let c = color(attributed, at: offset), !result.contains(where: { same($0, c) }) {
        result.append(c)
      }
    }
    return result
  }

  /// True when every character of the occurrence has exactly `expected` as foreground color
  private func isColored(
    _ needle: String, _ expected: NSColor, in attributed: NSAttributedString, occurrence: Int = 0
  ) -> Bool {
    let found = colors(of: needle, in: attributed, occurrence: occurrence)
    return found.count == 1 && same(found[0], expected)
  }

  // MARK: - Token classes

  @Test("keyword is keyword-colored and surrounding text is default")
  func keywordColored() {
    let a = highlight("SELECT name FROM users")
    #expect(isColored("SELECT", Token.keyword.color, in: a))
    #expect(isColored("FROM", Token.keyword.color, in: a))
    #expect(isColored("name", defaultColor, in: a))
    #expect(isColored("users", defaultColor, in: a))
  }

  @Test("keywords are case-insensitive")
  func keywordCaseInsensitive() {
    let a = highlight("select 1 From t wHeRe x")
    #expect(isColored("select", Token.keyword.color, in: a))
    #expect(isColored("From", Token.keyword.color, in: a))
    #expect(isColored("wHeRe", Token.keyword.color, in: a))
  }

  @Test("function is colored only when followed by an opening parenthesis")
  func functionOnlyBeforeParen() {
    let a = highlight("SELECT count(*), count FROM t")
    #expect(isColored("count", Token.function.color, in: a, occurrence: 0))
    #expect(isColored("count", defaultColor, in: a, occurrence: 1))
  }

  @Test("function with whitespace before the parenthesis is colored")
  func functionWithSpaceBeforeParen() {
    let a = highlight("SELECT sum (x)")
    // The pattern consumes the trailing whitespace too
    #expect(isColored("sum ", Token.function.color, in: a))
  }

  @Test("type is type-colored")
  func typeColored() {
    let a = highlight("CREATE TABLE t (id integer, name VARCHAR)")
    #expect(isColored("integer", Token.type.color, in: a))
    #expect(isColored("VARCHAR", Token.type.color, in: a))
  }

  @Test("number is colored but digits inside an identifier are not")
  func numberColored() {
    let a = highlight("SELECT t1.id, 42, 3.14 FROM t1")
    #expect(isColored("42", Token.number.color, in: a))
    #expect(isColored("3.14", Token.number.color, in: a))
    #expect(isColored("t1", defaultColor, in: a, occurrence: 0))
    #expect(isColored("t1", defaultColor, in: a, occurrence: 1))
  }

  @Test("single-quoted string is string-colored")
  func singleQuotedString() {
    let a = highlight("SELECT 'hello world' FROM t")
    #expect(isColored("'hello world'", Token.string.color, in: a))
  }

  @Test("dollar-quoted string is string-colored across lines")
  func dollarQuotedString() {
    let a = highlight("SELECT $$ body\nline two $$ FROM t")
    #expect(isColored("$$ body\nline two $$", Token.string.color, in: a))
    #expect(isColored("FROM", Token.keyword.color, in: a))
  }

  @Test("line comment runs to the end of the line only")
  func lineComment() {
    let a = highlight("SELECT 1 -- note here\nFROM t")
    #expect(isColored("-- note here", Token.comment.color, in: a))
    #expect(isColored("FROM", Token.keyword.color, in: a))
  }

  @Test("multi-line block comment is comment-colored")
  func blockComment() {
    let a = highlight("SELECT 1 /* first\nsecond */ FROM t")
    #expect(isColored("/* first\nsecond */", Token.comment.color, in: a))
    #expect(isColored("FROM", Token.keyword.color, in: a))
  }

  // MARK: - Interaction rules

  @Test("keywords, functions, types and numbers inside a string are not colored as such")
  func tokensInsideStringStayString() {
    let a = highlight("SELECT 'SELECT count(1) integer 42' FROM t")
    #expect(isColored("'SELECT count(1) integer 42'", Token.string.color, in: a))
  }

  @Test("keywords, functions, types and numbers inside comments are not colored as such")
  func tokensInsideCommentStayComment() {
    let line = highlight("-- SELECT count(1) integer 42\nx")
    #expect(isColored("-- SELECT count(1) integer 42", Token.comment.color, in: line))
    let block = highlight("/* SELECT count(1) integer 42 */ x")
    #expect(isColored("/* SELECT count(1) integer 42 */", Token.comment.color, in: block))
  }

  /// Intentional change from task 2.2: the block-token alternation matches the `--` comment
  /// first, so a quoted string inside a line comment stays comment-colored.
  @Test("string inside a line comment stays comment-colored")
  func stringInsideCommentIsComment() {
    let a = highlight("-- before 'quoted' after")
    #expect(isColored("'quoted'", Token.comment.color, in: a))
    #expect(isColored("-- before ", Token.comment.color, in: a))
    #expect(isColored(" after", Token.comment.color, in: a))
  }

  @Test("comment markers inside a string stay string-colored and do not bleed past the quote")
  func commentMarkerInsideStringIsString() {
    let line = highlight("SELECT '-- not a comment' FROM t")
    #expect(isColored("'-- not a comment'", Token.string.color, in: line))
    #expect(isColored("FROM", Token.keyword.color, in: line))
    let block = highlight("SELECT '/* not a comment' FROM t")
    #expect(isColored("'/* not a comment'", Token.string.color, in: block))
    #expect(isColored("FROM", Token.keyword.color, in: block))
  }

  @Test("word in keyword and function sets: function wins before a parenthesis, keyword otherwise")
  func keywordFunctionPrecedence() {
    let a = highlight("SELECT LEFT(x, 1) FROM a LEFT JOIN b")
    #expect(isColored("LEFT", Token.function.color, in: a, occurrence: 0))
    #expect(isColored("LEFT", Token.keyword.color, in: a, occurrence: 1))
  }

  @Test("word in function and type sets is colored as a type before a parenthesis")
  func functionTypePrecedence() {
    let a = highlight("SELECT INTERVAL(x), INTERVAL")
    #expect(isColored("INTERVAL", Token.type.color, in: a, occurrence: 0))
    #expect(isColored("INTERVAL", Token.type.color, in: a, occurrence: 1))
  }

  @Test("type and function share the same color today")
  func typeAndFunctionShareColor() {
    #expect(same(Token.type.color, Token.function.color))
    #expect(!same(Token.type.color, Token.keyword.color))
  }

  @Test("empty and whitespace-only input keep the default color")
  func plainInput() {
    let a = highlight("   x   ")
    #expect(a.string == "   x   ")
    #expect(colors(of: "x", in: a) == [defaultColor])
  }

  // MARK: - Search highlighting

  private func search(
    _ text: String, query: String, caseSensitive: Bool = false, current: NSRange? = nil
  ) -> NSAttributedString {
    withSyntaxHighlightingEnabled {
      SQLSyntaxHighlighter.highlightWithSearch(
        text, searchQuery: query, isCaseSensitive: caseSensitive, currentMatchRange: current)
    }
  }

  private func background(_ a: NSAttributedString, at offset: Int) -> NSColor? {
    a.attributes(at: offset, effectiveRange: nil)[.backgroundColor] as? NSColor
  }

  private var passiveMatchBackground: NSColor {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark
      ? NSColor.white.withAlphaComponent(0.8) : NSColor.gray.withAlphaComponent(0.6)
  }

  private let currentMatchBackground = NSColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 1.0)

  @Test("search: non-current matches get the passive background and black text")
  func searchPassiveMatches() {
    let text = "SELECT a FROM a"
    let a = search(text, query: "a")
    // "a" at offsets 7 and 14
    for offset in [7, 14] {
      #expect(background(a, at: offset) == passiveMatchBackground)
      #expect(color(a, at: offset) == NSColor.black)
    }
    #expect(background(a, at: 0) == nil)
    #expect(same(color(a, at: 0), Token.keyword.color))
  }

  @Test("search: the current match gets the #FFD500 background and black text")
  func searchCurrentMatch() {
    let text = "SELECT a FROM a"
    let a = search(text, query: "a", current: NSRange(location: 14, length: 1))
    #expect(background(a, at: 14) == currentMatchBackground)
    #expect(color(a, at: 14) == NSColor.black)
    #expect(background(a, at: 7) == passiveMatchBackground)
    #expect(color(a, at: 7) == NSColor.black)
  }

  @Test("search: matching is case-insensitive unless requested otherwise")
  func searchCaseSensitivity() {
    let text = "SELECT x FROM T"
    let insensitive = search(text, query: "t")
    #expect(background(insensitive, at: 14) == passiveMatchBackground)
    let sensitive = search(text, query: "t", caseSensitive: true)
    #expect(background(sensitive, at: 14) == nil)
  }

  @Test("search: empty query leaves plain syntax highlighting untouched")
  func searchEmptyQuery() {
    let text = "SELECT a FROM a"
    let a = search(text, query: "")
    let plain = highlight(text)
    #expect(a.string == plain.string)
    for offset in 0..<text.utf16.count {
      #expect(background(a, at: offset) == nil)
      #expect(same(color(a, at: offset), color(plain, at: offset)))
    }
  }
}
