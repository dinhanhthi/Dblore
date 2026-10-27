//
//  SafeModePasswordStore.swift
//  Dblore
//

import Foundation
import Security
import os

/// Storage for the Safe Mode password record (salted hash, never the plaintext).
/// The app uses the Keychain; tests use `InMemoryPasswordStore` so the test host never shows a
/// Keychain prompt (a prompt nobody clicks hangs the whole test run).
nonisolated protocol SafeModePasswordStore: AnyObject, Sendable {
  func load() -> Data?
  /// Tells a missing record from an unreadable one (locked keybag, denied access), so the Lock
  /// path fails closed. The default reports every nil `load()` as missing (Safe Mode stores).
  func loadRecord() -> KeychainRead
  @discardableResult func save(_ data: Data) -> Bool
  func delete()
}

nonisolated extension SafeModePasswordStore {
  func loadRecord() -> KeychainRead { load().map(KeychainRead.found) ?? .notFound }
}

/// Keychain-backed store: generic password, service `ace.thi.dblore.safemode`,
/// accessible only while unlocked and never migrated to another device.
nonisolated final class KeychainPasswordStore: SafeModePasswordStore {
  static let serviceName = "ace.thi.dblore.safemode"
  static let accountName = "safe-mode-password"

  static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func load() -> Data? {
    guard case .found(let data) = Self.vault.read(account: Self.accountName) else { return nil }
    return data
  }

  @discardableResult
  func save(_ data: Data) -> Bool {
    Self.vault.write(account: Self.accountName, data: data) == errSecSuccess
  }

  func delete() {
    Self.vault.delete(account: Self.accountName)
  }
}

/// In-memory store used under XCTest and by unit tests
nonisolated final class InMemoryPasswordStore: SafeModePasswordStore {
  private let data: OSAllocatedUnfairLock<Data?>

  init(data: Data? = nil) {
    self.data = OSAllocatedUnfairLock(initialState: data)
  }

  func load() -> Data? { data.withLock { $0 } }

  @discardableResult
  func save(_ data: Data) -> Bool {
    self.data.withLock { $0 = data }
    return true
  }

  func delete() {
    data.withLock { $0 = nil }
  }
}
