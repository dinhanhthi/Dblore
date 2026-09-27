//
//  SafeModeAuthenticator.swift
//  SQLNotebook
//

import Foundation

/// Owns the Safe Mode unlock: a password (salted PBKDF2 record in the password store, the
/// Keychain in the app) and optional Touch ID, with the password as the fallback.
///
/// Builds before the Keychain migration stored an unsalted SHA-256 hex in UserDefaults. That
/// legacy hash keeps verifying until the first successful entry, which re-stores the password
/// as PBKDF2 and only then deletes the UserDefaults key.
@MainActor
@Observable
final class SafeModeAuthenticator {
  /// UserDefaults key of the legacy unsalted SHA-256 hex (read only to migrate it)
  nonisolated static let legacyPasswordKey = "app.settings.safeModePassword"
  /// UserDefaults key of the "use Touch ID" preference (not secret)
  nonisolated static let biometricEnabledKey = "app.settings.safeModeBiometricEnabled"

  static let shared = makeShared()

  /// Keychain + Touch ID in the app. Under XCTest: in-memory store, biometrics that never
  /// prompt and an isolated defaults suite, because a Keychain or Touch ID prompt nobody
  /// clicks hangs the test run (and tests must not touch the user's real settings).
  static func makeShared(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SafeModeAuthenticator {
    if SessionManager.shouldRestoreSession(environment: environment) {
      return SafeModeAuthenticator(
        store: KeychainPasswordStore(), biometrics: LAContextBiometricAuthenticator(),
        defaults: .standard)
    }
    return SafeModeAuthenticator(
      store: InMemoryPasswordStore(), biometrics: UnavailableBiometricAuthenticator(),
      defaults: UserDefaults(suiteName: "com.sqlnotebook.tests.safemode") ?? UserDefaults())
  }

  private let store: SafeModePasswordStore
  private let biometrics: BiometricAuthenticator
  private let defaults: UserDefaults

  /// A Safe Mode password exists (PBKDF2 record or not-yet-migrated legacy hash)
  private(set) var hasPassword: Bool = false
  /// The user chose to unlock with Touch ID
  private(set) var isBiometricEnabled: Bool = false

  init(store: SafeModePasswordStore, biometrics: BiometricAuthenticator, defaults: UserDefaults) {
    self.store = store
    self.biometrics = biometrics
    self.defaults = defaults
    hasPassword = store.load() != nil || legacyHash != nil
    isBiometricEnabled = defaults.bool(forKey: Self.biometricEnabledKey)
  }

  /// True when neither the Keychain nor LocalAuthentication can be reached (test host)
  var usesTestDoubles: Bool {
    store is InMemoryPasswordStore && !(biometrics is LAContextBiometricAuthenticator)
  }

  /// Touch ID is enrolled and usable now (never prompts)
  var canUseBiometrics: Bool { biometrics.canUseBiometrics }

  /// Safe Mode has some unlock configured (password and/or Touch ID)
  var isProtected: Bool { hasPassword || isBiometricEnabled }

  private var legacyHash: String? {
    guard let hex = defaults.string(forKey: Self.legacyPasswordKey), !hex.isEmpty else {
      return nil
    }
    return hex
  }

  // MARK: - Password

  /// Stores `password` as a new salted PBKDF2 record and deletes any legacy hash.
  /// Returns false (nothing changed) if the password is empty or storing failed.
  @discardableResult
  func setPassword(_ password: String) -> Bool {
    guard !password.isEmpty,
      let record = SafeModePasswordRecord.make(password: password),
      let data = try? JSONEncoder().encode(record),
      store.save(data)
    else { return false }
    defaults.removeObject(forKey: Self.legacyPasswordKey)
    hasPassword = true
    return true
  }

  /// True if `password` is the Safe Mode password. False when no password is set.
  /// A match against the legacy hash migrates it to the password store.
  func verify(password: String) -> Bool {
    if let data = store.load(),
      let record = try? JSONDecoder().decode(SafeModePasswordRecord.self, from: data)
    {
      return record.matches(password)
    }
    guard let legacy = legacyHash,
      SafeModePasswordRecord.matchesLegacyHash(password, legacyHex: legacy)
    else { return false }
    // One-time migration; the legacy key is deleted only if the new record was stored
    setPassword(password)
    return true
  }

  /// Removes the password (store and legacy key) and turns Touch ID off
  func removePassword() {
    store.delete()
    defaults.removeObject(forKey: Self.legacyPasswordKey)
    hasPassword = false
    disableBiometrics()
  }

  // MARK: - Touch ID

  /// Prompts for Touch ID when it is enabled and available. False means "show the password
  /// field" (failed, cancelled, disabled or unavailable).
  func authenticate(reason: String) async -> Bool {
    guard isBiometricEnabled, biometrics.canUseBiometrics else { return false }
    return await biometrics.authenticate(reason: reason)
  }

  /// Turns Touch ID on after a successful prompt. The password (if any) is kept as fallback.
  func enableBiometrics(reason: String) async -> Bool {
    guard biometrics.canUseBiometrics, await biometrics.authenticate(reason: reason) else {
      return false
    }
    defaults.set(true, forKey: Self.biometricEnabledKey)
    isBiometricEnabled = true
    return true
  }

  func disableBiometrics() {
    defaults.set(false, forKey: Self.biometricEnabledKey)
    isBiometricEnabled = false
  }
}
