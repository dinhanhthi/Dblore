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

  @Test func parseMarksOnlySQLRunFencesAsRun() {
    #expect(
      AIMessageParser.parse(
        "```sql run\nSELECT 1\n```\n```sql\nSELECT 2\n```\n```python run\nx\n```")
        == [
          .code(language: "sql", body: "SELECT 1", isRun: true),
          .code(language: "sql", body: "SELECT 2", isRun: false),
          .code(language: "python", body: "x", isRun: false),
        ])
  }

  @Test(arguments: [
    ("```sql run\n  SELECT 1\n```", "SELECT 1"),
    ("```SQL RUN\nSELECT 1\n```", "SELECT 1"),
    ("```postgresql run\nSELECT 1\n```", "SELECT 1"),
    ("Text\n```sql run\nSELECT 1\n```\n```sql run\nSELECT 2\n```", "SELECT 1"),
  ])
  func runQueryReturnsFirstClosedRunFenceBody(markdown: String, expected: String) {
    #expect(AIMessageParser.runQuery(in: markdown) == expected)
  }

  @Test(arguments: [
    "```sql run\nSELECT 1",
    "```sql\nSELECT 1\n```",
    "```\nSELECT 1\n```",
    "```python run\nprint(1)\n```",
    "```sql run\n  \n```",
    "No code here",
  ])
  func runQueryIsNilWithoutClosedNonEmptyRunFence(markdown: String) {
    #expect(AIMessageParser.runQuery(in: markdown) == nil)
  }

  @Test func nilLanguageIsSQLAndOthersAreNot() {
    #expect(AIMessageParser.isSQL(language: nil))
    #expect(!AIMessageParser.isSQL(language: "python"))
  }

  @Test func selectIsReadOnly() {
    #expect(AIMessageParser.isReadOnly("SELECT * FROM users", dialect: .postgresql))
  }

  @Test(arguments: [
    "DELETE FROM users",
    "DROP TABLE users",
    "WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d",
    "SELECT 1; DELETE FROM users",
  ])
  func modifyingStatementsAreNotReadOnly(sql: String) {
    #expect(!AIMessageParser.isReadOnly(sql, dialect: .postgresql))
  }

  @Test func explainAnalyzeUpdateIsNotReadOnly() {
    // The classifier reports .explain(inner: .dml, analyze: true), which is not read-only safe.
    #expect(
      !AIMessageParser.isReadOnly("EXPLAIN ANALYZE UPDATE users SET a = 1", dialect: .postgresql))
  }
}
