import Foundation
import Security

/// A pinned SSH host key (TOFU). The fingerprint is the OpenSSH "SHA256:..." form.
nonisolated struct SSHKnownHost: Codable, Equatable, Sendable {
  var algorithm: String
  var fingerprint: String
  var addedAt: Date
}

nonisolated enum SSHHostKeyVerdict: Equatable, Sendable {
  case trusted
  case unknown
  case changed(stored: SSHKnownHost)
}

/// A pin exists but cannot be read. Callers fail closed: never treat it as "unknown".
nonisolated enum SSHKnownHostStoreError: Error, Equatable {
  case keychain(OSStatus)
  case undecodable
}

nonisolated protocol SSHKnownHostStore: AnyObject, Sendable {
  /// Nil only when nothing is pinned. Throws when a pin exists but cannot be read.
  func load(account: String) throws -> SSHKnownHost?
  /// Adds a pin only when none exists. False when one does (or on failure); never overwrites.
  @discardableResult func add(_ host: SSHKnownHost, account: String) -> Bool
  /// Adds or overwrites a pin.
  @discardableResult func save(_ host: SSHKnownHost, account: String) -> Bool
  func delete(account: String)
}

nonisolated extension SSHKnownHostStore {
  func lookup(host: String, port: Int) throws -> SSHKnownHost? {
    try load(account: SSHKnownHostStoreFactory.account(host: host, port: port))
  }

  /// Pins a first-seen key. Returns false, and changes nothing, when a key is already pinned
  /// (even one added concurrently after the lookup): overwriting goes only through `replacePin`.
  @discardableResult
  func trust(
    host: String, port: Int, algorithm: String, fingerprint: String, at date: Date = Date()
  ) throws -> Bool {
    let verdict = SSHKnownHostStoreFactory.evaluate(
      presented: (algorithm: algorithm, fingerprint: fingerprint),
      stored: try lookup(host: host, port: port))
    return switch verdict {
    case .trusted: true
    case .changed: false
    case .unknown:
      add(
        SSHKnownHost(algorithm: algorithm, fingerprint: fingerprint, addedAt: date),
        account: SSHKnownHostStoreFactory.account(host: host, port: port))
    }
  }

  /// Overwrites the pin. Only for an explicit "replace key" action the user confirmed.
  @discardableResult
  func replacePin(
    host: String, port: Int, algorithm: String, fingerprint: String, at date: Date = Date()
  ) -> Bool {
    save(
      SSHKnownHost(algorithm: algorithm, fingerprint: fingerprint, addedAt: date),
      account: SSHKnownHostStoreFactory.account(host: host, port: port))
  }

  func remove(host: String, port: Int) {
    delete(account: SSHKnownHostStoreFactory.account(host: host, port: port))
  }
}

/// One JSON payload per SSH endpoint. This-device-only Keychain items do not migrate.
nonisolated final class KeychainSSHKnownHostStore: SSHKnownHostStore, Sendable {
  static let serviceName = "ace.thi.dblore.ssh-host-key"

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load(account: String) throws -> SSHKnownHost? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return try Self.decode(status: status, data: result as? Data)
  }

  /// Only "not found" means no pin. A locked Keychain, a denied read or corrupt JSON throws.
  static func decode(status: OSStatus, data: Data?) throws -> SSHKnownHost? {
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw SSHKnownHostStoreError.keychain(status) }
    guard let data, let host = try? JSONDecoder().decode(SSHKnownHost.self, from: data) else {
      throw SSHKnownHostStoreError.undecodable
    }
    return host
  }

  /// SecItemAdd fails with errSecDuplicateItem when a pin exists, so two first-use
  /// connections cannot overwrite each other.
  @discardableResult
  func add(_ host: SSHKnownHost, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(host) else { return false }
    var attributes = baseQuery(account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  @discardableResult
  func save(_ host: SSHKnownHost, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(host) else { return false }
    let status = SecItemUpdate(
      baseQuery(account: account) as CFDictionary,
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    return add(host, account: account)
  }

  func delete(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemorySSHKnownHostStore: SSHKnownHostStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: SSHKnownHost] = [:]

  func load(account: String) throws -> SSHKnownHost? {
    lock.withLock { values[account] }
  }

  @discardableResult
  func add(_ host: SSHKnownHost, account: String) -> Bool {
    lock.withLock {
      guard values[account] == nil else { return false }
      values[account] = host
      return true
    }
  }

  @discardableResult
  func save(_ host: SSHKnownHost, account: String) -> Bool {
    lock.withLock { values[account] = host }
    return true
  }

  func delete(account: String) {
    lock.withLock { values[account] = nil }
  }
}

nonisolated enum SSHKnownHostStoreFactory {
  static let shared: any SSHKnownHostStore = makeDefault()

  static func makeDefault() -> any SSHKnownHostStore {
    SessionManager.isRunningAsTestHost
      ? InMemorySSHKnownHostStore() : KeychainSSHKnownHostStore()
  }

  /// Host names are case-insensitive; the port is part of the identity.
  static func account(host: String, port: Int) -> String {
    KeychainAccount.v2([host.lowercased(), String(port)])
  }

  /// A changed algorithm counts as a changed key: it blocks the connection.
  static func evaluate(
    presented: (algorithm: String, fingerprint: String), stored: SSHKnownHost?
  ) -> SSHHostKeyVerdict {
    guard let stored else { return .unknown }
    guard stored.algorithm == presented.algorithm, stored.fingerprint == presented.fingerprint
    else { return .changed(stored: stored) }
    return .trusted
  }
}
