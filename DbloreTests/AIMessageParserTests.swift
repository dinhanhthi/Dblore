// AIMessageParserTests.swift
// Tests for splitting assistant markdown into text / code segments and SQL safety checks

import Foundation
import Testing

@testable import Dblore

@Suite("AIMessageParser")
struct AIMessageParserTests {

  @Test func mixedTextAndCodeKeepsOrder() {
    let markdown = "Here you go:\n```sql\nSELECT 1;\n```\nThen run it.\n```\nplain\n```"
    #expect(
      AIMessageParser.parse(markdown) == [
        .text("Here you go:"),
        .code(language: "sql", body: "SELECT 1;"),
        .text("Then run it."),
        .code(language: nil, body: "plain"),
      ])
  }

  @Test func unclosedTrailingFenceBecomesCode() {
    #expect(
      AIMessageParser.parse("Try:\n```sql\nSELECT *\nFROM t")
        == [.text("Try:"), .code(language: "sql", body: "SELECT *\nFROM t")])
  }

  @Test func fenceWithoutLanguageHasNilLanguage() {
    #expect(AIMessageParser.parse("```\nx\n```") == [.code(language: nil, body: "x")])
  }

  @Test func plainTextIsOneSegment() {
    #expect(AIMessageParser.parse("Hello\nworld") == [.text("Hello\nworld")])
  }

  @Test func emptyInputHasNoSegments() {
    #expect(AIMessageParser.parse("").isEmpty)
  }

  @Test(arguments: ["sql", "SQL", "postgresql", "postgres", "psql", "pgsql"])
  func sqlLanguagesAreSQL(language: String) {
    #expect(AIMessageParser.isSQL(language: language))
  }

  @Test func nilLanguageIsSQLAndOthersAreNot() {
    #expect(AIMessageParser.isSQL(language: nil))
    #expect(!AIMessageParser.isSQL(language: "python"))
  }

  @Test func selectIsReadOnly() {
    #expect(AIMessageParser.isReadOnly("SELECT * FROM users"))
  }

  @Test func emptySQLIsReadOnly() {
    #expect(AIMessageParser.isReadOnly(""))
  }

  @Test(arguments: [
    "DELETE FROM users",
    "DROP TABLE users",
    "WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d",
    "SELECT 1; DELETE FROM users",
  ])
  func modifyingStatementsAreNotReadOnly(sql: String) {
    #expect(!AIMessageParser.isReadOnly(sql))
  }

  @Test func explainAnalyzeUpdateIsNotReadOnly() {
    // The classifier reports .explain(inner: .dml, analyze: true), which is not read-only safe.
    #expect(!AIMessageParser.isReadOnly("EXPLAIN ANALYZE UPDATE users SET a = 1"))
  }
}
