// AIComposerSuggestionsTests.swift
// The AI composer's suggestion popup: the token at the end of the draft, what it lists and the
// draft a pick leaves

import Foundation
import Testing

@testable import Dblore

@Suite("AI composer suggestions")
@MainActor
struct AIComposerSuggestionsTests {
  private static let tables = [
    DatabaseTable(schema: "public", name: "orders"),
    DatabaseTable(schema: "public", name: "order_items"),
    DatabaseTable(schema: "public", name: "users"),
    DatabaseTable(schema: "audit", name: "users"),
  ]

  private func items(
    _ draft: String,
    commands: [AISlashCommand] = AISlashCommand.available(custom: [], dialect: .postgresql),
    tables: [DatabaseTable] = Self.tables,
    favorites: [FavoriteStatement] = []
  ) -> [AIComposerSuggestions.Item] {
    guard let token = AIComposerSuggestions.token(in: draft) else { return [] }
    return AIComposerSuggestions.items(
      for: token, commands: commands, tables: tables, favorites: favorites)
  }

  private func pick(
    _ title: String, in draft: String, favorites: [FavoriteStatement] = []
  ) -> String? {
    guard let token = AIComposerSuggestions.token(in: draft),
      let item = items(draft, favorites: favorites).first(where: { $0.title == title })
    else { return nil }
    return AIComposerSuggestions.draft(draft, picking: item, at: token)
  }

  // MARK: - Commands

  @Test("a slash lists the built-ins and the custom commands")
  func slashListsCommands() {
    let custom = AICustomCommand(name: "indexes", template: "List indexes\n{{schema}}")
    let commands = AISlashCommand.available(custom: [custom], dialect: .postgresql)
    let listed = items("/", commands: commands)
    #expect(listed.map(\.title) == ["/explain", "/fix", "/review", "/optimize", "/indexes"])
    #expect(listed.last?.detail == "List indexes")
  }

  @Test("MongoDB lists no Review or Optimize")
  func mongoListsNoReview() {
    let commands = AISlashCommand.available(custom: [], dialect: .mongodb)
    #expect(items("/", commands: commands).map(\.title) == ["/explain", "/fix"])
  }

  @Test("a partial name filters ignoring case, and a pick replaces the draft")
  func commandFilterAndPick() {
    #expect(items("/EX").map(\.title) == ["/explain"])
    #expect(pick("/explain", in: "  /ex") == "  /explain ")
  }

  @Test("a command typed in full, a space after it, or no command shows nothing")
  func commandClosed() {
    #expect(items("/explain").isEmpty)
    #expect(AIComposerSuggestions.token(in: "/explain ") == nil)
    #expect(items("//").isEmpty)
    #expect(AIComposerSuggestions.token(in: "a /ex") == nil)
  }

  // MARK: - Mentions

  @Test("an at sign lists the mention kinds; a name kind keeps the popup open")
  func mentionKinds() {
    #expect(items("show @").map(\.title) == ["@table:", "@query", "@results", "@favorite:"])
    #expect(pick("@table:", in: "show @ta") == "show @table:")
    #expect(pick("@query", in: "(@q") == "(@query ")
  }

  @Test("an at sign inside a word is no mention")
  func mentionStartsWord() {
    #expect(AIComposerSuggestions.token(in: "mail a@b") == nil)
    #expect(AIComposerSuggestions.token(in: "@query and more") == nil)
  }

  @Test("a keyword with a capital is no mention, so the popup closes on it")
  func nameKeywordCase() {
    #expect(AIComposerSuggestions.token(in: "@Table:ord") == nil)
    #expect(AIComposerSuggestions.token(in: "@FAVORITE:daily") == nil)
    #expect(AIComposerSuggestions.token(in: "@table:ord")?.kind == .name(.table))
  }

  @Test("table names match the name or schema.name ignoring case, exact first")
  func tableNames() {
    #expect(items("@table:ORDER").map(\.title) == ["orders", "order_items"])
    #expect(items("@table:order_items").isEmpty)
    #expect(items("@table:audit.").map(\.insertion) == ["@table:audit.users "])
  }

  @Test("a table name another schema shares is inserted as schema.name")
  func ambiguousTableQualified() {
    #expect(
      items("@table:us").map(\.insertion) == ["@table:public.users ", "@table:audit.users "])
    #expect(pick("orders", in: "count @table:o") == "count @table:orders ")
  }

  @Test("a quoted name in progress is matched, and the pick closes the quote")
  func quotedName() {
    let tables = [DatabaseTable(schema: "public", name: "order items")]
    let listed = items(#"@table:"order i"#, tables: tables)
    #expect(listed.map(\.insertion) == [#"@table:"order items" "#])
    #expect(AIComposerSuggestions.token(in: #"@table:"order items" "#) == nil)
  }

  @Test("favorites are listed with their first line, a name with spaces quoted")
  func favorites() {
    let favorites = [
      FavoriteStatement(name: "Daily sales", sql: "\n-- per day\nSELECT 1"),
      FavoriteStatement(name: "bad\"name", sql: "SELECT 2"),
    ]
    let listed = items("@favorite:", favorites: favorites)
    #expect(listed.map(\.title) == ["Daily sales"])
    #expect(listed.first?.detail == "-- per day")
    #expect(
      pick("Daily sales", in: "@favorite:da", favorites: favorites) == #"@favorite:"Daily sales" "#)
  }

  @Test("the list keeps at most eight items")
  func capped() {
    let many = (0..<20).map { DatabaseTable(schema: "public", name: "t\($0)") }
    #expect(items("@table:t", tables: many).count == AIComposerSuggestions.maxItems)
  }
}
