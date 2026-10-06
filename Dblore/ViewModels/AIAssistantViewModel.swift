// AIAssistantViewModel.swift
// Workspace-level chat state for the AI SQL assistant. Only schema is sent; SQL is never executed.

import Foundation
import Observation

struct AIChatEntry: Identifiable, Equatable, Codable {
  let id: UUID
  let role: AIChatMessage.Role
  var text: String
  var isError: Bool
}

/// Structure-only snapshot of the connected database, read at send time
struct AISchemaSnapshot: Sendable {
  var tables: [DatabaseTable]
  var foreignKeys: [ForeignKey]
  var databaseName: String?
  var dialect: SQLDialect = .postgresql

  static let empty = AISchemaSnapshot(tables: [], foreignKeys: [], databaseName: nil)
}

@MainActor @Observable
final class AIAssistantViewModel {
  private static let historyLimit = 20
  private static let conversationLimit = 100
  private static let titleLength = 80

  var messages: [AIChatEntry] = []
  /// Saved conversations of the workspace, most recently updated first
  private(set) var conversations: [AIConversation] = []
  private(set) var conversationId = UUID()
  var draft = ""
  var isGenerating = false
  /// True while an on-device model is being loaded into memory (before the first token)
  var isLoadingModel = false
  var isVisible = false
  var providerOverride: AIProviderKind?
  var modelOverride: String?
  /// Qualified table names; empty means automatic selection
  var selectedTableNames: Set<String> = []
  /// Table added to `selectedTableNames` by `attachViewerTable`, nil when the user already had it
  @ObservationIgnored private var viewerTableName: String?

  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  @ObservationIgnored let settings: AISettings
  @ObservationIgnored private let makeClient:
    (AIProviderKind, AIProviderConfig, String?) throws -> any AIChatClient
  @ObservationIgnored var schemaSource: () -> AISchemaSnapshot = { .empty }
  /// nil keeps conversations in memory only
  @ObservationIgnored var historyStore: AIConversationStore? {
    didSet { conversations = historyStore?.load() ?? [] }
  }

  init(
    settings: AISettings = .shared,
    makeClient: @escaping (AIProviderKind, AIProviderConfig, String?) throws -> any AIChatClient = {
      try AIClientFactory.make(kind: $0, config: $1, apiKey: $2)
    }
  ) {
    self.settings = settings
    self.makeClient = makeClient
    localDataChanges.start { [weak self] note in
      guard LocalDataCategory.notification(note, includes: .aiChats) else { return }
      Task { @MainActor [weak self] in
        self?.reloadConversationsFromStore()
      }
    }
  }

  // MARK: - Derived state

  var activeProvider: AIProviderKind? {
    providerOverride ?? settings.configuration.activeProvider
  }

  var activeModel: String {
    guard let provider = activeProvider else { return modelOverride ?? "" }
    return modelOverride ?? settings.config(for: provider).model
  }

  var needsSetup: Bool {
    guard let provider = activeProvider else { return true }
    return !settings.isConfigured(provider)
  }

  // MARK: - Actions

  /// Follows the table shown in the active data viewer: the previously attached table is
  /// replaced, tables the user picked are left as they are. nil detaches.
  func attachViewerTable(_ name: String?) {
    guard name != viewerTableName else { return }
    if let old = viewerTableName { selectedTableNames.remove(old) }
    viewerTableName = nil
    if let name, selectedTableNames.insert(name).inserted { viewerTableName = name }
  }

  func send() {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isGenerating, !question.isEmpty, activeProvider != nil else { return }
    draft = ""
    submit(question: question)
  }

  /// Restarts the conversation from a message: that question and everything after it are
  /// dropped, then the question is sent again with the current provider, model and tables.
  /// An assistant entry restarts from the question before it. The draft is left alone.
  func retry(from id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }),
      let userIndex = messages[...index].lastIndex(where: { $0.role == .user }),
      activeProvider != nil
    else { return }
    let question = messages[userIndex].text
    stop()
    messages.removeSubrange(userIndex...)
    submit(question: question)
  }

  private func submit(question: String) {
    guard let provider = activeProvider else { return }
    messages.append(AIChatEntry(id: UUID(), role: .user, text: question, isError: false))
    saveConversation()

    let entryId = UUID()
    messages.append(AIChatEntry(id: entryId, role: .assistant, text: "", isError: false))

    let model = activeModel
    let client: any AIChatClient
    do {
      guard !model.isEmpty else { throw AIClientError.missingModel }
      client = try makeClient(
        provider, settings.config(for: provider), settings.apiKey(for: provider))
    } catch {
      markError(entryId, error)
      saveConversation()
      return
    }

    // Schema selection and rendering can be large; they run off the main actor
    let snapshot = schemaSource()
    let explicit = selectedTableNames
    let history = makeHistory()
    isGenerating = true
    generation += 1
    let token = generation
    generationTask = Task { [weak self] in
      let request = await Self.buildRequest(
        model: model, question: question, explicit: explicit, snapshot: snapshot,
        history: history)
      do {
        for try await event in client.stream(request) {
          guard let self, !Task.isCancelled else { return }
          switch event {
          case .text(let delta):
            self.isLoadingModel = false
            self.append(delta, to: entryId)
          case .loadingModel:
            self.isLoadingModel = true
          }
        }
      } catch {
        if !Task.isCancelled { self?.markError(entryId, error) }
      }
      self?.finishGeneration(token)
    }
  }

  func stop() {
    generationTask?.cancel()
    generationTask = nil
    generation += 1
    isGenerating = false
    isLoadingModel = false
    removeEmptyAssistantEntries()
    saveConversation()
  }

  /// Query text and error messages can contain row values, so these only fill the draft;
  /// the user reviews it and presses Send.
  func explain(sql: String) {
    fillDraft(AIPrompts.explain(sql: sql))
  }

  func fixError(sql: String, error: String) {
    fillDraft(AIPrompts.fixError(sql: sql, error: error))
  }

  private func fillDraft(_ prompt: String) {
    draft =
      draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? prompt : draft + "\n\n" + prompt
  }

  /// The current conversation is already saved, so this only starts an empty one
  func newChat() {
    stop()
    messages = []
    conversationId = UUID()
  }

  func openConversation(id: UUID) {
    guard id != conversationId, let conversation = conversations.first(where: { $0.id == id })
    else { return }
    stop()
    messages = conversation.messages
    conversationId = id
  }

  func deleteConversation(id: UUID) {
    if id == conversationId { newChat() }
    conversations.removeAll { $0.id == id }
    historyStore?.save(conversations)
  }

  // MARK: - History

  /// Replaces `conversations` from disk. A nil store keeps the in-memory list.
  private func reloadConversationsFromStore() {
    guard let historyStore else { return }
    conversations = historyStore.load()
  }

  /// Upserts the current conversation and moves it to the top; unchanged or empty ones are skipped
  private func saveConversation() {
    guard
      let firstQuestion = messages.first(where: { $0.role == .user })?.text
    else { return }
    if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
      guard conversations[index].messages != messages else { return }
      conversations.remove(at: index)
    }
    let title = firstQuestion.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    conversations.insert(
      AIConversation(
        id: conversationId, title: String(title.prefix(Self.titleLength)), updatedAt: Date(),
        messages: messages),
      at: 0)
    conversations = Array(conversations.prefix(Self.conversationLimit))
    historyStore?.save(conversations)
  }

  // MARK: - Helpers

  /// History of the conversation (which already ends with the new question)
  private func makeHistory() -> [AIChatMessage] {
    messages
      .filter { !$0.isError && !$0.text.isEmpty }
      .suffix(Self.historyLimit)
      .drop(while: { $0.role == .assistant })  // Anthropic requires the first message to be user
      .map { AIChatMessage(role: $0.role, text: $0.text) }
  }

  /// Builds the request off the main actor: table selection and rendering are O(tables)
  nonisolated private static func buildRequest(
    model: String, question: String, explicit: Set<String>, snapshot: AISchemaSnapshot,
    history: [AIChatMessage]
  ) async -> AIChatRequest {
    await Task.detached {
      let selected = AISchemaContext.selectTables(
        explicit: explicit, question: question, tables: snapshot.tables,
        foreignKeys: snapshot.foreignKeys)
      let schema = AISchemaContext.render(tables: selected, foreignKeys: snapshot.foreignKeys)
      return AIChatRequest(
        model: model,
        system: AIPrompts.system(
          databaseName: snapshot.databaseName, schema: schema, dialect: snapshot.dialect),
        messages: history)
    }.value
  }

  private func append(_ delta: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += delta
  }

  /// Keeps partial text in its entry and shows the error in a separate entry below it;
  /// an entry that has no text yet becomes the error entry itself.
  private func markError(_ id: UUID, _ error: Error) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    let description = error.localizedDescription
    if messages[index].text.isEmpty {
      messages[index].text = description
      messages[index].isError = true
    } else {
      messages.insert(
        AIChatEntry(id: UUID(), role: .assistant, text: description, isError: true),
        at: index + 1)
    }
  }

  private func finishGeneration(_ token: Int) {
    guard token == generation else { return }
    isGenerating = false
    isLoadingModel = false
    generationTask = nil
    removeEmptyAssistantEntries()
    saveConversation()
  }

  /// An assistant entry that never received text would show "Thinking…" forever
  private func removeEmptyAssistantEntries() {
    messages.removeAll { $0.role == .assistant && !$0.isError && $0.text.isEmpty }
  }
}
