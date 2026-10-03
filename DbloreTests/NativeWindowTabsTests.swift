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

  @Test("Setting off: no parent")
  func offReturnsNil() {
    let window = makeWindow(styleMask: [.titled, .resizable])
    #expect(NewWindowStore.tabParent(openAsTab: false, keyWindow: window) == nil)
  }

  @Test("Setting on without a key window: no parent")
  func noKeyWindowReturnsNil() {
    #expect(NewWindowStore.tabParent(openAsTab: true, keyWindow: nil) == nil)
  }

  @Test("Setting on with a non-resizable panel: no parent")
  func panelReturnsNil() {
    let panel = makeWindow(styleMask: [.titled, .closable])
    #expect(NewWindowStore.tabParent(openAsTab: true, keyWindow: panel) == nil)
  }

  @Test("Setting on with a document window: that window")
  func documentWindowIsParent() {
    let window = makeWindow(styleMask: [.titled, .closable, .resizable])
    #expect(NewWindowStore.tabParent(openAsTab: true, keyWindow: window) === window)
  }

  @Test("Reopen check: the closed window is excluded")
  func closedWindowExcluded() {
    let closed = makeWindow(styleMask: [.titled, .closable, .resizable])
    closed.orderFront(nil)
    defer { closed.orderOut(nil) }
    #expect(!NSWindow.hasOtherOpenDocumentWindow(in: [closed], excluding: closed))
  }

  @Test("Reopen check: another visible document window counts")
  func visibleWindowCounts() {
    let closed = makeWindow(styleMask: [.titled, .closable, .resizable])
    let other = makeWindow(styleMask: [.titled, .closable, .resizable])
    other.orderFront(nil)
    defer { other.orderOut(nil) }
    #expect(NSWindow.hasOtherOpenDocumentWindow(in: [closed, other], excluding: closed))
  }

  // Miniaturized and background-tab windows count as open too, but both need the window server:
  // addTabbedWindow stalls the main actor for ~25s in the test host, so they are not tested here.
}
