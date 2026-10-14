// NativeWindowTabsTests.swift
// Native window tabs are opt-in: a new window joins the key window only for document windows.

import AppKit
import Testing

@testable import Dblore

@Suite("Native Window Tabs")
@MainActor
struct NativeWindowTabsTests {
  private func makeWindow(styleMask: NSWindow.StyleMask) -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: styleMask, backing: .buffered, defer: true)
  }

  @Test("Setting on with a document window: that window")
  func documentWindowIsParent() {
    let window = makeWindow(styleMask: [.titled, .closable, .resizable])
    #expect(NewWindowStore.tabParent(openAsTab: true, keyWindow: window) === window)
  }

  // Miniaturized and background-tab windows count as open too, but both need the window server:
  // addTabbedWindow stalls the main actor for ~25s in the test host, so they are not tested here.
}
