// RedisSyntaxHighlighterTests.swift
// Token categories of the Redis highlighter (redis-cli quoting, one command per line) and its
// delegation from SQLSyntaxHighlighter for the Redis dialect.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("Redis Syntax Highlighter Tests")
@MainActor
struct RedisSyntaxHighlighterTests {
  typealias TokenType = SQLSyntaxHighlighter.TokenType

  // MARK: - Helpers

  private func tokens(_ text: String) -> [RedisSyntaxHighlighter.Token] {
    let ns = text as NSString
    return RedisSyntaxHighlighter.tokens(in: ns, range: NSRange(location: 0, length: ns.length))
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
  private func type(of needle: String, in text: String, occurrence: Int = 0) -> TokenType? {
    let target = range(of: needle, in: text, occurrence: occurrence)
    return tokens(text).first { $0.range == target }?.type
  }

  /// Type of the token containing the first character of `needle`
  private func typeAt(_ needle: String, in text: String, occurrence: Int = 0) -> TokenType? {
    let location = range(of: needle, in: text, occurrence: occurrence).location
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

  @Test("Known commands and their subcommands are keywords, in any case")
  func commandsAndSubcommands() {
    let text = "get key\n  CONFIG get maxmemory\nFOO bar\nSET get 10"
    #expect(type(of: "get", in: text) == .keyword)
    #expect(type(of: "CONFIG", in: text) == .keyword)
    #expect(type(of: "get", in: text, occurrence: 1) == .keyword)
    #expect(typeAt("maxmemory", in: text) == nil)
    #expect(typeAt("key", in: text) == nil)
    // Unknown command, and a subcommand name after a command that takes none
    #expect(typeAt("FOO", in: text) == nil)
    #expect(type(of: "SET", in: text) == .keyword)
    #expect(typeAt("get", in: text, occurrence: 2) == nil)
    #expect(type(of: "10", in: text) == .number)
  }

  @Test("Quoted strings keep their escapes; # starts a comment only at the line start")
  func stringsAndComments() {
    let text = #"SET k "a\"b\x41" 'it\'s'"# + "\n  # note\nSET k #v"
    #expect(type(of: #""a\"b\x41""#, in: text) == .string)
    #expect(type(of: #"'it\'s'"#, in: text) == .string)
    #expect(type(of: "# note", in: text) == .comment)
    #expect(typeAt("#v", in: text) == nil)
    // A quote opens mid-word, as redis-cli reads it
    #expect(type(of: "\"b c\"", in: "SET a\"b c\" x") == .string)
  }

  @Test("Unterminated quotes and a \\x without two hex digits run to the line end")
  func unterminated() {
    let text = "SET k \"abc\\x\nGET 'x\\\nDEL k\nSET k \"\\x\" v\nSET k \"\\x4\" v\nGET k"
    #expect(type(of: "\"abc\\x", in: text) == .string)
    #expect(type(of: "GET", in: text) == .keyword)
    #expect(type(of: "'x\\", in: text) == .string)
    #expect(type(of: "DEL", in: text) == .keyword)
    // The tokenizer refuses these escapes, so the closing quote does not end the string
    #expect(type(of: "\"\\x\" v", in: text) == .string)
    #expect(type(of: "\"\\x4\" v", in: text) == .string)
    #expect(type(of: "GET", in: text, occurrence: 1) == .keyword)
    for broken in ["\"", "'", "SET \"\\", "SET '\\", "#", "SET k \"\\x4"] {
      let ns = broken as NSString
      let found = tokens(broken)
      #expect(found.allSatisfy { NSMaxRange($0.range) <= ns.length })
    }
  }

  // MARK: - Delegation

  @Test("SQLSyntaxHighlighter delegates for the Redis dialect, rehighlighting the whole text")
  func delegation() {
    let text = "HSET h f \"v\" -- x\nselect"
    let attributed = withSyntaxHighlightingEnabled {
      SQLSyntaxHighlighter.highlight(text, dialect: .redis)
    }
    let ns = text as NSString
    #expect(same(color(attributed, at: 0), NSColor(Color.syntaxKeyword)))
    #expect(
      same(color(attributed, at: ns.range(of: "\"v\"").location), NSColor(Color.syntaxString)))
    #expect(!same(color(attributed, at: ns.range(of: "x").location), NSColor(Color.syntaxComment)))
    #expect(
      SQLSyntaxHighlighter.blockSpans(in: ns, dialect: .redis) == [ns.range(of: "\"v\"")])

    let storage = NSMutableAttributedString(string: text)
    withSyntaxHighlightingEnabled {
      let palette = SQLSyntaxHighlighter.Palette()
      storage.addAttributes(
        palette.defaultAttributes, range: NSRange(location: 0, length: storage.length))
      SQLSyntaxHighlighter.rehighlight(
        storage: storage, range: ns.range(of: "select"), palette: palette, dialect: .redis)
    }
    #expect(same(color(storage, at: 0), NSColor(Color.syntaxKeyword)))
  }
}
