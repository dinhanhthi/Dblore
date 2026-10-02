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
  }

  private let lock = NSLock()
  private var captured: [AIChatRequest] = []
  private let script: Script

  init(_ script: Script) { self.script = script }

  var requests: [AIChatRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    lock.lock()
    captured.append(request)
    lock.unlock()
    let script = script
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
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func listModels() async throws -> [String] { [] }
}

@Suite("AI Assistant ViewModel")
@MainActor
struct AIAssistantViewModelTests {

  private func makeSettings(configured: Bool = true) -> AISettings {
    let suite = "AIAssistantViewModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    if configured {
      settings.configuration = AIConfiguration(
        activeProvider: .ollama,
        configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")])
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
      AISchemaSnapshot(tables: tables, foreignKeys: [], databaseName: "shop")
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

  @Test("loading state is set by the client event and cleared by the first text")
  func loadingState() async {
    let vm = makeVM(FakeAIChatClient(.loadingThenText("ok")))
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    #expect(!vm.isLoadingModel)
    #expect(vm.messages.last?.text == "ok")
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

  @Test("error before any text marks the empty assistant entry")
  func errorWithoutPartial() async {
    let vm = makeVM(FakeAIChatClient(.eventsThenFail([], AIClientError.missingAPIKey)))
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    #expect(vm.messages.count == 2)
    #expect(vm.messages[1].isError)
    #expect(vm.messages[1].text == AIClientError.missingAPIKey.errorDescription)
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

  @Test("empty draft is ignored")
  func emptyDraftIgnored() {
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.draft = "  \n "
    vm.send()
    #expect(vm.messages.isEmpty)
    #expect(!vm.isGenerating)
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

  @Test("quick actions append to a non-empty draft after a blank line")
  func quickActionKeepsDraft() {
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.draft = "my note"
    vm.explain(sql: "SELECT 1")
    #expect(vm.draft.hasPrefix("my note\n\n"))
    #expect(vm.draft.contains("SELECT 1"))
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

  @Test("stream finishing with no text leaves no empty entry")
  func finishWithoutText() async {
    let vm = makeVM(FakeAIChatClient(.events([])))
    vm.draft = "hi"
    vm.send()
    await finish(vm)
    #expect(vm.messages.count == 1)
    #expect(!vm.messages.contains { $0.text.isEmpty })
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

  @Test("needsSetup is true with empty config and false after configuring Ollama")
  func needsSetup() {
    let settings = makeSettings(configured: false)
    let vm = makeVM(FakeAIChatClient(.events([])), settings: settings)
    #expect(vm.needsSetup)
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "llama3")])
    #expect(!vm.needsSetup)
  }

  @Test("overrides take precedence over settings")
  func overrides() {
    let vm = makeVM(FakeAIChatClient(.events([])))
    #expect(vm.activeProvider == .ollama)
    #expect(vm.activeModel == "m1")
    vm.providerOverride = .openAI
    vm.modelOverride = "gpt-x"
    #expect(vm.activeProvider == .openAI)
    #expect(vm.activeModel == "gpt-x")
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
}
