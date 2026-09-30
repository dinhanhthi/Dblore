// AIAssistantViewModel.swift
// Workspace-level chat state for the AI SQL assistant. Only schema is sent; SQL is never executed.

import Foundation
import Observation

struct AIChatEntry: Identifiable, Equatable {
  let id: UUID
  let role: AIChatMessage.Role
  var text: String
  var isError: Bool
}

/// Structure-only snapshot of the connected database, read at send time
struct AISchemaSnapshot {
  var tables: [DatabaseTable]
  var foreignKeys: [ForeignKey]
  var databaseName: String?

  static let empty = AISchemaSnapshot(tables: [], foreignKeys: [], databaseName: nil)
}

@MainActor @Observable
final class AIAssistantViewModel {
  private static let historyLimit = 20

  var messages: [AIChatEntry] = []
  var draft = ""
  var isGenerating = false
  var isVisible = false
  var providerOverride: AIProviderKind?
  var modelOverride: String?
  /// Qualified table names; empty means automatic selection
  var selectedTableNames: Set<String> = []

  @ObservationIgnored private var generationTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  @ObservationIgnored let settings: AISettings
  @ObservationIgnored private let makeClient:
    (AIProviderKind, AIProviderConfig, String?) throws -> any AIChatClient
  @ObservationIgnored var schemaSource: () -> AISchemaSnapshot = { .empty }

  init(
    settings: AISettings = .shared,
    makeClient: @escaping (AIProviderKind, AIProviderConfig, String?) throws -> any AIChatClient = {
      try AIClientFactory.make(kind: $0, config: $1, apiKey: $2)
    }
  ) {
    self.settings = settings
    self.makeClient = makeClient
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

  func send() {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isGenerating, !question.isEmpty, let provider = activeProvider else { return }

    messages.append(AIChatEntry(id: UUID(), role: .user, text: question, isError: false))
    draft = ""

    let request = makeRequest(question: question)
    let entryId = UUID()
    messages.append(AIChatEntry(id: entryId, role: .assistant, text: "", isError: false))

    let client: any AIChatClient
    do {
      guard !request.model.isEmpty else { throw AIClientError.missingModel }
      client = try makeClient(
        provider, settings.config(for: provider), settings.apiKey(for: provider))
    } catch {
      markError(entryId, error)
      return
    }

    isGenerating = true
    generation += 1
    let token = generation
    generationTask = Task { [weak self] in
      do {
        for try await event in client.stream(request) {
          guard let self, !Task.isCancelled else { return }
          if case .text(let delta) = event { self.append(delta, to: entryId) }
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
    removeEmptyAssistantEntries()
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

  func clear() {
    stop()
    messages = []
  }

  // MARK: - Helpers

  /// Builds the request from the current history (which already ends with the new question)
  private func makeRequest(question: String) -> AIChatRequest {
    let snapshot = schemaSource()
    let selected = AISchemaContext.selectTables(
      explicit: selectedTableNames, question: question, tables: snapshot.tables,
      foreignKeys: snapshot.foreignKeys)
    let schema = AISchemaContext.render(tables: selected, foreignKeys: snapshot.foreignKeys)
    let history =
      messages
      .filter { !$0.isError && !$0.text.isEmpty }
      .suffix(Self.historyLimit)
      .drop(while: { $0.role == .assistant })  // Anthropic requires the first message to be user
      .map { AIChatMessage(role: $0.role, text: $0.text) }
    return AIChatRequest(
      model: activeModel,
      system: AIPrompts.system(databaseName: snapshot.databaseName, schema: schema),
      messages: Array(history))
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
    generationTask = nil
    removeEmptyAssistantEntries()
  }

  /// An assistant entry that never received text would show "Thinking…" forever
  private func removeEmptyAssistantEntries() {
    messages.removeAll { $0.role == .assistant && !$0.isError && $0.text.isEmpty }
  }
}
