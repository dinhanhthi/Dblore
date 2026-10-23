// FocusedActionRegistryTests.swift
// Menu commands read the values the key window publishes, also in AppKit-hosted workspace
// windows that SwiftUI's focused scene values do not reach.

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("Focused Action Registry")
@MainActor
struct FocusedActionRegistryTests {
  /// Stands in for a publishing view: its identity is the owner of a value
  private final class Publisher {
    var owner: ObjectIdentifier { ObjectIdentifier(self) }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  @Test("Returns the key window's values and never another window's")
  func keyWindowLookup() {
    let first = makeWindow()
    let second = makeWindow()
    var keyWindow: NSWindow? = first
    let registry = FocusedActionRegistry(keyWindow: { keyWindow })
    let publisherA = Publisher()
    let publisherB = Publisher()
    var imported: String?
    registry.publish(DocumentMode.editor, for: \.documentMode, owner: publisherA.owner, in: first)
    registry.publish(
      { imported = "first" }, for: \.openTableImportAction, owner: publisherA.owner, in: first)
    registry.publish(
      DocumentMode.notebook, for: \.documentMode, owner: publisherB.owner, in: second)

    #expect(registry.value(for: \.documentMode) == .editor)
    registry.value(for: \.openTableImportAction)?()
    #expect(imported == "first")

    keyWindow = second
    #expect(registry.value(for: \.documentMode) == .notebook)
    #expect(registry.value(for: \.openTableImportAction) == nil)

    keyWindow = makeWindow()
    #expect(registry.value(for: \.documentMode) == nil)
    keyWindow = nil
    #expect(registry.value(for: \.documentMode) == nil)
  }

  @Test("The innermost publisher wins; withdrawing it falls back to the outer one")
  func nestedPublishers() {
    let window = makeWindow()
    let registry = FocusedActionRegistry(keyWindow: { window })
    let outer = Publisher()
    let inner = Publisher()
    registry.publish(
      DocumentMode.markdown, for: \.documentMode, owner: inner.owner, depth: 1, in: window)
    registry.publish(
      DocumentMode.editor, for: \.documentMode, owner: outer.owner, depth: 0, in: window)
    #expect(registry.value(for: \.documentMode) == .markdown)

    registry.withdraw(owner: inner.owner)
    #expect(registry.value(for: \.documentMode) == .editor)
  }

  @Test("Closing a window drops its values")
  func closedWindowCleared() {
    let window = makeWindow()
    let registry = FocusedActionRegistry(keyWindow: { window })
    let publisher = Publisher()
    registry.publish(DocumentMode.editor, for: \.documentMode, owner: publisher.owner, in: window)
    #expect(registry.value(for: \.documentMode) == .editor)

    window.close()
    #expect(registry.value(for: \.documentMode) == nil)
  }
}
