// AIProviderConfigTests.swift
// Unit tests for AI provider model, configuration coding and AISettings

import Foundation
import Testing

@testable import Dblore

@Suite("AI Provider Config Tests")
@MainActor
struct AIProviderConfigTests {

  private static let key = "app.settings.aiConfiguration"

  private func makeSettings(
    defaults: UserDefaults? = nil, keyStore: AIKeyStore = InMemoryAIKeyStore()
  ) -> (AISettings, UserDefaults, AIKeyStore) {
    let suite = defaults ?? UserDefaults(suiteName: "AIProviderConfigTests-\(UUID())")!
    return (AISettings(defaults: suite, keyStore: keyStore), suite, keyStore)
  }

  @Test("AIConfiguration JSON round-trips with enum-keyed dictionary")
  func configurationRoundTrip() throws {
    let config = AIConfiguration(
      activeProvider: .ollama,
      configs: [
        .ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "llama3"),
        .anthropic: AIProviderConfig(baseURL: "https://api.anthropic.com/v1", model: "claude"),
      ])
    let data = try JSONEncoder().encode(config)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["configs"] is [String: Any])
    let decoded = try JSONDecoder().decode(AIConfiguration.self, from: data)
    #expect(decoded == config)
  }

  @Test("provider kind defaults")
  func kindDefaults() {
    #expect(AIProviderKind.allCases.count == 7)
    #expect(AIProviderKind.anthropic.wire == .anthropicMessages)
    #expect(AIProviderKind.ollama.wire == .chatCompletions)
    #expect(AIProviderKind.ollama.defaultBaseURL == "http://127.0.0.1:11434/v1")
    #expect(AIProviderKind.custom.defaultBaseURL.isEmpty)
    for kind in [AIProviderKind.ollama, .lmStudio, .mlxServer, .custom] {
      #expect(!kind.requiresAPIKey)
    }
    for kind in [AIProviderKind.anthropic, .openAI, .openRouter] {
      #expect(kind.requiresAPIKey)
    }
  }

  @Test("corrupt JSON falls back to empty")
  func corruptJSON() {
    let suite = UserDefaults(suiteName: "AIProviderConfigTests-\(UUID())")!
    suite.set(Data("not json".utf8), forKey: Self.key)
    let (settings, _, _) = makeSettings(defaults: suite)
    #expect(settings.configuration == .empty)
  }

  @Test("configuration persists across instances")
  func persistence() {
    let (settings, suite, _) = makeSettings()
    settings.configuration.activeProvider = .openAI
    settings.configuration.configs[.openAI] = AIProviderConfig(baseURL: "u", model: "m")
    let (reloaded, _, _) = makeSettings(defaults: suite)
    #expect(reloaded.configuration == settings.configuration)
  }

  @Test("config(for:) falls back to default base URL and empty model")
  func configFallback() {
    let (settings, _, _) = makeSettings()
    let config = settings.config(for: .lmStudio)
    #expect(config.baseURL == "http://127.0.0.1:1234/v1")
    #expect(config.model.isEmpty)
  }

  @Test("isConfigured for keyless local provider needs only a model")
  func ollamaConfigured() {
    let (settings, _, _) = makeSettings()
    #expect(!settings.isConfigured(.ollama))
    settings.configuration.configs[.ollama] = AIProviderConfig(baseURL: "", model: "llama3")
    #expect(settings.isConfigured(.ollama))
  }

  @Test("isConfigured for Anthropic needs a key")
  func anthropicConfigured() {
    let (settings, _, _) = makeSettings()
    settings.configuration.configs[.anthropic] = AIProviderConfig(baseURL: "", model: "claude")
    #expect(!settings.isConfigured(.anthropic))
    settings.setAPIKey("sk-test", for: .anthropic)
    #expect(settings.apiKey(for: .anthropic) == "sk-test")
    #expect(settings.isConfigured(.anthropic))
  }

  @Test("setAPIKey with empty string deletes the key")
  func emptyKeyDeletes() {
    let (settings, _, _) = makeSettings()
    settings.setAPIKey("sk-test", for: .openAI)
    settings.setAPIKey("", for: .openAI)
    #expect(settings.apiKey(for: .openAI) == nil)
  }

  @Test("setAPIKey reports a failed save")
  func failedSaveReported() {
    let (settings, _, _) = makeSettings(keyStore: FailingAIKeyStore())
    #expect(!settings.setAPIKey("sk-test", for: .openAI))
    #expect(settings.apiKey(for: .openAI) == nil)
    #expect(settings.setAPIKey("", for: .openAI))
  }
}

private final class FailingAIKeyStore: AIKeyStore, @unchecked Sendable {
  func load(account: String) -> String? { nil }
  func save(_ value: String, account: String) -> Bool { false }
  func delete(account: String) {}
}
