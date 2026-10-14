// SQLSyntaxHighlighterTests.swift
// Unit tests for SQLSyntaxHighlighter utility
// Converted to Swift Testing framework

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("SQL Syntax Highlighter Tests")
@MainActor
struct SQLSyntaxHighlighterTests {

  // MARK: - Keyword Detection Tests

  // MARK: - Function Detection Tests

  // MARK: - String Literal Tests

  // MARK: - Number Tests

  // MARK: - Comment Tests

  // MARK: - Operator Tests

  // MARK: - Complex Query Tests

  // MARK: - Edge Cases

  // MARK: - PostgreSQL Specific Tests

  // MARK: - UTF-16 Coverage Tests

  private func components(_ color: NSColor?) -> [CGFloat]? {
    guard let c = color?.usingColorSpace(.sRGB) else { return nil }
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
  }

  @Test("Font covers every UTF-16 unit with emoji/CJK")
  func fontCoversEveryUTF16Unit() {
    let sql = "SELECT '😀日本' AS a, 😀😀😀 FROM t WHERE x = 1"
    let attributed = withSyntaxHighlightingEnabled { SQLSyntaxHighlighter.highlight(sql) }
    let length = (sql as NSString).length
    #expect(attributed.length == length)
    for i in 0..<length {
      #expect(attributed.attribute(.font, at: i, effectiveRange: nil) != nil)
    }
  }

  @Test("plainText covers full UTF-16 length")
  func plainTextCoversFullLength() {
    let settings = AppSettings.shared
    let previous = settings.syntaxHighlightingEnabled
    settings.syntaxHighlightingEnabled = false
    defer { settings.syntaxHighlightingEnabled = previous }

    let sql = "SELECT '😀日本' FROM t"
    let attributed = SQLSyntaxHighlighter.highlight(sql)
    let length = (sql as NSString).length
    for i in 0..<length {
      #expect(attributed.attribute(.font, at: i, effectiveRange: nil) != nil)
    }
  }

  // MARK: - Token Colors

  /// sRGB hex of a (dynamic) color; `NSColor(Color)` instances never compare equal
  private func hex(_ color: NSColor?) -> String? {
    guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
    return String(
      format: "%02X%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
      Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255))
  }

  private func hex(_ color: Color) -> String? { hex(NSColor(color)) }

  /// Foreground color (sRGB hex) at the `occurrence`-th occurrence of `token`
  private func color(
    of token: String, in sql: String, occurrence: Int = 0
  ) -> String? {
    let attributed = withSyntaxHighlightingEnabled { SQLSyntaxHighlighter.highlight(sql) }
    var range = (sql as NSString).range(of: token)
    for _ in 0..<occurrence {
      let start = range.upperBound
      range = (sql as NSString).range(
        of: token, range: NSRange(location: start, length: (sql as NSString).length - start))
    }
    return hex(
      attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
  }

  @Test("Token colors: keyword, function, type, number, string, identifier")
  func tokenColors() {
    let sql = "select count(id), x::int FROM t WHERE n = 42 AND s = 'abc'"
    #expect(color(of: "select", in: sql) == hex(Color.syntaxKeyword))
    #expect(color(of: "count", in: sql) == hex(Color.syntaxFunction))
    #expect(color(of: "int", in: sql) == hex(Color.syntaxFunction))
    #expect(color(of: "42", in: sql) == hex(Color.syntaxNumber))
    #expect(color(of: "'abc'", in: sql) == hex(Color.syntaxString))
    #expect(color(of: "id", in: sql) == hex(Color.foreground))
  }

  // MARK: - Performance Tests

  // MARK: - Equivalence with the original regexes

  private static let oldBlockRegex = try! NSRegularExpression(
    pattern: "--[^\n]*|/\\*[\\s\\S]*?\\*/|'(?:[^'\\\\]|\\\\.)*'|\\$\\$[\\s\\S]*?\\$\\$")
  private static let oldNumberRegex = try! NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b")

  private func randomStrings(
    count: Int, alphabet: [String], maxLength: Int, seed: UInt64
  )
    -> [String]
  {
    var rng = SeededGenerator(seed: seed)
    return (0..<count).map { _ in
      let length = Int(rng.next() % UInt64(maxLength + 1))
      return (0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }.joined()
    }
  }

}
