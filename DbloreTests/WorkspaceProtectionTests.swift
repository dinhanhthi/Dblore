// WorkspaceProtectionTests.swift
// Workspace tabs use the workspace connection's protection level and Safe Mode, and the
// actor never weakens the caller's policy (stricter merge with the connected config).

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace Protection Source Tests")
@MainActor
struct WorkspaceProtectionTests {
  private func makeWorkspace(
    protectionLevel: ConnectionProtectionLevel = .none, safeMode: SafeMode? = nil
  ) -> WorkspaceManager {
    let config = ConnectionConfig(protectionLevel: protectionLevel, safeMode: safeMode)
    return WorkspaceManager(workspace: Workspace(connectionConfig: config), restoreTabs: false)
  }

  private func tabViewModel(_ manager: WorkspaceManager, content: String) -> NotebookViewModel? {
    let tabId = manager.newNotebook()
    guard let viewModel = manager.viewModel(for: tabId) else { return nil }
    viewModel.notebook.cells = [NotebookCell(cellType: .sql, content: content)]
    return viewModel
  }

  // MARK: - Stricter merge (pure)

  @Test("Stricter merge takes the higher protection level, either order")
  func stricterMergeLevels() {
    let levels: [ConnectionProtectionLevel] = [.none, .schemaOnly, .readOnly]
    for (i, lhs) in levels.enumerated() {
      for (j, rhs) in levels.enumerated() {
        let merged = ProtectionPolicy(protectionLevel: lhs)
          .stricter(ProtectionPolicy(protectionLevel: rhs))
        #expect(merged.protectionLevel == levels[max(i, j)])
      }
    }
  }

  @Test("Stricter merge ORs protected mode and keeps the caller's Safe Mode")
  func stricterMergeFlags() {
    let caller = ProtectionPolicy(protectionLevel: .none, safeMode: .silent)
    let connected = ProtectionPolicy(
      protectionLevel: .readOnly, safeMode: .safeAll, protectedMode: true)
    let merged = caller.stricter(connected)
    #expect(merged.protectionLevel == .readOnly)
    #expect(merged.protectedMode)
    #expect(merged.safeMode == .silent)
  }

  @Test("Actor gate blocks DELETE under a .readOnly connected config even with a .none caller")
  func actorMergeBlocks() {
    let decision = DatabaseConnectionManager.evaluate(
      SQLStatementClassifier.classify("DELETE FROM users WHERE id = 1"),
      policy: ProtectionPolicy(protectionLevel: .none)
        .stricter(ProtectionPolicy(config: ConnectionConfig(protectionLevel: .readOnly))))
    guard case .blocked = decision else {
      Issue.record("expected blocked, got \(decision)")
      return
    }
  }

  // MARK: - Workspace tabs

  @Test("Workspace tab on a .readOnly workspace connection blocks DELETE (nothing sent)")
  func workspaceTabReadOnlyBlocksDelete() throws {
    let manager = makeWorkspace(protectionLevel: .readOnly)
    let viewModel = try #require(tabViewModel(manager, content: "DELETE FROM users WHERE id = 1"))
    let cellId = viewModel.notebook.cells[0].id

    #expect(viewModel.protectionPolicy.protectionLevel == .readOnly)
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.notebook.cells[0].isRunning == false)
    #expect(viewModel.notebook.cells[0].executionCount == nil)
  }

  @Test("Existing tabs pick up the workspace config on sync")
  func existingTabsSyncWorkspaceConfig() throws {
    let manager = makeWorkspace(protectionLevel: .none)
    let viewModel = try #require(tabViewModel(manager, content: "SELECT 1"))
    #expect(viewModel.protectionPolicy.protectionLevel == .none)

    manager.workspace.connectionConfig?.protectionLevel = .schemaOnly
    manager.syncConnectionStateToTabs()
    #expect(viewModel.protectionPolicy.protectionLevel == .schemaOnly)
  }

  @Test("Runtime protection change in one tab reaches the workspace and the other tabs")
  func runtimeChangePropagates() throws {
    let manager = makeWorkspace(protectionLevel: .none)
    let first = try #require(tabViewModel(manager, content: "SELECT 1"))
    let second = try #require(tabViewModel(manager, content: "DELETE FROM users WHERE id = 1"))

    // What the footer/sidebar protection dialogs do
    first.notebook.connectionConfig?.protectionLevel = .readOnly

    #expect(manager.workspace.connectionConfig?.protectionLevel == .readOnly)
    #expect(second.protectionPolicy.protectionLevel == .readOnly)
    WorkspaceWindowManager.shared.dismissToast()
    second.confirmAndRunCell(id: second.notebook.cells[0].id)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(second.notebook.cells[0].isRunning == false)
  }

  @Test("Workspace commit style applies in a tab")
  func workspaceSafeModeApplies() throws {
    var config = ConnectionConfig(protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.applyCommitStyle(.confirm)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    let viewModel = try #require(
      tabViewModel(manager, content: "DELETE FROM users WHERE id = 1"))

    viewModel.confirmAndRunCell(id: viewModel.notebook.cells[0].id)

    #expect(viewModel.queryConfirmationState.showDialog)
    viewModel.cancelPendingQuery()
  }
}
