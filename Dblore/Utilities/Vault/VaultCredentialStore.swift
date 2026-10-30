// VaultCredentialStore.swift
// The Vault secret of a connection: a token, or an AppRole role id and secret id (the role id
// lives only here, never in ConnectionConfig). One Keychain item per connection identity under
// ace.thi.dblore.vault, this device only; session only when the Keychain refuses the write (no
// data protection keychain in ad hoc builds). The test host gets the in-memory store. Every
// store call may read or write the Keychain: call it off the main actor. Secrets are never
// logged. A secret is bound to the destination it was entered for (`destination(for:)`): a
// config whose Vault address, CA, auth method, mount, role, SSH hop or TLS mode differs never
// gets it, so a workspace file copying the identity cannot send it elsewhere.

import CryptoKit
import Foundation
import Security

/// How Dblore signs in to Vault for one connection.
nonisolated enum VaultSecret: Equatable, Sendable {
  case token(String)
  case appRole(roleID: String, secretID: String)
}

/// A secret with the destination it is bound to (`VaultCredentialStore.destination(for:)`).
nonisolated struct VaultStoredSecret: Equatable, Sendable {
  let secret: VaultSecret
  let destination: String
}

/// Keychain JSON: `{"token", "destination"}` or `{"roleId", "secretId", "destination"}`. This
/// format is permanent; an item without a destination does not decode, so it is never used.
nonisolated extension VaultStoredSecret: Codable {
  private enum CodingKeys: String, CodingKey {
    case token, roleId, secretId, destination
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    destination = try container.decode(String.self, forKey: .destination)
    if let token = try container.decodeIfPresent(String.self, forKey: .token) {
      secret = .token(token)
    } else {
      secret = .appRole(
        roleID: try container.decode(String.self, forKey: .roleId),
        secretID: try container.decode(String.self, forKey: .secretId))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch secret {
    case .token(let token):
      try container.encode(token, forKey: .token)
    case .appRole(let roleID, let secretID):
      try container.encode(roleID, forKey: .roleId)
      try container.encode(secretID, forKey: .secretId)
    }
    try container.encode(destination, forKey: .destination)
  }
}

/// Where a save landed: the Keychain, or this session only (the Keychain refused the write).
nonisolated enum VaultSecretSave: Equatable, Sendable {
  case keychain
  case sessionOnly
}

nonisolated protocol VaultSecretStore: AnyObject, Sendable {
  func load(account: String) -> VaultStoredSecret?
  @discardableResult func save(_ secret: VaultStoredSecret, account: String) -> VaultSecretSave
  func delete(account: String)
  /// The account's secret lasts this session only
  func isSessionOnly(account: String) -> Bool
}

nonisolated final class KeychainVaultSecretStore: VaultSecretStore, @unchecked Sendable {
  static let serviceName = "ace.thi.dblore.vault"

  private let vault: KeychainVault
  private let lock = NSLock()
  /// Secrets the Keychain refused, by account
  private var session: [String: VaultStoredSecret] = [:]

  init(
    vault: KeychainVault = KeychainVault(
      service: KeychainVaultSecretStore.serviceName,
      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
  ) {
    self.vault = vault
  }

  /// A session-only secret is newer than any Keychain copy.
  func load(account: String) -> VaultStoredSecret? {
    lock.withLock {
      if let secret = session[account] { return secret }
      guard case .found(let data) = vault.read(account: account) else { return nil }
      return try? JSONDecoder().decode(VaultStoredSecret.self, from: data)
    }
  }

  @discardableResult
  func save(_ secret: VaultStoredSecret, account: String) -> VaultSecretSave {
    lock.withLock {
      if let data = try? JSONEncoder().encode(secret),
        vault.write(account: account, data: data) == errSecSuccess
      {
        session[account] = nil
        return .keychain
      }
      session[account] = secret
      return .sessionOnly
    }
  }

  func delete(account: String) {
    lock.withLock {
      session[account] = nil
      vault.delete(account: account)
    }
  }

  func isSessionOnly(account: String) -> Bool {
    lock.withLock { session[account] != nil }
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemoryVaultSecretStore: VaultSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: VaultStoredSecret] = [:]

  func load(account: String) -> VaultStoredSecret? {
    lock.withLock { values[account] }
  }

  @discardableResult
  func save(_ secret: VaultStoredSecret, account: String) -> VaultSecretSave {
    lock.withLock { values[account] = secret }
    return .keychain
  }

  func delete(account: String) {
    lock.withLock { values[account] = nil }
  }

  func isSessionOnly(account: String) -> Bool { false }
}

/// The Vault secret of a connection: the operation's scoped secret (the form's draft, a side
/// manager's re-keyed one), else the stored one, either only for the destination it is bound to.
/// Lease, Test Connection and side managers read only through `load(for:)` / `lookup(for:)`.
nonisolated enum VaultCredentialStore {
  static let shared: any VaultSecretStore = makeDefault()

  static func makeDefault() -> any VaultSecretStore {
    SessionManager.isRunningAsTestHost ? InMemoryVaultSecretStore() : KeychainVaultSecretStore()
  }

  /// The account of a connection's Keychain key (`ConnectionKeychainKey.password(for:)`).
  static func account(keychainKey: String) -> String {
    KeychainAccount.v2([keychainKey])
  }

  /// Nil when the connection has no Vault source.
  static func account(for config: ConnectionConfig) -> String? {
    guard config.vault != nil else { return nil }
    return account(keychainKey: ConnectionKeychainKey.password(for: config))
  }

  /// Where a secret may go, beyond the account's host, port, database and user: SHA-256 (hex)
  /// of the Vault address (scheme and host lowercased, port, path without a trailing "/"), the
  /// CA PEM without whitespace, the auth method, mount and role, the SSH hop (host, port, user)
  /// and the TLS mode. The database and user are left out, so a side manager on another
  /// database of the connection keeps the secret. Nil without a Vault source.
  static func destination(for config: ConnectionConfig) -> String? {
    guard let vault = config.vault else { return nil }
    let address = vault.address.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URLComponents(string: address)
    var path = url?.percentEncodedPath ?? ""
    while path.hasSuffix("/") { path.removeLast() }
    let parts = [
      url?.scheme?.lowercased() ?? address, url?.percentEncodedHost?.lowercased() ?? "",
      url?.port.map(String.init) ?? "", path,
      (vault.caPEM ?? "").filter { !$0.isWhitespace }, vault.authMethod.rawValue, vault.mount,
      vault.role, config.sshTunnel?.host ?? "", config.sshTunnel.map { String($0.port) } ?? "",
      config.sshTunnel?.username ?? "", config.sslMode.rawValue,
    ]
    let digest = SHA256.hash(data: Data(KeychainAccount.v2(parts).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// A secret for one connection, kept while an unremembered connection is open
  /// (`DatabaseConnectionManager.activeUnrememberedVaultSecret`).
  struct ConnectionSecret: Sendable, Equatable {
    let account: String
    let destination: String
    let secret: VaultSecret
  }

  /// Cleared when the operation ends, so a task that inherited it cannot keep using it.
  final class ScopedSecret: @unchecked Sendable {
    let account: String
    let destination: String
    private let lock = NSLock()
    private var storage: VaultSecret?

    init(account: String, destination: String, secret: VaultSecret) {
      self.account = account
      self.destination = destination
      storage = secret
    }

    convenience init(_ secret: ConnectionSecret) {
      self.init(account: secret.account, destination: secret.destination, secret: secret.secret)
    }

    var secret: VaultSecret? { lock.withLock { storage } }

    func clear() { lock.withLock { storage = nil } }
  }

  @TaskLocal static var operationSecret: ScopedSecret?

  /// What `lookup(for:)` found
  enum Lookup: Equatable, Sendable {
    case found(VaultSecret)
    /// A secret of the account exists, bound to another destination
    case destinationChanged
    case missing
  }

  /// The scoped secret when it belongs to `config`'s account and destination.
  static func currentSecret(for config: ConnectionConfig) -> ConnectionSecret? {
    guard let account = account(for: config), let destination = destination(for: config),
      let scoped = operationSecret, scoped.account == account,
      scoped.destination == destination, let secret = scoped.secret
    else { return nil }
    return ConnectionSecret(account: account, destination: destination, secret: secret)
  }

  /// The scoped secret of `config`'s account, else the stored one, when bound to `config`'s
  /// destination. A scoped secret of the account bound elsewhere is not passed over for the
  /// stored one.
  static func lookup(
    for config: ConnectionConfig, from store: any VaultSecretStore = shared
  ) -> Lookup {
    guard let account = account(for: config), let destination = destination(for: config) else {
      return .missing
    }
    if let scoped = operationSecret, scoped.account == account, let secret = scoped.secret {
      return scoped.destination == destination ? .found(secret) : .destinationChanged
    }
    guard let stored = store.load(account: account) else { return .missing }
    return stored.destination == destination ? .found(stored.secret) : .destinationChanged
  }

  /// `lookup(for:)`'s secret; nil when missing or bound to another destination.
  static func load(
    for config: ConnectionConfig, from store: any VaultSecretStore = shared
  ) -> VaultSecret? {
    guard case .found(let secret) = lookup(for: config, from: store) else { return nil }
    return secret
  }

  /// Saves `secret` for `config`'s account, bound to its destination. Nil without a Vault
  /// source.
  @discardableResult
  static func save(
    _ secret: VaultSecret, for config: ConnectionConfig, to store: any VaultSecretStore = shared
  ) -> VaultSecretSave? {
    guard let account = account(for: config), let destination = destination(for: config) else {
      return nil
    }
    return store.save(VaultStoredSecret(secret: secret, destination: destination), account: account)
  }

  /// Saves the scoped secret of a remembered Vault connection. Nil when there is nothing to
  /// save.
  @discardableResult
  static func persistOperationSecret(
    for config: ConnectionConfig, to store: any VaultSecretStore = shared
  ) -> VaultSecretSave? {
    guard config.rememberConnection, let current = currentSecret(for: config) else { return nil }
    return save(current.secret, for: config, to: store)
  }

  /// Wraps `secret` for `config`'s account, bound to the destination of `boundTo` (`config`
  /// when nil: the config the secret was found or entered for). Nil without a secret or a Vault
  /// source.
  static func scoped(
    _ secret: VaultSecret?, for config: ConnectionConfig, boundTo source: ConnectionConfig? = nil
  ) -> ScopedSecret? {
    guard let secret, let account = account(for: config),
      let destination = destination(for: source ?? config)
    else { return nil }
    return ScopedSecret(account: account, destination: destination, secret: secret)
  }

  /// The stored secret of `config` lasts this session only.
  static func isSessionOnly(
    for config: ConnectionConfig, in store: any VaultSecretStore = shared
  ) -> Bool {
    guard let account = account(for: config) else { return false }
    return store.isSessionOnly(account: account)
  }
}
