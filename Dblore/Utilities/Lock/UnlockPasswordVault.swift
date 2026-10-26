//
//  UnlockPasswordVault.swift
//  Dblore
//

import Foundation
import Security
import os

/// Set, verify and remove one password kept as a salted PBKDF2 record in a password store.
/// Serves the Safe Mode password (through `SafeModeAuthenticator`, which owns the legacy
/// migration) and the Lock password. Verify runs PBKDF2, so Lock callers run it off the main
/// actor. The throttle never sleeps: a throttled verify returns at once with the retry time.
nonisolated final class UnlockPasswordVault: Sendable {
  enum Outcome: Equatable, Sendable {
    case accepted
    case rejected
    /// No record in the store
    case noPassword
    /// A record may exist but cannot be read (locked keybag, denied access) or decoded: never
    /// treat it as `noPassword` (fail closed)
    case unreadable
    /// Too many wrong entries: refused without checking until `until`
    case throttled(until: Date)
  }

  enum PasswordState: Equatable, Sendable {
    case present
    case absent
    /// See `Outcome.unreadable`
    case unreadable
  }

  /// Wrong entries allowed freely, then a delay that doubles from `firstDelay` up to `maxDelay`
  struct Throttle: Sendable {
    var freeAttempts = 5
    var firstDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 60

    func delay(afterFailures failures: Int) -> TimeInterval {
      min(maxDelay, firstDelay * pow(2, Double(failures - freeAttempts)))
    }
  }

  private enum StoredRecord {
    case found(SafeModePasswordRecord)
    case notFound
    case failed
  }

  private struct ThrottleState {
    var failures = 0
    var retryAt: Date?
  }

  static let lockMinimumLength = 8

  let store: any SafeModePasswordStore
  let minimumLength: Int
  private let throttle: Throttle?
  private let iterations: Int
  private let normalizesPassword: Bool
  private let now: @Sendable () -> Date
  private let state = OSAllocatedUnfairLock(initialState: ThrottleState())

  /// `normalizesPassword`: hash the NFC form, so a password typed decomposed (NFD) matches
  init(
    store: any SafeModePasswordStore, minimumLength: Int, throttle: Throttle? = nil,
    iterations: Int = SafeModePasswordRecord.defaultIterations, normalizesPassword: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.minimumLength = minimumLength
    self.throttle = throttle
    self.iterations = iterations
    self.normalizesPassword = normalizesPassword
    self.now = now
  }

  /// The Lock password: 8-character minimum, the wrong-entry throttle, `lockIterations` and NFC
  /// (the same normalization as the envelope wrap)
  static func lockPassword(
    store: any SafeModePasswordStore, now: @escaping @Sendable () -> Date = { Date() }
  ) -> UnlockPasswordVault {
    UnlockPasswordVault(
      store: store, minimumLength: lockMinimumLength, throttle: Throttle(),
      iterations: SafeModePasswordRecord.lockIterations, normalizesPassword: true, now: now)
  }

  /// Whether a record is stored. Decodes it (no PBKDF2), so a corrupt record is `.unreadable`
  var passwordState: PasswordState {
    switch record() {
    case .found: return .present
    case .notFound: return .absent
    case .failed: return .unreadable
    }
  }

  /// False only when the store has no record: an unreadable one counts as set (fail closed)
  var hasPassword: Bool { passwordState != .absent }

  /// Stores `password` as a new record. False (nothing changed) if it is shorter than
  /// `minimumLength` or storing failed.
  @discardableResult
  func setPassword(_ password: String) -> Bool {
    guard password.count >= minimumLength,
      let record = SafeModePasswordRecord.make(
        password: prepared(password), iterations: iterations),
      let data = try? JSONEncoder().encode(record),
      store.save(data)
    else { return false }
    state.withLock { $0 = ThrottleState() }
    return true
  }

  func verify(_ password: String) -> Outcome {
    let record: SafeModePasswordRecord
    switch self.record() {
    case .found(let found): record = found
    case .notFound: return .noPassword
    case .failed: return .unreadable
    }
    if let retryAt = countAttempt() { return .throttled(until: retryAt) }
    guard record.matches(prepared(password)) else { return .rejected }
    state.withLock { $0 = ThrottleState() }
    return .accepted
  }

  func removePassword() {
    store.delete()
    state.withLock { $0 = ThrottleState() }
  }

  /// The stored record; a store failure or a record that does not decode is `.failed`
  private func record() -> StoredRecord {
    switch store.loadRecord() {
    case .found(let data):
      guard let record = try? JSONDecoder().decode(SafeModePasswordRecord.self, from: data)
      else { return .failed }
      return .found(record)
    case .notFound: return .notFound
    case .failed: return .failed
    }
  }

  private func prepared(_ password: String) -> String {
    normalizesPassword ? password.precomposedStringWithCanonicalMapping : password
  }

  /// The retry time while throttled. Otherwise counts this attempt as wrong before PBKDF2 runs
  /// (a match resets it), so attempts made in parallel cannot slip past the delay.
  private func countAttempt() -> Date? {
    guard let throttle else { return nil }
    let now = now()
    return state.withLock { state in
      if let retryAt = state.retryAt, retryAt > now { return retryAt }
      state.failures += 1
      if state.failures >= throttle.freeAttempts {
        state.retryAt = now + throttle.delay(afterFailures: state.failures)
      }
      return nil
    }
  }
}

/// Keychain-backed store of the Lock password record: generic password, service
/// `ace.thi.dblore.lock`, accessible only while unlocked and never migrated to another device.
nonisolated final class LockPasswordStore: SafeModePasswordStore {
  static let serviceName = "ace.thi.dblore.lock"
  static let accountName = "lock-password"

  static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func load() -> Data? {
    guard case .found(let data) = loadRecord() else { return nil }
    return data
  }

  /// A Keychain failure stays a failure, never a missing record
  func loadRecord() -> KeychainRead { Self.vault.read(account: Self.accountName) }

  @discardableResult
  func save(_ data: Data) -> Bool {
    Self.vault.write(account: Self.accountName, data: data) == errSecSuccess
  }

  func delete() {
    Self.vault.delete(account: Self.accountName)
  }
}
