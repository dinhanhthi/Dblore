// AIProvider.swift
// AI provider catalog, persisted configuration and the settings store

import Foundation
import Observation

nonisolated enum AIProviderKind: String, Codable, CaseIterable, Sendable {
  case anthropic, openAI, openRouter, ollama, lmStudio, mlxServer, custom

  var displayName: String {
    switch self {
    case .anthropic: return "Anthropic"
    case .openAI: return "OpenAI"
    case .openRouter: return "OpenRouter"
    case .ollama: return "Ollama"
    case .lmStudio: return "LM Studio"
    case .mlxServer: return "mlx_lm.server"
    case .custom: return "Custom (OpenAI-compatible)"
    }
  }

  var wire: AIWire {
    self == .anthropic ? .anthropicMessages : .chatCompletions
  }

  var defaultBaseURL: String {
    switch self {
    case .anthropic: return "https://api.anthropic.com/v1"
    case .openAI: return "https://api.openai.com/v1"
    case .openRouter: return "https://openrouter.ai/api/v1"
    case .ollama: return "http://127.0.0.1:11434/v1"
    case .lmStudio: return "http://127.0.0.1:1234/v1"
    case .mlxServer: return "http://127.0.0.1:8080/v1"
    case .custom: return ""
    }
  }

  var requiresAPIKey: Bool {
    switch self {
    case .anthropic, .openAI, .openRouter: return true
    case .ollama, .lmStudio, .mlxServer, .custom: return false
    }
  }

  /// Used when the provider's /models list cannot be fetched (verify at implementation)
  var fallbackModels: [String] {
    switch self {
    case .anthropic: return ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1"]
    case .openAI: return ["gpt-4.1", "gpt-4.1-mini", "gpt-4o"]
    case .openRouter:
      return ["anthropic/claude-sonnet-4.5", "openai/gpt-4.1", "google/gemini-2.5-pro"]
    case .ollama, .lmStudio, .mlxServer, .custom: return []
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

  static let empty = AIConfiguration(activeProvider: nil, configs: [:])

  init(activeProvider: AIProviderKind?, configs: [AIProviderKind: AIProviderConfig]) {
    self.activeProvider = activeProvider
    self.configs = configs
  }

  private enum CodingKeys: String, CodingKey { case activeProvider, configs }

  // A dictionary with enum keys encodes as a flat array by default; use string keys instead
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activeProvider = try container.decodeIfPresent(AIProviderKind.self, forKey: .activeProvider)
    let raw =
      try container.decodeIfPresent([String: AIProviderConfig].self, forKey: .configs) ?? [:]
    // Unknown provider keys (e.g. from a newer version) are dropped
    configs = Dictionary(
      uniqueKeysWithValues: raw.compactMap { key, value in
        AIProviderKind(rawValue: key).map { ($0, value) }
      })
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(activeProvider, forKey: .activeProvider)
    let raw = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
    try container.encode(raw, forKey: .configs)
  }
}

@MainActor @Observable
final class AISettings {
  static let shared = AISettings(
    defaults: AppSettings.sharedDefaults, keyStore: AIKeyStoreFactory.makeDefault())

  private static let defaultsKey = "app.settings.aiConfiguration"

  var configuration: AIConfiguration {
    didSet { persist() }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let keyStore: AIKeyStore

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

  func setAPIKey(_ value: String, for kind: AIProviderKind) {
    let account = AIKeyStoreFactory.apiKeyAccount(kind.rawValue)
    if value.isEmpty {
      keyStore.delete(account: account)
    } else {
      keyStore.save(value, account: account)
    }
  }

  func isConfigured(_ kind: AIProviderKind) -> Bool {
    guard !config(for: kind).model.isEmpty else { return false }
    guard kind.requiresAPIKey else { return true }
    return !(apiKey(for: kind) ?? "").isEmpty
  }
}
