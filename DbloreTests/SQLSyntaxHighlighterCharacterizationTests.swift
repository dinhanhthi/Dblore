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

  // MARK: - Interaction rules

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

  private var passiveMatchBackground: NSColor { NSColor(SearchHighlighter.highlightColor) }

  private let currentMatchBackground = NSColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 1.0)

  @Test("search: matching is case-insensitive unless requested otherwise")
  func searchCaseSensitivity() {
    let text = "SELECT x FROM T"
    let insensitive = search(text, query: "t")
    #expect(background(insensitive, at: 14) == passiveMatchBackground)
    let sensitive = search(text, query: "t", caseSensitive: true)
    #expect(background(sensitive, at: 14) == nil)
  }
}
