//
//  ModalDismissRegistryTests.swift
//  DbloreTests
//

import AppKit
import Testing

@testable import Dblore

@Suite("Modal Escape")
@MainActor
struct ModalDismissRegistryTests {
  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
  }

  @Test("Escape closes only the top modal in that window")
  func closesTopModalInThatWindow() {
    let registry = ModalDismissRegistry()
    let window = makeWindow()
    let other = makeWindow()
    var closed: [String] = []
    let first = UUID()
    let second = UUID()
    let foreign = UUID()
    registry.upsert(id: first, window: window) { closed.append("first") }
    registry.upsert(id: second, window: window) { closed.append("second") }
    registry.upsert(id: foreign, window: other) { closed.append("foreign") }

    #expect(registry.handleEscape(in: window))
    #expect(closed == ["second"])

    // The first dismiss has not left the screen yet, so a repeat is swallowed.
    #expect(registry.handleEscape(in: window))
    #expect(closed == ["second"])

    registry.unregister(id: second)
    #expect(registry.handleEscape(in: window))
    #expect(closed == ["second", "first"])
    // The view unregisters when it leaves the screen, not when Escape fires.
    registry.unregister(id: first)
    #expect(registry.hasModal(in: window) == false)
    #expect(registry.hasModal(in: other) == true)
  }

  @Test("Refreshing a modal does not move it above one opened later")
  func refreshDoesNotReorder() {
    let registry = ModalDismissRegistry()
    let window = makeWindow()
    var closed: [String] = []
    let first = UUID()
    let second = UUID()
    registry.upsert(id: first, window: window) { closed.append("first") }
    registry.upsert(id: second, window: window) { closed.append("second") }
    registry.upsert(id: first, window: window) { closed.append("first-updated") }

    #expect(registry.handleEscape(in: window))
    #expect(closed == ["second"])
  }

  @Test("Escape in a window with no modal is not handled")
  func ignoresWindowWithoutModal() {
    let registry = ModalDismissRegistry()
    #expect(!registry.handleEscape(in: makeWindow()))
  }
}
