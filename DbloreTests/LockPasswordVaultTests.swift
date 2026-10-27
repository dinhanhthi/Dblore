// LockPasswordVaultTests.swift
// Lock password vault: independence from the Safe Mode password (stores and legacy key),
// the 8-character minimum, the iteration count, NFC, fail-closed unreadable records and the
// wrong-entry throttle. In-memory stores, an isolated
// UserDefaults suite and an injected clock: no test touches the real Keychain or waits.

import Foundation
import Security
import Testing
import os

@testable import Dblore

/// Clock the tests move by hand
nonisolated private final class TestClock: Sendable {
  private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))

  var now: Date { current.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    current.withLock { $0 += seconds }
  }
}

/// A store whose Keychain read fails (locked keybag, denied access)
nonisolated private final class UnreadablePasswordStore: SafeModePasswordStore {
  func load() -> Data? { nil }
  func loadRecord() -> KeychainRead { .failed(errSecInteractionNotAllowed) }
  func save(_ data: Data) -> Bool { true }
  func delete() {}
}

@Suite("Lock Password Vault")
@MainActor
struct LockPasswordVaultTests {
  private let clock = TestClock()

  private func lockVault(
    store: InMemoryPasswordStore = InMemoryPasswordStore()
  )
    -> UnlockPasswordVault
  {
    let clock = clock
    return UnlockPasswordVault.lockPassword(store: store, now: { clock.now })
  }

  @Test("Setting or removing the Lock or Safe Mode password never touches the other")
  func lockAndSafeModeAreIndependent() {
    let suiteName = "LockPasswordVaultTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(LockPasswordStore.serviceName != KeychainPasswordStore.serviceName)

    let legacyHex = String(repeating: "ab", count: 32)
    defaults.set(legacyHex, forKey: SafeModeAuthenticator.legacyPasswordKey)
    let safeModeStore = InMemoryPasswordStore()
    let safeMode = SafeModeAuthenticator(
      store: safeModeStore, biometrics: FakeBiometricAuthenticator(), defaults: defaults)
    let lockStore = InMemoryPasswordStore()
    let lock = lockVault(store: lockStore)

    // Lock set/remove leaves the Safe Mode store and its legacy key alone
    #expect(lock.setPassword("lock password 1"))
    #expect(safeModeStore.load() == nil)
    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) == legacyHex)
    #expect(lock.verify("lock password 1") == .accepted)
    #expect(!safeMode.verify(password: "lock password 1"))
    lock.removePassword()
    #expect(defaults.string(forKey: SafeModeAuthenticator.legacyPasswordKey) == legacyHex)
    #expect(safeMode.hasPassword)

    // Safe Mode set/remove leaves the Lock store alone
    #expect(lock.setPassword("lock password 2"))
    let lockRecord = lockStore.load()
    #expect(safeMode.setPassword("safe"))
    #expect(lockStore.load() == lockRecord)
    #expect(lock.verify("safe") == .rejected)
    safeMode.removePassword()
    #expect(lockStore.load() == lockRecord)
    #expect(lock.verify("lock password 2") == .accepted)
  }

  @Test("Lock password needs at least 8 characters")
  func minimumLength() {
    let vault = lockVault()
    #expect(!vault.setPassword("seven77"))
    #expect(!vault.hasPassword)
    #expect(vault.setPassword("eight888"))
    #expect(vault.verify("eight888") == .accepted)
  }

  @Test("The Lock password record is written with at least 600,000 PBKDF2 iterations")
  func lockRecordIterations() throws {
    let store = InMemoryPasswordStore()
    #expect(lockVault(store: store).setPassword("lock password"))

    let data = try #require(store.load())
    let record = try JSONDecoder().decode(SafeModePasswordRecord.self, from: data)
    #expect(record.iterations >= 600_000)
  }

  @Test("The Lock password is NFC-normalized: set in NFC, an NFD-typed entry is accepted")
  func lockPasswordIsNormalizedToNFC() {
    let vault = lockVault()
    #expect(vault.setPassword("caf\u{E9} lock"))

    #expect(vault.verify("cafe\u{301} lock") == .accepted)
  }

  @Test("An unreadable or corrupt Lock record is unreadable, never 'no password'")
  func unreadableRecordFailsClosed() {
    let missing = lockVault()
    #expect(missing.verify("lock password") == .noPassword)
    #expect(missing.passwordState == .absent)
    #expect(!missing.hasPassword)

    let failing = UnlockPasswordVault.lockPassword(store: UnreadablePasswordStore())
    let corrupt = lockVault(store: InMemoryPasswordStore(data: Data("not a record".utf8)))
    for vault in [failing, corrupt] {
      #expect(vault.verify("lock password") == .unreadable)
      #expect(vault.passwordState == .unreadable)
      #expect(vault.hasPassword)
    }
  }

  @Test("Wrong entries throttle after 5 with a doubling, capped delay; success resets it")
  func throttle() {
    let vault = lockVault()
    #expect(vault.setPassword("correct password"))

    for _ in 1...5 {
      #expect(vault.verify("wrong") == .rejected)
    }
    // Throttled: refused without checking, even the right password
    #expect(vault.verify("correct password") == .throttled(until: clock.now + 1))
    clock.advance(by: 1)
    #expect(vault.verify("wrong") == .rejected)
    #expect(vault.verify("wrong") == .throttled(until: clock.now + 2))

    for _ in 0..<10 {
      clock.advance(by: 60)
      #expect(vault.verify("wrong") == .rejected)
    }
    #expect(vault.verify("wrong") == .throttled(until: clock.now + 60))

    clock.advance(by: 60)
    #expect(vault.verify("correct password") == .accepted)
    for _ in 1...5 {
      #expect(vault.verify("wrong") == .rejected)
    }
  }
}
