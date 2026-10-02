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

  @Test("Pinning moves the tab to the end of the pinned zone")
  func pinMovesToPinnedEnd() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[2].id)
    manager.setPinned(true, id: manager.tabs[3].id)
    #expect(Self.titles(manager) == ["t2", "t3", "t0", "t1"])
    #expect(manager.pinnedCount == 2)
  }

  @Test("Unpinning moves the tab to the first slot after the pinned zone")
  func unpinMovesAfterZone() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[2].id)
    manager.setPinned(true, id: manager.tabs[3].id)  // t2, t3, t0, t1
    manager.setPinned(false, id: manager.tabs[0].id)
    #expect(Self.titles(manager) == ["t3", "t2", "t0", "t1"])
    #expect(manager.pinnedCount == 1)
  }

  @Test("moveTab cannot cross the pinned boundary")
  func moveClamped() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[0].id)
    manager.setPinned(true, id: manager.tabs[1].id)  // t0, t1 pinned; t2, t3
    manager.moveTab(from: 0, to: 3)
    #expect(Self.titles(manager) == ["t1", "t0", "t2", "t3"])
    manager.moveTab(from: 3, to: 0)
    #expect(Self.titles(manager) == ["t1", "t0", "t3", "t2"])
  }

  @Test("clampedMoveTarget keeps the visual drag target inside its zone")
  func clampedTargetStaysInZone() {
    let manager = Self.manager(tabCount: 4)
    manager.setPinned(true, id: manager.tabs[0].id)
    manager.setPinned(true, id: manager.tabs[1].id)
    #expect(manager.clampedMoveTarget(from: 0, to: 3) == 1)
    #expect(manager.clampedMoveTarget(from: 3, to: 0) == 2)
    #expect(manager.clampedMoveTarget(from: 2, to: 3) == 3)
    #expect(manager.clampedMoveTarget(from: 1, to: 0) == 0)
  }

  @Test("requestCloseTab is a no-op for a pinned tab")
  func pinnedCannotClose() {
    let manager = Self.manager(tabCount: 2)
    let id = manager.tabs[0].id
    manager.setPinned(true, id: id)
    #expect(!manager.canClose(tabId: id))
    manager.requestCloseTab(id: id)
    #expect(manager.tabs.count == 2)
  }

  @Test("Pinning a preview tab clears isPreview so the next preview keeps it")
  func pinPreviewSurvivesNextPreview() {
    let manager = Self.manager(tabCount: 0)
    manager.openDataViewer(schema: "public", name: "a", orderColumns: [])
    let id = manager.tabs[0].id
    manager.setPinned(true, id: id)
    #expect(manager.tabs[0].isPinned)
    #expect(!manager.tabs[0].isPreview)
    manager.openDataViewer(schema: "public", name: "b", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.tabs[0].id == id)
  }

  @Test("Only file-backed tabs can be revealed, and reveal passes their URL")
  func revealFileOnlyForFileTabs() {
    let manager = Self.manager(tabCount: 0)
    var revealed: [URL] = []
    manager.revealInFinder = { revealed.append($0) }
    let url = URL(fileURLWithPath: "/tmp/a.sql")
    let file = TabItem(fileURL: url, documentType: .sqlFile, title: "a", isDirty: false)
    let untitled = TabItem(documentType: .notebook, title: "u", isDirty: false)
    let viewer = TabItem(documentType: .dataViewer, title: "v", isDirty: false)
    manager.tabs = [file, untitled, viewer]

    #expect(manager.canRevealFile(tabId: file.id))
    #expect(!manager.canRevealFile(tabId: untitled.id))
    #expect(!manager.canRevealFile(tabId: viewer.id))

    manager.revealFile(tabId: untitled.id)
    manager.revealFile(tabId: viewer.id)
    #expect(revealed.isEmpty)
    manager.revealFile(tabId: file.id)
    #expect(revealed == [url])
  }
}
