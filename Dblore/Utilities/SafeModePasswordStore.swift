//
//  SafeModePasswordStore.swift
//  Dblore
//

import Foundation
import Security

/// Storage for the Safe Mode password record (salted hash, never the plaintext).
/// The app uses the Keychain; tests use `InMemoryPasswordStore` so the test host never shows a
/// Keychain prompt (a prompt nobody clicks hangs the whole test run).
protocol SafeModePasswordStore: AnyObject {
  func load() -> Data?
  @discardableResult func save(_ data: Data) -> Bool
  func delete()
}

/// Keychain-backed store: generic password, service `ace.thi.dblore.safemode`,
/// accessible only while unlocked and never migrated to another device.
final class KeychainPasswordStore: SafeModePasswordStore {
  nonisolated static let serviceName = "ace.thi.dblore.safemode"
  nonisolated static let accountName = "safe-mode-password"

  nonisolated static let vault = KeychainVault(
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
final class InMemoryPasswordStore: SafeModePasswordStore {
  private var data: Data?

  init(data: Data? = nil) {
    self.data = data
  }

  func load() -> Data? { data }

  @discardableResult
  func save(_ data: Data) -> Bool {
    self.data = data
    return true
  }

  func delete() {
    data = nil
  }
}
