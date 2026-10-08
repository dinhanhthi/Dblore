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

  @Test("opening from hidden with the bubble default shows an expanded bubble")
  func openFromHiddenInBubbleModeExpands() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    #expect(vm.showsBubble)
    #expect(vm.isBubbleExpanded)
    #expect(!vm.showsSidebarPanel)
  }

  @Test("toggling while the bubble is collapsed expands it")
  func toggleWhileBubbleCollapsedExpands() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    vm.collapseBubble()
    vm.toggleVisibility(defaultMode: .bubble)
    #expect(vm.showsBubble)
    #expect(vm.isBubbleExpanded)
  }

  @Test("toggling while the bubble is expanded hides the assistant")
  func toggleWhileBubbleExpandedHides() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    vm.toggleVisibility(defaultMode: .bubble)
    #expect(!vm.isVisible)
    #expect(!vm.isBubbleExpanded)
    #expect(!vm.showsBubble)
  }

  @Test("toggling while the sidebar is visible hides the assistant")
  func toggleWhileSidebarVisibleHides() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .sidebar)
    vm.toggleVisibility(defaultMode: .sidebar)
    #expect(!vm.isVisible)
    #expect(!vm.showsSidebarPanel)
  }

  @Test("reopening after hide uses the default mode, not the session mode")
  func reopenAfterHideResetsToDefault() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .sidebar)
    vm.togglePresentation()
    #expect(vm.presentation == .bubble)
    vm.hide()
    vm.toggleVisibility(defaultMode: .sidebar)
    #expect(vm.presentation == .sidebar)
    #expect(vm.showsSidebarPanel)
    #expect(!vm.isBubbleExpanded)
  }

  @Test("switching from sidebar to bubble lands expanded")
  func togglePresentationSidebarToBubbleLandsExpanded() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .sidebar)
    vm.togglePresentation()
    #expect(vm.presentation == .bubble)
    #expect(vm.showsBubble)
    #expect(vm.isBubbleExpanded)
    #expect(!vm.showsSidebarPanel)
  }

  @Test("switching from bubble to sidebar shows the sidebar and clears expanded")
  func togglePresentationBubbleToSidebar() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    vm.togglePresentation()
    #expect(vm.presentation == .sidebar)
    #expect(vm.showsSidebarPanel)
    #expect(!vm.isBubbleExpanded)
    #expect(!vm.showsBubble)
  }

  @Test("toggleBubbleExpanded does nothing unless the bubble is shown")
  func toggleBubbleExpandedIsNoOpOutsideBubble() {
    let vm = makeVM()
    vm.toggleBubbleExpanded()
    #expect(!vm.isVisible)
    #expect(!vm.isBubbleExpanded)

    vm.toggleVisibility(defaultMode: .sidebar)
    vm.toggleBubbleExpanded()
    #expect(vm.showsSidebarPanel)
    #expect(!vm.isBubbleExpanded)
  }

  @Test("collapsing the bubble keeps the circle visible")
  func collapseBubbleKeepsCircle() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    vm.collapseBubble()
    #expect(vm.showsBubble)
    #expect(vm.isVisible)
    #expect(!vm.isBubbleExpanded)
  }

  @Test("hide clears visibility and the expanded state")
  func hideClearsExpanded() {
    let vm = makeVM()
    vm.toggleVisibility(defaultMode: .bubble)
    vm.hide()
    #expect(!vm.isVisible)
    #expect(!vm.isBubbleExpanded)
    #expect(!vm.showsBubble)
    #expect(!vm.showsSidebarPanel)
  }

  @Test("WorkspaceManager.toggleAIAssistant forwards the default mode")
  func workspaceManagerToggleForwardsDefaultMode() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.toggleAIAssistant(defaultMode: .bubble)
    #expect(manager.aiAssistant.showsBubble)
    #expect(manager.aiAssistant.isBubbleExpanded)
  }
}
