// WorkspaceWindowLifecycleTests.swift
// Workspace windows: the close button, what a window does once its workspace is gone, and
// which window shows a workspace the menus, Finder, Shortcuts and Settings open.

import AppKit
import Testing

@testable import Dblore

@Suite("Workspace Window Lifecycle")
@MainActor
struct WorkspaceWindowLifecycleTests {
  @Test("Close guard gives the close button back its own target and action")
  func closeGuardRestoresOriginalAction() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    let button = try #require(window.standardWindowButton(.closeButton))
    let originalTarget = button.target
    let originalAction = button.action

    let guardView = WorkspaceWindowCloseGuard.GuardView()
    window.contentView?.addSubview(guardView)
    #expect(button.target === guardView)

    guardView.removeFromSuperview()
    #expect(button.target === originalTarget)
    #expect(button.action == originalAction)
    // `performClose` clicks the close button: as its action, every click recursed until a crash
    #expect(button.action != #selector(NSWindow.performClose(_:)))
  }

  /// A manager whose window seams record what `showPendingWorkspace` asks for
  private final class WindowSeams {
    var existing: NSWindow?
    var hasWelcomeHandler = false
    var opened: [UUID] = []
  }

  private func windows(_ seams: WindowSeams) -> WorkspaceWindowManager {
    let windows = WorkspaceWindowManager()
    windows.findWorkspaceWindow = { _ in seams.existing }
    windows.hasWelcomeHandler = { seams.hasWelcomeHandler }
    windows.openWorkspaceWindow = { seams.opened.append($0) }
    return windows
  }

  @Test("No Welcome window takes the id: a workspace window opens at once")
  func showPendingWorkspaceOpensWindowWithoutHandler() {
    let seams = WindowSeams()
    let windows = windows(seams)
    let id = UUID()

    windows.showPendingWorkspace(id)

    #expect(seams.opened == [id])
    // Left set, no window would ever read it
    #expect(windows.pendingWorkspaceId == nil)
  }

  @Test("New commands with no workspace create one and show it; with one, nothing new opens")
  func activeWorkspaceOrNewShowsCreatedWorkspace() {
    let seams = WindowSeams()
    let windows = windows(seams)

    let created = windows.activeWorkspaceOrNew()

    #expect(windows.workspaces[created.id] === created)
    #expect(seams.opened == [created.id])

    let again = windows.activeWorkspaceOrNew()

    #expect(again === created)
    #expect(windows.workspaces.count == 1)
    #expect(seams.opened == [created.id])
  }

  @Test("A Welcome window takes the id; still pending later, a window opens")
  func showPendingWorkspaceHandsIdToWelcome() async {
    let seams = WindowSeams()
    seams.hasWelcomeHandler = true
    let windows = windows(seams)
    let id = UUID()

    windows.showPendingWorkspace(id)

    #expect(windows.pendingWorkspaceId == id)
    #expect(seams.opened.isEmpty)
    // Safety net: nothing took it
    for _ in 0..<40 where seams.opened.isEmpty {
      try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(seams.opened == [id])
    #expect(windows.pendingWorkspaceId == nil)
  }

  @Test("A workspace already in a window: that window comes to the front, no second one opens")
  func showPendingWorkspaceFocusesExistingWindow() {
    func makeWindow() -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.orderFront(nil)
      return window
    }
    let existing = makeWindow()
    let other = makeWindow()
    defer {
      existing.orderOut(nil)
      other.orderOut(nil)
    }
    let seams = WindowSeams()
    seams.existing = existing
    seams.hasWelcomeHandler = true
    let windows = windows(seams)

    windows.showPendingWorkspace(UUID())

    let order = NSApp.orderedWindows
    #expect(
      (order.firstIndex(of: existing) ?? .max) < (order.firstIndex(of: other) ?? .max))
    #expect(seams.opened.isEmpty)
    #expect(windows.pendingWorkspaceId == nil)
  }

  @Test("A window closing with its workspace is not reused: a new window opens")
  func showPendingWorkspaceSkipsClosingWindow() {
    let closing = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    closing.isReleasedWhenClosed = false
    closing.orderFront(nil)
    NewWindowStore.shared.markClosing(closing)
    defer {
      NewWindowStore.shared.unmarkClosing(closing)
      closing.orderOut(nil)
    }
    let seams = WindowSeams()
    seams.existing = closing
    let windows = windows(seams)
    let id = UUID()

    windows.showPendingWorkspace(id)

    // Focusing it would leave the workspace with no window once it closes
    #expect(seams.opened == [id])
  }
}
