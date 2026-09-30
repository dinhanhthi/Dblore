//
//  AIKeyStore.swift
//  Dblore
//

import Foundation
import Security

/// Storage for AI provider API keys, one entry per account (see `AIKeyStoreFactory.apiKeyAccount`).
/// The app uses the Keychain; tests use `InMemoryAIKeyStore` so the test host never shows a
/// Keychain prompt (a prompt nobody clicks hangs the whole test run).
nonisolated protocol AIKeyStore: AnyObject, Sendable {
  func load(account: String) -> String?
  @discardableResult func save(_ value: String, account: String) -> Bool
  func delete(account: String)
}

/// Keychain-backed store: generic password, service `ace.thi.dblore.ai`,
/// accessible only while unlocked and never migrated to another device.
nonisolated final class KeychainAIKeyStore: AIKeyStore, Sendable {
  private let service = "ace.thi.dblore.ai"

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func load(account: String) -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Delete-then-add (same pattern as SafeModePasswordStore)
  @discardableResult
  func save(_ value: String, account: String) -> Bool {
    delete(account: account)
    var attributes = baseQuery(account: account)
    attributes[kSecValueData as String] = Data(value.utf8)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  func delete(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}

/// In-memory store used under XCTest and by unit tests
nonisolated final class InMemoryAIKeyStore: AIKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]

  func load(account: String) -> String? {
    lock.withLock { values[account] }
  }

  @discardableResult
  func save(_ value: String, account: String) -> Bool {
    lock.withLock { values[account] = value }
    return true
  }

  func delete(account: String) {
    lock.withLock { values[account] = nil }
  }
}

nonisolated enum AIKeyStoreFactory {
  /// The one app-wide store: `AISettings` reads and `ChatGPTTokenProvider` writes through it
  static let shared: AIKeyStore = makeDefault()

  /// Keychain in the app, in-memory under the test host
  static func makeDefault() -> AIKeyStore {
    SessionManager.isRunningAsTestHost ? InMemoryAIKeyStore() : KeychainAIKeyStore()
  }

  /// Takes the raw value so this file does not depend on `AIProviderKind`
  static func apiKeyAccount(_ kindRawValue: String) -> String {
    "apikey.\(kindRawValue)"
  }
}
