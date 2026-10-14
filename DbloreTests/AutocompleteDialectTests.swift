// AutocompleteDialectTests.swift
// Autocomplete, syntax highlighting and the AI read-only badge follow the connection dialect.

import AppKit
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Autocomplete, highlighter and AI dialect")
struct AutocompleteDialectTests {

  // MARK: - Autocomplete statement window

  @Test("MySQL window ignores a ; inside a # comment, backticks or a backslash string")
  func mysqlWindowIsLexed() {
    let provider = SQLAutocompleteProvider()
    for text in [
      "SELECT 1 # a;b\nFROM us",
      "SELECT `a;b` FROM us",
      "SELECT 'a\\';b' FROM us",
    ] {
      let window = provider.statementWindow(in: text, at: utf16(text), dialect: .mysql)
      #expect(window.text == text)
    }
  }

  @Test("MySQL window still splits at a real ;")
  func mysqlWindowSplits() {
    let provider = SQLAutocompleteProvider()
    let text = "SELECT 1; SELECT x FROM us"
    let window = provider.statementWindow(in: text, at: utf16(text), dialect: .mysql)
    #expect(window.text == " SELECT x FROM us")
  }

  @Test("PostgreSQL and SQLite windows are unchanged")
  func otherWindowsUnchanged() {
    let provider = SQLAutocompleteProvider()
    let text = "SELECT 1 # a;b\nFROM us"
    #expect(
      provider.statementWindow(in: text, at: utf16(text), dialect: .postgresql).text
        == "b\nFROM us")
    let quoted = "SELECT 'a;b' FROM us"
    #expect(
      provider.statementWindow(in: quoted, at: utf16(quoted), dialect: .sqlite).text == quoted)
  }

  @Test("MySQL suggestions see the table referenced before a # comment holding ;")
  func mysqlSuggestionsUseDialect() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      DatabaseTable(
        schema: "shop", name: "users",
        columns: [DatabaseColumn(name: "user_id", type: "int")]),
      DatabaseTable(
        schema: "shop", name: "orders",
        columns: [DatabaseColumn(name: "us_total", type: "int")]),
    ])
    let text = "SELECT us # pick;\nFROM users"
    let cursor = utf16("SELECT us")
    let mysql = provider.getSuggestions(for: text, at: cursor, dialect: .mysql).map(\.text)
    #expect(mysql.contains("user_id"))
    #expect(!mysql.contains("us_total"))
  }

  // MARK: - Highlighter block spans

  // MARK: - Highlighter keywords

  // MARK: - AI read-only badge

  @Test("AI read-only check follows the dialect")
  func aiReadOnlyUsesDialect() {
    let sql = "SELECT 1 # '\n; DELETE FROM users -- '"
    #expect(AIMessageParser.isReadOnly(sql, dialect: .postgresql))
    #expect(!AIMessageParser.isReadOnly(sql, dialect: .mysql))
  }

  // MARK: - Helpers

  private func utf16(_ text: String) -> Int { (text as NSString).length }

  private func makeDefaults() -> UserDefaults {
    let name = "AutocompleteDialectTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
  }

  /// Block spans as (text, kind): "c" comment, "s" string, "i" quoted identifier
  private func blockSpans(_ text: String, _ dialect: SQLDialect) -> [(text: String, kind: String)] {
    let ns = text as NSString
    return SQLSyntaxHighlighter.scanBlockSpans(
      in: ns, range: NSRange(location: 0, length: ns.length), dialect: dialect
    ).map { span in
      let kind: String
      switch span.kind {
      case .comment: kind = "c"
      case .string: kind = "s"
      case .identifier: kind = "i"
      }
      return (ns.substring(with: span.range), kind)
    }
  }

  /// One letter per UTF-16 unit: k keyword, f function/type, s string, c comment, n number,
  /// "." default; newlines are kept
  private func colorString(_ text: String, _ dialect: SQLDialect) -> String {
    let storage = NSMutableAttributedString(string: text)
    let palette = SQLSyntaxHighlighter.Palette()
    let full = NSRange(location: 0, length: storage.length)
    storage.addAttributes(palette.defaultAttributes, range: full)
    SQLSyntaxHighlighter.highlight(in: storage, range: full, palette: palette, dialect: dialect)
    let ns = text as NSString
    var result = ""
    for offset in 0..<storage.length {
      if ns.character(at: offset) == 0x0A {
        result += "\n"
        continue
      }
      let color = storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as AnyObject
      switch color {
      case let c where c === palette.keyword: result += "k"
      case let c where c === palette.function: result += "f"
      case let c where c === palette.string: result += "s"
      case let c where c === palette.comment: result += "c"
      case let c where c === palette.number: result += "n"
      default: result += "."
      }
    }
    return result
  }
}
