// SafeModeDatabasePasswordFallbackTests.swift
// "Forgot Password?" in the Safe Mode unlock sheet: the database password is accepted only when
// no Safe Mode password exists, never when empty, and compared in constant time.

import Foundation
import Testing

@testable import Dblore

@Suite("Safe Mode Database Password Fallback Tests")
struct SafeModeDatabasePasswordFallbackTests {
  private func accepts(_ entry: String, stored: String?, hasSafeModePassword: Bool) -> Bool {
    NotebookViewModel.acceptsDatabasePasswordFallback(
      entry: entry, storedPassword: stored, hasSafeModePassword: hasSafeModePassword)
  }

  @Test("Empty stored DB password + empty entry -> rejected")
  func emptyRejected() {
    #expect(!accepts("", stored: "", hasSafeModePassword: false))
    #expect(!accepts("", stored: nil, hasSafeModePassword: false))
    #expect(!accepts("anything", stored: "", hasSafeModePassword: false))
  }

  @Test("Safe Mode password set -> DB password fallback rejected")
  func safeModePasswordSetRejected() {
    #expect(!accepts("secret", stored: "secret", hasSafeModePassword: true))
  }

  @Test("No Safe Mode password + correct non-empty DB password -> accepted")
  func correctAccepted() {
    #expect(accepts("secret", stored: "secret", hasSafeModePassword: false))
  }

  @Test("Wrong DB password -> rejected")
  func wrongRejected() {
    #expect(!accepts("secreT", stored: "secret", hasSafeModePassword: false))
    #expect(!accepts("secret1", stored: "secret", hasSafeModePassword: false))
  }
}
