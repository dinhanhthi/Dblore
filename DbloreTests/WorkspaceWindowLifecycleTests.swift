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

  /// A workspace of `windows` whose running-work prompts are counted and answered by `answer`
  private func workspaceWithRunningWork(
    _ windows: WorkspaceWindowManager, answer: @escaping () -> Bool
  ) -> (WorkspaceManager, RunningWorkRegistry) {
    let manager = windows.activeWorkspaceOrNew()
    let registry = RunningWorkRegistry()
    registry.presentPrompt = { _ in answer() }
    manager.runningWork = registry
    return (manager, registry)
  }

  @Test("A close with running work asks once: Cancel keeps the workspace, Stop stops and closes")
  func closeAsksOnceForRunningWork() async {
    let windows = windows(WindowSeams())
    var prompts = 0
    var stops = false
    let (manager, registry) = workspaceWithRunningWork(windows) {
      prompts += 1
      return stops
    }
    var cancels = 0
    // Its cancel never ends it: the import still runs when the close's disconnect comes
    let importRun = registry.begin(
      workspaceID: manager.id, label: "Import into orders", kind: .dataImport
    ) { cancels += 1 }
    registry.stopLimit = .milliseconds(100)

    #expect(await windows.closeWorkspace(id: manager.id) == false)
    #expect(windows.workspaces[manager.id] === manager)
    #expect(prompts == 1)
    #expect(cancels == 0)

    // Connected: the close's disconnect must not ask a second time
    manager.connectionState = .connected
    stops = true
    #expect(await windows.closeWorkspace(id: manager.id))
    #expect(windows.workspaces[manager.id] == nil)
    #expect(prompts == 2)
    #expect(cancels == 1)
    #expect(registry.items.map(\.label) == ["Import into orders"])
    registry.end(importRun)
  }

  @Test("A second close or disconnect while Stop waits asks nothing and closes nothing")
  func secondCloseWhileStopping() async {
    let windows = windows(WindowSeams())
    var prompts = 0
    let (manager, registry) = workspaceWithRunningWork(windows) {
      prompts += 1
      return true
    }
    // A cancel that hangs: the stop waits its whole limit
    let copy = registry.begin(
      workspaceID: manager.id, label: "Copy Objects to shop", kind: .copyObjects
    ) {}
    registry.stopLimit = .milliseconds(500)
    manager.connectionState = .connected

    let first = Task { await windows.closeWorkspace(id: manager.id) }
    for _ in 0..<1000 where !registry.stopsWithoutAsking(workspaceID: manager.id) {
      await Task.yield()
    }
    #expect(registry.stopsWithoutAsking(workspaceID: manager.id))
    #expect(await windows.closeWorkspace(id: manager.id) == false)
    #expect(await manager.disconnect(asksForRunningWork: true) == false)
    #expect(prompts == 1)
    #expect(manager.connectionState == .connected)

    #expect(await first.value)
    #expect(windows.workspaces[manager.id] == nil)
    #expect(prompts == 1)
    registry.end(copy)
  }

  @Test("A query running inside a pending transaction says Stop rolls the transaction back")
  func runningQueryNamesRollback() async throws {
    let windows = windows(WindowSeams())
    var prompts: [RunningWorkRegistry.Prompt] = []
    let manager = windows.activeWorkspaceOrNew()
    let registry = RunningWorkRegistry()
    registry.presentPrompt = { prompt in
      prompts.append(prompt)
      return false
    }
    manager.runningWork = registry
    let tabId = manager.newNotebook()
    manager.viewModels[tabId]?.isEditorQueryRunning = true
    let pending = SQLStatementClassifier.classify(
      "UPDATE t SET v = 1 WHERE id = 1; DELETE FROM t WHERE id = 2"
    ).map { StatementSummary(statement: $0, affectedRows: 1) }
    manager.pendingTransaction = .appTx(pending: pending)
    manager.transactionOriginTabId = tabId

    #expect(await manager.confirmStoppingRunningWork(.close(workspaceID: manager.id)) == false)
    let line = try #require(prompts.last?.lines.first)
    #expect(line.hasPrefix("Query in "))
    #expect(line.hasSuffix(" will be stopped; this will roll back 2 pending changes"))

    // A user BEGIN (Protected off) has no count
    manager.pendingTransaction = .idle
    manager.transactionOriginTabId = nil
    manager.isUserTransactionOpen = true
    #expect(await manager.confirmStoppingRunningWork(.close(workspaceID: manager.id)) == false)
    #expect(
      prompts.last?.lines.first?.hasSuffix(
        " will be stopped; this will roll back the open transaction")
        == true)
    manager.viewModels[tabId]?.isEditorQueryRunning = false
    _ = await windows.closeWorkspace(id: manager.id, force: true)
  }

  @Test("Disconnect asks about running work only for the user's own Disconnect")
  func disconnectAsksOnlyWhenAsked() async {
    let windows = windows(WindowSeams())
    var prompts = 0
    let (manager, registry) = workspaceWithRunningWork(windows) {
      prompts += 1
      return false
    }
    registry.begin(workspaceID: manager.id, label: "Copy Objects to shop", kind: .copyObjects) {}

    manager.connectionState = .connected
    #expect(await manager.disconnect(asksForRunningWork: true) == false)
    #expect(manager.connectionState == .connected)
    #expect(prompts == 1)

    // Internal callers (a close, a connection switch) never ask
    #expect(await manager.disconnect())
    #expect(manager.connectionState == .disconnected)
    #expect(prompts == 1)
    _ = await windows.closeWorkspace(id: manager.id, force: true)
  }
}
