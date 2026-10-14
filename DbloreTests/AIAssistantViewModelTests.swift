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
    vm.explain(sql: "SELECT 42")
    #expect(vm.draft.contains("SELECT 42"))
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)
    vm.draft = ""
    vm.fixError(sql: "SELEC 1", error: "syntax error near SELEC")
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
    #expect(client.requests.first?.model == "m1")
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
}
