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

  @Test("A suspended modal keeps its place and lets Escape through")
  func suspendedModalKeepsOrder() {
    let registry = ModalDismissRegistry()
    let window = makeWindow()
    var closed: [String] = []
    let bubble = UUID()
    let modal = UUID()
    registry.upsert(id: bubble, window: window) { closed.append("bubble") }
    registry.upsert(id: modal, window: window) { closed.append("modal") }

    // Suspending and resuming the lower entry does not move it above the modal.
    registry.upsert(id: bubble, window: window, isEnabled: false) { closed.append("bubble") }
    registry.upsert(id: bubble, window: window, isEnabled: true) { closed.append("bubble") }
    #expect(registry.handleEscape(in: window))
    #expect(closed == ["modal"])
    registry.unregister(id: modal)

    // A modal on top takes Escape even while the entry below it is suspended.
    registry.upsert(id: bubble, window: window, isEnabled: false) { closed.append("bubble") }
    registry.upsert(id: modal, window: window) { closed.append("modal 2") }
    #expect(registry.handleEscape(in: window))
    #expect(closed == ["modal", "modal 2"])
    registry.unregister(id: modal)

    // The suspended top entry does not consume Escape and is not dismissed.
    #expect(registry.handleEscape(in: window) == false)
    #expect(closed == ["modal", "modal 2"])
    #expect(registry.hasModal(in: window))

    registry.upsert(id: bubble, window: window, isEnabled: true) { closed.append("bubble") }
    #expect(registry.handleEscape(in: window))
    #expect(closed == ["modal", "modal 2", "bubble"])
  }

}
