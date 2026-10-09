import Foundation
import Security

/// PEM bytes live only in the Keychain, never in ConnectionConfig or backup providers.
nonisolated struct ClientCertificateMaterial: Codable, Equatable, Sendable {
  var certificatePEM: String
  var privateKeyPEM: String
  var caPEM: String?
  var passphrase: String?

  init(
    certificatePEM: String, privateKeyPEM: String,
    caPEM: String? = nil, passphrase: String? = nil
  ) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
    self.caPEM = caPEM
    self.passphrase = passphrase
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

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: account,
    ]
  }

  func load(account: String) -> ClientCertificateMaterial? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(ClientCertificateMaterial.self, from: data)
  }

  @discardableResult
  func save(_ material: ClientCertificateMaterial, account: String) -> Bool {
    guard let data = try? JSONEncoder().encode(material) else { return false }
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
    let parts = [config.host, String(config.port), config.database, config.username]
    return "v2|" + parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
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
