// ProtectionLoweringGateTests.swift
// Unlock follows commit-style strength: immediate < confirm < review < password.
// A Safe Mode password or Touch ID is required. Lowering from review or password needs
// the unlock; confirm → immediate does not. Lowering the protection level needs it only
// while the current style is password. The unlock check does not project legacy fields.

import Foundation
import Testing

@testable import Dblore

@Suite("Protection lowering gate")
@MainActor
struct ProtectionLoweringGateTests {
  private func state(
    _ style: CommitStyle, _ level: ConnectionProtectionLevel = .none
  ) -> ConnectionSafetyState {
    ConnectionSafetyState(commitStyle: style, protectionLevel: level)
  }

  private func needsUnlock(
    from old: CommitStyle, to new: CommitStyle,
    hasPassword: Bool = true, hasTouchID: Bool = false
  ) -> Bool {
    NotebookViewModel.requiresUnlockForChange(
      from: state(old), to: state(new), hasPassword: hasPassword, hasTouchID: hasTouchID)
  }

  // MARK: - Pure decision

  @Test("password → review, review → confirm, and review → immediate require unlock")
  func loweringReviewOrPasswordRequiresUnlock() {
    #expect(needsUnlock(from: .password, to: .review))
    #expect(needsUnlock(from: .review, to: .confirm, hasPassword: false, hasTouchID: true))
    #expect(needsUnlock(from: .review, to: .immediate))
  }

  @Test("confirm → immediate does not require unlock")
  func confirmToImmediateIsFree() {
    #expect(!needsUnlock(from: .confirm, to: .immediate))
  }

  @Test("Raising strength does not require unlock")
  func strengtheningIsFree() {
    #expect(!needsUnlock(from: .immediate, to: .password))
    #expect(!needsUnlock(from: .confirm, to: .review))
    #expect(!needsUnlock(from: .review, to: .password))
    #expect(!needsUnlock(from: .password, to: .password))
  }

  @Test("No password and no Touch ID: lowering is not gated")
  func noUnlockConfiguredIsNotGated() {
    #expect(
      !needsUnlock(from: .password, to: .immediate, hasPassword: false, hasTouchID: false))
    #expect(!needsUnlock(from: .review, to: .confirm, hasPassword: false, hasTouchID: false))
  }

  @Test("Lowering protection level requires unlock only when the current style is password")
  func loweringLevelOnlyUnderPassword() {
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.password, .readOnly), to: state(.password, .none),
        hasPassword: true, hasTouchID: false))
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.password, .readOnly), to: state(.password, .schemaOnly),
        hasPassword: false, hasTouchID: true))
    #expect(
      NotebookViewModel.requiresUnlockForChange(
        from: state(.password, .schemaOnly), to: state(.password, .none),
        hasPassword: true, hasTouchID: false))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.review, .readOnly), to: state(.review, .none),
        hasPassword: true, hasTouchID: true))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.confirm, .readOnly), to: state(.confirm, .none),
        hasPassword: true, hasTouchID: false))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.password, .readOnly), to: state(.password, .none),
        hasPassword: false, hasTouchID: false))
    #expect(
      !NotebookViewModel.requiresUnlockForChange(
        from: state(.password, .none), to: state(.password, .readOnly),
        hasPassword: true, hasTouchID: false))
  }

  @Test("Legacy unprotected nil safe mode uses the default commit style")
  func defaultCommitStyleFallback() {
    let inherits = ConnectionConfig(protectionLevel: .readOnly, safeMode: nil, protectedMode: false)
    #expect(
      ConnectionSafetyState(config: inherits, defaultCommitStyle: .password).commitStyle
        == .password)
    let protected = ConnectionConfig(protectionLevel: .readOnly, safeMode: nil, protectedMode: true)
    #expect(
      ConnectionSafetyState(config: protected, defaultCommitStyle: .password).commitStyle
        == .review)
    var explicit = ConnectionConfig(protectedMode: false)
    explicit.applyCommitStyle(.immediate)
    #expect(
      ConnectionSafetyState(config: explicit, defaultCommitStyle: .password).commitStyle
        == .immediate)
  }

  // MARK: - ViewModel request/apply

  private func viewModel(
    style: CommitStyle, level: ConnectionProtectionLevel = .none
  ) -> NotebookViewModel {
    var config = ConnectionConfig(protectionLevel: level)
    config.applyCommitStyle(style)
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config
    return viewModel
  }

  private func armUnlock() {
    AppSettings.shared.setSafeModePassword("gate")
  }

  @Test("Chosen weaker commit style is not applied until unlock, then only via applyCommitStyle")
  func commitStyleHeldUntilUnlock() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = viewModel(style: .password, level: .readOnly)
    #expect(viewModel.requestConnectionCommitStyle(.review) == false)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .password)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == false)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeRead)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == .readOnly)

    viewModel.applyConnectionCommitStyle(.review)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .review)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == true)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .silent)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == .readOnly)
  }

  @Test("Legacy protected connection stays unchanged until the chosen weaker style is unlocked")
  func legacyProtectedHeldUntilUnlock() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: .none, safeMode: .safeAll, protectedMode: true)
    #expect(viewModel.requestConnectionCommitStyle(.immediate) == false)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == true)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeAll)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == nil)

    viewModel.applyConnectionCommitStyle(.immediate)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .immediate)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == false)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .silent)
  }

  @Test("confirm → immediate applies immediately through applyCommitStyle")
  func confirmToImmediateApplies() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = viewModel(style: .confirm)
    #expect(viewModel.requestConnectionCommitStyle(.immediate))
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .immediate)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == false)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .silent)
  }

  @Test("Raising the commit style applies immediately")
  func strengtheningStyleAppliesImmediately() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = viewModel(style: .confirm)
    #expect(viewModel.requestConnectionCommitStyle(.password))
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .password)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeRead)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == false)
  }

  @Test("readOnly → none under password is not applied until unlocked, and writes only the level")
  func levelRequestHeldUntilUnlock() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = viewModel(style: .password, level: .readOnly)
    #expect(viewModel.requestProtectionLevelChange(to: .none) == false)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == .readOnly)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .password)
    viewModel.applyProtectionLevel(.none)
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .password)
    #expect(viewModel.notebook.connectionConfig?.safeMode == .safeRead)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == false)
  }

  @Test("Non-password styles apply a protection-level change immediately")
  func nonPasswordLevelAppliesImmediately() {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    let viewModel = viewModel(style: .review, level: .readOnly)
    #expect(viewModel.requestProtectionLevelChange(to: .none))
    #expect(viewModel.notebook.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
    #expect(viewModel.notebook.connectionConfig?.commitStyle == .review)
    #expect(viewModel.notebook.connectionConfig?.protectedMode == true)
  }

  @Test("Workspace tab: a protection lowering under password does not reach the workspace until unlock")
  func workspaceNotUpdatedUntilUnlock() throws {
    armUnlock()
    defer { AppSettings.shared.clearSafeModePassword() }
    var config = ConnectionConfig(protectionLevel: .readOnly)
    config.applyCommitStyle(.password)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    let viewModel = try #require(manager.viewModel(for: manager.newNotebook()))
    #expect(viewModel.requestProtectionLevelChange(to: .none) == false)
    #expect(manager.workspace.connectionConfig?.protectionLevel == .readOnly)
    #expect(manager.workspace.connectionConfig?.commitStyle == .password)
    viewModel.applyProtectionLevel(.none)
    #expect(manager.workspace.connectionConfig?.protectionLevel == ConnectionProtectionLevel.none)
    #expect(manager.workspace.connectionConfig?.commitStyle == .password)
  }
}
