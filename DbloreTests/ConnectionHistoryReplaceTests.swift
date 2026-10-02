// Replacing one recent connection keeps its id and moves the stored password with the key.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection history replace")
@MainActor
struct ConnectionHistoryReplaceTests {
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
