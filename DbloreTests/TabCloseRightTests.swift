// TabCloseRightTests.swift
// "Close to the right": clean tabs close at once, dirty ones prompt one at a time, Cancel or a
// failed save stops the rest, pinned tabs and tabs left of the target stay.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Close tabs to the right")
@MainActor
struct TabCloseRightTests {
  /// Tabs t0...; `dirty` lists the indices of dirty tabs
  private static func manager(tabCount: Int, dirty: Set<Int> = []) -> WorkspaceManager {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    for index in 0..<tabCount {
      manager.tabs.append(
        TabItem(documentType: .sqlFile, title: "t\(index)", isDirty: dirty.contains(index)))
    }
    return manager
  }

  /// Let the queued drain task (which itself yields once) run
  private static func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  private static func titles(_ manager: WorkspaceManager) -> [String] { manager.tabs.map(\.title) }

  @Test("tabsToCloseRight lists only unpinned tabs after the target")
  func rangeSkipsPinned() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[3].id)  // t3, t0, t1, t2
    let target = manager.tabs[1].id  // t0
    #expect(manager.tabsToCloseRight(of: target) == manager.tabs[2...].map(\.id))
    #expect(manager.tabsToCloseRight(of: manager.tabs[3].id).isEmpty)
    #expect(manager.tabsToCloseRight(of: UUID()).isEmpty)
  }

  @Test("Clean tabs to the right close immediately")
  func cleanClose() {
    let manager = Self.manager(tabCount: 4)
    manager.closeTabsToTheRight(of: manager.tabs[1].id)
    #expect(Self.titles(manager) == ["t0", "t1"])
    #expect(manager.tabToClose == nil)
  }

  @Test("No-op when the target is the last tab")
  func lastIsNoOp() {
    let manager = Self.manager(tabCount: 3)
    manager.closeTabsToTheRight(of: manager.tabs[2].id)
    #expect(Self.titles(manager) == ["t0", "t1", "t2"])
  }

  @Test("Pinned tabs are untouched")
  func pinnedKept() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[3].id)  // t3, t0, t1, t2
    manager.closeTabsToTheRight(of: manager.tabs[1].id)
    #expect(Self.titles(manager) == ["t3", "t0"])
  }

  @Test("Dirty tabs prompt one at a time and the queue continues after each answer")
  func dirtySequenced() async {
    let manager = Self.manager(tabCount: 5, dirty: [2, 4])
    let ids = manager.tabs.map(\.id)
    manager.closeTabsToTheRight(of: ids[0])
    // t1 closed, t2 prompts, t3 and t4 wait
    #expect(Self.titles(manager) == ["t0", "t2", "t3", "t4"])
    #expect(manager.tabToClose == ids[2])
    #expect(manager.showingCloseConfirmation)

    manager.closeTabWithoutSaving()
    #expect(manager.tabToClose == nil)  // the next prompt waits until the dialog has closed
    await Self.settle()
    #expect(Self.titles(manager) == ["t0", "t4"])
    #expect(manager.tabToClose == ids[4])
    #expect(manager.showingCloseConfirmation)

    manager.closeTabWithoutSaving()
    #expect(Self.titles(manager) == ["t0"])
    #expect(manager.tabToClose == nil)
    #expect(!manager.showingCloseConfirmation)
  }

  @Test("Cancel stops the remaining tabs")
  func cancelStops() async {
    let manager = Self.manager(tabCount: 5, dirty: [1, 3])
    manager.closeTabsToTheRight(of: manager.tabs[0].id)
    #expect(manager.tabToClose == manager.tabs[1].id)
    manager.cancelClose()
    #expect(Self.titles(manager) == ["t0", "t1", "t2", "t3", "t4"])
    manager.closeTabWithoutSaving()  // nothing pending: queue must be gone
    await Self.settle()
    #expect(manager.tabToClose == nil)
    #expect(manager.tabs.count == 5)
  }

  // With a key window (CI test host) the save panel opens as a sheet nobody answers, so this
  // only runs where the panel fails fast for lack of a window.
  @Test(
    "A failed save acts like Cancel and clears the queue",
    .enabled(if: NSApp?.keyWindow == nil))
  func failedSaveStops() async {
    let manager = Self.manager(tabCount: 4, dirty: [1])
    manager.closeTabsToTheRight(of: manager.tabs[0].id)
    #expect(manager.tabToClose == manager.tabs[1].id)
    await manager.saveAndCloseTab()  // untitled tab, no window: the save panel cannot run
    #expect(Self.titles(manager) == ["t0", "t1", "t2", "t3"])
    #expect(manager.tabToClose == nil)
  }

  @Test("A tab holding a pending transaction is skipped and stays open")
  func pendingTransactionTabSkipped() {
    let manager = Self.manager(tabCount: 5)
    let ids = manager.tabs.map(\.id)
    manager.pendingTransaction = .aborted(reason: "x", pending: [])
    manager.transactionOriginTabId = ids[2]
    manager.closeTabsToTheRight(of: ids[0])
    #expect(Self.titles(manager) == ["t0", "t2"])
    #expect(manager.tabToClose == nil)
  }
}
