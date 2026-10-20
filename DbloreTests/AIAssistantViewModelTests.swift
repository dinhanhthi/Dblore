// AIAssistantViewModelTests.swift
// Tests for the AI assistant chat view model, using a scripted fake client

import Foundation
import Testing

@testable import Dblore

nonisolated private final class FakeAIChatClient: AIChatClient, @unchecked Sendable {
  enum Script {
    case events([String])
    case eventsThenFail([String], Error)
    case eventsThenHang([String])
    case loadingThenHang
    case loadingThenText(String)
    /// Yields the texts, runs `action` on the main actor, then finishes
    case eventsThenAct([String], @MainActor @Sendable () -> Void)
  }

  private let lock = NSLock()
  private var captured: [AIChatRequest] = []
  private let scripts: [Script]

  init(_ script: Script) { self.scripts = [script] }

  /// One script per `stream` call; the last one repeats
  init(_ scripts: [Script]) { self.scripts = scripts }

  var requests: [AIChatRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    lock.lock()
    captured.append(request)
    let script = scripts[min(captured.count, scripts.count) - 1]
    lock.unlock()
    return AsyncThrowingStream { continuation in
      let task = Task {
        switch script {
        case .events(let texts):
          for text in texts { continuation.yield(.text(text)) }
          continuation.finish()
        case .eventsThenFail(let texts, let error):
          for text in texts { continuation.yield(.text(text)) }
          continuation.finish(throwing: error)
        case .loadingThenHang:
          continuation.yield(.loadingModel)
          try? await Task.sleep(for: .seconds(60))
          continuation.finish()
        case .loadingThenText(let text):
          continuation.yield(.loadingModel)
          continuation.yield(.text(text))
          continuation.finish()
        case .eventsThenHang(let texts):
          for text in texts { continuation.yield(.text(text)) }
          try? await Task.sleep(for: .seconds(60))
          continuation.finish()
        case .eventsThenAct(let texts, let action):
          for text in texts { continuation.yield(.text(text)) }
          await action()
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func listModels() async throws -> [String] { [] }
}

/// Records the SQL it gets and answers with `result`, `error` or, after `delay`, a late result
@MainActor private final class FakeQueryRunner {
  var sqls: [String] = []
  var error: Error?
  /// Sleeps (ignoring cancellation) before answering
  var delay: Duration?
  let result = QueryResult(
    columns: [ColumnInfo(name: "email", type: "text")], rows: [[.string(sentinel)]], rowCount: 1,
    executionTime: 0)

  /// Cell value that must never reach the provider
  static let sentinel = "zq-91x7@example.com"

  func run(_ sql: String) async throws -> QueryResult {
    sqls.append(sql)
    if let delay { try? await Task.sleep(for: delay) }
    if let error { throw error }
    return result
  }
}

private struct FakeDatabaseError: LocalizedError {
  var errorDescription: String? { "relation \"users\" does not exist" }
}

/// A server error that echoes a row value, as PostgreSQL does for a bad cast
private struct LeakyDatabaseError: LocalizedError {
  static let value = "zq-err-5531@example.com"
  var errorDescription: String? { "invalid input syntax for type integer: \"\(Self.value)\"" }
}

@Suite("AI Assistant ViewModel")
@MainActor
struct AIAssistantViewModelTests {

  private func makeSettings(configured: Bool = true, runsQueries: Bool = false) -> AISettings {
    let suite = "AIAssistantViewModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    if configured {
      settings.configuration = AIConfiguration(
        activeProvider: .ollama,
        configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
        runsQueries: runsQueries)
    }
    return settings
  }

  private func table(_ name: String) -> DatabaseTable {
    DatabaseTable(
      schema: "public", name: name, columns: [DatabaseColumn(name: "id", type: "int4")])
  }

  private func makeVM(
    _ client: FakeAIChatClient, settings: AISettings? = nil, tables: [DatabaseTable] = []
  ) -> AIAssistantViewModel {
    let vm = AIAssistantViewModel(
      settings: settings ?? makeSettings(), makeClient: { _, _, _ in client })
    vm.schemaSource = {
      AISchemaSnapshot(
        tables: tables, foreignKeys: [], databaseName: "shop", dialect: .postgresql)
    }
    // The workspace owns this rule (WorkspaceAIConnectionSwitchTests)
    vm.isCurrentMongoCollection = { _, _ in true }
    return vm
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  private func finish(_ vm: AIAssistantViewModel) async {
    await waitUntil { !vm.isGenerating }
  }

  @Test("deltas accumulate into one assistant entry")
  func deltasAccumulate() async {
    let vm = makeVM(FakeAIChatClient(.events(["Hel", "lo"])))
    vm.draft = "  hi  "
    vm.send()
    await finish(vm)
    #expect(vm.draft.isEmpty)
    #expect(vm.messages.count == 2)
    #expect(vm.messages[0].role == .user)
    #expect(vm.messages[0].text == "hi")
    #expect(vm.messages[1].role == .assistant)
    #expect(vm.messages[1].text == "Hello")
    #expect(!vm.messages[1].isError)
  }

  @Test("stop during model load clears loading and generating")
  func stopDuringLoad() async {
    let vm = makeVM(FakeAIChatClient(.loadingThenHang))
    vm.draft = "hi"
    vm.send()
    await waitUntil { vm.isLoadingModel }
    #expect(vm.isLoadingModel && vm.isGenerating)
    vm.stop()
    #expect(!vm.isLoadingModel && !vm.isGenerating)
  }

  @Test("stop keeps partial text and stops generating")
  func stopKeepsPartial() async {
    let vm = makeVM(FakeAIChatClient(.eventsThenHang(["part"])))
    vm.draft = "hi"
    vm.send()
    await waitUntil { vm.messages.last?.text == "part" }
    #expect(vm.isGenerating)
    vm.stop()
    #expect(!vm.isGenerating)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(vm.messages.last?.text == "part")
    #expect(vm.messages.last?.isError == false)
  }

  @Test("client error marks the assistant entry as error and keeps partial text")
  func clientError() async {
    let vm = makeVM(
      FakeAIChatClient(.eventsThenFail(["par"], AIClientError.http(status: 500, message: "boom"))))
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    #expect(vm.messages.count == 3)
    #expect(vm.messages[1].text == "par")
    #expect(!vm.messages[1].isError)
    #expect(vm.messages[2].isError)
    #expect(vm.messages[2].text == "boom")
  }

  @Test("client factory failure surfaces as an error entry")
  func factoryFailure() async {
    let vm = AIAssistantViewModel(
      settings: makeSettings(), makeClient: { _, _, _ in throw AIClientError.missingAPIKey })
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    #expect(!vm.isGenerating)
    #expect(vm.messages.last?.isError == true)
  }

  @Test("second send while generating is ignored")
  func secondSendIgnored() async {
    let client = FakeAIChatClient(.eventsThenHang(["a"]))
    let vm = makeVM(client)
    vm.draft = "one"
    vm.send()
    vm.draft = "two"
    vm.send()
    #expect(vm.messages.count == 2)
    #expect(vm.draft == "two")
    vm.stop()
    #expect(client.requests.count <= 1)
  }

  @Test("retry from a user entry keeps earlier history, drops later ones and uses new settings")
  func retryFromUserEntry() async {
    let client = FakeAIChatClient(.events(["r"]))
    let vm = makeVM(client)
    for question in ["one", "two", "three"] {
      vm.draft = question
      vm.send()
      await finish(vm)
    }
    #expect(vm.messages.count == 6)
    vm.modelOverride = "m2"
    vm.draft = "typing"
    vm.retry(from: vm.messages[2].id)
    await finish(vm)
    #expect(vm.messages.map(\.text) == ["one", "r", "two", "r"])
    #expect(vm.draft == "typing")
    #expect(client.requests.last?.model == "m2")
    #expect(client.requests.last?.messages.map(\.text) == ["one", "r", "two"])
  }

  @Test("retry with edited text replaces the question and drops later entries")
  func retryWithEditedText() async {
    let client = FakeAIChatClient(.events(["r"]))
    let vm = makeVM(client)
    for question in ["one", "two"] {
      vm.draft = question
      vm.send()
      await finish(vm)
    }
    vm.retry(from: vm.messages[0].id, editedText: "  uno  ")
    await finish(vm)
    #expect(vm.messages.map(\.text) == ["uno", "r"])
    #expect(client.requests.last?.messages.map(\.text) == ["uno"])
    vm.retry(from: vm.messages[0].id, editedText: "   ")
    #expect(vm.messages.map(\.text) == ["uno", "r"])
  }

  @Test("explain and fixError only fill the draft and never send")
  func quickActions() async {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.explain(sql: "SELECT 42", sessionKey: nil)
    #expect(vm.draft.contains("SELECT 42"))
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)
    vm.draft = ""
    vm.fixError(sql: "SELEC 1", error: "syntax error near SELEC", sessionKey: nil)
    #expect(vm.draft.contains("SELEC 1"))
    #expect(vm.draft.contains("syntax error near SELEC"))
    #expect(vm.messages.isEmpty)
    #expect(client.requests.isEmpty)
    vm.send()
    await finish(vm)
    #expect(client.requests.count == 1)
    #expect(vm.messages[0].text.contains("syntax error near SELEC"))
  }

  @Test("stop before any text leaves no empty assistant entry")
  func stopBeforeText() async {
    let vm = makeVM(FakeAIChatClient(.eventsThenHang([])))
    vm.draft = "hi"
    vm.send()
    vm.stop()
    #expect(vm.messages.count == 1)
    #expect(!vm.messages.contains { $0.role == .assistant && $0.text.isEmpty })
  }

  @Test("explicit table selection limits the system prompt")
  func explicitSelection() async {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client, tables: [table("users"), table("orders"), table("secrets")])
    vm.selectedTableNames = ["public.orders"]
    vm.draft = "show users"
    vm.send()
    await finish(vm)
    let system = client.requests.first?.system ?? ""
    #expect(system.contains("public.orders("))
    #expect(!system.contains("public.users("))
    #expect(!system.contains("public.secrets("))
    #expect(system.contains("shop"))
    #expect(system.contains("Only the schema is provided automatically"))
    #expect(client.requests.first?.model == "m1")
  }

  @Test("the on-device provider gets the compact system prompt")
  func localMLXCompactPrompt() async {
    let client = FakeAIChatClient(.events(["ok"]))
    let settings = makeSettings()
    settings.configuration = AIConfiguration(
      activeProvider: .localMLX,
      configs: [.localMLX: AIProviderConfig(baseURL: "", model: "qwen3.5-4b")],
      runsQueries: false)
    let vm = makeVM(client, settings: settings, tables: [table("orders")])
    vm.draft = "show orders"
    vm.send()
    await finish(vm)
    let system = client.requests.first?.system ?? ""
    #expect(system.contains("Use only tables and columns from the schema."))
    #expect(!system.contains("Only the schema is provided automatically"))
  }

  @Test("history sent to the client is capped at 20 non-error entries")
  func historyCapped() async {
    let client = FakeAIChatClient(.events(["r"]))
    let vm = makeVM(client)
    vm.messages = (0..<30).map {
      AIChatEntry(
        id: UUID(), role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)", isError: false)
    }
    vm.messages.insert(
      AIChatEntry(id: UUID(), role: .assistant, text: "bad", isError: true), at: 29)
    vm.draft = "latest"
    vm.send()
    await finish(vm)
    let sent = client.requests.first?.messages ?? []
    #expect(sent.count <= 20)
    #expect(sent.first?.role == .user)
    #expect(sent.last?.text == "latest")
    #expect(!sent.contains { $0.text == "bad" })
  }

  @Test("new chat stops, empties messages and keeps the partial chat in history")
  func newChatEmpties() async {
    let vm = makeVM(FakeAIChatClient(.eventsThenHang(["a"])))
    let previousId = vm.conversationId
    vm.draft = "hi"
    vm.send()
    await waitUntil { vm.messages.last?.text == "a" }
    vm.newChat()
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)
    #expect(vm.conversationId != previousId)
    #expect(vm.conversations.map(\.id) == [previousId])
    #expect(vm.conversations.first?.messages.map(\.text) == ["hi", "a"])
  }

  private func postLocalDataChange(_ category: LocalDataCategory) {
    NotificationCenter.default.post(
      name: .localDataChanged, object: nil,
      userInfo: [LocalDataCategory.userInfoKey: category.rawValue])
  }

  private func makeStore() -> AIConversationStore {
    AIConversationStore(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("AIConversationStoreTests-\(UUID().uuidString).json"))
  }

  @Test("a local data change reloads saved chats and leaves a memory-only list")
  func localDataChangeReloadsConversations() async {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let store = makeStore()
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.historyStore = store
    let kept = AIConversation(
      id: UUID(), title: "kept", updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      messages: [AIChatEntry(id: UUID(), role: .user, text: "hi", isError: false)])
    store.save([kept])
    #expect(vm.conversations.isEmpty)

    postLocalDataChange(.logs)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(vm.conversations.isEmpty)

    postLocalDataChange(.aiChats)
    await waitUntil { vm.conversations == [kept] }
    #expect(vm.conversations == [kept])

    let memoryOnly = makeVM(FakeAIChatClient(.events(["x"])))
    memoryOnly.draft = "hi"
    memoryOnly.send()
    await finish(memoryOnly)
    let snapshot = memoryOnly.conversations
    #expect(!snapshot.isEmpty)
    postLocalDataChange(.aiChats)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(memoryOnly.conversations == snapshot)
  }

  @Test("finished chats are saved, newest first, and reload from the store")
  func historyPersists() async {
    let store = makeStore()
    let vm = makeVM(FakeAIChatClient(.events(["answer"])))
    vm.historyStore = store
    vm.draft = "first   question\nwith lines"
    vm.send()
    await finish(vm)
    vm.newChat()
    vm.draft = "second"
    vm.send()
    await finish(vm)

    #expect(vm.conversations.map(\.title) == ["second", "first question with lines"])
    let reloaded = makeVM(FakeAIChatClient(.events([])))
    reloaded.historyStore = store
    #expect(reloaded.conversations == vm.conversations)
  }

  @Test("opening a chat restores its messages without reordering history")
  func openConversation() async {
    let vm = makeVM(FakeAIChatClient(.events(["answer"])))
    vm.historyStore = makeStore()
    vm.draft = "first"
    vm.send()
    await finish(vm)
    let firstId = vm.conversationId
    vm.newChat()
    vm.draft = "second"
    vm.send()
    await finish(vm)

    vm.openConversation(id: firstId)
    #expect(vm.conversationId == firstId)
    #expect(vm.messages.map(\.text) == ["first", "answer"])
    #expect(vm.conversations.map(\.title) == ["second", "first"])
  }

  @Test("deleting the current chat starts an empty one")
  func deleteCurrentConversation() async {
    let store = makeStore()
    let vm = makeVM(FakeAIChatClient(.events(["answer"])))
    vm.historyStore = store
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    let id = vm.conversationId

    vm.deleteConversation(id: id)
    #expect(vm.messages.isEmpty)
    #expect(vm.conversationId != id)
    #expect(vm.conversations.isEmpty)
    #expect(store.load().isEmpty)
  }

  @Test("viewer table replaces the previous one and keeps tables the user picked")
  func attachViewerTable() {
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.selectedTableNames = ["public.users"]
    vm.attachViewerTable("public.orders")
    #expect(vm.selectedTableNames == ["public.users", "public.orders"])
    vm.attachViewerTable("public.items")
    #expect(vm.selectedTableNames == ["public.users", "public.items"])
    vm.attachViewerTable("public.users")
    #expect(vm.selectedTableNames == ["public.users"])
    vm.attachViewerTable(nil)
    #expect(vm.selectedTableNames == ["public.users"])
  }

  @Test("old chat entries decode without a query result and new ones round-trip without row values")
  func chatEntryCoding() throws {
    let id = UUID()
    let old = #"{"id":"\#(id.uuidString)","role":"assistant","text":"hi","isError":false}"#
    let decoded = try JSONDecoder().decode(AIChatEntry.self, from: Data(old.utf8))
    #expect(decoded == AIChatEntry(id: id, role: .assistant, text: "hi", isError: false))
    #expect(decoded.queryResult == nil)
    #expect(decoded.isRunning == nil)
    #expect(decoded.queryOutcome == nil)
    #expect(decoded.toolCalls == nil)
    #expect(decoded.toolResults == nil)

    // Chats saved while the AI could read results carry `sharedWithModel`, now ignored
    let shared = #"""
      {"id":"\#(id.uuidString)","role":"assistant","text":"","isError":false,"sharedWithModel":true,
      "queryResult":{"columns":[{"name":"id","type":"int4"}],"rowCount":2,"rowsTruncated":false}}
      """#
    let sharedEntry = try JSONDecoder().decode(AIChatEntry.self, from: Data(shared.utf8))
    #expect(sharedEntry.queryResult?.rowCount == 2)
    #expect(sharedEntry.queryResult?.rows == [])

    var entry = AIChatEntry(id: UUID(), role: .assistant, text: "", isError: false)
    entry.queryResult = AIQueryResult(
      columns: [.init(name: "id", type: "int4")], rows: [["1"], [nil]], rowCount: 2,
      rowsTruncated: true)
    entry.isRunning = false
    let data = try JSONEncoder().encode(entry)
    var expected = entry
    expected.queryResult?.rows = []
    #expect(try JSONDecoder().decode(AIChatEntry.self, from: data) == expected)
  }

  @Test("tool calls and results round-trip on a chat entry, the signature kept unchanged")
  func chatEntryToolCoding() throws {
    var entry = AIChatEntry(id: UUID(), role: .assistant, text: "", isError: false)
    entry.toolCalls = [
      AIToolCall(id: "call_1", name: "list_tables", inputJSON: "{}", signature: "c2ln"),
      AIToolCall(id: "call_2", name: "describe_table", inputJSON: #"{"table":"users"}"#),
    ]
    entry.toolResults = [AIToolResult(id: "call_1", content: "users", isError: false)]
    let data = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(AIChatEntry.self, from: data) == entry)

    let plain = AIChatEntry(id: UUID(), role: .user, text: "hi", isError: false)
    let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(!json.contains("toolCalls") && !json.contains("toolResults"))
  }

  @Test("a chat message's text joins its text blocks only")
  func chatMessageText() {
    let call = AIToolCall(id: "call_1", name: "list_tables", inputJSON: "{}")
    let message = AIChatMessage(
      role: .assistant, blocks: [.text("Let me "), .toolUse(call), .text("look.")])
    #expect(message.text == "Let me look.")
    #expect(AIChatMessage(role: .user, text: "hi").blocks == [.text("hi")])
  }

  // MARK: - Query runs

  private static let runSQL = "SELECT email FROM users WHERE id = 11"
  private static let runReply = "Let me check.\n```sql run\n\(runSQL)\n```"

  /// A view model whose queries go to `runner`, with "Run read-only queries" set to `runsQueries`
  private func makeQueryVM(
    _ client: FakeAIChatClient, runsQueries: Bool = true, runner: FakeQueryRunner?
  ) -> (AIAssistantViewModel, AISettings) {
    let settings = makeSettings(runsQueries: runsQueries)
    let vm = makeVM(client, settings: settings)
    if let runner { vm.queryRunner = { try await runner.run($0) } }
    return (vm, settings)
  }

  private func ask(_ vm: AIAssistantViewModel, _ question: String) async {
    vm.draft = question
    vm.send()
    await finish(vm)
  }

  /// Every text the provider received: system prompts and messages
  private func sentTexts(_ client: FakeAIChatClient) -> [String] {
    client.requests.flatMap { [$0.system] + $0.messages.map(\.text) }
  }

  @Test("off never runs a run fence and does not ask for one")
  func offNeverRuns() async {
    let client = FakeAIChatClient(.events([Self.runReply]))
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runsQueries: false, runner: runner)
    await ask(vm, "email of user 11?")
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(client.requests.first?.system.contains("```sql run") == false)
    #expect(vm.messages.count == 2)
  }

  @Test("on: one model call, rows stay with the user, later turns get a placeholder")
  func runsOnceAndNeverSendsRows() async throws {
    let client = FakeAIChatClient([.events([Self.runReply]), .events(["ok"])])
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "email of user 11?")
    #expect(runner.sqls == [Self.runSQL])
    #expect(client.requests.count == 1)
    #expect(client.requests.first?.system.contains("```sql run") == true)
    try #require(vm.messages.map(\.role) == [.user, .assistant, .assistant])
    #expect(vm.messages[1].text == Self.runReply)
    #expect(vm.messages[2].queryResult?.rows == [[FakeQueryRunner.sentinel]])
    #expect(vm.messages[2].isRunning == nil)
    #expect(!vm.isGenerating)

    await ask(vm, "thanks, and user 12?")
    #expect(client.requests.count == 2)
    let sent = client.requests.last?.messages ?? []
    #expect(
      sent.contains {
        $0.role == .user && $0.text == AIPrompts.queryShownPlaceholder(rowCount: 1)
      })
    #expect(!sentTexts(client).contains { $0.contains(FakeQueryRunner.sentinel) })
  }

  @Test("a plain sql block (the user asked for SQL) never runs")
  func plainSQLNeverRuns() async {
    let client = FakeAIChatClient(.events(["```sql\nSELECT 1\n```"]))
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "give me the sql")
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(vm.messages.count == 2)
  }

  @Test("a write in a run fence is refused before the database, with the SQL shown")
  func writeIsRefused() async {
    let client = FakeAIChatClient(.events(["```sql run\nUPDATE users SET a = 1\n```"]))
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "fix the data")
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    let last = vm.messages.last
    #expect(last?.text.contains("Couldn't run the query") == true)
    #expect(last?.text.contains("```sql\nUPDATE users SET a = 1") == true)
    #expect(last?.isError == false)
    #expect(last?.isRunning == nil)
    #expect(last?.queryOutcome == .refused)
  }

  @Test("a database error shows the error and the SQL without another model call")
  func runnerErrorShowsSQL() async {
    let client = FakeAIChatClient(.events([Self.runReply]))
    let runner = FakeQueryRunner()
    runner.error = FakeDatabaseError()
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "email of user 11?")
    #expect(runner.sqls == [Self.runSQL])
    #expect(client.requests.count == 1)
    #expect(vm.messages.count == 3)
    let text = vm.messages.last?.text ?? ""
    #expect(text.contains("Couldn't run the query: relation \"users\" does not exist"))
    #expect(text.contains("```sql\n\(Self.runSQL)"))
    #expect(vm.messages.last?.isError == false)
    #expect(vm.messages.last?.queryOutcome == .failed)
  }

  @Test("a run the app refuses before the server (another tab's transaction) is refused")
  func transactionElsewhereIsRefused() async {
    let client = FakeAIChatClient(.events([Self.runReply]))
    let runner = FakeQueryRunner()
    runner.error = DatabaseError.transactionPendingInAnotherTab
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "email of user 11?")
    #expect(runner.sqls == [Self.runSQL])
    #expect(client.requests.count == 1)
    #expect(vm.messages.last?.text.contains("```sql\n\(Self.runSQL)") == true)
    #expect(vm.messages.last?.queryOutcome == .refused)
  }

  @Test("without a connection the run fails with the SQL shown")
  func noRunnerMeansNotConnected() async {
    let client = FakeAIChatClient(.events([Self.runReply]))
    let (vm, _) = makeQueryVM(client, runner: nil)
    await ask(vm, "email of user 11?")
    #expect(client.requests.count == 1)
    let text = vm.messages.last?.text ?? ""
    #expect(text.contains("Not connected to a database."))
    #expect(text.contains("```sql\n\(Self.runSQL)"))
  }

  @Test("stop while a query runs removes the placeholder and ignores the late result")
  func stopDuringRun() async {
    let client = FakeAIChatClient(.events([Self.runReply]))
    let runner = FakeQueryRunner()
    runner.delay = .milliseconds(300)
    let (vm, _) = makeQueryVM(client, runner: runner)
    vm.draft = "email of user 11?"
    vm.send()
    await waitUntil { vm.messages.last?.isRunning == true }
    #expect(vm.messages.last?.isRunning == true)
    vm.stop()
    #expect(!vm.isGenerating)
    #expect(!vm.messages.contains { $0.isRunning == true })
    try? await Task.sleep(for: .milliseconds(400))
    #expect(vm.messages.count == 2)
    #expect(!vm.messages.contains { $0.queryResult != nil })
    #expect(client.requests.count == 1)
  }

  @Test("a database error is never sent to the provider")
  func databaseErrorsStayPrivate() async throws {
    let client = FakeAIChatClient([.events([Self.runReply]), .events(["ok"])])
    let runner = FakeQueryRunner()
    runner.error = LeakyDatabaseError()
    let (vm, _) = makeQueryVM(client, runner: runner)
    await ask(vm, "email of user 11?")
    #expect(vm.messages.last?.text.contains(LeakyDatabaseError.value) == true)
    await ask(vm, "why?")
    #expect(client.requests.count == 2)
    #expect(!sentTexts(client).contains { $0.contains(LeakyDatabaseError.value) })
    let sent = client.requests.last?.messages ?? []
    #expect(sent.contains { $0.role == .assistant && $0.text == AIPrompts.queryFailedPlaceholder })
  }

  @Test("a database error stays in memory but is not saved with the chat")
  func databaseErrorNotSaved() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConversationStoreTests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let client = FakeAIChatClient(.events([Self.runReply]))
    let runner = FakeQueryRunner()
    runner.error = LeakyDatabaseError()
    let (vm, _) = makeQueryVM(client, runner: runner)
    vm.historyStore = AIConversationStore(fileURL: url)
    await ask(vm, "email of user 11?")

    #expect(vm.messages.last?.text.contains(LeakyDatabaseError.value) == true)
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains(LeakyDatabaseError.value))
    let entry = try #require(AIConversationStore(fileURL: url).load().first?.messages.last)
    #expect(entry.queryOutcome == .failed)
    #expect(entry.text.contains("```sql\n\(Self.runSQL)\n```"))
  }

  @Test("DuckDB: a file read in a run fence is refused before the database")
  func duckDBFileReadIsRefused() async {
    let client = FakeAIChatClient(
      .events(["```sql run\nSELECT * FROM read_csv('/etc/passwd')\n```"]))
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runner: runner)
    vm.dialectSource = { .duckdb }
    await ask(vm, "show the file")
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(vm.messages.last?.text.contains("Couldn't run the query") == true)
  }

  @Test("a connection switched to another database type while answering refuses the query")
  func dialectChangeRefusesQuery() async {
    let client = FakeAIChatClient(
      .events(["```sql run\nSELECT pg_terminate_backend(pid) FROM pg_stat_activity\n```"]))
    let runner = FakeQueryRunner()
    let (vm, _) = makeQueryVM(client, runner: runner)
    var dialect = SQLDialect.duckdb
    vm.dialectSource = { dialect }
    vm.draft = "kill the sessions"
    vm.send()
    dialect = .postgresql
    await finish(vm)
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(vm.messages.last?.text.contains("Couldn't run the query") == true)
    #expect(vm.messages.last?.text.contains("The connection changed") == true)
    #expect(vm.messages.last?.queryOutcome == .refused)
  }

  @Test("turning queries off while the reply streams leaves its run fence unrun")
  func turnedOffMidStreamDoesNotRun() async {
    let settings = makeSettings(runsQueries: true)
    let client = FakeAIChatClient(
      .eventsThenAct([Self.runReply]) { settings.configuration.runsQueries = false })
    let runner = FakeQueryRunner()
    let vm = makeVM(client, settings: settings)
    vm.queryRunner = { try await runner.run($0) }
    await ask(vm, "email of user 11?")
    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(vm.messages.count == 2)
  }

  @Test("a result reopened without its rows is sent as a placeholder")
  func decodedResultSendsPlaceholder() async throws {
    let client = FakeAIChatClient(.events(["ok"]))
    let (vm, _) = makeQueryVM(client, runner: FakeQueryRunner())
    var result = AIChatEntry(id: UUID(), role: .assistant, text: "", isError: false)
    result.queryResult = AIQueryResult(
      columns: [.init(name: "email", type: "text")], rows: [], rowCount: 2, rowsTruncated: false)
    vm.messages = [
      AIChatEntry(id: UUID(), role: .user, text: "emails?", isError: false),
      AIChatEntry(id: UUID(), role: .assistant, text: Self.runReply, isError: false),
      result,
      AIChatEntry(id: UUID(), role: .assistant, text: "Two rows.", isError: false),
    ]
    await ask(vm, "next")
    let sent = client.requests.first?.messages ?? []
    try #require(sent.map(\.role) == [.user, .assistant, .user, .assistant, .user])
    #expect(sent[2].text == AIPrompts.queryShownPlaceholder(rowCount: 2))
  }

  @Test("a chat saved while a query ran opens without the running placeholder")
  func staleRunningEntryDropped() {
    let store = makeStore()
    let running = AIChatEntry(
      id: UUID(), role: .assistant, text: "", isError: false, isRunning: true)
    let saved = AIConversation(
      id: UUID(), title: "q", updatedAt: Date(),
      messages: [AIChatEntry(id: UUID(), role: .user, text: "q", isError: false), running])
    store.save([saved])
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.historyStore = store
    vm.openConversation(id: saved.id)
    #expect(vm.messages.map(\.text) == ["q"])
  }

  // MARK: - MongoDB collection screen

  private func mongoSnapshot() -> AISchemaSnapshot {
    let field = [DatabaseColumn(name: "status", type: "string")]
    return AISchemaSnapshot(
      tables: [
        DatabaseTable(schema: "shop", name: "orders", columns: field),
        DatabaseTable(schema: "shop", name: "users", columns: field),
      ],
      foreignKeys: [], databaseName: "shop", dialect: .mongodb)
  }

  @Test("the shown collection screen reaches the chat system prompt")
  func mongoScreenInChat() async {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.schemaSource = mongoSnapshot
    vm.mongoScreenSource = {
      AIMongoAssist.Screen(database: "shop", collection: "orders", showsAggregations: false)
    }
    vm.draft = "paid orders"
    vm.send()
    await finish(vm)
    let system = client.requests.first?.system ?? ""
    #expect(system.contains("The user is viewing the collection \"shop.orders\""))
  }

  @Test("one-shot leaves the chat alone")
  func mongoAssistOneShot() async throws {
    let client = FakeAIChatClient(.events(["{status: ", "\"paid\"}"]))
    let vm = makeVM(client)
    vm.schemaSource = mongoSnapshot
    let reply = try await vm.mongoAssist(
      .filter, prompt: "paid orders", database: "shop", collection: "orders", current: "")
    #expect(reply == "{status: \"paid\"}")
    let request = try #require(client.requests.first)
    #expect(request.system.contains("shop.orders"))
    #expect(!request.system.contains("shop.users"))
    #expect(request.messages.map(\.text) == ["paid orders"])
    #expect(request.messages.map(\.role) == [.user])
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)
  }

  @Test("a one-shot cancelled after the last event throws instead of returning")
  func mongoAssistCancelledAtEnd() async {
    final class Holder { var task: Task<String, Error>? }
    let holder = Holder()
    let client = FakeAIChatClient(.eventsThenAct([]) { holder.task?.cancel() })
    let vm = makeVM(client)
    vm.schemaSource = mongoSnapshot
    let task = Task {
      try await vm.mongoAssist(
        .filter, prompt: "paid orders", database: "shop", collection: "orders", current: "")
    }
    holder.task = task
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  // MARK: - Connection AI access

  /// The connection "Prod" with `policy`, asking its own gate so approvals stay in the test
  private func access(
    _ policy: AIAccessPolicy, rules: String = "", gate: AIAccessGate = AIAccessGate(),
    host: String = "db.example"
  ) -> AIAccessContext {
    var config = ConnectionConfig(
      host: host, port: 5432, database: "shop", username: "ana", name: "Prod")
    config.aiAccess = policy
    config.aiRules = rules
    return AIAccessContext(config: config, savedPolicies: [], gate: gate)
  }

  /// Session key of the connection `access` builds for `host`
  private func key(host: String = "db.example") -> String {
    AIAccessGate.sessionKey(for: access(.always, host: host).config)
  }

  @Test("a private connection sends no schema, screen or rules, and generic chat still works")
  func deniedChatSendsNoConnectionData() async throws {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.schemaSource = mongoSnapshot
    vm.mongoScreenSource = {
      AIMongoAssist.Screen(database: "shop", collection: "orders", showsAggregations: false)
    }
    vm.aiAccessSource = { self.access(.never, rules: "Never read payments.") }
    await ask(vm, "how do I count documents?")

    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(request.messages.map(\.text) == ["how do I count documents?"])
    #expect(!request.system.contains("orders"))
    #expect(!request.system.contains("shop"))
    #expect(!request.system.contains("The user is viewing"))
    #expect(!request.system.contains("Never read payments."))
    #expect(request.system.contains("MongoDB assistant"))
    #expect(vm.privateNote == .messageOnly)
    #expect(vm.messages.last?.text == "ok")
  }

  @Test("a Fix draft on a private connection is held; a typed question then goes alone")
  func deniedConnectionDraftIsHeld() async throws {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.aiAccessSource = { self.access(.never) }
    vm.fixError(
      sql: "INSERT INTO t VALUES (1)", error: LeakyDatabaseError.value, sessionKey: key())

    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
    #expect(vm.messages.isEmpty)
    #expect(vm.draft.contains(LeakyDatabaseError.value))
    #expect(vm.privateNote == .draftHeld)

    vm.draft = ""
    vm.draft = "hello"
    vm.send()
    await finish(vm)
    #expect(client.requests.map { $0.messages.map(\.text) } == [["hello"]])
    #expect(vm.privateNote == .messageOnly)
  }

  @Test("a private connection gets only the new question; allowed turns keep the history")
  func deniedSendsNoHistory() async throws {
    final class Holder { var policy = AIAccessPolicy.always }
    let holder = Holder()
    let client = FakeAIChatClient(.events(["r"]))
    let vm = makeVM(client)
    vm.aiAccessSource = { self.access(holder.policy) }
    await ask(vm, "columns of payments?")
    await ask(vm, "and orders?")
    #expect(
      client.requests.last?.messages.map(\.text) == ["columns of payments?", "r", "and orders?"])

    holder.policy = .never
    await ask(vm, "what is a join?")
    #expect(client.requests.last?.messages.map(\.text) == ["what is a join?"])
    #expect(vm.privateNote == .messageOnly)
    vm.newChat()
    #expect(vm.privateNote == nil)
  }

  @Test("a private connection refuses Retry and Edit of a stored Fix message")
  func deniedRetrySendsNothing() async throws {
    final class Holder { var policy = AIAccessPolicy.always }
    let holder = Holder()
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.aiAccessSource = { self.access(holder.policy) }
    vm.fixError(
      sql: "INSERT INTO t VALUES (1)", error: LeakyDatabaseError.value, sessionKey: key())
    vm.send()
    await finish(vm)
    let stored = vm.messages
    #expect(client.requests.count == 1)

    holder.policy = .never
    vm.retry(from: stored[0].id)
    vm.retry(from: stored[0].id, editedText: "edited")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.count == 1)
    #expect(vm.messages == stored)
    #expect(vm.privateNote == .retryHeld)

    vm.connectionDidChange()
    #expect(vm.privateNote == nil)
  }

  @Test("a switch to another connection drops a Fix draft; a reconnect and a typed one keep it")
  func connectionChangeDropsFixDraft() async throws {
    final class Holder { var host = "db.example" }
    let holder = Holder()
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.aiAccessSource = { self.access(.never, host: holder.host) }
    vm.fixError(
      sql: "INSERT INTO t VALUES (1)", error: LeakyDatabaseError.value, sessionKey: key())
    vm.connectionDidChange()  // reconnect or MongoDB database switch: same connection
    #expect(!vm.draft.isEmpty)
    holder.host = "other.example"
    vm.connectionDidChange()
    #expect(vm.draft.isEmpty)

    vm.draft = "hello"
    vm.connectionDidChange()
    #expect(vm.draft == "hello")
    vm.send()  // not held: the Fix flag went with the draft
    await finish(vm)
    #expect(client.requests.map { $0.messages.map(\.text) } == [["hello"]])
  }

  @Test("a Fix draft filled on another connection, or unstamped, is held at send")
  func fixDraftOfAnotherConnectionHeld() async throws {
    final class Holder { var host = "a.example" }
    let holder = Holder()
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client)
    vm.aiAccessSource = { self.access(.always, host: holder.host) }
    vm.fixError(
      sql: "INSERT INTO t VALUES (1)", error: LeakyDatabaseError.value,
      sessionKey: key(host: "a.example"))
    holder.host = "b.example"
    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
    #expect(vm.privateNote == .draftFromOtherConnection)
    vm.draft = ""
    #expect(vm.privateNote == nil)

    // A source without a session key fails closed
    vm.fixError(sql: "INSERT INTO t VALUES (1)", error: LeakyDatabaseError.value, sessionKey: nil)
    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
    #expect(vm.privateNote == .draftFromOtherConnection)
  }

  @Test("needs approval: nothing is sent until Allow; Not now keeps the draft")
  func needsApprovalHoldsTheTurn() async throws {
    let client = FakeAIChatClient(.events(["ok"]))
    let vm = makeVM(client, tables: [table("customers")])
    let context = access(.askOncePerSession, rules: "Never read payments.")
    vm.aiAccessSource = { context }

    vm.draft = "top customers"
    vm.send()
    #expect(vm.pendingApproval?.connectionName == "Prod")
    vm.dismissPendingTurn()
    #expect(vm.pendingApproval == nil)
    #expect(vm.draft == "top customers")

    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)

    vm.allowPendingTurn()
    await finish(vm)
    #expect(vm.pendingApproval == nil)
    #expect(vm.draft.isEmpty)
    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(request.system.contains("customers"))
    #expect(request.system.contains("Connection rules (from the user):\nNever read payments."))
    #expect(context.decision(settings: vm.settings.configuration) == .allowed)
  }

  @Test("a slash command reading the query asks first; Allow runs it again with the values")
  func slashCommandAllowRerunsCommand() throws {
    let client = FakeAIChatClient(.events(["ok"]))
    let settings = makeSettings()
    settings.configuration.customCommands = [
      AICustomCommand(name: "probe", template: "Explain {{query}}")
    ]
    let vm = makeVM(client, settings: settings)
    let context = access(.askOncePerSession)
    vm.aiAccessSource = { context }
    let tab = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: context.config))
    tab.viewMode = .editor
    tab.editorContent = "SELECT id FROM orders"

    vm.draft = "/probe"
    #expect(vm.runSlashCommand(in: tab) == .awaitingApproval)
    #expect(vm.pendingApproval?.connectionName == "Prod")
    #expect(vm.draft == "/probe")

    vm.allowPendingTurn()
    #expect(vm.pendingApproval == nil)
    #expect(vm.draft == "Explain SELECT id FROM orders")
    #expect(context.decision(settings: vm.settings.configuration) == .allowed)
    #expect(client.requests.isEmpty)
  }

  @Test("a connection made private while answering refuses the query")
  func privateMidTurnRefusesQuery() async {
    final class Holder { var policy = AIAccessPolicy.always }
    let holder = Holder()
    let settings = makeSettings(runsQueries: true)
    let client = FakeAIChatClient(.eventsThenAct([Self.runReply]) { holder.policy = .never })
    let runner = FakeQueryRunner()
    let vm = makeVM(client, settings: settings)
    vm.queryRunner = { try await runner.run($0) }
    vm.aiAccessSource = { self.access(holder.policy) }
    await ask(vm, "email of user 11?")

    #expect(runner.sqls.isEmpty)
    #expect(client.requests.count == 1)
    #expect(vm.messages.last?.queryOutcome == .refused)
  }

  @Test("a private connection gets no filter or pipeline request")
  func deniedMongoAssistSendsNothing() async {
    let client = FakeAIChatClient(.events(["{}"]))
    let vm = makeVM(client)
    vm.schemaSource = mongoSnapshot
    vm.aiAccessSource = { self.access(.never) }

    await #expect(throws: AIAssistantViewModel.AIAccessError.denied) {
      _ = try await vm.mongoAssist(
        .filter, prompt: "paid orders", database: "shop", collection: "orders", current: "")
    }
    #expect(client.requests.isEmpty)
  }
}
