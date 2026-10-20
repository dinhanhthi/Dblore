// MongoAIPromptStateTests.swift
// What the MongoDB AI prompt popover shows for the connection's AI access, on open and on Apply

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo AI Prompt State")
@MainActor
struct MongoAIPromptStateTests {

  private final class Holder {
    var policy: AIAccessPolicy
    var clientsMade = 0
    init(_ policy: AIAccessPolicy) { self.policy = policy }
  }

  private struct NoClient: Error {}

  /// Runs `body` with a throwaway defaults suite, removed afterwards
  private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
    let name = "MongoAIPromptStateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(defaults)
  }

  /// A configured assistant on the MongoDB connection "QA Mongo", whose policy `holder` holds;
  /// every client it makes is counted (nothing reaches a model)
  private func makeAssistant(_ holder: Holder, _ defaults: UserDefaults) -> AIAssistantViewModel {
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")])
    let vm = AIAssistantViewModel(settings: settings) { _, _, _ in
      holder.clientsMade += 1
      throw NoClient()
    }
    vm.isCurrentMongoCollection = { _, _ in true }
    let gate = AIAccessGate()
    vm.aiAccessSource = {
      var config = ConnectionConfig(
        databaseType: .mongodb, host: "db.local", database: "shop", name: "QA Mongo")
      config.aiAccess = holder.policy
      return AIAccessContext(config: config, savedPolicies: [], gate: gate)
    }
    return vm
  }

  private func state(_ vm: AIAssistantViewModel) -> MongoAIPromptState {
    MongoAIPromptState(needsSetup: vm.needsSetup, access: vm.aiAccessCheck())
  }

  @Test("a connection with AI access off opens on the off note, without a prompt")
  func deniedOnOpen() async throws {
    try await withDefaults { defaults in
      let vm = makeAssistant(Holder(.never), defaults)
      #expect(state(vm) == .off)
    }
  }

  @Test("allowed shows the prompt; turned off before Apply, the off note and nothing sent")
  func deniedAtApply() async throws {
    try await withDefaults { defaults in
      let holder = Holder(.always)
      let vm = makeAssistant(holder, defaults)
      #expect(state(vm) == .prompt)

      holder.policy = .never
      #expect(state(vm) == .off)
      await #expect(throws: AIAssistantViewModel.AIAccessError.denied) {
        _ = try await vm.mongoAssist(
          .filter, prompt: "paid orders", database: "shop", collection: "orders", current: "")
      }
      #expect(holder.clientsMade == 0)
    }
  }

  @Test("a connection that asks once per session waits for approval, then shows the prompt")
  func askThenAllow() async throws {
    try await withDefaults { defaults in
      let vm = makeAssistant(Holder(.askOncePerSession), defaults)
      #expect(state(vm) == .approval(connectionName: "QA Mongo"))

      let context = try #require(vm.aiAccessCheck().context)
      vm.approveForSession(context)
      #expect(state(vm) == .prompt)
    }
  }

  @Test("needs approval without a connection to approve fails closed on the off note")
  func approvalWithoutContextIsOff() {
    let access: AIAssistantViewModel.AccessCheck = (context: nil, decision: .needsApproval)
    #expect(MongoAIPromptState(needsSetup: false, access: access) == .off)
  }
}
