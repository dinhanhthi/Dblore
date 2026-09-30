// CapabilityGatingTests.swift
// SQLite skips Keychain save/load/delete. PostgreSQL still uses host:port:database:username.

import Foundation
import Testing

@testable import Dblore

@Suite("Capability gating")
@MainActor
struct CapabilityGatingTests {
  @Test("SQLite does not save, load, or delete a connection password")
  func sqliteSkipsPasswordStore() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let config = ConnectionConfig(
      databaseType: .sqlite,
      host: "db.example",
      port: 5432,
      database: "app",
      username: "ada",
      password: "should-not-be-stored",
      rememberConnection: true
    )

    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    let entry = try #require(loaded.first)
    #expect(entry.config.password.isEmpty)
    SessionManager.removeConnection(
      id: entry.id, defaults: harness.defaults, passwords: harness.store)

    #expect(harness.store.savedKeys.isEmpty)
    #expect(harness.store.loadedKeys.isEmpty)
    #expect(harness.store.deletedKeys.isEmpty)
  }

  @Test("PostgreSQL still stores the password under host:port:database:username")
  func postgresqlUsesExistingKey() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = "db.example:5432:app:ada"
    let config = ConnectionConfig(
      databaseType: .postgresql,
      host: "db.example",
      port: 5432,
      database: "app",
      username: "ada",
      password: "s3cret",
      rememberConnection: true
    )

    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(loaded.first?.config.password == "s3cret")
    #expect(loaded.first?.keychainKey == key)
    let entry = try #require(loaded.first)
    SessionManager.removeConnection(
      id: entry.id, defaults: harness.defaults, passwords: harness.store)

    #expect(harness.store.savedKeys == [key])
    #expect(!harness.store.loadedKeys.isEmpty)
    #expect(harness.store.loadedKeys.allSatisfy { $0 == key })
    #expect(harness.store.deletedKeys == [key])
  }

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.capability-gating.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}

/// Records password save/load/delete. Never opens the Keychain.
@MainActor
final class RecordingConnectionPasswordStore: ConnectionPasswordStore {
  private(set) var savedKeys: [String] = []
  private(set) var loadedKeys: [String] = []
  private(set) var deletedKeys: [String] = []
  private var passwords: [String: String] = [:]

  func savePassword(_ password: String, forKey key: String) {
    savedKeys.append(key)
    passwords[key] = password
  }

  func loadPassword(forKey key: String) -> String? {
    loadedKeys.append(key)
    return passwords[key]
  }

  func deletePassword(forKey key: String) {
    deletedKeys.append(key)
    passwords[key] = nil
  }
}
