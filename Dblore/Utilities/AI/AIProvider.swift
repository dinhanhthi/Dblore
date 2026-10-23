// AIProvider.swift
// AI provider catalog, persisted configuration and the settings store

import Foundation
import Observation

nonisolated enum AIProviderKind: String, Codable, CaseIterable, Sendable {
  case anthropic, openAI, gemini, openRouter, xAI, requesty, ollama, lmStudio, mlxServer, custom
  case chatGPT, localMLX

  var displayName: String {
    switch self {
    case .anthropic: return "Anthropic"
    case .openAI: return "OpenAI"
    case .gemini: return "Google Gemini"
    case .openRouter: return "OpenRouter"
    case .xAI: return "xAI"
    case .requesty: return "Requesty"
    case .ollama: return "Ollama"
    case .lmStudio: return "LM Studio"
    case .mlxServer: return "mlx_lm.server"
    case .custom: return "Custom (OpenAI-compatible)"
    case .chatGPT: return "ChatGPT (subscription, experimental)"
    case .localMLX: return "On-device (MLX)"
    }
  }

  var wire: AIWire {
    switch self {
    case .anthropic: return .anthropicMessages
    case .chatGPT: return .responses
    case .gemini: return .geminiGenerateContent
    default: return .chatCompletions
    }
  }

  var defaultBaseURL: String {
    switch self {
    case .anthropic: return "https://api.anthropic.com/v1"
    case .openAI: return "https://api.openai.com/v1"
    case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
    case .openRouter: return "https://openrouter.ai/api/v1"
    case .xAI: return "https://api.x.ai/v1"
    case .requesty: return "https://router.requesty.ai/v1"
    case .ollama: return "http://127.0.0.1:11434/v1"
    case .lmStudio: return "http://127.0.0.1:1234/v1"
    case .mlxServer: return "http://127.0.0.1:8080/v1"
    case .custom: return ""
    case .chatGPT: return "https://chatgpt.com/backend-api/codex"
    case .localMLX: return ""
    }
  }

  var requiresAPIKey: Bool {
    switch self {
    case .anthropic, .openAI, .gemini, .openRouter, .xAI, .requesty: return true
    case .ollama, .lmStudio, .mlxServer, .custom, .chatGPT, .localMLX: return false
    }
  }

  /// Used when the provider's /models list cannot be fetched (verify at implementation)
  var fallbackModels: [String] {
    switch self {
    case .anthropic: return ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"]
    case .openAI: return ["gpt-4.1", "gpt-4.1-mini", "gpt-4o"]
    case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
    case .openRouter:
      return ["anthropic/claude-sonnet-4.5", "openai/gpt-4.1", "google/gemini-2.5-pro"]
    case .chatGPT: return ["gpt-5.1-codex", "gpt-5.1-codex-mini", "gpt-5.1"]
    // xAI and Requesty: models come from their /models list only
    case .xAI, .requesty, .ollama, .lmStudio, .mlxServer, .custom, .localMLX: return []
    }
  }
}

nonisolated struct AIProviderConfig: Codable, Equatable, Sendable {
  var baseURL: String
  var model: String
}

nonisolated struct AIConfiguration: Codable, Equatable, Sendable {
  var activeProvider: AIProviderKind?
  var configs: [AIProviderKind: AIProviderConfig]
  /// The assistant runs the read-only query of a ```sql run block and shows the rows to the
  /// user only; they never reach the model
  var runsQueries: Bool
  /// Policy of a connection left on "use default". `.always` keeps the behavior from before
  /// per-connection policies.
  var defaultConnectionAccess: AIAccessPolicy
  /// Whether result rows may be sent to the model (off: the model sees the query only)
  var sendsResultRows: Bool
  /// Ghost text in SQL editors (explicit opt-in)
  var inlineEnabled: Bool
  /// Provider of ghost text; nil uses the chat provider
  var inlineProvider: AIProviderKind?
  /// Model of ghost text on `inlineProvider`; nil uses that provider's model. Ignored on-device.
  var inlineModel: String?
  /// Typing pause before a ghost text request
  var inlineDebounceMs: Int
  /// Slash commands the user wrote (`AISlashCommand.sanitized` on decode)
  var customCommands: [AICustomCommand]

  static let empty = AIConfiguration(activeProvider: nil, configs: [:])

  init(
    activeProvider: AIProviderKind?, configs: [AIProviderKind: AIProviderConfig],
    runsQueries: Bool = false, defaultConnectionAccess: AIAccessPolicy = .always,
    sendsResultRows: Bool = false, inlineEnabled: Bool = false,
    inlineProvider: AIProviderKind? = nil, inlineModel: String? = nil, inlineDebounceMs: Int = 400,
    customCommands: [AICustomCommand] = []
  ) {
    self.activeProvider = activeProvider
    self.configs = configs
    self.runsQueries = runsQueries
    self.defaultConnectionAccess = defaultConnectionAccess
    self.sendsResultRows = sendsResultRows
    self.inlineEnabled = inlineEnabled
    self.inlineProvider = inlineProvider
    self.inlineModel = inlineModel
    self.inlineDebounceMs = inlineDebounceMs
    self.customCommands = customCommands
  }

  /// Provider and model ghost text uses: the inline provider (else the chat provider) with the
  /// inline model (else that provider's model; only when the inline provider is set). On-device
  /// always uses its chat model: the engine holds one resident model, and a second one would
  /// reload weights on every typing pause. Nil without a provider or a model.
  var inlineTarget: (provider: AIProviderKind, model: String)? {
    guard let provider = inlineProvider ?? activeProvider else { return nil }
    let chatModel = configs[provider]?.model ?? ""
    let model =
      provider == .localMLX || inlineProvider == nil
      ? chatModel : (inlineModel.flatMap { $0.isEmpty ? nil : $0 } ?? chatModel)
    return model.isEmpty ? nil : (provider, model)
  }

  private enum CodingKeys: String, CodingKey {
    case activeProvider, configs, runsQueries, defaultConnectionAccess, sendsResultRows
    case inlineEnabled, inlineProvider, inlineModel, inlineDebounceMs, customCommands
  }

  /// One saved command; nil when it cannot be decoded, so one bad entry drops only itself
  private struct LossyCommand: Decodable {
    let command: AICustomCommand?

    init(from decoder: Decoder) throws {
      command = try? AICustomCommand(from: decoder)
    }
  }

  // A dictionary with enum keys encodes as a flat array by default; use string keys instead
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // An unknown provider (e.g. from a newer version) decodes as none
    activeProvider = try container.decodeIfPresent(String.self, forKey: .activeProvider)
      .flatMap(AIProviderKind.init(rawValue:))
    let raw =
      try container.decodeIfPresent([String: AIProviderConfig].self, forKey: .configs) ?? [:]
    // Unknown provider keys (e.g. from a newer version) are dropped
    configs = Dictionary(
      uniqueKeysWithValues: raw.compactMap { key, value in
        AIProviderKind(rawValue: key).map { ($0, value) }
      })
    runsQueries = try container.decodeIfPresent(Bool.self, forKey: .runsQueries) ?? false
    // Absent before per-connection policies: keep the original behavior. An unknown value
    // (e.g. from a newer version) asks (fail closed).
    let rawAccess = try container.decodeIfPresent(String.self, forKey: .defaultConnectionAccess)
    defaultConnectionAccess =
      rawAccess.map { AIAccessPolicy(rawValue: $0) ?? .askOncePerSession } ?? .always
    sendsResultRows = try container.decodeIfPresent(Bool.self, forKey: .sendsResultRows) ?? false
    inlineEnabled = try container.decodeIfPresent(Bool.self, forKey: .inlineEnabled) ?? false
    // An unknown provider (e.g. from a newer version) falls back to the chat provider
    inlineProvider = try container.decodeIfPresent(String.self, forKey: .inlineProvider)
      .flatMap(AIProviderKind.init(rawValue:))
    inlineModel = try container.decodeIfPresent(String.self, forKey: .inlineModel)
    inlineDebounceMs = try container.decodeIfPresent(Int.self, forKey: .inlineDebounceMs) ?? 400
    // Absent before slash commands. The saved list is untrusted: invalid entries are dropped and
    // the limits applied; a list that is no array drops every command, not the configuration.
    let commands = (try? container.decodeIfPresent([LossyCommand].self, forKey: .customCommands))
      .flatMap { $0 }?.compactMap(\.command)
    customCommands = AISlashCommand.sanitized(commands ?? [])
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(activeProvider, forKey: .activeProvider)
    let raw = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
    try container.encode(raw, forKey: .configs)
    try container.encode(runsQueries, forKey: .runsQueries)
    try container.encode(defaultConnectionAccess, forKey: .defaultConnectionAccess)
    try container.encode(sendsResultRows, forKey: .sendsResultRows)
    try container.encode(inlineEnabled, forKey: .inlineEnabled)
    try container.encodeIfPresent(inlineProvider, forKey: .inlineProvider)
    try container.encodeIfPresent(inlineModel, forKey: .inlineModel)
    try container.encode(inlineDebounceMs, forKey: .inlineDebounceMs)
    try container.encode(customCommands, forKey: .customCommands)
  }
}

@MainActor @Observable
final class AISettings {
  static let shared = AISettings(
    defaults: AppSettings.sharedDefaults, keyStore: AIKeyStoreFactory.shared)

  private nonisolated static let defaultsKey = "app.settings.aiConfiguration"

  var configuration: AIConfiguration {
    didSet { persist() }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let keyStore: AIKeyStore
  /// Bumped when an API key is saved or removed; clients built with the old key are stale
  @ObservationIgnored private(set) var keyRevision = 0
  /// Installed on-device model ids; a cached, observable set (no disk access while rendering)
  @ObservationIgnored var installedLocalModels: @MainActor () -> Set<String> = {
    LocalModelManager.shared.installedIDs
  }

  init(defaults: UserDefaults, keyStore: AIKeyStore) {
    self.defaults = defaults
    self.keyStore = keyStore
    if let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode(AIConfiguration.self, from: data)
    {
      configuration = decoded
    } else {
      configuration = .empty
    }
  }

  /// The configuration saved in `defaults`, read from any isolation: `.empty` when none is
  /// saved, nil when the saved value cannot be decoded.
  nonisolated static func savedConfiguration(in defaults: UserDefaults) -> AIConfiguration? {
    guard let stored = defaults.object(forKey: defaultsKey) else { return .empty }
    guard let data = stored as? Data else { return nil }
    return try? JSONDecoder().decode(AIConfiguration.self, from: data)
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  func config(for kind: AIProviderKind) -> AIProviderConfig {
    configuration.configs[kind] ?? AIProviderConfig(baseURL: kind.defaultBaseURL, model: "")
  }

  func apiKey(for kind: AIProviderKind) -> String? {
    keyStore.load(account: AIKeyStoreFactory.apiKeyAccount(kind.rawValue))
  }

  /// Returns false when the key store could not save the key
  @discardableResult
  func setAPIKey(_ value: String, for kind: AIProviderKind) -> Bool {
    let account = AIKeyStoreFactory.apiKeyAccount(kind.rawValue)
    keyRevision += 1
    if value.isEmpty {
      keyStore.delete(account: account)
      return true
    }
    return keyStore.save(value, account: account)
  }

  func chatGPTTokens() -> ChatGPTTokens? {
    ChatGPTTokenStorage.load(from: keyStore)
  }

  func isConfigured(_ kind: AIProviderKind) -> Bool {
    guard !config(for: kind).model.isEmpty else { return false }
    if kind == .localMLX {
      guard let model = LocalModelCatalog.model(for: config(for: kind).model) else { return false }
      return installedLocalModels().contains(model.id)
    }
    if kind == .chatGPT { return ChatGPTTokenStorage.load(from: keyStore) != nil }
    guard kind.requiresAPIKey else { return true }
    return !(apiKey(for: kind) ?? "").isEmpty
  }
}
