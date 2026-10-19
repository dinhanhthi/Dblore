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
  /// A turn waiting for "Allow AI for <connection> this session"
  struct PendingApproval {
    let connectionName: String
    fileprivate let context: AIAccessContext
    /// Repeats the held send, which asks the gate again
    fileprivate let resume: @MainActor () -> Void
  }

  /// Why the gate stopped a one-shot request: nothing was sent
  enum AIAccessError: LocalizedError, Equatable {
    case denied
    case needsApproval
    /// The collection is not one the current connection's loaded schema lists
    case otherConnection

    var errorDescription: String? {
      switch self {
      case .denied: "AI access is off for this connection."
      case .needsApproval: "Allow AI for this connection first."
      case .otherConnection: "This tab belongs to a different connection. Reload it first."
      }
    }
  }

  /// What the footer says about a connection that is private to AI
  enum PrivateNote: Equatable {
    /// Only the new message was sent, without schema or earlier messages
    case messageOnly
    /// The draft holds Explain or Fix text from the connection, so it was not sent
    case draftHeld
    /// The draft holds Explain or Fix text from another connection, so it was not sent
    case draftFromOtherConnection
    /// Retry and Edit are off: the stored message may hold Explain or Fix text
    case retryHeld
  }

  typealias AccessCheck = (context: AIAccessContext?, decision: AIAccessGate.Decision)

  private static let historyLimit = 20
  private static let conversationLimit = 100
  private static let titleLength = 80
  /// Rows of a result kept for the card
  static let modelRowCap = 50

  var messages: [AIChatEntry] = []
  /// Saved conversations of the workspace, most recently updated first
  private(set) var conversations: [AIConversation] = []
  private(set) var conversationId = UUID()
  var draft = "" {
    didSet {
      if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draftHoldsConnectionText = false
        draftSessionKey = nil
        if privateNote == .draftHeld { privateNote = .messageOnly }
        if privateNote == .draftFromOtherConnection { privateNote = nil }
      }
    }
  }
  /// The draft holds Explain or Fix text (query, server error) of the connection: it is not sent
  /// while the connection is private to AI. Cleared when the draft is emptied or sent.
  @ObservationIgnored private var draftHoldsConnectionText = false
  /// `AIAccessGate.sessionKey` of the connection the Explain or Fix text came from; it is sent
  /// only while that connection is the current one
  @ObservationIgnored private var draftSessionKey: String?
  /// Session key at the last `connectionDidChange()`
  @ObservationIgnored private var connectionSessionKey: String?
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
  /// True when the current connection's loaded schema lists the collection (database nil: any);
  /// a tab can still show a collection of the previous connection
  @ObservationIgnored var isCurrentMongoCollection:
    (_ database: String?, _ collection: String) ->
      Bool = { _, _ in false }
  /// Reads only the connection's dialect, so a view body does not collect the whole schema.
  /// Nil falls back to `schemaSource`.
  @ObservationIgnored var dialectSource: (() -> SQLDialect)?
  /// Runs one read-only statement the assistant asked for; nil means not connected
  @ObservationIgnored var queryRunner: ((String) async throws -> QueryResult)?
  /// The connection's AI access, read on user actions (send, retry, live answer, one-shot),
  /// never from a view body. Nil without a connection: nothing to protect.
  @ObservationIgnored var aiAccessSource: () -> AIAccessContext? = { nil }
  /// A send held until the user allows AI for the connection this session
  private(set) var pendingApproval: PendingApproval?
  /// The connection of the last send is private to AI; nil when it was not
  private(set) var privateNote: PrivateNote?
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
    guard !isGenerating, !question.isEmpty, activeProvider != nil,
      let access = admitTurn(resume: { [weak self] in self?.send() })
    else { return }
    if draftHoldsConnectionText {
      if access.decision == .denied {
        privateNote = .draftHeld
        return
      }
      if draftSessionKey != Self.sessionKey(access.context) {
        privateNote = .draftFromOtherConnection
        return
      }
    }
    draft = ""
    submit(question: question, access: access)
  }

  /// Restarts the conversation from a user message: that question and everything after it
  /// are dropped, then the question (or `editedText` when given) is sent with the current
  /// provider, model and tables. The draft is left alone. On a connection private to AI nothing
  /// is dropped or sent: the stored message may hold Explain or Fix text. Returns true when sent.
  @discardableResult
  func retry(from id: UUID, editedText: String? = nil) -> Bool {
    guard let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].role == .user, activeProvider != nil
    else { return false }
    let question = (editedText ?? messages[index].text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty,
      let access = admitTurn(resume: { [weak self] in
        self?.retry(from: id, editedText: editedText)
      })
    else { return false }
    if access.decision == .denied {
      privateNote = .retryHeld
      return false
    }
    stop()
    messages.removeSubrange(index...)
    submit(question: question, access: access)
    return true
  }

  // MARK: - AI access

  /// The connection's AI access and the gate's decision. Decodes the saved list: call it on a
  /// user action only.
  func aiAccessCheck() -> AccessCheck {
    guard let context = aiAccessSource() else { return (nil, .allowed) }
    return (context, context.decision(settings: settings.configuration))
  }

  func approveForSession(_ context: AIAccessContext) {
    context.gate.approveForSession(AIAccessGate.sessionKey(for: context.config))
  }

  private static func sessionKey(_ context: AIAccessContext?) -> String? {
    context.map { AIAccessGate.sessionKey(for: $0.config) }
  }

  /// The connection's name, else host/database (as History labels it)
  static func connectionName(_ config: ConnectionConfig) -> String {
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "\(config.host)/\(config.database)" : name
  }

  /// Asks the gate for a send. Needs approval: holds `resume` for Allow and returns nil, so
  /// nothing is sent and the draft stays.
  private func admitTurn(resume: @escaping @MainActor () -> Void) -> AccessCheck? {
    let check = aiAccessCheck()
    guard check.decision == .needsApproval, let context = check.context else {
      pendingApproval = nil
      return check
    }
    pendingApproval = PendingApproval(
      connectionName: Self.connectionName(context.config), context: context, resume: resume)
    return nil
  }

  /// Allows the held connection for this session, then sends the held turn
  func allowPendingTurn() {
    guard let pending = pendingApproval else { return }
    pendingApproval = nil
    approveForSession(pending.context)
    pending.resume()
  }

  /// Not now: drops the held send; the draft stays
  func dismissPendingTurn() {
    pendingApproval = nil
  }

  /// The workspace connected, switched or disconnected: notes about the old connection go. On
  /// another connection (session key) a draft holding Explain or Fix text of the old one goes,
  /// and so do the picked tables. A reconnect or a MongoDB database switch keeps the same key. A
  /// hand-typed draft stays.
  func connectionDidChange() {
    let key = Self.sessionKey(aiAccessSource())
    if draftHoldsConnectionText && draftSessionKey != key { draft = "" }
    if key != connectionSessionKey {
      selectedTableNames = []
      viewerTableName = nil
    }
    connectionSessionKey = key
    pendingApproval = nil
    privateNote = nil
  }

  private func submit(question: String, access: AccessCheck) {
    guard let provider = activeProvider else { return }
    privateNote = access.decision == .denied ? .messageOnly : nil
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
      compactPrompt: provider == .localMLX, dialect: sqlDialect, screen: mongoScreenSource(),
      access: access.context)
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
    pendingApproval = nil
    generationTask?.cancel()
    generationTask = nil
    generation += 1
    isGenerating = false
    isLoadingModel = false
    removeEmptyAssistantEntries()
    saveConversation()
  }

  /// Query text and error messages can contain row values, so these only fill the draft;
  /// the user reviews it and presses Send. `sessionKey` is the `AIAccessGate.sessionKey` of the
  /// connection the text came from (the tab's, stamped on its error), not the workspace's: a
  /// tab can lag behind a switch. Nil (unstamped) is held at send while connected.
  func explain(sql: String, sessionKey: String?) {
    fillDraft(AIPrompts.explain(sql: sql), sessionKey: sessionKey)
  }

  func fixError(sql: String, error: String, sessionKey: String?) {
    fillDraft(AIPrompts.fixError(sql: sql, error: error), sessionKey: sessionKey)
  }

  private func fillDraft(_ prompt: String, sessionKey: String?) {
    // Text of two connections never shares one draft
    if draftHoldsConnectionText && draftSessionKey != sessionKey { draft = "" }
    draft =
      draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? prompt : draft + "\n\n" + prompt
    draftHoldsConnectionText = true
    draftSessionKey = sessionKey
  }

  /// The current conversation is already saved, so this only starts an empty one
  func newChat() {
    stop()
    messages = []
    conversationId = UUID()
    privateNote = nil
  }

  func openConversation(id: UUID) {
    guard id != conversationId, let conversation = conversations.first(where: { $0.id == id })
    else { return }
    stop()
    // A query still running when the app quit never finished
    messages = conversation.messages.filter { $0.isRunning != true }
    conversationId = id
    privateNote = nil
  }

  func deleteConversation(id: UUID) {
    if id == conversationId { newChat() }
    conversations.removeAll { $0.id == id }
    historyStore?.save(conversations)
  }

  // MARK: - One-shot

  /// Generates the filter or pipeline of `collection` from `prompt` and returns the raw reply.
  /// Outside the chat: no entry, history or generating state is touched. The caller owns
  /// cancellation and timeout. Throws `AIAccessError` before anything is sent unless the gate
  /// allows the connection and the collection is the current connection's.
  func mongoAssist(
    _ target: AIMongoAssist.Target, prompt: String, database: String?, collection: String,
    current: String
  ) async throws -> String {
    guard let provider = activeProvider else { throw AIClientError.missingModel }
    let model = activeModel
    guard !model.isEmpty else { throw AIClientError.missingModel }
    switch aiAccessCheck().decision {
    case .allowed: break
    case .needsApproval: throw AIAccessError.needsApproval
    case .denied: throw AIAccessError.denied
    }
    guard isCurrentMongoCollection(database, collection) else {
      throw AIAccessError.otherConnection
    }
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
    screen: AIMongoAssist.Screen? = nil, rules: String = ""
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
          runsQueries: runsQueries, compact: compactPrompt, screen: screen, rules: rules),
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
