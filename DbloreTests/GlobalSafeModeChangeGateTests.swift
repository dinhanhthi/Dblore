// GlobalSafeModeChangeGateTests.swift
// The global Safe Mode picker (SafeModeModal, Settings > Security) uses the per-connection
// rule: weakening away from a password Safe Mode needs the unlock, strengthening never does.
// Without any unlock (no password, no Touch ID) nothing gates, so the user is not locked out.
// Touch ID can only be enabled once a Safe Mode password exists.

import Foundation
import Testing

@testable import Dblore

@Suite("Global Safe Mode change gate")
@MainActor
struct GlobalSafeModeChangeGateTests {
  private let modes: [SafeMode] = [.silent, .alertRead, .alertAll, .safeRead, .safeAll]

  /// Expected: from a password mode to a weaker mode, with some unlock configured
  private func expected(from: SafeMode, to: SafeMode, hasUnlock: Bool) -> Bool {
    hasUnlock && from.requiresPassword && to.strength < from.strength
  }

  @Test(
    "Rule table: every (from, to) pair with and without password and Touch ID",
    arguments: [(false, false), (true, false), (false, true), (true, true)])
  func ruleTable(hasPassword: Bool, hasTouchID: Bool) {
    for from in modes {
      for to in modes {
        let actual = NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
          from: from, to: to, hasPassword: hasPassword, hasTouchID: hasTouchID)
        #expect(
          actual == expected(from: from, to: to, hasUnlock: hasPassword || hasTouchID),
          "\(from) -> \(to), password: \(hasPassword), Touch ID: \(hasTouchID)")
      }
    }
  }

  @Test("safeAll -> silent with a password requires unlock")
  func weakeningWithPassword() {
    #expect(
      NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .safeAll, to: .silent, hasPassword: true, hasTouchID: false))
    #expect(
      NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .safeRead, to: .alertAll, hasPassword: false, hasTouchID: true))
  }

  @Test("safeRead -> safeAll (strengthening) never requires unlock")
  func strengtheningIsFree() {
    #expect(
      !NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .safeRead, to: .safeAll, hasPassword: true, hasTouchID: true))
  }

  @Test("No password and no Touch ID: weakening is not gated (no lockout)")
  func noUnlockConfiguredIsNotGated() {
    #expect(
      !NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
        from: .safeAll, to: .silent, hasPassword: false, hasTouchID: false))
  }

  @Test("Same semantics as the per-connection rule when an unlock is configured")
  func matchesPerConnectionRule() {
    for from in modes {
      for to in modes {
        let perConnection = NotebookViewModel.requiresUnlockForChange(
          from: ConnectionSafetyState(safeMode: from, protectionLevel: .none, protectedMode: false),
          to: ConnectionSafetyState(safeMode: to, protectionLevel: .none, protectedMode: false))
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
