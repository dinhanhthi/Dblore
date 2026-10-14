// AIAssistantPresentationTests.swift
// Session presentation state of the AI assistant: sidebar or bubble, expand and collapse,
// and the 3-state toggle.

import Foundation
import Testing

@testable import Dblore

@Suite("AI Assistant presentation")
@MainActor
struct AIAssistantPresentationTests {

  private func makeVM() -> AIAssistantViewModel {
    let defaults = UserDefaults(suiteName: "ai-presentation-\(UUID().uuidString)")!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    return AIAssistantViewModel(settings: settings)
  }

  @Test("opening from hidden with the sidebar default shows the sidebar panel")
  func openFromHiddenUsesSidebarDefault() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .sidebar)
    #expect(vm.isVisible)
    #expect(vm.presentation == .sidebar)
    #expect(vm.showsSidebarPanel)
    #expect(!vm.showsBubble)
  }

}
