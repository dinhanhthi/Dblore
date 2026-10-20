// AIReviewFlowTests.swift
// Tests for the Review and Optimize flow of the AI assistant: draft fill, gate, catalog context
// and the review metadata of the answer

import Foundation
import Testing

@testable import Dblore

nonisolated private final class FakeReviewClient: AIChatClient, @unchecked Sendable {
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
      continuation.yield(.text(#"{"summary": "ok", "steps": [], "sql": null}"#))
      continuation.finish()
    }
  }

  func listModels() async throws -> [String] { [] }
}

/// Records the statements the context is read for
@MainActor private final class ContextCalls {
  var statements: [String] = []
  var plans: [ExplainPlan?] = []
}

@Suite("AI Review flow")
@MainActor
struct AIReviewFlowTests {
  private static let sql = "SELECT id FROM orders WHERE total > 100"
  private static let context = "public.orders(id int4 PK, total numeric) -- ctx-7731"

  private func makeSettings(runsQueries: Bool = false) -> AISettings {
    let defaults = UserDefaults(suiteName: "AIReviewFlowTests-\(UUID().uuidString)")!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      runsQueries: runsQueries)
    return settings
  }

  private func config(_ type: DatabaseType = .postgresql) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "db.example", port: 5432, database: "shop", username: "ana",
      name: "Prod")
  }

  /// The connection of `config()` with `policy` and `rules`
  private func access(_ policy: AIAccessPolicy, rules: String = "") -> AIAccessContext {
    var config = config()
    config.aiAccess = policy
    config.aiRules = rules
    return AIAccessContext(config: config, savedPolicies: [], gate: AIAccessGate())
  }

  private func makeVM(
    _ client: FakeReviewClient, policy: AIAccessPolicy = .always, rules: String = "",
    runsQueries: Bool = false, calls: ContextCalls? = nil
  ) -> AIAssistantViewModel {
    let vm = AIAssistantViewModel(
      settings: makeSettings(runsQueries: runsQueries), makeClient: { _, _, _ in client })
    vm.schemaSource = {
      AISchemaSnapshot(tables: [], foreignKeys: [], databaseName: "shop", dialect: .postgresql)
    }
    vm.aiAccessSource = { self.access(policy, rules: rules) }
    vm.queryContextSource = { statement, plan in
      calls?.statements.append(statement)
      calls?.plans.append(plan)
      return Self.context
    }
    return vm
  }

  /// An editor tab of `config(type)` holding `text`, showing `result`
  private func editorTab(
    _ text: String = sql, type: DatabaseType = .postgresql, result: CellResult? = nil
  ) -> NotebookViewModel {
    let tab = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config(type)))
    tab.viewMode = .editor
    tab.editorContent = text
    tab.editorResult = result
    return tab
  }

  private var planResult: CellResult {
    CellResult(
      columns: [ColumnInfo(name: "QUERY PLAN", type: "json")],
      rows: [[.json(ExplainFixtures.seqScan)]], rowCount: 1,
      sourceQuery: "EXPLAIN (FORMAT JSON) " + Self.sql)
  }

  private func finish(_ vm: AIAssistantViewModel) async {
    for _ in 0..<500 where vm.isGenerating { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test("Review fills the draft and records the request; nothing is sent")
  func reviewFillsDraft() {
    let client = FakeReviewClient()
    let vm = makeVM(client)
    let tab = editorTab(result: planResult)
    vm.review(.review, in: tab)

    #expect(vm.draft == AIPrompts.review(sql: Self.sql))
    #expect(
      vm.pendingReview?.request
        == AIReviewRequest(kind: .review, sourceSQL: Self.sql, notebookId: tab.id, cellId: nil))
    #expect(vm.pendingReview?.plan != nil)
    #expect(vm.messages.isEmpty)
    #expect(client.requests.isEmpty)
  }

  @Test("the plan of another statement is not attached")
  func otherPlanNotAttached() {
    let vm = makeVM(FakeReviewClient())
    let result = CellResult(
      columns: [ColumnInfo(name: "QUERY PLAN", type: "json")],
      rows: [[.json(ExplainFixtures.seqScan)]], rowCount: 1,
      sourceQuery: "EXPLAIN (FORMAT JSON) SELECT 1")
    vm.review(.review, in: editorTab(result: result))
    #expect(vm.pendingReview != nil)
    #expect(vm.pendingReview?.plan == nil)
  }

  @Test("retrying or editing a Review question sends it as a review again")
  func retryKeepsReview() async throws {
    let client = FakeReviewClient()
    let vm = makeVM(client, runsQueries: true)
    let tab = editorTab()
    vm.review(.review, in: tab)
    vm.send()
    await finish(vm)
    let request = AIReviewRequest(
      kind: .review, sourceSQL: Self.sql, notebookId: tab.id, cellId: nil)
    #expect(vm.messages.last?.review == request)

    #expect(vm.retry(from: vm.messages[0].id))
    await finish(vm)
    #expect(client.requests.count == 2)
    let retried = try #require(client.requests.last)
    #expect(retried.system.contains("Reply with ONLY one JSON object"))
    #expect(retried.system.contains("<query_context>"))
    #expect(!retried.system.contains("```sql run"))
    #expect(vm.messages.count == 2)
    #expect(vm.messages.last?.review == request)

    #expect(vm.retry(from: vm.messages[0].id, editedText: "Review it again:\n" + Self.sql))
    await finish(vm)
    #expect(client.requests.count == 3)
    #expect(client.requests.last?.system.contains("Reply with ONLY one JSON object") == true)
    #expect(vm.messages.last?.review == request)
  }

  @Test("a Review question edited without its SQL is retried as a plain turn")
  func editedRetryWithoutSQLIsNoReview() async throws {
    let client = FakeReviewClient()
    let calls = ContextCalls()
    let vm = makeVM(client, calls: calls)
    vm.review(.review, in: editorTab())
    vm.send()
    await finish(vm)
    #expect(calls.statements.count == 1)

    #expect(vm.retry(from: vm.messages[0].id, editedText: "Which tables hold orders?"))
    await finish(vm)
    #expect(client.requests.count == 2)
    let retried = try #require(client.requests.last)
    #expect(!retried.system.contains("Reply with ONLY one JSON object"))
    #expect(calls.statements.count == 1)
    #expect(vm.messages.first?.askedReview == nil)
    #expect(vm.messages.last?.review == nil)
  }

  @Test("Optimize on a notebook targets the selected cell")
  func optimizeTargetsCell() {
    let vm = makeVM(FakeReviewClient())
    let cell = NotebookCell(content: Self.sql)
    let tab = NotebookViewModel(notebook: DbloreNotebook(cells: [cell], connectionConfig: config()))
    tab.viewMode = .notebook
    tab.selectedCellId = cell.id
    vm.review(.optimize, in: tab)

    #expect(vm.draft == AIPrompts.optimize(sql: Self.sql))
    #expect(
      vm.pendingReview?.request
        == AIReviewRequest(
          kind: .optimize, sourceSQL: Self.sql, notebookId: tab.id, cellId: cell.id))
    #expect(vm.pendingReview?.plan == nil)
  }

  @Test("a private connection holds the Review draft and reads no context")
  func deniedHoldsReview() async {
    let client = FakeReviewClient()
    let calls = ContextCalls()
    let vm = makeVM(client, policy: .never, calls: calls)
    vm.review(.review, in: editorTab())
    vm.send()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(client.requests.isEmpty)
    #expect(vm.messages.isEmpty)
    #expect(calls.statements.isEmpty)
    #expect(vm.privateNote == .draftHeld)
    #expect(vm.draft.contains(Self.sql))
  }

  @Test("an allowed Review sends the catalog and JSON rule; the answer carries the request")
  func allowedReviewSendsContext() async throws {
    let client = FakeReviewClient()
    let calls = ContextCalls()
    let vm = makeVM(client, rules: "Never read payments.", runsQueries: true, calls: calls)
    let tab = editorTab(result: planResult)
    vm.review(.review, in: tab)
    vm.send()
    await finish(vm)

    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(calls.statements == [Self.sql])
    #expect(calls.plans.first??.root.nodeType == "Seq Scan")
    #expect(request.system.contains("<query_context>\n\(Self.context)\n</query_context>"))
    #expect(request.system.contains("Reply with ONLY one JSON object"))
    #expect(!request.system.contains("```sql run"))
    #expect(request.system.components(separatedBy: "Never read payments.").count == 2)
    #expect(request.messages.last?.text.contains(Self.sql) == true)
    #expect(
      vm.messages.last?.review
        == AIReviewRequest(kind: .review, sourceSQL: Self.sql, notebookId: tab.id, cellId: nil))
    #expect(vm.pendingReview == nil)
  }

  @Test("a failed context read sends the Review without a catalog")
  func failedContextSendsWithoutCatalog() async throws {
    let client = FakeReviewClient()
    let vm = makeVM(client)
    vm.queryContextSource = { _, _ in throw URLError(.timedOut) }
    vm.review(.review, in: editorTab())
    vm.send()
    await finish(vm)

    let request = try #require(client.requests.first)
    #expect(!request.system.contains("<query_context>"))
    #expect(request.system.contains("Reply with ONLY one JSON object"))
    #expect(vm.messages.last?.review?.kind == .review)
  }

  @Test("stop while the context is read sends nothing")
  func stopDuringContextSendsNothing() async {
    let client = FakeReviewClient()
    let vm = makeVM(client)
    vm.queryContextSource = { _, _ in
      try await Task.sleep(for: .seconds(60))
      return Self.context
    }
    vm.review(.review, in: editorTab())
    vm.send()
    #expect(vm.isGenerating)
    vm.stop()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
  }

  @Test("retry after a stop during the context read sends it as a review again")
  func retryAfterEarlyStopKeepsReview() async throws {
    let client = FakeReviewClient()
    let vm = makeVM(client)
    vm.queryContextSource = { _, _ in
      try await Task.sleep(for: .seconds(60))
      return Self.context
    }
    let tab = editorTab()
    vm.review(.review, in: tab)
    vm.send()
    vm.stop()
    #expect(vm.messages.count == 1)

    vm.queryContextSource = { _, _ in Self.context }
    #expect(vm.retry(from: vm.messages[0].id))
    await finish(vm)
    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(request.system.contains("Reply with ONLY one JSON object"))
    #expect(vm.messages.count == 2)
    #expect(
      vm.messages.last?.review
        == AIReviewRequest(kind: .review, sourceSQL: Self.sql, notebookId: tab.id, cellId: nil))
  }

  @Test("a second Review replaces the draft and targets the second tab only")
  func secondReviewReplacesDraft() {
    let vm = makeVM(FakeReviewClient())
    let other = "SELECT name FROM customers"
    vm.review(.review, in: editorTab())
    let tab = editorTab(other)
    vm.review(.optimize, in: tab)

    #expect(vm.draft == AIPrompts.optimize(sql: other))
    #expect(
      vm.pendingReview?.request
        == AIReviewRequest(kind: .optimize, sourceSQL: other, notebookId: tab.id, cellId: nil))
  }

  @Test("a draft rewritten into another question is sent as a plain turn")
  func rewrittenDraftIsNoReview() async throws {
    let client = FakeReviewClient()
    let calls = ContextCalls()
    let vm = makeVM(client, calls: calls)
    vm.review(.review, in: editorTab())
    vm.draft = "Which tables hold orders?"
    vm.send()
    await finish(vm)

    let request = try #require(client.requests.first)
    #expect(!request.system.contains("Reply with ONLY one JSON object"))
    #expect(calls.statements.isEmpty)
    #expect(vm.messages.last?.review == nil)
    #expect(vm.pendingReview == nil)
  }

  @Test("emptying the draft, another fill or a new chat drops the pending request")
  func pendingReviewGoesWithTheDraft() async {
    let client = FakeReviewClient()
    let vm = makeVM(client)
    let tab = editorTab()
    vm.review(.review, in: tab)
    vm.draft = ""
    #expect(vm.pendingReview == nil)

    vm.review(.optimize, in: tab)
    vm.newChat()
    #expect(vm.pendingReview == nil)

    vm.review(.review, in: tab)
    vm.explain(sql: Self.sql, sessionKey: tab.aiSessionKey)
    #expect(vm.pendingReview == nil)
    #expect(vm.draft == AIPrompts.explain(sql: Self.sql))
    vm.send()
    await finish(vm)
    #expect(client.requests.count == 1)
    #expect(vm.messages.last?.review == nil)
  }

  @Test("a read-only source tab and a MongoDB tab offer no Review or Optimize")
  func readOnlyAndMongoOfferNothing() {
    #expect(AIAssistantViewModel.offersReview(in: editorTab(), dialect: .postgresql))
    #expect(!AIAssistantViewModel.offersReview(in: nil, dialect: .postgresql))

    let source = editorTab()
    source.objectSourceLoad = .loaded
    #expect(!AIAssistantViewModel.offersReview(in: source, dialect: .postgresql))

    let mongo = editorTab("db.orders.find({})", type: .mongodb)
    #expect(!AIAssistantViewModel.offersReview(in: mongo, dialect: .mongodb))
    #expect(!AIAssistantViewModel.offersReview(in: editorTab(), dialect: .mongodb))

    let vm = makeVM(FakeReviewClient())
    vm.review(.review, in: source)
    vm.review(.optimize, in: mongo)
    #expect(vm.draft.isEmpty)
    #expect(vm.pendingReview == nil)
  }

  @Test("SQL longer than a prompt holds offers no Review or Optimize")
  func overCapSQLOffersNothing() {
    let fits = editorTab(String(repeating: "x", count: AIPrompts.maxInputChars))
    #expect(AIAssistantViewModel.offersReview(in: fits, dialect: .postgresql))
    let long = editorTab(String(repeating: "x", count: AIPrompts.maxInputChars + 1))
    #expect(!AIAssistantViewModel.offersReview(in: long, dialect: .postgresql))

    let vm = makeVM(FakeReviewClient())
    vm.review(.review, in: long)
    #expect(vm.draft.isEmpty)
    #expect(vm.pendingReview == nil)
  }

  @Test("a saved answer without review metadata still decodes")
  func oldEntryDecodes() throws {
    let json =
      #"{"id": "\#(UUID().uuidString)", "role": "assistant", "text": "x", "isError": false}"#
    let entry = try JSONDecoder().decode(AIChatEntry.self, from: Data(json.utf8))
    #expect(entry.review == nil)
  }

  @Test("a saved review request without a selection still decodes")
  func oldRequestDecodes() throws {
    let json =
      #"{"kind": "review", "sourceSQL": "x", "notebookId": "\#(UUID().uuidString)", "cellId": null}"#
    let request = try JSONDecoder().decode(AIReviewRequest.self, from: Data(json.utf8))
    #expect(request.selection == nil)
  }
}
