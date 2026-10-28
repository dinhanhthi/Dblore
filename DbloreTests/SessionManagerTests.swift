//
//  SessionManagerTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

@Suite("SessionManager launch restore")
@MainActor
struct SessionManagerTests {
  // MARK: - Unknown engine entries

  private static let historyKey = "ace.thi.dblore.connectionHistory"

  @Test("History with an unknown engine still loads the known entry")
  func unknownEntryDoesNotHideKnownOnes() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    try harness.write(valid: valid, unknown: Self.unknownEntry())

    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(loaded.map(\.id) == [valid.id])
  }

  @Test("Save and remove keep the unknown entry unchanged")
  func saveAndRemoveKeepUnknownEntry() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    let unknown = try Self.unknownEntry()
    try harness.write(valid: valid, unknown: unknown)

    SessionManager.saveConnection(
      ConnectionConfig(host: "other", database: "app", username: "ada", password: "pw"),
      defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).count == 2)

    let replaced = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)
    var renamed = replaced.config
    renamed.name = "Renamed"
    SessionManager.replaceConnection(
      id: replaced.id, with: renamed, defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])

    SessionManager.removeConnection(
      id: valid.id, defaults: harness.defaults, passwords: harness.store)
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).map(
        \.config.name) == ["Renamed"])
  }

  @Test("Reconnecting a saved row keeps its id, so settings keyed by id (MCP allowlist) survive")
  func resaveKeepsRowID() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    var config = ConnectionConfig(host: "db.example", database: "app", username: "ada")
    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let saved = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    config.name = "Reconnected"
    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let reloaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(reloaded.map(\.id) == [saved.id])
    #expect(reloaded.first?.config.name == "Reconnected")

    // Another engine on the same unscoped key is another connection: its save is refused
    var sqlite = config
    sqlite.databaseType = .sqlite
    #expect(
      ConnectionKeychainKey.password(for: sqlite) == ConnectionKeychainKey.password(for: config))
    #expect(SessionManager.keyUsedByAnotherIdentity(sqlite, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(sqlite, defaults: harness.defaults, passwords: harness.store))
    let kept = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(kept.map(\.id) == [saved.id])
    #expect(kept.map(\.config.databaseType) == [.postgresql])
  }

  /// Same engine and user; host, port and database differ but join into the same unscoped key
  private static let collidingA = ConnectionConfig(
    host: "h", port: 5432, database: "x:6000:y", username: "ada", password: "a-secret")
  private static let collidingB = ConnectionConfig(
    host: "h:5432:x", port: 6000, database: "y", username: "ada", password: "b-secret")

  @Test("Saving a connection whose Keychain key another saved connection uses is refused")
  func saveOntoAnotherConnectionsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    #expect(ConnectionKeychainKey.password(for: Self.collidingB) == key)
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(SessionManager.keyUsedByAnotherIdentity(Self.collidingB, defaults: harness.defaults))
    #expect(!SessionManager.keyUsedByAnotherIdentity(Self.collidingA, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(
        Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    #expect(
      SessionManagerError.keychainKeyInUse.errorDescription
        == "Another saved connection uses the same Keychain entry.")

    let rows = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(rows.map(\.id) == [a.id])
    #expect(rows.first?.config.host == "h")
    #expect(rows.first?.config.password == "a-secret")
    #expect(harness.store.savedKeys == [key])
    #expect(harness.store.deletedKeys.isEmpty)

    // The same tuple under a new name is still its own row: renamed in place, same id
    var renamed = Self.collidingA
    renamed.name = "Renamed"
    #expect(
      SessionManager.saveConnection(renamed, defaults: harness.defaults, passwords: harness.store))
    let renamedRows = SessionManager.loadHistory(
      defaults: harness.defaults, passwords: harness.store)
    #expect(renamedRows.map(\.id) == [a.id])
    #expect(renamedRows.first?.config.name == "Renamed")
  }

  @Test("Retargeting a row onto another saved connection's Keychain key is refused")
  func retargetOntoAnotherConnectionsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    var elsewhere = Self.collidingB
    elsewhere.host = "elsewhere"
    for config in [Self.collidingA, elsewhere] {
      #expect(
        SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store))
    }
    let before = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    let row = try #require(before.first { $0.config.host == "elsewhere" })
    let saves = harness.store.savedKeys.count

    #expect(
      SessionManager.keyUsedByAnotherIdentity(
        Self.collidingB, excluding: row.id, defaults: harness.defaults))
    #expect(
      !SessionManager.replaceConnection(
        id: row.id, with: Self.collidingB, defaults: harness.defaults, passwords: harness.store))

    let after = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.config.host) == before.map(\.config.host))
    #expect(harness.store.loadPassword(forKey: key) == "a-secret")
    #expect(harness.store.savedKeys.count == saves)
    #expect(!harness.store.deletedKeys.contains(key))
  }

  @Test("A row moved onto its own Keychain key under another identity is not refused by itself")
  func retargetOntoOwnKeyIsNotRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(
      !SessionManager.keyUsedByAnotherIdentity(
        Self.collidingB, excluding: a.id, defaults: harness.defaults))
    #expect(
      SessionManager.replaceConnection(
        id: a.id, with: Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    let rows = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(rows.map(\.id) == [a.id])
    #expect(rows.first?.config.password == "b-secret")
  }

  @Test("Deleting a connection deletes its Keychain password")
  func removeDeletesPassword() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = ConnectionKeychainKey.password(for: Self.collidingA)
    #expect(
      SessionManager.saveConnection(
        Self.collidingA, defaults: harness.defaults, passwords: harness.store))
    #expect(
      !SessionManager.saveConnection(
        Self.collidingB, defaults: harness.defaults, passwords: harness.store))
    let a = try #require(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).first)

    #expect(
      SessionManager.removeConnection(
        id: a.id, defaults: harness.defaults, passwords: harness.store))
    #expect(harness.store.deletedKeys == [key])
    #expect(harness.store.loadPassword(forKey: key) == nil)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).isEmpty)
  }

  @Test("Saving onto the Keychain key of a row this build cannot decode is refused")
  func saveOntoUndecodableRowsKeyIsRefused() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    let unknown = try Self.unknownEntry()
    try harness.write(valid: valid, unknown: unknown)
    // The unknown engine keeps the unscoped key, which a PostgreSQL row of the same fields uses
    let colliding = ConnectionConfig(
      host: "future", database: "lake", username: "bob", password: "pw")

    #expect(SessionManager.keyUsedByAnotherIdentity(colliding, defaults: harness.defaults))
    #expect(
      !SessionManager.saveConnection(
        colliding, defaults: harness.defaults, passwords: harness.store))
    #expect(try harness.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(harness.store.savedKeys.isEmpty)
    #expect(
      SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store).map(\.id)
        == [valid.id])
  }

  @Test("Export then replace keeps the unknown entry")
  func exportReplaceRoundTripKeepsUnknownEntry() throws {
    let source = try Harness()
    let target = try Harness()
    defer {
      source.cleanup()
      target.cleanup()
    }
    let valid = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "db.example", database: "app", username: "ada"))
    var unknown = try Self.unknownEntry()
    try source.write(valid: valid, unknown: unknown)

    let snapshot = SessionManager.exportSnapshot(
      defaults: source.defaults, domainName: source.suiteName)
    SessionManager.replace(
      history: snapshot.history, legacySession: snapshot.legacy, defaults: target.defaults,
      domainName: target.suiteName)

    // Export strips password keys, so compare against the entry without them.
    var config = try #require(unknown["config"] as? [String: Any])
    config.removeValue(forKey: "password")
    unknown["config"] = config
    #expect(try target.storedUnknownEntries() == [LocalDataJSON.jsonData(from: unknown)])
    #expect(
      SessionManager.loadHistory(defaults: target.defaults, passwords: target.store).map(\.id)
        == [valid.id])
  }

  /// A saved entry from a newer build whose engine this build does not know.
  private static func unknownEntry() throws -> [String: Any] {
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(host: "future", database: "lake", username: "bob"))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    var config = try #require(object["config"] as? [String: Any])
    config["databaseType"] = "FutureEngine"
    config["futureOnlyField"] = ["nested": true]
    object["config"] = config
    return object
  }

  @MainActor
  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.session-manager.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func write(valid: ConnectionHistoryEntry, unknown: [String: Any]) throws {
      let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
      defaults.set(
        try JSONSerialization.data(withJSONObject: [validObject, unknown]),
        forKey: SessionManagerTests.historyKey)
    }

    /// Stored entries whose engine is unknown, normalized for comparison.
    func storedUnknownEntries() throws -> [Data?] {
      let data = try #require(defaults.data(forKey: SessionManagerTests.historyKey))
      let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
      return array.filter {
        ($0["config"] as? [String: Any])?["databaseType"] as? String == "FutureEngine"
      }.map { LocalDataJSON.jsonData(from: $0) }
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
