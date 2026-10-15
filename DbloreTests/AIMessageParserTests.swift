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
      AIMessageParser.parse(markdown, dialect: .postgresql) == [
        .text("Here you go:"),
        .code(language: "sql", body: "SELECT 1;"),
        .text("Then run it."),
        .code(language: nil, body: "plain"),
      ])
  }

  @Test func unclosedTrailingFenceBecomesCode() {
    #expect(
      AIMessageParser.parse("Try:\n```sql\nSELECT *\nFROM t", dialect: .postgresql)
        == [.text("Try:"), .code(language: "sql", body: "SELECT *\nFROM t")])
  }

  @Test func parseMarksOnlySQLRunFencesAsRun() {
    #expect(
      AIMessageParser.parse(
        "```sql run\nSELECT 1\n```\n```sql\nSELECT 2\n```\n```python run\nx\n```",
        dialect: .postgresql)
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
    #expect(AIMessageParser.runQuery(in: markdown, dialect: .postgresql) == expected)
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
    #expect(AIMessageParser.runQuery(in: markdown, dialect: .postgresql) == nil)
  }

  @Test func nilLanguageIsSQLAndOthersAreNot() {
    #expect(AIMessageParser.isRunnable(language: nil, dialect: .postgresql))
    #expect(!AIMessageParser.isRunnable(language: "python", dialect: .postgresql))
  }

  // MARK: - Fences per tab type

  @Test(arguments: [
    ("sql", true, false), ("SQL", true, false), ("postgresql", true, false),
    ("postgres", true, false), ("psql", true, false), ("pgsql", true, false),
    ("mongodb", false, true), ("MongoDB", false, true), ("js", false, true),
    ("javascript", false, true), ("python", false, false),
  ])
  func fenceLanguagesAreRunnablePerTabType(language: String, onSQL: Bool, onMongo: Bool) {
    #expect(AIMessageParser.isRunnable(language: language, dialect: .postgresql) == onSQL)
    #expect(AIMessageParser.isRunnable(language: language, dialect: .mysql) == onSQL)
    #expect(AIMessageParser.isRunnable(language: language, dialect: .mongodb) == onMongo)
  }

  @Test func untaggedFenceIsRunnableOnEveryTabType() {
    #expect(AIMessageParser.isRunnable(language: nil, dialect: .mongodb))
  }

  @Test func runMarkerFollowsTheTabType() {
    let markdown = "```js run\ndb.c.find()\n```\n```sql run\nSELECT 1\n```"
    #expect(
      AIMessageParser.parse(markdown, dialect: .mongodb) == [
        .code(language: "js", body: "db.c.find()", isRun: true),
        .code(language: "sql", body: "SELECT 1", isRun: false),
      ])
    #expect(
      AIMessageParser.parse(markdown, dialect: .postgresql) == [
        .code(language: "js", body: "db.c.find()", isRun: false),
        .code(language: "sql", body: "SELECT 1", isRun: true),
      ])
    #expect(AIMessageParser.runQuery(in: markdown, dialect: .mongodb) == "db.c.find()")
    #expect(AIMessageParser.runQuery(in: markdown, dialect: .postgresql) == "SELECT 1")
    #expect(
      AIMessageParser.runQuery(in: "```mongodb run\ndb.c.find()\n```", dialect: .postgresql)
        == nil)
  }

  // MARK: - MongoDB read-only check (MongoCommandClassifier)

  @Test(arguments: [
    "db.orders.find({status: \"open\"}).limit(10)",
    "db.getCollection(\"orders\").countDocuments({})",
    "db.orders.aggregate([{$group: {_id: \"$city\", n: {$sum: 1}}}])",
    "show collections",
  ])
  func mongoReadsAreReadOnly(command: String) {
    #expect(AIMessageParser.isReadOnly(command, dialect: .mongodb))
  }

  @Test(arguments: [
    "db.orders.deleteMany({})",
    "db.orders.updateOne({_id: 1}, {$set: {a: 1}})",
    "db.orders.aggregate([{$match: {}}, {$out: \"copy\"}])",
    "db.orders.find({}); db.orders.deleteMany({})",
    "db.orders.findOne({})",
    "db.orders.find().toArray()",
    "const x = db.orders.find()",
    "SELECT * FROM orders",
  ])
  func mongoWritesAndUnparseableAreNotReadOnly(command: String) {
    #expect(!AIMessageParser.isReadOnly(command, dialect: .mongodb))
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
