// SecretInventory.swift
// Accounts stored in the Keychain. Listing reads attributes only; values stay in the Keychain.

import Foundation
import Security

/// Which stored value an account holds.
nonisolated enum SecretKind: String, Sendable {
  case dbPassword
  case aiKey
  case chatGPTToken
  case safeModePassword
}

/// One Keychain account. `label` is the account name. The value itself is not here.
nonisolated struct SecretItem: Identifiable, Equatable, Sendable {
  var service: String
  var account: String
  var label: String
  var kind: SecretKind

  var id: String { "\(service)\n\(account)" }

  /// Builds an item from a service and account. The label is the account name.
  static func listed(service: String, account: String) -> SecretItem {
    SecretItem(
      service: service, account: account, label: account,
      kind: kind(service: service, account: account))
  }

  /// Database and Safe Mode follow the service. The ChatGPT account on the AI service is the token.
  static func kind(service: String, account: String) -> SecretKind {
    switch service {
    case SessionManager.keychainService:
      return .dbPassword
    case KeychainPasswordStore.serviceName:
      return .safeModePassword
    case KeychainAIKeyStore.serviceName:
      return account == ChatGPTTokenStorage.account ? .chatGPTToken : .aiKey
    default:
      return .aiKey
    }
  }
}

/// Lists and removes stored accounts without reading their values.
nonisolated protocol SecretInventory: Sendable {
  func items() async -> [SecretItem]
  func delete(_ item: SecretItem) async throws
  func deleteAll(kind: SecretKind) async throws
}

nonisolated enum SecretInventoryError: Error, Equatable, Sendable {
  case keychainStatus(OSStatus)
}

/// Store used by tests and by the app when it is the test host.
nonisolated final class InMemorySecretInventory: SecretInventory, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [SecretItem]

  init(items: [SecretItem] = []) {
    stored = items
  }

  func items() async -> [SecretItem] {
    lock.withLock { stored }
  }

  func delete(_ item: SecretItem) async throws {
    lock.withLock {
      stored.removeAll { $0.service == item.service && $0.account == item.account }
    }
  }

  func deleteAll(kind: SecretKind) async throws {
    lock.withLock {
      stored.removeAll { $0.kind == kind }
    }
  }
}

/// Keychain store for the app. Queries attributes for each service the app already uses.
nonisolated final class KeychainSecretInventory: SecretInventory, Sendable {
  private static let services = [
    SessionManager.keychainService,
    KeychainAIKeyStore.serviceName,
    KeychainPasswordStore.serviceName,
  ]

  func items() async -> [SecretItem] {
    var listed: [SecretItem] = []
    for service in Self.services {
      for account in accounts(service: service) {
        listed.append(SecretItem.listed(service: service, account: account))
      }
    }
    return listed
  }

  func delete(_ item: SecretItem) async throws {
    if item.kind == .safeModePassword {
      await MainActor.run {
        SafeModeAuthenticator.shared.removePassword()
      }
      if item.service != KeychainPasswordStore.serviceName
        || item.account != KeychainPasswordStore.accountName
      {
        try deleteGeneric(service: item.service, account: item.account)
      }
      return
    }
    try deleteGeneric(service: item.service, account: item.account)
  }

  func deleteAll(kind: SecretKind) async throws {
    for item in await items() where item.kind == kind {
      try await delete(item)
    }
  }

  private func accounts(service: String) -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let result, let rows = result as? NSArray else { return [] }
    var accounts: [String] = []
    for case let row as NSDictionary in rows {
      guard let account = row[kSecAttrAccount as String] as? String else { continue }
      accounts.append(account)
    }
    return accounts
  }

  private func deleteGeneric(service: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretInventoryError.keychainStatus(status)
    }
  }
}

/// Keychain in the app, in-memory under the test host.
nonisolated enum SecretInventoryFactory {
  static func makeDefault() -> any SecretInventory {
    if SessionManager.isRunningAsTestHost {
      return InMemorySecretInventory()
    }
    return KeychainSecretInventory()
  }
}
