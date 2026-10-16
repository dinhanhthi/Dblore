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
  static let serviceName = "ace.thi.dblore.ai"

  static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func load(account: String) -> String? {
    guard case .found(let data) = Self.vault.read(account: account) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  func save(_ value: String, account: String) -> Bool {
    Self.vault.write(account: account, data: Data(value.utf8)) == errSecSuccess
  }

  func delete(account: String) {
    Self.vault.delete(account: account)
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
