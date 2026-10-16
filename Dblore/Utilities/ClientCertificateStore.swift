import Foundation
import Security

/// PEM bytes live only in the Keychain, never in ConnectionConfig or backup providers.
/// Certificate and key come together or not at all (a custom CA alone has neither).
nonisolated struct ClientCertificateMaterial: Codable, Equatable, Sendable {
  var certificatePEM: String?
  var privateKeyPEM: String?
  var caPEM: String?
  var passphrase: String?

  init(
    certificatePEM: String? = nil, privateKeyPEM: String? = nil,
    caPEM: String? = nil, passphrase: String? = nil
  ) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
    self.caPEM = caPEM
    self.passphrase = passphrase
  }
}

/// Length-prefixed Keychain account keys, so ":" or "|" inside a part cannot collide.
nonisolated enum KeychainAccount {
  static func v2(_ parts: [String]) -> String {
    "v2|" + parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

nonisolated protocol ClientCertificateStore: AnyObject, Sendable {
  func load(account: String) -> ClientCertificateMaterial?
  @discardableResult func save(_ material: ClientCertificateMaterial, account: String) -> Bool
  func delete(account: String)
}

/// One JSON payload per connection identity. This-device-only Keychain items do not migrate.
nonisolated final class KeychainClientCertificateStore: ClientCertificateStore, Sendable {
  static let serviceName = "ace.thi.dblore.client-certificate"

  private static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func load(account: String) -> ClientCertificateMaterial? {
    guard case .found(let data) = Self.vault.read(account: account) else { return nil }
    return try? JSONDecoder().decode(ClientCertificateMaterial.self, from: data)
  }

  @discardableResult
  func save(_ material: ClientCertificateMaterial, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(material) else { return false }
    return Self.vault.write(account: account, data: data) == errSecSuccess
  }

  func delete(account: String) {
    Self.vault.delete(account: account)
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemoryClientCertificateStore: ClientCertificateStore, @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [String: ClientCertificateMaterial] = [:]

  func load(account: String) -> ClientCertificateMaterial? {
    lock.withLock { values[account] }
  }

  @discardableResult
  func save(_ material: ClientCertificateMaterial, account: String) -> Bool {
    lock.withLock { values[account] = material }
    return true
  }

  func delete(account: String) {
    lock.withLock { values[account] = nil }
  }
}

nonisolated enum ClientCertificateStoreFactory {
  static let shared: any ClientCertificateStore = makeDefault()

  struct ConnectionMaterial: Sendable, Equatable {
    let account: String
    let material: ClientCertificateMaterial
  }

  final class ScopedMaterial: @unchecked Sendable {
    let account: String
    private let lock = NSLock()
    private var storage: ClientCertificateMaterial?

    init(account: String, material: ClientCertificateMaterial) {
      self.account = account
      storage = material
    }

    var material: ClientCertificateMaterial? { lock.withLock { storage } }

    func clear() { lock.withLock { storage = nil } }
  }

  @TaskLocal static var operationMaterial: ScopedMaterial?

  static func currentMaterial(for config: ConnectionConfig) -> ConnectionMaterial? {
    let account = account(for: config)
    guard let scoped = operationMaterial, scoped.account == account,
      let material = scoped.material
    else { return nil }
    return ConnectionMaterial(account: account, material: material)
  }

  static func makeDefault() -> any ClientCertificateStore {
    SessionManager.isRunningAsTestHost
      ? InMemoryClientCertificateStore() : KeychainClientCertificateStore()
  }

  static func account(for config: ConnectionConfig) -> String {
    ConnectionKeychainKey.certificateAccount(for: config)
  }

  static func load(
    for config: ConnectionConfig, from store: any ClientCertificateStore = shared
  ) -> ClientCertificateMaterial? {
    let account = account(for: config)
    if let scoped = operationMaterial, scoped.account == account,
      let material = scoped.material
    {
      return material
    }
    return store.load(account: account)
  }

  @discardableResult
  static func persistOperationMaterial(
    for config: ConnectionConfig, to store: any ClientCertificateStore = shared
  ) -> Bool {
    let account = account(for: config)
    guard config.clientCertificate != nil, config.rememberConnection,
      let scoped = operationMaterial, scoped.account == account,
      let material = scoped.material
    else { return true }
    return store.save(material, account: account)
  }

  static func delete(
    for config: ConnectionConfig, from store: any ClientCertificateStore = shared
  ) {
    store.delete(account: account(for: config))
  }
}
