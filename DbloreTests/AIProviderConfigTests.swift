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

  @Test("runsQueries defaults to off, ignores the old query mode keys and round-trips")
  func runsQueriesCoding() throws {
    let old = #"{"activeProvider":"ollama","configs":{"ollama":{"baseURL":"u","model":"m"}}}"#
    #expect(
      try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8)).runsQueries == false)

    let unreleased =
      #"{"configs":{"ollama":{"baseURL":"u","model":"m"}},"queryMode":"readResults","hidesQueryModeInChat":true}"#
    let decoded = try JSONDecoder().decode(AIConfiguration.self, from: Data(unreleased.utf8))
    #expect(decoded.runsQueries == false)
    #expect(decoded.configs[.ollama]?.model == "m")

    let config = AIConfiguration(activeProvider: nil, configs: [:], runsQueries: true)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: data).runsQueries)
  }

  @Test("Connection access: absent is always, unknown asks; rows default to off; round-trip")
  func connectionAccessCoding() throws {
    let old = #"{"activeProvider":"ollama","configs":{"ollama":{"baseURL":"u","model":"m"}}}"#
    let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8))
    #expect(legacy.defaultConnectionAccess == .always)
    #expect(legacy.sendsResultRows == false)
    let future = #"{"configs":{},"defaultConnectionAccess":"fromTheFuture"}"#
    let unknown = try JSONDecoder().decode(AIConfiguration.self, from: Data(future.utf8))
    #expect(unknown.defaultConnectionAccess == .askOncePerSession)

    let config = AIConfiguration(
      activeProvider: nil, configs: [:], defaultConnectionAccess: .never, sendsResultRows: true)
    let decoded = try JSONDecoder().decode(
      AIConfiguration.self, from: try JSONEncoder().encode(config))
    #expect(decoded == config)
  }

  @Test("An unknown active provider decodes as none and keeps the rest of the configuration")
  func unknownActiveProviderDecodes() throws {
    let future = """
      {"activeProvider":"fromTheFuture","configs":{"ollama":{"baseURL":"u","model":"m"}},\
      "defaultConnectionAccess":"never",\
      "customCommands":[{"id":"\(UUID().uuidString)","name":"summary","template":"T"}]}
      """
    let decoded = try JSONDecoder().decode(AIConfiguration.self, from: Data(future.utf8))
    #expect(decoded.activeProvider == nil)
    #expect(decoded.configs[.ollama]?.model == "m")
    #expect(decoded.defaultConnectionAccess == .never)
    #expect(decoded.customCommands.map(\.name) == ["summary"])
  }

  @Test("configuration saved before Gemini decodes unchanged; Gemini round-trips")
  func geminiCoding() throws {
    let old =
      #"{"activeProvider":"anthropic","configs":{"anthropic":{"baseURL":"https://api.anthropic.com/v1","model":"claude"},"ollama":{"baseURL":"u","model":"m"}},"runsQueries":true,"defaultConnectionAccess":"never","sendsResultRows":true}"#
    let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8))
    #expect(
      legacy
        == AIConfiguration(
          activeProvider: .anthropic,
          configs: [
            .anthropic: AIProviderConfig(baseURL: "https://api.anthropic.com/v1", model: "claude"),
            .ollama: AIProviderConfig(baseURL: "u", model: "m"),
          ], runsQueries: true, defaultConnectionAccess: .never, sendsResultRows: true))

    let config = AIConfiguration(
      activeProvider: .gemini,
      configs: [
        .gemini: AIProviderConfig(
          baseURL: AIProviderKind.gemini.defaultBaseURL, model: "gemini-2.5-flash")
      ])
    let data = try JSONEncoder().encode(config)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["activeProvider"] as? String == "gemini")
    #expect((json["configs"] as? [String: Any])?["gemini"] != nil)
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: data) == config)
  }

  @Test("Gemini is listed, keyed, speaks its own wire and has fallback models")
  func geminiProvider() {
    #expect(AIProviderKind.allCases.contains(.gemini))
    #expect(AIProviderKind.gemini.requiresAPIKey)
    #expect(AIProviderKind.gemini.wire == .geminiGenerateContent)
    #expect(
      AIProviderKind.gemini.defaultBaseURL == "https://generativelanguage.googleapis.com/v1beta")
    #expect(!AIProviderKind.gemini.fallbackModels.isEmpty)
    #expect(AIProviderKind.gemini.fallbackModels.allSatisfy { AIEndpoint.geminiModelID($0) == $0 })
  }

  @Test("isConfigured for Gemini needs a key")
  func geminiConfigured() {
    let (settings, _, _) = makeSettings()
    settings.configuration.configs[.gemini] = AIProviderConfig(
      baseURL: "", model: "gemini-2.5-flash")
    #expect(!settings.isConfigured(.gemini))
    settings.setAPIKey("gm-test", for: .gemini)
    #expect(settings.isConfigured(.gemini))
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

  @Test("isConfigured for on-device MLX needs the plugin and an installed catalog model")
  func localMLXConfigured() {
    let (settings, _, _) = makeSettings()
    let catalogID = LocalModelCatalog.all[0].id
    settings.installedLocalModels = { [catalogID, "not-in-catalog"] }
    settings.localRuntimeInstalled = { true }
    #expect(!settings.isConfigured(.localMLX))  // empty model
    settings.configuration.configs[.localMLX] = AIProviderConfig(
      baseURL: "", model: "not-in-catalog")
    #expect(!settings.isConfigured(.localMLX))  // not a catalog id, even if "installed"
    settings.configuration.configs[.localMLX] = AIProviderConfig(baseURL: "", model: catalogID)
    #expect(settings.isConfigured(.localMLX))
    settings.localRuntimeInstalled = { false }
    #expect(!settings.isConfigured(.localMLX))  // model installed, On-device AI plugin missing
    settings.localRuntimeInstalled = { true }
    #expect(settings.isConfigured(.localMLX))
    settings.installedLocalModels = { [] }
    #expect(!settings.isConfigured(.localMLX))  // catalog id not installed
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
