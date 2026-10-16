// KeychainVault.swift
// One generic-password Keychain service, stored in the data protection keychain. Debug and
// Release builds share its access group, while file-based keychain ACLs trusted only the
// signature that created an item. Reads fall back to the legacy file-based keychain and copy
// a hit into the data protection keychain; the legacy copy is kept until delete.

import Foundation
import Security
import os

/// Result of one Keychain lookup. A failure (for example a denied prompt) is never a miss.
nonisolated enum KeychainRead: Equatable, Sendable {
  case found(Data)
  case notFound
  case failed(OSStatus)
}

/// One Keychain domain (data protection or legacy file-based). Tests inject an in-memory twin.
nonisolated protocol KeychainBackend: Sendable {
  func copy(service: String, account: String) -> KeychainRead
  func add(service: String, account: String, data: Data, accessible: CFString) -> OSStatus
  /// Updates the data and accessibility, or adds the item when it does not exist.
  func upsert(service: String, account: String, data: Data, accessible: CFString) -> OSStatus
  func delete(service: String, account: String) -> OSStatus
  /// Account names only; item data is never read.
  func accounts(service: String) -> [String]
}

/// SecItem calls on generic-password items. No access group is set, so items land in the
/// default one (the first keychain-access-groups entitlement).
nonisolated struct SecItemKeychainBackend: KeychainBackend {
  let dataProtection: Bool

  init(dataProtection: Bool) {
    self.dataProtection = dataProtection
  }

  private var domain: String { dataProtection ? "data protection" : "legacy" }

  private func query(service: String, account: String? = nil) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
      query[kSecAttrSynchronizable as String] = false
    }
    return query
  }

  func copy(service: String, account: String) -> KeychainRead {
    var query = query(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    KeychainLog.status(status, "copy", domain, service, account)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return .failed(errSecDecode) }
      return .found(data)
    case errSecItemNotFound: return .notFound
    default: return .failed(status)
    }
  }

  func add(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    var attributes = query(service: service, account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = accessible
    let status = SecItemAdd(attributes as CFDictionary, nil)
    KeychainLog.status(status, "add", domain, service, account)
    return status
  }

  func upsert(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    let changes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessible,
    ]
    let status = SecItemUpdate(
      query(service: service, account: account) as CFDictionary, changes as CFDictionary)
    guard status == errSecItemNotFound else {
      KeychainLog.status(status, "update", domain, service, account)
      return status
    }
    return add(service: service, account: account, data: data, accessible: accessible)
  }

  func delete(service: String, account: String) -> OSStatus {
    let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
    KeychainLog.status(status, "delete", domain, service, account)
    return status
  }

  func accounts(service: String) -> [String] {
    var query = query(service: service)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    KeychainLog.status(status, "accounts", domain, service, nil)
    guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }
}

/// A service in the data protection keychain, migrated lazily from the legacy keychain.
nonisolated struct KeychainVault: Sendable {
  let service: String
  /// Kept as a String: CFString is not Sendable.
  private let accessibility: String
  private let modern: any KeychainBackend
  private let legacy: any KeychainBackend

  private var accessible: CFString { accessibility as CFString }

  init(
    service: String, accessible: CFString,
    modern: any KeychainBackend = SecItemKeychainBackend(dataProtection: true),
    legacy: any KeychainBackend = SecItemKeychainBackend(dataProtection: false)
  ) {
    self.service = service
    self.accessibility = accessible as String
    self.modern = modern
    self.legacy = legacy
  }

  /// Data protection first. A legacy hit is copied over (never overwriting) and returned even
  /// when the copy fails; a legacy failure stays a failure so callers can fail closed.
  func read(account: String) -> KeychainRead {
    let current = modern.copy(service: service, account: account)
    guard current == .notFound else { return current }
    let old = legacy.copy(service: service, account: account)
    if case .found(let data) = old {
      _ = modern.add(service: service, account: account, data: data, accessible: accessible)
    }
    return old
  }

  /// Writes to the data protection keychain only; the legacy copy is left alone.
  @discardableResult func write(account: String, data: Data) -> OSStatus {
    modern.upsert(service: service, account: account, data: data, accessible: accessible)
  }

  /// Adds only when absent: false on a duplicate or any failure.
  func add(account: String, data: Data) -> Bool {
    modern.add(service: service, account: account, data: data, accessible: accessible)
      == errSecSuccess
  }

  /// Deletes in both keychains, legacy first: when the legacy delete fails the modern copy is
  /// kept, so a later read cannot migrate the old value back. A missing item is fine.
  @discardableResult func delete(account: String) -> OSStatus {
    for backend in [legacy, modern] {
      let status = backend.delete(service: service, account: account)
      guard status == errSecSuccess || status == errSecItemNotFound else { return status }
    }
    return errSecSuccess
  }

  /// Accounts in either keychain, data protection order first, without duplicates.
  func accounts() -> [String] {
    var seen = Set<String>()
    return (modern.accounts(service: service) + legacy.accounts(service: service))
      .filter { seen.insert($0).inserted }
  }
}

/// Keychain statuses worth a look. Accounts are private; data is never logged.
nonisolated private enum KeychainLog {
  static let logger = Logger(subsystem: "ace.thi.dblore.app", category: "Keychain")

  static func status(
    _ status: OSStatus, _ operation: String, _ domain: String, _ service: String,
    _ account: String?
  ) {
    guard status != errSecSuccess, status != errSecItemNotFound else { return }
    let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
    logger.error(
      "\(operation, privacy: .public) \(domain, privacy: .public) \(service, privacy: .public) \(account ?? "-", privacy: .private): \(status) \(message, privacy: .public)"
    )
  }
}
