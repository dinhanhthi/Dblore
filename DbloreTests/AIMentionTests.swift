// AIMentionTests.swift
// @mentions of the AI composer: parsing, tokens, the labelled blocks, and what a turn sends
// through the gate (read-only source tabs, denied and not yet allowed connections, result rows,
// unknown names, MongoDB collections)

import Foundation
import Testing

@testable import Dblore

nonisolated private final class FakeMentionClient: AIChatClient, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [AIChatRequest] = []

  var requests: [AIChatRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    lock.lock()
    captured.append(request)
    lock.unlock()
    return AsyncThrowingStream { continuation in
      continuation.yield(.text("ok"))
      continuation.finish()
    }
  }

  func listModels() async throws -> [String] { [] }
}

@Suite("AI mentions")
@MainActor
struct AIMentionTests {
  private static let sql = "SELECT id FROM orders"
  /// Cell value that must reach the provider only with "Send result rows" on
  private static let sentinel = "zq-77m1@example.com"

  // MARK: - Parsing

  @Test("mentions start a word, in order, each once")
  func parsesMentions() {
    #expect(
      AIMention.parse("why is @query slow on @table:orders? see @results and @query")
        == [.query, .table("orders"), .results])
    #expect(AIMention.parse("@results") == [.results])
    #expect(AIMention.parse("(@query)") == [.query])
    #expect(AIMention.parse("look at @table:public.orders.") == [.table("public.orders")])
    #expect(AIMention.parse("@favorite:daily-sum, please") == [.favorite("daily-sum")])
    #expect(AIMention.parse("look at @query.") == [.query])
    #expect(AIMention.parse("@results.") == [.results])
  }

  @Test("emails, unknown or uppercase keywords and longer words are no mentions")
  func ignoresNonMentions() {
    for text in [
      "mail ana@query.com", "a@b.com", "@Query", "@queryx", "@query:x", "@query.x", "@resultsx",
      "@rows",
      "@table", "@table:", "@table: orders", "@favorite:\"\"", "@table:\"unclosed",
      "@table:\"line\nbreak\"", "x@table:orders",
      "@table:" + String(repeating: "t", count: AIMention.maxNameChars + 1),
    ] {
      #expect(AIMention.parse(text).isEmpty, "\(text)")
    }
  }

  @Test("a quoted name holds spaces, dots and punctuation")
  func quotedNames() {
    #expect(
      AIMention.parse(#"@table:"order items" and @favorite:"Daily revenue (EU)""#)
        == [.table("order items"), .favorite("Daily revenue (EU)")])
    #expect(AIMention.parse(#"@table:"my schema.my table"."#) == [.table("my schema.my table")])
  }

  @Test("at most 8 mentions; duplicates do not count")
  func mentionCap() {
    let text = (0..<12).map { "@table:t\($0) @table:t0" }.joined(separator: " ")
    #expect(AIMention.parse(text) == (0..<8).map { .table("t\($0)") })
  }

  @Test("a token parses back into its mention, quoted when needed")
  func tokens() {
    for mention: AIMention in [
      .query, .results, .table("orders"), .table("public.orders"), .table("order items"),
      .table("v1."), .favorite("Daily revenue"),
    ] {
      #expect(mention.token.map(AIMention.parse) == [mention], "\(mention)")
    }
    #expect(AIMention.table("orders").token == "@table:orders")
    #expect(AIMention.favorite("a b").token == #"@favorite:"a b""#)
    #expect(AIMention.table(#"say "hi""#).token == nil)
    #expect(
      AIMention.Kind.allCases.map(\.prefix) == ["@table:", "@query", "@results", "@favorite:"])
  }

  @Test("blocks are labelled, fenced under the data notice and capped")
  func render() {
    #expect(AIMention.render([]) == "")
    let text = AIMention.render([
      AIMention.Block(mention: .table("orders"), text: "public.orders(id int4)"),
      AIMention.Block(mention: .query, text: "SELECT ```x```"),
    ])
    #expect(
      text.hasPrefix("Context the user attached with @mentions. " + MCPResultEncoder.dataNotice))
    #expect(text.contains("@table:orders\n```\npublic.orders(id int4)\n```"))
    #expect(text.contains("@query\n````\nSELECT ```x```\n````"))

    let long = String(repeating: "q", count: AIMention.maxBlockChars + 5)
    let cut = AIMention.render([AIMention.Block(mention: .query, text: long)])
    #expect(cut.contains(String(long.prefix(AIMention.maxBlockChars)) + "\n[truncated]"))
    #expect(!cut.contains(long))

    let blocks = (0..<4).map {
      AIMention.Block(mention: .table("t\($0)"), text: String(repeating: "x", count: 8_000))
    }
    let total = AIMention.render(blocks)
    #expect(total.contains("@table:t2"))
    #expect(!total.contains("@table:t3"))
  }

  @Test("a favorite matches its exact name first, then ignoring case")
  func favoriteLookup() {
    let upper = FavoriteStatement(name: "Daily", sql: "SELECT 1")
    let lower = FavoriteStatement(name: "daily", sql: "SELECT 2")
    #expect(AIMention.favorite(named: "daily", in: [upper, lower]) == lower)
    #expect(AIMention.favorite(named: "DAILY", in: [upper, lower]) == upper)
    #expect(AIMention.favorite(named: "weekly", in: [upper]) == nil)
  }

  // MARK: - Turns

  private func config(
    _ type: DatabaseType = .postgresql, policy: AIAccessPolicy = .always,
    host: String = "db.example"
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: type, host: host, port: 5432, database: "shop", username: "ana",
      name: "Prod")
    config.aiAccess = policy
    return config
  }

  private final class TableReads {
    var names: [String] = []
  }

  private func makeVM(
    _ client: FakeMentionClient, policy: AIAccessPolicy = .always, sendsRows: Bool = false,
    tab: NotebookViewModel? = nil, reads: TableReads = TableReads()
  ) -> AIAssistantViewModel {
    let defaults = UserDefaults(suiteName: "AIMentionTests-\(UUID().uuidString)")!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      sendsResultRows: sendsRows)
    let vm = AIAssistantViewModel(settings: settings, makeClient: { _, _, _ in client })
    let access = AIAccessContext(
      config: config(policy: policy), savedPolicies: [], gate: AIAccessGate())
    vm.aiAccessSource = { access }
    vm.activeTabSource = { tab }
    vm.tableStructureSource = { name, _ in
      reads.names.append(name)
      return name == "orders" ? "public.orders(id int4, total numeric)" : nil
    }
    vm.favoritesSource = { [FavoriteStatement(name: "Daily revenue", sql: "SELECT sum(total)")] }
    return vm
  }

  private func editorTab(_ text: String = sql, host: String = "db.example") -> NotebookViewModel {
    let tab = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config(host: host)))
    tab.viewMode = .editor
    tab.editorContent = text
    return tab
  }

  private func ask(_ vm: AIAssistantViewModel, _ question: String) async {
    vm.draft = question
    vm.send()
    for _ in 0..<500 where vm.isGenerating { try? await Task.sleep(for: .milliseconds(10)) }
  }

  /// The last message the provider got: this turn's question with its mention blocks
  private func sentQuestion(_ client: FakeMentionClient) -> String {
    client.requests.last?.messages.last?.text ?? ""
  }

  @Test("@query sends the tab's query; the chat keeps the question as typed")
  func querySendsCurrentSQL() async {
    let client = FakeMentionClient()
    let vm = makeVM(client, tab: editorTab())
    await ask(vm, "why is @query slow?")
    let sent = sentQuestion(client)
    #expect(sent.hasPrefix("why is @query slow?\n\n"))
    #expect(sent.contains("@query\n```\n\(Self.sql)\n```"))
    #expect(vm.messages.first?.text == "why is @query slow?")
  }

  @Test("@query on a read-only source tab sends nothing")
  func queryOnReadOnlySourceSendsNothing() async {
    let client = FakeMentionClient()
    let tab = editorTab("CREATE VIEW v AS SELECT secret FROM t")
    tab.objectSourceLoad = .loaded
    let vm = makeVM(client, tab: tab)
    await ask(vm, "explain @query")
    #expect(client.requests.count == 1)
    #expect(sentQuestion(client) == "explain @query")
    #expect(
      !client.requests.flatMap { [$0.system] + $0.messages.map(\.text) }.joined().contains("secret")
    )
  }

  @Test("@query of a tab on another connection sends nothing")
  func queryOfOtherConnectionSendsNothing() async {
    let client = FakeMentionClient()
    let vm = makeVM(client, tab: editorTab(host: "other.example"))
    await ask(vm, "explain @query")
    #expect(sentQuestion(client) == "explain @query")
  }

  @Test("a denied connection resolves no mention: only the question goes")
  func deniedSendsNoMentionContent() async {
    let client = FakeMentionClient()
    let reads = TableReads()
    let vm = makeVM(client, policy: .never, tab: editorTab(), reads: reads)
    await ask(vm, #"@query @table:orders @favorite:"Daily revenue" @results"#)
    #expect(client.requests.count == 1)
    #expect(
      client.requests[0].messages.map(\.text) == [
        #"@query @table:orders @favorite:"Daily revenue" @results"#
      ])
    #expect(reads.names.isEmpty)
    #expect(vm.privateNote == .messageOnly)
  }

  @Test("not yet allowed: the Allow prompt shows and nothing is read; Allow sends the blocks")
  func needsApprovalThenContent() async {
    let client = FakeMentionClient()
    let reads = TableReads()
    let vm = makeVM(client, policy: .askOncePerSession, tab: editorTab(), reads: reads)
    vm.draft = "columns of @table:orders for @query"
    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(vm.pendingApproval?.connectionName == "Prod")
    #expect(client.requests.isEmpty)
    #expect(reads.names.isEmpty)

    vm.allowPendingTurn()
    for _ in 0..<500 where vm.isGenerating { try? await Task.sleep(for: .milliseconds(10)) }
    let sent = sentQuestion(client)
    #expect(reads.names == ["orders"])
    #expect(sent.contains("@table:orders\n```\npublic.orders(id int4, total numeric)\n```"))
    #expect(sent.contains(Self.sql))
  }

  /// An editor tab showing one row, stamped with the connection it ran on (nil: a file)
  private func resultTab(ranOn host: String? = "db.example") -> NotebookViewModel {
    let tab = editorTab()
    tab.editorResult = CellResult(
      columns: [ColumnInfo(name: "email", type: "text")], rows: [[.string(Self.sentinel)]],
      rowCount: 1,
      aiSessionKey: host.map { AIAccessGate.sessionKey(for: config(host: $0)) })
    return tab
  }

  @Test("@results sends columns and row count; rows only with Send result rows on")
  func resultsRowsOnlyWhenSent() async {
    let client = FakeMentionClient()
    await ask(makeVM(client, tab: resultTab()), "summarize @results")
    let withoutRows = sentQuestion(client)
    #expect(withoutRows.contains("\"email\""))
    #expect(withoutRows.contains("\"rowCount\":1"))
    #expect(!withoutRows.contains(Self.sentinel))

    let rowsClient = FakeMentionClient()
    await ask(makeVM(rowsClient, sendsRows: true, tab: resultTab()), "summarize @results")
    #expect(sentQuestion(rowsClient).contains(Self.sentinel))
  }

  @Test("@results of a result from another connection or a file sends nothing")
  func resultsOfOtherOriginSendNothing() async {
    for host: String? in ["other.example", nil] {
      let client = FakeMentionClient()
      await ask(makeVM(client, sendsRows: true, tab: resultTab(ranOn: host)), "summarize @results")
      #expect(sentQuestion(client) == "summarize @results")
    }
  }

  @Test("an unknown table or favorite resolves to nothing")
  func unknownResolvesToNothing() async {
    let client = FakeMentionClient()
    let vm = makeVM(client)
    await ask(vm, "use @table:nope and @favorite:missing")
    #expect(sentQuestion(client) == "use @table:nope and @favorite:missing")
  }

  @Test("@favorite sends the saved SQL; the saved chat never holds it")
  func favoriteSendsSQL() async throws {
    let client = FakeMentionClient()
    let vm = makeVM(client)
    await ask(vm, "speed up @favorite:\"daily revenue\"")
    #expect(
      sentQuestion(client).contains("@favorite:\"daily revenue\"\n```\nSELECT sum(total)\n```"))
    let saved = try #require(vm.conversations.first)
    #expect(!saved.messages.map(\.text).joined().contains("SELECT sum(total)"))
  }

  @Test("later turns replay the question as typed, without its blocks")
  func blocksAreNotReplayed() async {
    let client = FakeMentionClient()
    let vm = makeVM(client, tab: editorTab())
    await ask(vm, "explain @query")
    await ask(vm, "thanks")
    #expect(client.requests.last?.messages.map(\.text) == ["explain @query", "ok", "thanks"])
  }

  // MARK: - Workspace

  @Test("MongoDB @table gives the collection's sampled fields; other names give nothing")
  func mongoTableGivesSampledFields() async {
    let mongo = config(.mongodb)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: mongo), restoreTabs: false)
    let gate = AIAccessGate()
    manager.aiAccessSource = { AIAccessContext(config: mongo, savedPolicies: [], gate: gate) }
    manager.connectionState = .connected
    manager.databaseTables = [
      DatabaseTable(
        schema: "shop", name: "orders",
        columns: [
          DatabaseColumn(name: "_id", type: "objectId"),
          DatabaseColumn(name: "total", type: "double"),
        ])
    ]
    manager.schemaConnectionEpoch = 1
    let key = AIAccessGate.sessionKey(for: mongo)

    let text = await manager.aiMentionTable("orders", sessionKey: key)
    #expect(text?.contains("shop.orders(_id objectId, total double)") == true)
    #expect(await manager.aiMentionTable("nope", sessionKey: key) == nil)
    #expect(await manager.aiMentionTable("orders", sessionKey: "other") == nil)
    #expect(await manager.aiMentionTable("orders", sessionKey: nil) == nil)
  }
}
