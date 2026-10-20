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

  // MARK: Text-protocol tool calls

  private let toolNames: Set<String> = ["list_tables", "run_read_query"]

  private func toolCall(_ markdown: String) throws(AIStreamError) -> AIToolCall? {
    try AIMessageParser.toolCall(in: markdown, toolNames: toolNames, id: "local-1")
  }

  private func expectInvalid(_ body: String) {
    #expect(throws: AIStreamError.self) { try toolCall("```tool\n\(body)\n```") }
  }

  @Test func toolBlockBecomesToolCall() throws {
    let markdown = """
      Let me check.
      ```tool
      {"tool": "run_read_query", "arguments": {"sql": "SELECT 1", "limit": 5}}
      ```
      """
    #expect(
      try toolCall(markdown)
        == AIToolCall(
          id: "local-1", name: "run_read_query", inputJSON: #"{"limit":5,"sql":"SELECT 1"}"#))
    // Text outside the block stays displayable text
    #expect(
      AIMessageParser.parse(markdown, dialect: .postgresql).first == .text("Let me check."))
    let empty = "```tool\n{\"tool\": \"list_tables\", \"arguments\": {}}\n```"
    #expect(try toolCall(empty)?.inputJSON == "{}")
  }

  /// `1e999` fails to parse; `-1e999` parses to -inf, which would raise when serialized
  @Test(arguments: ["1e999", "-1e999"])
  func nonFiniteToolArgumentThrows(number: String) {
    #expect(throws: AIStreamError.invalidToolCall("The model sent a malformed tool call.")) {
      try toolCall("```tool\n{\"tool\": \"list_tables\", \"arguments\": {\"x\": \(number)}}\n```")
    }
  }

  @Test func onlyTheFirstToolBlockCounts() throws {
    let markdown = """
      ```sql
      SELECT 1
      ```
      ```tool
      {"tool": "list_tables", "arguments": {}}
      ```
      ```tool
      {"tool": "run_read_query", "arguments": {"sql": "SELECT 2"}}
      ```
      """
    #expect(try toolCall(markdown)?.name == "list_tables")
  }

  @Test func noClosedToolBlockIsNil() throws {
    #expect(try toolCall("No tools needed.\n```sql\nSELECT 1\n```") == nil)
    #expect(try toolCall("```tool\n{\"tool\": \"list_tables\", \"arguments\": {}}") == nil)
  }

  @Test(arguments: [
    #"{"tool": "drop_everything", "arguments": {}}"#,
    #"{"tool": 1, "arguments": {}}"#,
    #"{"tool": "list_tables"}"#,
    #"{"tool": "list_tables", "arguments": "{}"}"#,
    #"{"tool": "list_tables", "arguments": []}"#,
    #"{"tool": "list_tables", "arguments": {}, "extra": true}"#,
    #"{"tool": "list_tables", "arguments": {} /* note */}"#,
    #"[{"tool": "list_tables", "arguments": {}}]"#,
    "list_tables()",
    "",
  ])
  func invalidToolBlockThrows(body: String) {
    expectInvalid(body)
  }

  @Test func oversizedToolBlockThrows() {
    let sql = String(repeating: "x", count: AISSEParser.maxToolInputBytes)
    expectInvalid(#"{"tool": "run_read_query", "arguments": {"sql": "\#(sql)"}}"#)
  }

  @Test func unknownToolErrorIsGeneric() {
    #expect(throws: AIStreamError.invalidToolCall("The model called a tool that was not offered."))
    {
      try toolCall("```tool\n{\"tool\": \"evil\", \"arguments\": {}}\n```")
    }
  }

  @Test func textProtocolSectionListsToolsAndBlockShape() {
    let tool = AIToolSpec(
      name: "run_read_query", description: "Run one read-only query",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["sql": .object(["type": .string("string")])]),
      ]))
    let section = AITextToolProtocol.systemSection(tools: [tool])
    #expect(section.contains("```tool"))
    #expect(section.contains(#""tool""#) && section.contains(#""arguments""#))
    #expect(
      section.contains(
        #"- run_read_query: Run one read-only query"#
          + "\n" + #"  Arguments schema: {"properties":{"sql":{"type":"string"}},"type":"object"}"#
      ))
  }
}
