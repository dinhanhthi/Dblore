// WorkspaceManagerSidebarTests.swift
// Toggling the left sidebar updates the manager state and the workspace settings it saves.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("WorkspaceManager left sidebar")
@MainActor
struct WorkspaceManagerSidebarTests {
  @Test("toggleLeftSidebar flips the visibility and the workspace setting")
  func toggleFlipsVisibility() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let initial = manager.isLeftSidebarVisible

    manager.toggleLeftSidebar()
    #expect(manager.isLeftSidebarVisible == !initial)
    #expect(manager.workspace.settings.isLeftSidebarVisible == !initial)

    manager.toggleLeftSidebar()
    #expect(manager.isLeftSidebarVisible == initial)
    #expect(manager.workspace.settings.isLeftSidebarVisible == initial)
  }
}
