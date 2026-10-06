// Replacing one recent connection keeps its id and moves the stored password with the key.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection history replace")
@MainActor
struct ConnectionHistoryReplaceTests {
  @Test("Deleting one of two saved references retains the certificate")
  func sharedCertificateSurvivesOneRemoval() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let certificates = InMemoryClientCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: true, name: "First")
    config.clientCertificate = ClientCertificateInfo(subject: "client", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    let material = ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key")
    #expect(certificates.save(material, account: account))
    let first = ConnectionHistoryEntry(config: config)
    config.name = "Second"
    let second = ConnectionHistoryEntry(config: config)
    harness.defaults.set(
      try JSONEncoder().encode([first, second]),
      forKey: "ace.thi.dblore.connectionHistory")

    SessionManager.removeConnection(
      id: first.id, defaults: harness.defaults, passwords: harness.store,
      certificates: certificates)
    #expect(certificates.load(account: account) == material)
    SessionManager.removeConnection(
      id: second.id, defaults: harness.defaults, passwords: harness.store,
      certificates: certificates)
    #expect(certificates.load(account: account) == nil)
  }

  @Test("A pasted line break in the name is saved as one line")
  func savedNameIsSingleLine() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let config = ConnectionConfig(
      host: "localhost", port: 5435, database: "dblore_test", username: "dblore_test",
      rememberConnection: true, name: "dblore-postgres-test\n\n\ndblore-postgres-test\n")
    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let saved = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    #expect(saved.config.name == "dblore-postgres-test dblore-postgres-test")

    var renamed = saved.config
    renamed.name = "a\nb"
    SessionManager.replaceConnection(
      id: saved.id, with: renamed, defaults: harness.defaults, passwords: harness.store)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first?
        .config.name == "a b")
  }

  @Test("Clear history removes its saved certificate")
  func clearCertificate() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let certificates = InMemoryClientCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: true)
    config.clientCertificate = ClientCertificateInfo(subject: "client", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    #expect(
      certificates.save(
        ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key"), account: account))
    SessionManager.saveConnection(
      config, defaults: harness.defaults, passwords: harness.store, certificates: certificates)
    SessionManager.clearAllHistory(
      defaults: harness.defaults, passwords: harness.store, certificates: certificates)
    #expect(certificates.load(account: account) == nil)
  }

  @Test("Saving a certificate commits pending material only for remembered connections")
  func pendingMaterialLifecycle() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let certificates = InMemoryClientCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: false)
    config.clientCertificate = ClientCertificateInfo(subject: "client", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    let material = ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key")
    ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      #expect(
        SessionManager.saveConnection(
          config, defaults: harness.defaults, passwords: harness.store,
          certificates: certificates))
    }
    #expect(certificates.load(account: account) == nil)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).isEmpty)

    config.rememberConnection = true
    ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: material)
    ) {
      #expect(
        SessionManager.saveConnection(
          config, defaults: harness.defaults, passwords: harness.store,
          certificates: certificates))
    }
    #expect(certificates.load(account: account) == material)
  }

  @Test("Certificate write failure preserves prior history and certificate")
  func certificateWriteFailureDoesNotSaveHistory() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let store = RejectingCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: true)
    config.clientCertificate = ClientCertificateInfo(subject: "client", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    let old = ClientCertificateMaterial(certificatePEM: "old", privateKeyPEM: "old-key")
    store.existing = old
    let originalEntry = ConnectionHistoryEntry(config: config)
    harness.defaults.set(
      try JSONEncoder().encode([originalEntry]),
      forKey: "ace.thi.dblore.connectionHistory")
    config.clientCertificate = ClientCertificateInfo(subject: "new", expiry: nil, hasCA: false)
    let draft = ClientCertificateMaterial(certificatePEM: "new", privateKeyPEM: "new-key")
    let oldHistory = SessionManager.loadHistory(
      defaults: harness.defaults, passwords: harness.store)
    let saved = ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: draft)
    ) {
      SessionManager.saveConnection(
        config, defaults: harness.defaults, passwords: harness.store, certificates: store)
    }
    #expect(!saved)
    #expect(store.load(account: account) == old)
    #expect(
      SessionManager.loadHistory(
        defaults: harness.defaults, passwords: harness.store
      ).map(\.id) == oldHistory.map(\.id))
    #expect(
      SessionManager.loadHistory(
        defaults: harness.defaults, passwords: harness.store
      ).first?.config.clientCertificate?.subject
        == "client")
  }

  @Test("Saved-card edit reports certificate failure and keeps the original card")
  func replaceCertificateFailureKeepsHistory() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let store = RejectingCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: true, name: "Original")
    config.clientCertificate = ClientCertificateInfo(subject: "old", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    let old = ClientCertificateMaterial(certificatePEM: "old", privateKeyPEM: "old-key")
    store.existing = old
    let entry = ConnectionHistoryEntry(config: config)
    harness.defaults.set(
      try JSONEncoder().encode([entry]),
      forKey: "ace.thi.dblore.connectionHistory")
    config.name = "Edited"
    config.clientCertificate = ClientCertificateInfo(subject: "new", expiry: nil, hasCA: false)
    let draft = ClientCertificateMaterial(certificatePEM: "new", privateKeyPEM: "new-key")

    let saved = ClientCertificateStoreFactory.$operationMaterial.withValue(
      .init(account: account, material: draft)
    ) {
      SessionManager.replaceConnection(
        id: entry.id, with: config, defaults: harness.defaults, passwords: harness.store,
        certificates: store)
    }
    #expect(!saved)
    #expect(store.load(account: account) == old)
    let after = try #require(
      SessionManager.loadHistory(
        defaults: harness.defaults, passwords: harness.store
      ).first)
    #expect(after.id == entry.id)
    #expect(after.config.name == "Original")
    #expect(after.config.clientCertificate?.subject == "old")
  }

  private final class RejectingCertificateStore: ClientCertificateStore, @unchecked Sendable {
    var existing: ClientCertificateMaterial?
    func load(account: String) -> ClientCertificateMaterial? { existing }
    func save(_ material: ClientCertificateMaterial, account: String) -> Bool { false }
    func delete(account: String) { existing = nil }
  }

  @Test("Removing certificate metadata deletes old material after a saved edit")
  func replaceRemovesCertificate() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let certificates = InMemoryClientCertificateStore()
    var config = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      rememberConnection: true)
    config.clientCertificate = ClientCertificateInfo(subject: "client", expiry: nil, hasCA: false)
    let account = ClientCertificateStoreFactory.account(for: config)
    #expect(
      certificates.save(
        ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key"), account: account))
    SessionManager.saveConnection(
      config, defaults: harness.defaults, passwords: harness.store, certificates: certificates)
    let entry = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    config.clientCertificate = nil
    SessionManager.replaceConnection(
      id: entry.id, with: config, defaults: harness.defaults, passwords: harness.store,
      certificates: certificates)
    #expect(certificates.load(account: account) == nil)
  }

  @Test("Replace keeps the row id and position and moves the password")
  func replaceMovesPassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let older = ConnectionConfig(
      host: "old-host", port: 5432, database: "app", username: "ada",
      password: "older", rememberConnection: true, name: "Older")
    let original = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      password: "s3cret", rememberConnection: true, name: "Production")
    SessionManager.saveConnection(older, defaults: harness.defaults, passwords: harness.store)
    SessionManager.saveConnection(original, defaults: harness.defaults, passwords: harness.store)

    let before = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    let entry = try #require(before.first)
    let olderID = try #require(before.last?.id)
    let edited = ConnectionConfig(
      host: "db.other", port: 5433, database: "app", username: "ada",
      password: "next", rememberConnection: true, name: "Renamed")

    SessionManager.replaceConnection(
      id: entry.id, with: edited, defaults: harness.defaults, passwords: harness.store)

    let after = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(after.map(\.id) == [entry.id, olderID])
    #expect(after.first?.lastUsedAt == entry.lastUsedAt)
    #expect(after.first?.config.name == "Renamed")
    #expect(after.first?.config.host == "db.other")
    #expect(after.first?.config.port == 5433)
    #expect(after.first?.config.password == "next")
    #expect(after.last?.config.password == "older")
    #expect(harness.store.savedKeys.contains("db.other:5433:app:ada"))
    #expect(harness.store.deletedKeys.contains("db.example:5432:app:ada"))
  }

  @Test("An empty password deletes the stored one")
  func emptyPasswordDeletes() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let original = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      password: "s3cret", rememberConnection: true, name: "Production")
    SessionManager.saveConnection(original, defaults: harness.defaults, passwords: harness.store)
    let entry = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    var cleared = original
    cleared.password = ""

    SessionManager.replaceConnection(
      id: entry.id, with: cleared, defaults: harness.defaults, passwords: harness.store)

    let after = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(after.first?.id == entry.id)
    #expect(after.first?.config.password.isEmpty == true)
    #expect(harness.store.deletedKeys.contains(entry.keychainKey))
  }

  @Test("Remember off removes the card and its password")
  func rememberOffRemoves() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let original = ConnectionConfig(
      host: "db.example", port: 5432, database: "app", username: "ada",
      password: "s3cret", rememberConnection: true, name: "Production")
    SessionManager.saveConnection(original, defaults: harness.defaults, passwords: harness.store)
    let entry = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    var forgotten = original
    forgotten.rememberConnection = false

    SessionManager.replaceConnection(
      id: entry.id, with: forgotten, defaults: harness.defaults, passwords: harness.store)

    let after = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(after.isEmpty)
    #expect(harness.store.deletedKeys.contains(entry.keychainKey))
  }

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.connection-replace.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
