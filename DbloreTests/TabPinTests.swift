// TabPinTests.swift
// Pinned tabs form a leading zone: pinning moves a tab to its end, unpinning to the slot after
// it, moves cannot cross the boundary, and pinned tabs cannot be closed.

import Foundation
import Testing

@testable import Dblore

@Suite("Tab pinning")
@MainActor
struct TabPinTests {
  private static func manager(tabCount: Int) -> WorkspaceManager {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    for index in 0..<tabCount {
      manager.tabs.append(TabItem(documentType: .sqlFile, title: "t\(index)", isDirty: false))
    }
    return manager
  }

  private static func titles(_ manager: WorkspaceManager) -> [String] { manager.tabs.map(\.title) }

  @Test("requestCloseTab is a no-op for a pinned tab")
  func pinnedCannotClose() {
    let manager = Self.manager(tabCount: 2)
    let id = manager.tabs[0].id
    manager.setPinned(true, id: id)
    #expect(!manager.canClose(tabId: id))
    manager.requestCloseTab(id: id)
    #expect(manager.tabs.count == 2)
  }

}
