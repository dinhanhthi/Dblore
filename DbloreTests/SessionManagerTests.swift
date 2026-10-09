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
  @Test("Does not restore session when running under XCTest")
  func skipsRestoreUnderXCTest() {
    let environment = ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]
    #expect(SessionManager.shouldRestoreSession(environment: environment) == false)
  }

  @Test("Restores session on normal launch")
  func restoresOnNormalLaunch() {
    #expect(SessionManager.shouldRestoreSession(environment: [:]) == true)
  }

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
