import Foundation
import Testing

@testable import Dblore

@Suite("Client certificate store")
@MainActor
struct ClientCertificateStoreTests {
  private let material = ClientCertificateMaterial(
    certificatePEM: "-----BEGIN CERTIFICATE-----\nclient-secret-cert\n-----END CERTIFICATE-----",
    privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nclient-secret-key\n-----END PRIVATE KEY-----",
    caPEM: "-----BEGIN CERTIFICATE-----\nca-secret-cert\n-----END CERTIFICATE-----",
    passphrase: "private-passphrase")

  @Test("An account includes host, port, database, and username")
  func accountIdentity() {
    let config = ConnectionConfig(
      host: "db.example", port: 6432, database: "analytics", username: "ada")
    #expect(ClientCertificateStoreFactory.account(for: config).contains("db.example"))
    #expect(ClientCertificateStoreFactory.account(for: config) != "db.example:6432:analytics:ada")
  }

  @Test("Colon-containing database and username cannot share an account")
  func accountComponentsCannotCollide() {
    let first = ConnectionConfig(host: "db", port: 5432, database: "a:b", username: "c")
    let second = ConnectionConfig(host: "db", port: 5432, database: "a", username: "b:c")
    #expect(
      ClientCertificateStoreFactory.account(for: first)
        != ClientCertificateStoreFactory.account(for: second))
  }

  @Test("A scoped probe does not change saved certificate material")
  func probeMaterialIsScoped() async {
    var config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    config.clientCertificate = ClientCertificateInfo(subject: "saved", expiry: nil, hasCA: false)
    let store = InMemoryClientCertificateStore()
    let account = ClientCertificateStoreFactory.account(for: config)
    let draft = ClientCertificateMaterial(certificatePEM: "draft", privateKeyPEM: "draft-key")
    #expect(store.save(material, account: account))
    ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: draft)
    ) {
      #expect(ClientCertificateStoreFactory.load(for: config, from: store) == draft)
    }
    #expect(store.load(account: account) == material)
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
  }

  @Test("Remember off scopes a draft without shadowing a saved certificate afterward")
  func rememberOffDoesNotPersist() {
    var config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    config.rememberConnection = false
    config.clientCertificate = ClientCertificateInfo(subject: "draft", expiry: nil, hasCA: false)
    let store = InMemoryClientCertificateStore()
    let account = ClientCertificateStoreFactory.account(for: config)
    let saved = ClientCertificateMaterial(certificatePEM: "saved", privateKeyPEM: "saved-key")
    #expect(store.save(saved, account: account))
    ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
      #expect(ClientCertificateStoreFactory.persistOperationMaterial(for: config, to: store))
    }
    #expect(store.load(account: account) == saved)
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == saved)
  }

  @Test("A failed operation releases the draft and restores saved material")
  func failedOperationDoesNotShadowSavedCertificate() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let store = InMemoryClientCertificateStore()
    let account = ClientCertificateStoreFactory.account(for: config)
    let saved = ClientCertificateMaterial(certificatePEM: "saved", privateKeyPEM: "saved-key")
    #expect(store.save(saved, account: account))
    ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
    }
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == saved)
  }

  @Test("Inherited TaskLocal cannot retain a completed operation's private key")
  func completedOperationRevokesInheritedMaterial() async {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let store = InMemoryClientCertificateStore()
    let account = ClientCertificateStoreFactory.account(for: config)
    let saved = ClientCertificateMaterial(certificatePEM: "saved", privateKeyPEM: "saved-key")
    #expect(store.save(saved, account: account))
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(account: account, material: material)
    let inherited = ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      Task { ClientCertificateStoreFactory.load(for: config, from: store) }
    }
    scoped.clear()
    #expect(scoped.material == nil)
    #expect(await inherited.value == saved)
  }

  @Test("An unambiguous old account is read and moved to the new account")
  func legacyLookup() {
    var config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    config.clientCertificate = ClientCertificateInfo(subject: "saved", expiry: nil, hasCA: false)
    let store = InMemoryClientCertificateStore()
    #expect(store.save(material, account: "db:5432:app:ada"))
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
    #expect(store.load(account: ClientCertificateStoreFactory.account(for: config)) == material)
    #expect(store.load(account: "db:5432:app:ada") == nil)
  }

  @Test("A failed copy keeps the old account and still returns its material")
  func legacyCopyFailureKeepsOldAccount() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let inner = InMemoryClientCertificateStore()
    #expect(inner.save(material, account: "db:5432:app:ada"))
    let store = FailingSaveStore(inner: inner)
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
    #expect(inner.load(account: "db:5432:app:ada") == material)
    #expect(inner.load(account: ClientCertificateStoreFactory.account(for: config)) == nil)
  }

  @Test("When both accounts exist the new account wins")
  func newAccountWinsOverLegacy() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let store = InMemoryClientCertificateStore()
    let legacy = ClientCertificateMaterial(certificatePEM: "old", privateKeyPEM: "old-key")
    #expect(store.save(legacy, account: "db:5432:app:ada"))
    #expect(store.save(material, account: ClientCertificateStoreFactory.account(for: config)))
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == material)
    #expect(store.load(account: ClientCertificateStoreFactory.account(for: config)) == material)
  }

  @Test("Certificate material is encoded as JSON with the four fields")
  func jsonPayload() throws {
    let data = try JSONEncoder().encode(material)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(object["certificatePEM"] == material.certificatePEM)
    #expect(object["privateKeyPEM"] == material.privateKeyPEM)
    #expect(object["caPEM"] == material.caPEM)
    #expect(object["passphrase"] == material.passphrase)
    #expect(try JSONDecoder().decode(ClientCertificateMaterial.self, from: data) == material)
  }

  @Test("In-memory store replaces and deletes one account without affecting another")
  func inMemoryRoundTrip() {
    let store = InMemoryClientCertificateStore()
    let second = ClientCertificateMaterial(
      certificatePEM: "second-cert", privateKeyPEM: "second-key")
    #expect(store.save(material, account: "one"))
    #expect(store.save(second, account: "two"))
    #expect(store.load(account: "one") == material)
    #expect(store.save(second, account: "one"))
    #expect(store.load(account: "one") == second)
    store.delete(account: "one")
    #expect(store.load(account: "one") == nil)
    #expect(store.load(account: "two") == second)
  }

  @Test("The test host never opens the Keychain store")
  func defaultStoreIsInMemory() {
    #expect(ClientCertificateStoreFactory.makeDefault() is InMemoryClientCertificateStore)
    #expect(KeychainClientCertificateStore.serviceName == "ace.thi.dblore.client-certificate")
  }
}

/// Reads and deletes through `inner`; every save fails, like a Keychain write error.
nonisolated private final class FailingSaveStore: ClientCertificateStore, @unchecked Sendable {
  let inner: InMemoryClientCertificateStore

  init(inner: InMemoryClientCertificateStore) { self.inner = inner }

  func load(account: String) -> ClientCertificateMaterial? { inner.load(account: account) }

  func save(_ material: ClientCertificateMaterial, account: String) -> Bool { false }

  func delete(account: String) { inner.delete(account: account) }
}
