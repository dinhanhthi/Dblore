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

  @Test("The account string format is stable across releases")
  func accountLiteralIsPinned() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    #expect(ClientCertificateStoreFactory.account(for: config) == "v2|2:db|4:5432|3:app|3:ada")
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

  @Test("An item stored only under the old colon account is not read")
  func oldColonAccountIsIgnored() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let store = InMemoryClientCertificateStore()
    #expect(store.save(material, account: "db:5432:app:ada"))
    #expect(ClientCertificateStoreFactory.load(for: config, from: store) == nil)
    #expect(store.load(account: "db:5432:app:ada") == material)
    #expect(store.load(account: ClientCertificateStoreFactory.account(for: config)) == nil)
  }

  @Test("Delete removes only the new account")
  func deleteTouchesOnlyNewAccount() {
    let config = ConnectionConfig(host: "db", port: 5432, database: "app", username: "ada")
    let store = InMemoryClientCertificateStore()
    let legacy = ClientCertificateMaterial(certificatePEM: "old", privateKeyPEM: "old-key")
    #expect(store.save(legacy, account: "db:5432:app:ada"))
    #expect(store.save(material, account: ClientCertificateStoreFactory.account(for: config)))
    ClientCertificateStoreFactory.delete(for: config, from: store)
    #expect(store.load(account: ClientCertificateStoreFactory.account(for: config)) == nil)
    #expect(store.load(account: "db:5432:app:ada") == legacy)
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
