import Foundation
import Security

/// The SSH secret for one connection. A key is stored decrypted; its passphrase never is.
nonisolated enum SSHStoredCredential: Codable, Equatable, Sendable {
  case password(String)
  case privateKey(keychainRepresentation: Data)
}

nonisolated protocol SSHCredentialStore: AnyObject, Sendable {
  func load(account: String) -> SSHStoredCredential?
  @discardableResult func save(_ credential: SSHStoredCredential, account: String) -> Bool
  func delete(account: String)
}

/// One JSON payload per connection identity. This-device-only Keychain items do not migrate.
nonisolated final class KeychainSSHCredentialStore: SSHCredentialStore, Sendable {
  static let serviceName = "ace.thi.dblore.ssh-credential"

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load(account: String) -> SSHStoredCredential? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(SSHStoredCredential.self, from: data)
  }

  @discardableResult
  func save(_ credential: SSHStoredCredential, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(credential) else { return false }
    let status = SecItemUpdate(
      baseQuery(account: account) as CFDictionary,
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var attributes = baseQuery(account: account)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  func delete(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemorySSHCredentialStore: SSHCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: SSHStoredCredential] = [:]

  func load(account: String) -> SSHStoredCredential? {
    lock.withLock { values[account] }
  }

  @discardableResult
  func save(_ credential: SSHStoredCredential, account: String) -> Bool {
    lock.withLock { values[account] = credential }
    return true
  }

  func delete(account: String) {
    lock.withLock { values[account] = nil }
  }
}

nonisolated enum SSHCredentialStoreFactory {
  static let shared: any SSHCredentialStore = makeDefault()

  static func makeDefault() -> any SSHCredentialStore {
    SessionManager.isRunningAsTestHost
      ? InMemorySSHCredentialStore() : KeychainSSHCredentialStore()
  }

  /// Engine and bastion are part of the identity, so they never share a secret.
  static func account(
    databaseType: DatabaseType, host: String, port: Int, database: String, username: String,
    sshHost: String, sshPort: Int, sshUsername: String
  ) -> String {
    KeychainAccount.v2([
      databaseType.rawValue, host, String(port), database, username,
      sshHost, String(sshPort), sshUsername,
    ])
  }

  /// Nil when the connection has no SSH tunnel.
  static func account(for config: ConnectionConfig) -> String? {
    guard let tunnel = config.sshTunnel else { return nil }
    return account(
      databaseType: config.databaseType, host: config.host, port: config.port,
      database: config.database, username: config.username,
      sshHost: tunnel.host, sshPort: tunnel.port, sshUsername: tunnel.username)
  }
}
