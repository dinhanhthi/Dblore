// SafeModeAuthenticatorTests.swift
// Safe Mode password (salted PBKDF2 in the password store), legacy SHA-256 migration and
// Touch ID unlock. Uses an in-memory store, a fake biometric authenticator and an isolated
// UserDefaults suite: no test touches the real Keychain, LocalAuthentication or `.standard`.

import CryptoKit
import Foundation
import Testing

@testable import Dblore

/// Fake Touch ID: never prompts, returns `result`
@MainActor
final class FakeBiometricAuthenticator: BiometricAuthenticator {
  var canUseBiometrics: Bool
  var result: Bool
  private(set) var promptCount = 0

  init(canUseBiometrics: Bool = true, result: Bool = true) {
    self.canUseBiometrics = canUseBiometrics
    self.result = result
  }

  func authenticate(reason: String) async -> Bool {
    promptCount += 1
    return canUseBiometrics && result
  }
}

@Suite("Safe Mode Authenticator")
@MainActor
struct SafeModeAuthenticatorTests {
  let store = InMemoryPasswordStore()
  let biometrics = FakeBiometricAuthenticator()
  let suiteName = "SafeModeAuthenticatorTests.\(UUID().uuidString)"
  let defaults: UserDefaults
  let auth: SafeModeAuthenticator

  init() {
    defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    auth = SafeModeAuthenticator(store: store, biometrics: biometrics, defaults: defaults)
  }

  private func storedRecord() -> SafeModePasswordRecord? {
    guard let data = store.load() else { return nil }
    return try? JSONDecoder().decode(SafeModePasswordRecord.self, from: data)
  }

  private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Authenticator over `defaults` holding a legacy SHA-256 hex of `password`
  private func legacyAuthenticator(password: String) -> SafeModeAuthenticator {
    defaults.set(sha256Hex(password), forKey: SafeModeAuthenticator.legacyPasswordKey)
    return SafeModeAuthenticator(store: store, biometrics: biometrics, defaults: defaults)
  }

  private func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  // MARK: - Password

  @Test("Set password, then verify accepts it and rejects others")
  func setThenVerify() {
    defer { cleanUp() }
    #expect(auth.setPassword("correct horse"))
    #expect(auth.hasPassword)
    #expect(auth.verify(password: "correct horse"))
    #expect(!auth.verify(password: "wrong"))
    #expect(!auth.verify(password: ""))
  }

  @Test("Verify fails when no password is set")
  func verifyWithoutPasswordFails() {
    defer { cleanUp() }
    #expect(!auth.hasPassword)
    #expect(!auth.verify(password: ""))
    #expect(!auth.verify(password: "anything"))
  }

  @Test("Setting the same password twice uses a different random salt")
  func saltDiffersPerSet() throws {
    defer { cleanUp() }
    auth.setPassword("same")
    let first = try #require(storedRecord())
    auth.setPassword("same")
    let second = try #require(storedRecord())

    #expect(first.salt.count == 16)
    #expect(first.salt != second.salt)
    #expect(first.hash != second.hash)
    #expect(auth.verify(password: "same"))
  }

  @Test("Stored value has no plaintext and is not a bare SHA-256")
  func storedValueIsSaltedAndIterated() throws {
    defer { cleanUp() }
    let password = "hunter2-plaintext"
    auth.setPassword(password)
    let data = try #require(store.load())
    let record = try #require(storedRecord())
    let text = String(decoding: data, as: UTF8.self)

    #expect(!text.contains(password))
    #expect(record.iterations >= 200_000)
    #expect(record.hash != Data(SHA256.hash(data: Data(password.utf8))))
    #expect(!text.contains(sha256Hex(password)))
    // Nothing written to UserDefaults
    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) == nil)
  }

  // MARK: - Legacy migration

  @Test("Legacy SHA-256 verifies once, then is migrated to PBKDF2 and removed")
  func legacyHashMigrates() throws {
    defer { cleanUp() }
    let auth = legacyAuthenticator(password: "legacy-pass")
    #expect(auth.hasPassword)
    #expect(store.load() == nil)

    #expect(auth.verify(password: "legacy-pass"))

    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) == nil)
    let record = try #require(storedRecord())
    #expect(record.iterations >= 200_000)
    #expect(auth.hasPassword)
    #expect(auth.verify(password: "legacy-pass"))
    #expect(!auth.verify(password: "other"))
  }

  @Test("Wrong legacy password does not migrate")
  func wrongLegacyPasswordKeepsLegacy() {
    defer { cleanUp() }
    let auth = legacyAuthenticator(password: "legacy-pass")

    #expect(!auth.verify(password: "nope"))

    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) != nil)
    #expect(store.load() == nil)
    #expect(auth.hasPassword)
  }

  @Test("Remove password clears the store, the legacy key and Touch ID")
  func removeClearsEverything() async {
    defer { cleanUp() }
    let auth = legacyAuthenticator(password: "legacy-pass")
    auth.setPassword("new-pass")
    defaults.set("stale", forKey: SafeModeAuthenticator.legacyPasswordKey)
    #expect(await auth.enableBiometrics(reason: "test"))

    auth.removePassword()

    #expect(store.load() == nil)
    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) == nil)
    #expect(!auth.hasPassword)
    #expect(!auth.isBiometricEnabled)
    #expect(!auth.isProtected)
  }

  // MARK: - Biometrics

  @Test("Biometric success authenticates without a password")
  func biometricSuccess() async {
    defer { cleanUp() }
    auth.setPassword("pass")
    #expect(await auth.enableBiometrics(reason: "enable"))
    #expect(auth.isBiometricEnabled)
    // Enabling Touch ID keeps the password as the fallback
    #expect(auth.hasPassword)

    #expect(await auth.authenticate(reason: "run"))
    #expect(biometrics.promptCount == 2)
  }

  @Test("Biometric failure falls back (returns false)")
  func biometricFailure() async {
    defer { cleanUp() }
    auth.setPassword("pass")
    #expect(await auth.enableBiometrics(reason: "enable"))
    biometrics.result = false

    #expect(await auth.authenticate(reason: "run") == false)
    #expect(auth.verify(password: "pass"))
  }

  @Test("Authenticate returns false without prompting when Touch ID is off or unavailable")
  func biometricNotUsedWhenOffOrUnavailable() async {
    defer { cleanUp() }
    #expect(await auth.authenticate(reason: "run") == false)
    #expect(biometrics.promptCount == 0)

    #expect(await auth.enableBiometrics(reason: "enable"))
    biometrics.canUseBiometrics = false
    #expect(await auth.authenticate(reason: "run") == false)
    #expect(biometrics.promptCount == 1)
  }

  @Test("Enabling Touch ID fails when biometrics are unavailable or rejected")
  func enableBiometricsFails() async {
    defer { cleanUp() }
    biometrics.result = false
    #expect(await auth.enableBiometrics(reason: "enable") == false)
    #expect(!auth.isBiometricEnabled)

    biometrics.canUseBiometrics = false
    #expect(await auth.enableBiometrics(reason: "enable") == false)
  }

  // MARK: - Test host isolation

  @Test("Shared authenticator under XCTest uses the in-memory store and no-prompt biometrics")
  func sharedUsesTestDoublesUnderXCTest() {
    #expect(SafeModeAuthenticator.shared.usesTestDoubles)
    let made = SafeModeAuthenticator.makeShared(
      environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
    #expect(made.usesTestDoubles)
    #expect(!made.canUseBiometrics)
  }
}
