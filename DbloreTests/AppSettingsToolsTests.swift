// AppSettingsToolsTests.swift
// The AI chat's app settings tools: a change applies through the AppSettings setter, excluded,
// unknown and out-of-kind values are refused without a write, Undo reverts only while the live
// value is still the new one, and long-query notifications go through the permission request.

import Foundation
import Testing

@testable import Dblore

@Suite("App settings tools")
@MainActor
struct AppSettingsToolsTests {
  /// Runs `body` with settings on a fresh suite of its own, removed afterwards
  private func withSettings(
    _ body: (AppSettings, UserDefaults) async throws -> Void
  ) async throws {
    let suiteName = "AppSettingsToolsTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    defer { suite.removePersistentDomain(forName: suiteName) }
    try await body(AppSettings(defaults: suite), suite)
  }

  private func change(_ key: String, _ value: String) throws -> AppSettingsTools.Change {
    let json = String(
      decoding: try JSONEncoder().encode(["key": key, "value": value]), as: UTF8.self)
    let call = try AppSettingsTools.decode(
      AIToolCall(id: "1", name: AppSettingsTools.changeSetting, inputJSON: json))
    guard case .changeSetting(let change) = call else {
      Issue.record("Expected a change_setting call")
      throw AITools.ToolError.unknownTool
    }
    return change
  }

  private func apply(
    _ key: String, _ value: String, on settings: AppSettings, granted: Bool = true
  ) async throws -> AppSettingsTools.Outcome {
    await AppSettingsTools.apply(try change(key, value), settings: settings) { granted }
  }

  @Test("change_setting applies through the setter and returns the old and new values")
  func appliesThroughSetter() async throws {
    try await withSettings { settings, suite in
      let outcome = try await apply("themePreference", "Light", on: settings)

      #expect(outcome == .applied(old: "Dark", new: "Light"))
      #expect(settings.themePreference == .light)
      #expect(suite.string(forKey: "app.settings.themePreference") == "Light")
    }
  }

  @Test(
    "An excluded or unknown key, or a refused direction, is refused, names its tab and writes nothing",
    arguments: [
      ("safeMode", "0", "Settings > Security"),
      ("mcpEnabled", "true", "Settings > MCP"),
      ("historyRetentionDays", "7", "Settings > Data"),
      ("neutralizesCopiedFormulas", "false", "Settings > Results"),
      ("statementTimeout", "5", "Settings > Results"),
      ("rewindEnabled", "false", "Settings > Data"),
      ("includeResultsOnSave", "false", "Settings > Save"),
      ("noSuchSetting", "1", "list_settings"),
    ])
  func refusesKeys(key: String, value: String, named: String) async throws {
    try await withSettings { settings, suite in
      let outcome = try await apply(key, value, on: settings)

      guard case .refused(let error) = outcome else {
        Issue.record("Expected a refusal, got \(outcome)")
        return
      }
      #expect(error.message.contains(named))
      #expect(suite.object(forKey: "app.settings.\(key)") == nil)
    }
  }

  @Test(
    "A value outside the setting's kind is refused and nothing is written",
    arguments: [
      ("maxResultHeight", "225"), ("maxResultHeight", "1050"), ("formatterLineWidth", "95"),
    ])
  func refusesValues(key: String, value: String) async throws {
    try await withSettings { settings, suite in
      let outcome = try await apply(key, value, on: settings)

      guard case .refused = outcome else {
        Issue.record("Expected a refusal, got \(outcome)")
        return
      }
      #expect(suite.object(forKey: "app.settings.\(key)") == nil)
      #expect(settings.maxResultHeight == 500)
      #expect(settings.formatterLineWidth == 0)
    }
  }

  @Test("Undo writes the old value back while the live value is still the new one")
  func undoReverts() async throws {
    try await withSettings { settings, suite in
      _ = try await apply("themePreference", "Light", on: settings)

      let outcome = await AppSettingsTools.undo(
        key: "themePreference", oldValue: "Dark", newValue: "Light", settings: settings
      ) { true }

      #expect(outcome == .undone)
      #expect(settings.themePreference == .dark)
      #expect(suite.string(forKey: "app.settings.themePreference") == "Dark")
    }
  }

  @Test("Undo writes nothing when the setting changed since")
  func undoChangedSince() async throws {
    try await withSettings { settings, suite in
      _ = try await apply("themePreference", "Light", on: settings)
      settings.themePreference = .system

      let outcome = await AppSettingsTools.undo(
        key: "themePreference", oldValue: "Dark", newValue: "Light", settings: settings
      ) { true }

      #expect(outcome == .changedSince)
      #expect(settings.themePreference == .system)
      #expect(suite.string(forKey: "app.settings.themePreference") == "System")
    }
  }

  @Test(
    "validateUndo refuses a tampered change",
    arguments: [
      ("safeMode", "1", "0"), ("themePreference", "Neon", "Light"),
      ("maxResultHeight", "500", "225"), ("noSuchSetting", "true", "false"),
    ])
  func refusesTamperedUndo(key: String, oldValue: String, newValue: String) async throws {
    try await withSettings { settings, suite in
      #expect(!AppSettingsTools.validateUndo(key: key, oldValue: oldValue, newValue: newValue))

      let outcome = await AppSettingsTools.undo(
        key: key, oldValue: oldValue, newValue: newValue, settings: settings
      ) { true }

      #expect(outcome == .refused)
      #expect(suite.object(forKey: "app.settings.\(key)") == nil)
    }
  }

  @Test("Notifications go through the permission request: refused permission keeps them off")
  func notificationsPermission() async throws {
    try await withSettings { settings, _ in
      let refused = try await apply("notifyLongQueries", "true", on: settings, granted: false)

      #expect(refused == .noOp(.stayedOff))
      #expect(!settings.notifyLongQueries)

      settings.notifyLongQueries = true
      let turnedOff = try await apply("notifyLongQueries", "false", on: settings)
      #expect(turnedOff == .applied(old: "true", new: "false"))

      let undo = await AppSettingsTools.undo(
        key: "notifyLongQueries", oldValue: "true", newValue: "false", settings: settings
      ) { false }

      #expect(undo == .stayedOff)
      #expect(!settings.notifyLongQueries)
    }
  }

  @Test("Undo of an AI turn-on of query history turns it off again")
  func undoHistoryTurnOn() async throws {
    try await withSettings { settings, _ in
      settings.historyEnabled = false
      let outcome = try await apply("historyEnabled", "true", on: settings)
      #expect(outcome == .applied(old: "false", new: "true"))

      let undo = await AppSettingsTools.undo(
        key: "historyEnabled", oldValue: "false", newValue: "true", settings: settings
      ) { true }

      #expect(undo == .undone)
      #expect(!settings.historyEnabled)
    }
  }

  // MARK: - View model

  /// A view model on `settings` and `suite` whose notification permission request answers
  /// `granted`
  private func makeVM(
    _ settings: AppSettings, _ suite: UserDefaults, granted: Bool = true
  ) -> AIAssistantViewModel {
    AIAssistantViewModel(
      settings: AISettings(defaults: suite, keyStore: InMemoryAIKeyStore()),
      appSettings: settings, requestNotificationAuthorization: { granted })
  }

  private func runChange(
    _ vm: AIAssistantViewModel, _ key: String, _ value: String
  ) async throws -> AIToolResult? {
    let json = String(
      decoding: try JSONEncoder().encode(["key": key, "value": value]), as: UTF8.self)
    return await vm.runSettingsTool(
      AIToolCall(id: UUID().uuidString, name: AppSettingsTools.changeSetting, inputJSON: json),
      token: vm.generation)
  }

  @Test("A real change appends one entry with an applied Undo card; a refusal appends none")
  func changeAppendsCard() async throws {
    try await withSettings { settings, suite in
      let vm = makeVM(settings, suite, granted: false)
      vm.isSettingShadowed = { $0 == "themePreference" }
      vm.messages = [
        AIChatEntry(id: UUID(), role: .user, text: "Switch to the light theme", isError: false)
      ]

      let result = try #require(try await runChange(vm, "themePreference", "Light"))

      #expect(vm.messages.count == 2)
      let entry = try #require(vm.messages.last)
      #expect(
        entry.settingChange
          == AISettingChange(
            key: "themePreference", oldValue: "Dark", newValue: "Light", shadowed: true,
            state: .applied))
      #expect(entry.toolCalls?.map(\.name) == [AppSettingsTools.changeSetting])
      #expect(entry.toolResults == [result])
      #expect(entry.toolSessionKey == nil)
      #expect(!result.isError)
      #expect(result.content.contains("workspace"))
      #expect(settings.themePreference == .light)
      #expect(vm.conversations.first?.messages == vm.messages)

      for (key, value) in [("notifyLongQueries", "true"), ("safeMode", "0")] {
        let refused = try #require(try await runChange(vm, key, value))
        #expect(refused.isError)
        #expect(vm.messages.last?.settingChange == nil)
        #expect(vm.messages.last?.toolResults == [refused])
      }
      #expect(vm.messages.count == 4)
      #expect(!settings.notifyLongQueries)
    }
  }

  @Test("Undo marks the card undone, changed since, or notifications stayed off")
  func undoCard() async throws {
    try await withSettings { settings, suite in
      let vm = makeVM(settings, suite, granted: false)
      @MainActor func card(_ id: UUID) -> AISettingChange? {
        vm.messages.first { $0.id == id }?.settingChange
      }

      _ = try await runChange(vm, "themePreference", "Light")
      let undone = try #require(vm.messages.last?.id)
      await vm.undoSettingChange(undone)
      #expect(card(undone)?.state == .undone)
      #expect(settings.themePreference == .dark)

      _ = try await runChange(vm, "themePreference", "Light")
      let changed = try #require(vm.messages.last?.id)
      settings.themePreference = .system
      await vm.undoSettingChange(changed)
      #expect(card(changed)?.state == .changedSince)
      #expect(settings.themePreference == .system)

      settings.notifyLongQueries = true
      _ = try await runChange(vm, "notifyLongQueries", "false")
      let stayedOff = try #require(vm.messages.last?.id)
      await vm.undoSettingChange(stayedOff)
      #expect(card(stayedOff)?.state == .applied)
      #expect(card(stayedOff)?.notificationsStayedOff == true)
      #expect(!settings.notifyLongQueries)
    }
  }

  @Test("A change whose permission prompt outlives its conversation adds no card to the next one")
  func staleChangeOtherConversation() async throws {
    try await withSettings { settings, suite in
      final class Box { var vm: AIAssistantViewModel? }
      let box = Box()
      let vm = AIAssistantViewModel(
        settings: AISettings(defaults: suite, keyStore: InMemoryAIKeyStore()),
        appSettings: settings,
        requestNotificationAuthorization: { @MainActor in
          box.vm?.newChat()
          return true
        })
      box.vm = vm
      vm.messages = [
        AIChatEntry(id: UUID(), role: .user, text: "Notify me of long queries", isError: false)
      ]

      let result = try await runChange(vm, "notifyLongQueries", "true")

      #expect(result == nil)
      #expect(settings.notifyLongQueries)
      #expect(!vm.messages.contains { $0.settingChange != nil })
    }
  }
}
