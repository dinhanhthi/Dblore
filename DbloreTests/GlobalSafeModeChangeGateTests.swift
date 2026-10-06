// GlobalSafeModeChangeGateTests.swift
// The default commit-style picker uses the same strength rule as a connection: lowering
// from review or password needs the unlock when a password or Touch ID is configured.
// confirm → immediate does not. Strengthening never does. With no unlock configured
// nothing gates, so the user is not locked out.

import Foundation
import Testing

@testable import Dblore

@Suite("Global Safe Mode change gate")
@MainActor
struct GlobalSafeModeChangeGateTests {
  private let styles: [CommitStyle] = [.immediate, .confirm, .review, .password]

  /// Unlock only when some credential exists, the new style is weaker, and the old style
  /// is review or password.
  private func expected(from: CommitStyle, to: CommitStyle, hasUnlock: Bool) -> Bool {
    hasUnlock && to.strength < from.strength && (from == .review || from == .password)
  }

  @Test(
    "Rule table: every (from, to) commit style with and without password and Touch ID",
    arguments: [(false, false), (true, false), (false, true), (true, true)])
  func ruleTable(hasPassword: Bool, hasTouchID: Bool) {
    for from in styles {
      for to in styles {
        let actual = NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
          from: from, to: to, hasPassword: hasPassword, hasTouchID: hasTouchID)
        #expect(
          actual == expected(from: from, to: to, hasUnlock: hasPassword || hasTouchID),
          "\(from) -> \(to), password: \(hasPassword), Touch ID: \(hasTouchID)")
      }
    }
  }

  @Test("password → review with a password, and review → immediate with Touch ID, require unlock")
  func weakeningWithPassword() {
    #expect(
      NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .password, to: .review, hasPassword: true, hasTouchID: false))
    #expect(
      NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .review, to: .immediate, hasPassword: false, hasTouchID: true))
  }

  @Test("confirm → immediate does not require unlock")
  func confirmToImmediateIsFree() {
    #expect(
      !NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .confirm, to: .immediate, hasPassword: true, hasTouchID: true))
  }

  @Test("Raising strength never requires unlock")
  func strengtheningIsFree() {
    #expect(
      !NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .confirm, to: .password, hasPassword: true, hasTouchID: true))
  }

  @Test("No password and no Touch ID: weakening is not gated (no lockout)")
  func noUnlockConfiguredIsNotGated() {
    #expect(
      !NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .password, to: .immediate, hasPassword: false, hasTouchID: false))
  }

  @Test("Same semantics as the per-connection rule when an unlock is configured")
  func matchesPerConnectionRule() {
    for from in styles {
      for to in styles {
        let perConnection = NotebookViewModel.requiresUnlockForChange(
          from: ConnectionSafetyState(commitStyle: from, protectionLevel: .none),
          to: ConnectionSafetyState(commitStyle: to, protectionLevel: .none),
          hasPassword: true, hasTouchID: false)
        #expect(
          NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
            from: from, to: to, hasPassword: true, hasTouchID: false) == perConnection)
      }
    }
  }

  // MARK: - Touch ID needs a password

  @Test("enableBiometricAuth without a Safe Mode password throws passwordRequired")
  func enableBiometricWithoutPasswordThrows() async {
    let settings = AppSettings.shared
    settings.clearSafeModePassword()
    #expect(!settings.hasCustomPasswordSet)
    await #expect(throws: SafeModeBiometricError.passwordRequired) {
      try await settings.enableBiometricAuth()
    }
    #expect(!settings.isBiometricEnabled)
  }
}
