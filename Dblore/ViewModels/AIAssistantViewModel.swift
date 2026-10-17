// AIAssistantViewModel.swift
// Workspace-level chat state for the AI SQL assistant. Schema is sent; with "Run read-only
// queries" on, the read-only query of a ```sql run block runs (see `+Query`) and its rows are
// shown to the user only, never sent to the model. Other SQL is never executed.

import Foundation
import Observation

struct AIChatEntry: Identifiable, Equatable, Codable {
  let id: UUID
  let role: AIChatMessage.Role
  var text: String
  var isError: Bool
  /// Rows of a query the app ran for the assistant
  var queryResult: AIQueryResult? = nil
  /// The query is still running (placeholder entry)
  var isRunning: Bool? = nil
  /// Set on the entry of a query that could not run: its text holds the error and the SQL
  var queryOutcome: QueryOutcome? = nil
  /// The SQL of a query that could not run: a `.failed` entry is saved with it and without the
  /// database error (`AIConversationStore.save`)
  var querySQL: String? = nil

  enum QueryOutcome: String, Codable {
    /// The database (or the connection) returned an error
    case failed
    /// Refused before the database: guard refusal or no connection
    case refused
  }
}

/// Structure-only snapshot of the connected database, read at send time
struct AISchemaSnapshot: Sendable {
  var tables: [DatabaseTable]
  var foreignKeys: [ForeignKey]
  var databaseName: String?
  var dialect: SQLDialect

  static let empty = AISchemaSnapshot(
    tables: [], foreignKeys: [], databaseName: nil, dialect: .postgresql)
}

@MainActor @Observable
final class AIAssistantViewModel {
  private static let historyLimit = 20
  private static let conversationLimit = 100
  private static let titleLength = 80
  /// Rows of a result kept for the card
  static let modelRowCap = 50

  var messages: [AIChatEntry] = []
  /// Saved conversations of the workspace, most recently updated first
  private(set) var conversations: [AIConversation] = []
  private(set) var conversationId = UUID()
  var draft = ""
  var isGenerating = false
  /// True while an on-device model is being loaded into memory (before the first token)
  var isLoadingModel = false
  private(set) var isVisible = false
  /// Session presentation while visible; reset to the default mode on each open
  var presentation: AIPanelMode = .sidebar
  private(set) var isBubbleExpanded = false
  var providerOverride: AIProviderKind?
  var modelOverride: String?
  /// Qualified table names; empty means automatic selection
  var selectedTableNames: Set<String> = []
  /// Table added to `selectedTableNames` by `attachViewerTable`, nil when the user already had it
  @ObservationIgnored private var viewerTableName: String?

  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private(set) var generation = 0
  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  @ObservationIgnored let settings: AISettings
  @ObservationIgnored private let makeClient:
    (AIProviderKind, AIProviderConfig, String?) throws -> any AIChatClient
  @ObservationIgnored var schemaSource: () -> AISchemaSnapshot = { .empty }
  /// The MongoDB collection screen of the active tab, read at send time; nil elsewhere
  @ObservationIgnored var mongoScreenSource: () -> AIMongoAssist.Screen? = { nil }
  /// Reads only the connection's dialect, so a view body does not collect the whole schema.
  /// Nil falls back to `schemaSource`.
  @ObservationIgnored var dialectSource: (() -> SQLDialect)?
  /// Runs one read-only statement the assistant asked for; nil means not connected
  @ObservationIgnored var queryRunner: ((String) async throws -> QueryResult)?
  /// Dialect of the connected database (read-only badge on SQL replies)
  var sqlDialect: SQLDialect { dialectSource?() ?? schemaSource().dialect }
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

  var showsSidebarPanel: Bool { isVisible && presentation == .sidebar }

  var showsBubble: Bool { isVisible && presentation == .bubble }

  // MARK: - Presentation

  /// Hidden opens in `defaultMode`, a collapsed bubble expands, anything else hides
  func toggleVisibility(defaultMode: AIPanelMode) {
    if !isVisible {
      presentation = defaultMode
      isBubbleExpanded = defaultMode == .bubble
      isVisible = true
    } else if showsBubble && !isBubbleExpanded {
      isBubbleExpanded = true
    } else {
      hide()
    }
  }

  func toggleBubbleExpanded() {
    guard showsBubble else { return }
    isBubbleExpanded.toggle()
  }

  func collapseBubble() {
    isBubbleExpanded = false
  }

  func togglePresentation() {
    guard isVisible else { return }
    presentation = presentation == .sidebar ? .bubble : .sidebar
    isBubbleExpanded = presentation == .bubble
  }

  func hide() {
    isVisible = false
    isBubbleExpanded = false
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

  /// Restarts the conversation from a user message: that question and everything after it
  /// are dropped, then the question (or `editedText` when given) is sent with the current
  /// provider, model and tables. The draft is left alone.
  func retry(from id: UUID, editedText: String? = nil) {
    guard let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].role == .user, activeProvider != nil
    else { return }
    let question = (editedText ?? messages[index].text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    stop()
    messages.removeSubrange(index...)
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
    let context = TurnContext(
      client: client, model: model, question: question, explicit: selectedTableNames,
      snapshot: schemaSource(), runsQueries: settings.configuration.runsQueries,
      compactPrompt: provider == .localMLX, dialect: sqlDialect, screen: mongoScreenSource())
    let history = makeHistory()
    isGenerating = true
    generation += 1
    let token = generation
    generationTask = Task { [weak self] in
      await self?.runTurn(context, history: history, entryId: entryId, token: token)
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
    // A query still running when the app quit never finished
    messages = conversation.messages.filter { $0.isRunning != true }
    conversationId = id
  }

  func deleteConversation(id: UUID) {
    if id == conversationId { newChat() }
    conversations.removeAll { $0.id == id }
    historyStore?.save(conversations)
  }

  // MARK: - One-shot

  /// Generates the filter or pipeline of `collection` from `prompt` and returns the raw reply.
  /// Outside the chat: no entry, history or generating state is touched. The caller owns
  /// cancellation and timeout.
  func mongoAssist(
    _ target: AIMongoAssist.Target, prompt: String, database: String?, collection: String,
    current: String
  ) async throws -> String {
    guard let provider = activeProvider else { throw AIClientError.missingModel }
    let model = activeModel
    guard !model.isEmpty else { throw AIClientError.missingModel }
    let client = try makeClient(
      provider, settings.config(for: provider), settings.apiKey(for: provider))

    let snapshot = schemaSource()
    let tables = snapshot.tables.filter {
      $0.name == collection && (database == nil || $0.schema == database)
    }
    let request = AIChatRequest(
      model: model,
      system: AIPrompts.mongoAssistSystem(
        target, databaseName: database ?? snapshot.databaseName, collection: collection,
        schema: AISchemaContext.render(tables: tables, foreignKeys: []), current: current),
      messages: [AIChatMessage(role: .user, text: prompt)])

    var reply = ""
    for try await event in client.stream(request) {
      try Task.checkCancellation()
      if case .text(let delta) = event { reply += delta }
    }
    // A stop that lands after the last event must not hand the reply to the caller's write
    try Task.checkCancellation()
    return reply
  }

  // MARK: - History

  /// Replaces `conversations` from disk. A nil store keeps the in-memory list.
  private func reloadConversationsFromStore() {
    guard let historyStore else { return }
    conversations = historyStore.load()
  }

  /// Upserts the current conversation and moves it to the top; unchanged or empty ones are skipped
  func saveConversation() {
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

  /// History of the conversation (which already ends with the new question). Query results and
  /// errors are placeholders (`historyMessage`); running queries are left out.
  func makeHistory() -> [AIChatMessage] {
    let sent =
      messages
      .filter {
        !$0.isError && $0.isRunning != true && (!$0.text.isEmpty || $0.queryResult != nil)
      }
      .suffix(Self.historyLimit)
      .map(Self.historyMessage(for:))
      .drop(while: { $0.role == .assistant })  // Anthropic requires the first message to be user
    return Array(sent)
  }

  /// Builds the request off the main actor: table selection and rendering are O(tables)
  nonisolated static func buildRequest(
    model: String, question: String, explicit: Set<String>, snapshot: AISchemaSnapshot,
    history: [AIChatMessage], runsQueries: Bool, compactPrompt: Bool,
    screen: AIMongoAssist.Screen? = nil
  ) async -> AIChatRequest {
    await Task.detached {
      let selected = AISchemaContext.selectTables(
        explicit: explicit, question: question, tables: snapshot.tables,
        foreignKeys: snapshot.foreignKeys)
      let schema = AISchemaContext.render(tables: selected, foreignKeys: snapshot.foreignKeys)
      return AIChatRequest(
        model: model,
        system: AIPrompts.system(
          databaseName: snapshot.databaseName, schema: schema, dialect: snapshot.dialect,
          runsQueries: runsQueries, compact: compactPrompt, screen: screen),
        messages: history)
    }.value
  }

  func append(_ delta: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += delta
  }

  /// Keeps partial text in its entry and shows the error in a separate entry below it;
  /// an entry that has no text yet becomes the error entry itself.
  func markError(_ id: UUID, _ error: Error) {
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

  /// An assistant entry that never received text would show "Thinking…" forever, and a query
  /// placeholder "Running query…"; a query result has no text but stays
  private func removeEmptyAssistantEntries() {
    messages.removeAll {
      $0.role == .assistant && !$0.isError && $0.text.isEmpty && $0.queryResult == nil
    }
  }
}
