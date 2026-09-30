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

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: Self.accountName,
    ]
  }

  func load() -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  /// Delete-then-add (same pattern as SessionManager's database passwords)
  @discardableResult
  func save(_ data: Data) -> Bool {
    delete()
    var attributes = baseQuery
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  func delete() {
    SecItemDelete(baseQuery as CFDictionary)
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
