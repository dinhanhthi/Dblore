// AIInlineCompletionTests.swift
// Tests for ghost text: caret context, reply sanitizer, request and inline settings

import Foundation
import Testing

@testable import Dblore

@Suite("AI Inline Completion")
struct AIInlineCompletionTests {

  private func context(
    _ text: String, caret: Int? = nil, isReadOnlySource: Bool = false
  ) -> AIInlineCompletion.Context? {
    AIInlineCompletion.context(
      text: text, caret: caret ?? text.utf16.count, dialect: .postgresql, schema: nil,
      isReadOnlySource: isReadOnlySource)
  }

  // MARK: - Context

  @Test func splitsTheTextAtTheUTF16Caret() throws {
    let text = "SELECT 😀 \nFROM t WHERE"
    let caret = ("SELECT 😀" as NSString).length
    let result = try #require(context(text, caret: caret))
    #expect(result.prefix == "SELECT 😀")
    #expect(result.suffix == " \nFROM t WHERE")
    #expect(result.dialect == .postgresql)
  }

  @Test func capsPrefixAndSuffixAtTheirLimits() throws {
    let before = String(repeating: "a", count: 2_100) + "SELECT"
    let after = "\n" + String(repeating: "b", count: 600)
    let result = try #require(context(before + after, caret: before.utf16.count))
    #expect(result.prefix.count == 2_000)
    #expect(result.prefix.hasSuffix("SELECT"))
    #expect(result.suffix == "\n" + String(repeating: "b", count: 499))
  }

  @Test func capsCountCharactersAndNeverSplitAnEmoji() throws {
    // Each family emoji is one character of several UTF-16 units
    let family = "👨‍👩‍👧"
    let before = String(repeating: family, count: 2_001)
    let after = "\n" + String(repeating: family, count: 501)
    let result = try #require(context(before + after, caret: before.utf16.count))
    #expect(result.prefix == String(repeating: family, count: 2_000))
    #expect(result.suffix == "\n" + String(repeating: family, count: 499))
  }

  @Test func textAfterTheCaretOnItsLineGivesNothing() {
    // Ghost text would be drawn over it
    #expect(context("SELECT  * FROM orders", caret: 7) == nil)
    #expect(context("SELECT x\n", caret: 7) == nil)
    #expect(context("SELECT  \t\nFROM t", caret: 7) != nil)
    #expect(context("SELECT ") != nil)
  }

  @Test func suggestionLinesGoOnlyOverBlankLinesBelowTheCaret() {
    // Nothing after the caret line: one line
    #expect(context("SELECT *")?.maxLines == 1)
    // Each blank line after it holds one more line, up to the cap
    #expect(context("SELECT *\n", caret: 8)?.maxLines == 2)
    #expect(context("SELECT *\n  \n", caret: 8)?.maxLines == 3)
    #expect(context("SELECT *\n\n\n\n\n", caret: 8)?.maxLines == AIInlineCompletion.maxLines)
    // Any later line with text: one line
    #expect(context("SELECT *\n\nSELECT 2", caret: 8)?.maxLines == 1)
  }

  @Test func aCaretInsideACharacterOrOutsideTheTextGivesNothing() {
    // 1 is between the two UTF-16 units of the emoji
    #expect(context("😀 x", caret: 1) == nil)
    #expect(context("SELECT", caret: 7) == nil)
    #expect(context("SELECT", caret: -1) == nil)
  }

  @Test func readOnlySourceGivesNothing() {
    #expect(context("CREATE VIEW v AS SELECT", isReadOnlySource: true) == nil)
  }

  @Test func blankTextBeforeTheCaretGivesNothing() {
    #expect(context("") == nil)
    #expect(context("  \n", caret: 3) == nil)
    #expect(context("  \nSELECT", caret: 3) == nil)
    #expect(context("SELECT\n") != nil)
  }

  // MARK: - Sanitizer

  @Test func stripsOneLeadingAndTrailingFence() {
    #expect(
      AIInlineCompletion.sanitize("```sql\n* FROM users\n```", prefix: "SELECT ") == "* FROM users")
    #expect(
      AIInlineCompletion.sanitize("\n```\n* FROM users\n```\n", prefix: "SELECT ") == "* FROM users"
    )
  }

  @Test func keepsLeadingSpaceWithoutAFence() {
    #expect(AIInlineCompletion.sanitize(" * FROM users", prefix: "SELECT") == " * FROM users")
  }

  @Test func removesAnEchoedLineOrPrefixOrWord() {
    let prefix = "-- list\nSELECT * FROM us"
    #expect(AIInlineCompletion.sanitize("SELECT * FROM users", prefix: prefix) == "ers")
    #expect(AIInlineCompletion.sanitize(prefix + "ers LIMIT 10", prefix: prefix) == "ers LIMIT 10")
    #expect(AIInlineCompletion.sanitize("users", prefix: prefix) == "ers")
    #expect(AIInlineCompletion.sanitize("  SELECT 1", prefix: "x;\n  SELECT") == " 1")
  }

  @Test func removesAnEchoAcrossALineBreakOfAnyKind() {
    let prefix = "SELECT *\r\nFROM us"
    #expect(AIInlineCompletion.sanitize("SELECT *\nFROM users", prefix: prefix) == "ers")
    #expect(AIInlineCompletion.sanitize("SELECT *\r\nFROM users", prefix: prefix) == "ers")
    #expect(
      AIInlineCompletion.sanitize("SELECT *\nFROM users", prefix: "SELECT *\rFROM us") == "ers")
  }

  @Test func neverCutsAnEchoInsideAWord() {
    #expect(AIInlineCompletion.sanitize("okings", prefix: "SELECT * FROM bo") == "okings")
    #expect(AIInlineCompletion.sanitize("l", prefix: "WHERE a IS nul") == "l")
  }

  @Test func dropsALeadingNewlineOnlyAfterANewline() {
    #expect(AIInlineCompletion.sanitize("\nFROM t", prefix: "SELECT *\n") == "FROM t")
    #expect(AIInlineCompletion.sanitize("\nFROM t", prefix: "SELECT *") == "\nFROM t")
  }

  @Test func keepsTheLinesTheContextAllows() {
    #expect(AIInlineCompletion.sanitize("a\nb\nc", prefix: "SELECT ", maxLines: 1) == "a")
    #expect(AIInlineCompletion.sanitize("a\nb\nc", prefix: "SELECT ", maxLines: 2) == "a\nb")
  }

  @Test func everyLineBreakCountsAsALine() {
    #expect(AIInlineCompletion.sanitize("a\rb\rc", prefix: "SELECT ", maxLines: 1) == "a")
    #expect(AIInlineCompletion.sanitize("a\u{2028}b\u{2029}c", prefix: "SELECT ") == "a\nb\nc")
    #expect(AIInlineCompletion.sanitize("a\u{0B}b", prefix: "SELECT ", maxLines: 1) == "a")
  }

  @Test func keepsThreeLinesAndThreeHundredCharacters() {
    #expect(AIInlineCompletion.sanitize("a\nb\nc\nd\ne", prefix: "SELECT ") == "a\nb\nc")
    #expect(AIInlineCompletion.sanitize("a\r\nb\r\nc\r\nd", prefix: "SELECT ") == "a\nb\nc")
    let long = String(repeating: "x", count: 400)
    #expect(AIInlineCompletion.sanitize(long, prefix: "SELECT ")?.count == 300)
  }

  @Test func emptyOrEchoOnlyRepliesGiveNothing() {
    #expect(AIInlineCompletion.sanitize("", prefix: "SELECT ") == nil)
    #expect(AIInlineCompletion.sanitize("  \n\t", prefix: "SELECT ") == nil)
    #expect(AIInlineCompletion.sanitize("```sql\n```", prefix: "SELECT ") == nil)
    #expect(AIInlineCompletion.sanitize("SELECT * FROM t", prefix: "SELECT * FROM t") == nil)
  }

  // MARK: - Request

  @Test func requestIsOneShotWithoutToolsAndASmallBudget() throws {
    let input = try #require(context("SELECT * FROM "))
    let request = AIInlineCompletion.request(input, model: "m")
    #expect(request.model == "m")
    #expect(request.maxTokens == 96)
    #expect(request.tools.isEmpty)
    #expect(request.messages.count == 1)
    #expect(request.messages.first?.role == .user)
    #expect(
      request.messages.first?.text.contains("<before_caret>SELECT * FROM </before_caret>") == true)
  }

  @Test func schemaHelperKeepsTheTablesTheTextNamesWithinItsBudget() {
    let tables = (0..<200).map {
      DatabaseTable(
        schema: "public", name: "table_\($0)",
        columns: [DatabaseColumn(name: "column_with_a_long_name", type: "text")])
    }
    let named = [DatabaseTable(schema: "public", name: "invoices", columns: [])] + tables
    let schema = AIInlineCompletion.schema(
      prefix: "SELECT * FROM invoices", tables: named, foreignKeys: [])
    #expect(schema.hasPrefix("public.invoices"))
    #expect(!schema.contains("table_"))
    let fallback = AIInlineCompletion.schema(prefix: "SELECT ", tables: tables, foreignKeys: [])
    #expect(fallback.count <= 1_500 + 40)
  }

  @Test func schemaHelperReadsOnlyTheStatementAtTheCaret() async {
    let tables = [
      DatabaseTable(schema: "public", name: "invoices", columns: []),
      DatabaseTable(schema: "public", name: "orders", columns: []),
    ]
    let schema = await AIInlineCompletion.schemaOffMain(
      prefix: "SELECT * FROM invoices;\nSELECT * FROM orders", tables: tables, foreignKeys: [])
    #expect(schema == "public.orders()")
  }

  // MARK: - Settings

  @Test func oldConfigurationDecodesWithInlineDefaults() throws {
    let old = #"{"activeProvider":"ollama","configs":{"ollama":{"baseURL":"u","model":"m"}}}"#
    let config = try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8))
    #expect(config.inlineEnabled == false)
    #expect(config.inlineProvider == nil)
    #expect(config.inlineModel == nil)
    #expect(config.inlineDebounceMs == 400)
    #expect(AIConfiguration.empty.inlineEnabled == false)
    #expect(AIConfiguration.empty.inlineDebounceMs == 400)
  }

  @Test func inlineSettingsRoundTripAndAnUnknownProviderFallsBack() throws {
    let config = AIConfiguration(
      activeProvider: .anthropic, configs: [:], inlineEnabled: true, inlineProvider: .ollama,
      inlineModel: "qwen", inlineDebounceMs: 250)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: data) == config)

    let future = #"{"configs":{},"inlineEnabled":true,"inlineProvider":"fromTheFuture"}"#
    let decoded = try JSONDecoder().decode(AIConfiguration.self, from: Data(future.utf8))
    #expect(decoded.inlineProvider == nil)
    #expect(decoded.inlineEnabled)
  }

  @Test func inlineTargetFallsBackToTheChatProviderAndModel() {
    var config = AIConfiguration(
      activeProvider: .anthropic,
      configs: [
        .anthropic: AIProviderConfig(baseURL: "a", model: "claude"),
        .ollama: AIProviderConfig(baseURL: "o", model: "llama"),
      ])
    #expect(config.inlineTarget?.provider == .anthropic)
    #expect(config.inlineTarget?.model == "claude")

    config.inlineProvider = .ollama
    #expect(config.inlineTarget?.provider == .ollama)
    #expect(config.inlineTarget?.model == "llama")

    config.inlineModel = "qwen"
    #expect(config.inlineTarget?.model == "qwen")
    config.inlineModel = ""
    #expect(config.inlineTarget?.model == "llama")

    // An inline model belongs to the inline provider: without one it is not used
    config.inlineProvider = nil
    config.inlineModel = "qwen"
    #expect(config.inlineTarget?.model == "claude")
  }

  @Test func onDeviceInlineTargetIsAlwaysTheChatModel() {
    var config = AIConfiguration(
      activeProvider: .anthropic,
      configs: [.localMLX: AIProviderConfig(baseURL: "", model: "local-chat")],
      inlineProvider: .localMLX, inlineModel: "other-local")
    #expect(config.inlineTarget?.provider == .localMLX)
    #expect(config.inlineTarget?.model == "local-chat")

    config.inlineProvider = nil
    config.activeProvider = .localMLX
    #expect(config.inlineTarget?.model == "local-chat")
  }

  @Test func noProviderOrModelGivesNoInlineTarget() {
    #expect(AIConfiguration.empty.inlineTarget == nil)
    let config = AIConfiguration(
      activeProvider: .anthropic, configs: [:], inlineProvider: .localMLX)
    #expect(config.inlineTarget == nil)
  }
}
