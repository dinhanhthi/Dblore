// ProtectionLoweringGateTests.swift
// Weakening the effective Safe Mode, the connection protection level or protected mode needs
// the Safe Mode unlock while the current effective Safe Mode requires a password; strengthening
// never does. Pure decision plus the ViewModel request/apply flow (no Keychain, no LAContext).

import Foundation
import Testing

@testable import Dblore

@Suite("Protection lowering gate")
@MainActor
struct ProtectionLoweringGateTests {
  private func state(
    _ safeMode: SafeMode, _ level: ConnectionProtectionLevel = .none, protectedMode: Bool = true
  ) -> ConnectionSafetyState {
    ConnectionSafetyState(safeMode: safeMode, protectionLevel: level, protectedMode: protectedMode)
  }

  // MARK: - Pure decision

  @Test(
    "Safe Mode strength ordering is explicit: silent < alertRead < alertAll < safeRead < safeAll")
  func safeModeStrength() {
    let ordered: [SafeMode] = [.silent, .alertRead, .alertAll, .safeRead, .safeAll]
    for (lhs, rhs) in zip(ordered, ordered.dropFirst()) {
      #expect(lhs.strength < rhs.strength)
    }
  }

  @Test("safeAll: per-connection silent requires unlock")
  func safeAllToSilentRequiresUnlock() {
    #expect(NotebookViewModel.requiresUnlockForChange(from: state(.safeAll), to: state(.silent)))
    #expect(NotebookViewModel.requiresUnlockForChange(from: state(.safeAll), to: state(.safeRead)))
    #expect(NotebookViewModel.requiresUnlockForChange(from: state(.safeRead), to: state(.alertAll)))
  }

  @Test("safeRead: readOnly -> none or schemaOnly, schemaOnly -> none require unlock")
  func loweringLevelRequiresUnlock() {
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.safeRead, .readOnly), to: state(.safeRead, .none)))
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.safeRead, .readOnly), to: state(.safeRead, .schemaOnly)))
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.safeAll, .schemaOnly), to: state(.safeAll, .none)))
  }

  @Test("safeRead: turning protected mode off requires unlock")
  func protectedModeOffRequiresUnlock() {
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.safeRead, protectedMode: true), to: state(.safeRead, protectedMode: false)))
  }

  @Test("Strengthening never requires unlock")
  func strengtheningIsFree() {
    #expect(!NotebookViewModel.requiresUnlockForChange(from: state(.safeRead), to: state(.safeAll)))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.safeRead, .none), to: state(.safeRead, .readOnly)))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.safeAll, protectedMode: false), to: state(.safeAll, protectedMode: true)))
    #expect(!NotebookViewModel.requiresUnlockForChange(from: state(.safeAll), to: state(.safeAll)))
  }

  @Test("Non-password Safe Modes never require unlock (current behaviour)")
  func nonPasswordModesAreFree() {
    for mode in [SafeMode.silent, .alertRead, .alertAll] {
      #expect(
        !NotebookViewModel.requiresUnlockForChange(
          from: state(mode, .readOnly), to: state(.silent, .none, protectedMode: false)))
    }
  }

  @Test("Effective Safe Mode: per-connection override, else the global mode")
  func effectiveSafeMode() {
    let inherits = ConnectionConfig(protectionLevel: .readOnly, safeMode: nil)
    #expect(ConnectionSafetyState(config: inherits, globalSafeMode: .safeAll).safeMode == .safeAll)
    let overrides = ConnectionConfig(protectionLevel: .readOnly, safeMode: .silent)
    #expect(ConnectionSafetyState(config: overrides, globalSafeMode: .safeAll).safeMode == .silent)
    // "Use Global" from a safeAll override to a silent global is a weakening
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: ConnectionSafetyState(
          config: ConnectionConfig(safeMode: .safeAll), globalSafeMode: .silent),
        to: ConnectionSafetyState(config: ConnectionConfig(safeMode: nil), globalSafeMode: .silent))
    )
  }

  // MARK: - ViewModel request/apply

  private func viewModel(
    level: ConnectionProtectionLevel, safeMode: SafeMode?
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: level, safeMode: safeMode)
    return viewModel
  }

  @Test("Per-connection silent under safeAll is not applied until unlocked")
  func safeModeRequestHeldUntilUnlock() {
    let viewModel = viewModel(level: .none, safeMode: .safeAll)
    #expect(
      viewModel.requestConnectionSafeModeChange(to: .silent, globalSafeMode: .silent) == false)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeAll)
    viewModel.applyConnectionSafeMode(.silent)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .silent)
  }

  @Test("readOnly -> none under safeRead is not applied until unlocked")
  func levelRequestHeldUntilUnlock() {
    let viewModel = viewModel(level: .readOnly, safeMode: .safeRead)
    #expect(viewModel.requestProtectionLevelChange(to: .none, globalSafeMode: .silent) == false)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == .readOnly)
    viewModel.applyProtectionLevel(.none)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
  }

  @Test("Strengthening applies immediately")
  func strengtheningAppliesImmediately() {
    let viewModel = viewModel(level: .schemaOnly, safeMode: .safeRead)
    #expect(viewModel.requestProtectionLevelChange(to: .readOnly, globalSafeMode: .silent))
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == .readOnly)
    #expect(viewModel.requestConnectionSafeModeChange(to: .safeAll, globalSafeMode: .silent))
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeAll)
  }

  @Test("Non-password Safe Mode: lowering applies immediately (current behaviour)")
  func nonPasswordLoweringApplies() {
    let viewModel = viewModel(level: .readOnly, safeMode: .alertAll)
    #expect(viewModel.requestProtectionLevelChange(to: .none, globalSafeMode: .silent))
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
    #expect(viewModel.requestConnectionSafeModeChange(to: nil, globalSafeMode: .silent))
    #expect(viewModel.notebook.connectionConfig?.safeMode == nil)
  }

  @Test("Workspace tab: a lowering held for unlock does not reach the workspace config")
  func workspaceNotUpdatedUntilUnlock() throws {
    let manager = WorkspaceManager(
      workspace: Workspace(
        connectionConfig: ConnectionConfig(protectionLevel: .readOnly, safeMode: .safeRead)),
      restoreTabs: false)
    let viewModel = try #require(manager.viewModel(for: manager.newNotebook()))
    #expect(viewModel.requestProtectionLevelChange(to: .none, globalSafeMode: .silent) == false)
    #expect(manager.workspace.connectionConfig?.protectionLevel == .readOnly)
    viewModel.applyProtectionLevel(.none)
    #expect(manager.workspace.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
  }
}
