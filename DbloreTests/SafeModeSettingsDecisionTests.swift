// SafeModeSettingsDecisionTests.swift
// Settings > Safe Mode sheets ("Change Password" and "Authentication Required"): the database
// password fallback goes through `acceptsDatabasePasswordFallback`, so it never works while a
// Safe Mode password exists, never with an empty password, and its affordance is hidden then.

import Foundation
import Testing

@testable import Dblore

@Suite("Safe Mode Settings Decision Tests")
struct SafeModeSettingsDecisionTests {
  private func accepts(
    _ entry: String, usingDatabasePassword: Bool, stored: String?, hasSafeModePassword: Bool,
    safeModePasswordMatches: Bool = false
  ) -> Bool {
    NotebookViewModel.settingsAcceptsCredential(
      entry: entry, usingDatabasePassword: usingDatabasePassword,
      storedDatabasePassword: stored, hasSafeModePassword: hasSafeModePassword,
      verifySafeModePassword: { _ in safeModePasswordMatches })
  }

  @Test("Change password: existing Safe Mode password + empty DB password -> rejected")
  func changePasswordWithSafeModePasswordRejected() {
    #expect(!accepts("", usingDatabasePassword: true, stored: "", hasSafeModePassword: true))
    #expect(
      !accepts("secret", usingDatabasePassword: true, stored: "secret", hasSafeModePassword: true))
  }

  @Test("Touch-ID-only: empty entry + empty stored DB password -> rejected")
  func touchIDOnlyEmptyRejected() {
    #expect(!accepts("", usingDatabasePassword: true, stored: "", hasSafeModePassword: false))
    #expect(!accepts("", usingDatabasePassword: true, stored: nil, hasSafeModePassword: false))
  }

  @Test("No Safe Mode password + correct non-empty DB password -> accepted")
  func correctDatabasePasswordAccepted() {
    #expect(
      accepts("secret", usingDatabasePassword: true, stored: "secret", hasSafeModePassword: false))
    #expect(
      !accepts("wrong", usingDatabasePassword: true, stored: "secret", hasSafeModePassword: false))
  }

  @Test("Safe Mode password path uses the verifier, never the DB password")
  func safeModePasswordPath() {
    #expect(
      accepts(
        "pw", usingDatabasePassword: false, stored: "pw", hasSafeModePassword: true,
        safeModePasswordMatches: true))
    #expect(
      !accepts(
        "pw", usingDatabasePassword: false, stored: "pw", hasSafeModePassword: true,
        safeModePasswordMatches: false))
  }

  @Test("The 'use database password' affordance is hidden when a Safe Mode password exists")
  func affordanceHidden() {
    #expect(!NotebookViewModel.showsDatabasePasswordFallback(hasSafeModePassword: true))
    #expect(NotebookViewModel.showsDatabasePasswordFallback(hasSafeModePassword: false))
  }
}
