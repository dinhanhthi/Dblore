// DatabaseTypeDecodingTests.swift
// A saved engine name decodes when this build knows it and fails per entry when it does not.

import Foundation
import Testing

@testable import Dblore

@Suite("Database type decoding")
@MainActor
struct DatabaseTypeDecodingTests {
  @Test("Every known raw value decodes", arguments: DatabaseType.allCases)
  func knownRawValueDecodes(type: DatabaseType) throws {
    let data = try JSONEncoder().encode([type.rawValue])
    #expect(try JSONDecoder().decode([DatabaseType].self, from: data) == [type])
  }

  @Test("The saved name \"MongoDB\" decodes to MongoDB")
  func mongoDBRawValueDecodes() throws {
    let data = Data(#"["MongoDB"]"#.utf8)
    #expect(try JSONDecoder().decode([DatabaseType].self, from: data) == [.mongodb])
  }

  @Test("An unknown engine throws when decoding its history entry")
  func unknownRawValueThrowsAtEntryLevel() throws {
    let entry = ConnectionHistoryEntry(config: ConnectionConfig(host: "h", database: "d"))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    var config = try #require(object["config"] as? [String: Any])
    config["databaseType"] = "FutureEngine"
    object["config"] = config
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ConnectionHistoryEntry.self, from: data)
    }
  }

  @Test("History with a DuckDB entry loads it next to an unknown engine")
  func historyWithDuckDBEntryLoads() throws {
    let suiteName = "ace.thi.Dblore.tests.duckdb-history.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let duck = ConnectionHistoryEntry(
      config: ConnectionConfig(databaseType: .duckdb, host: "", database: "/tmp/lake.duckdb"))
    var unknown = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          ConnectionHistoryEntry(config: ConnectionConfig(host: "h", database: "d"))))
        as? [String: Any])
    var unknownConfig = try #require(unknown["config"] as? [String: Any])
    unknownConfig["databaseType"] = "FutureEngine"
    unknown["config"] = unknownConfig
    let duckObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(duck))
    defaults.set(
      try JSONSerialization.data(withJSONObject: [duckObject, unknown]),
      forKey: "ace.thi.dblore.connectionHistory")

    let loaded = SessionManager.loadHistory(
      defaults: defaults, passwords: RecordingConnectionPasswordStore())

    #expect(loaded.map(\.config.databaseType) == [.duckdb])
    #expect(loaded.first?.config.database == "/tmp/lake.duckdb")
  }

  /// A saved workspace whose connection names `engine`, with an extra key a newer build may write
  private func workspaceData(engine: String, dropping key: String? = nil) throws -> Data {
    let workspace = Workspace(
      name: "Future", connectionConfig: ConnectionConfig(host: "h", database: "d"),
      tabs: [WorkspaceTabReference(documentType: .sqlFile, title: "Query")])
    var object = try #require(
      JSONSerialization.jsonObject(with: Self.encoder.encode(workspace)) as? [String: Any])
    var connection = try #require(object["connection"] as? [String: Any])
    connection["databaseType"] = engine
    connection["futureOption"] = ["mode": "fast", "level": 3]
    if let key { connection.removeValue(forKey: key) }
    object["connection"] = connection
    return try JSONSerialization.data(withJSONObject: object)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  @Test("A workspace with an unknown engine opens without its connection and writes it back")
  func unknownEngineWorkspaceKeepsConnection() throws {
    let data = try workspaceData(engine: "FutureEngine")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let original = try #require(object["connection"] as? NSDictionary)

    let workspace = try Self.decoder.decode(Workspace.self, from: data)
    #expect(workspace.connectionConfig == nil)
    #expect(workspace.tabs.map(\.title) == ["Query"])

    let saved = try #require(
      JSONSerialization.jsonObject(with: Self.encoder.encode(workspace)) as? [String: Any])
    #expect(saved["connection"] as? NSDictionary == original)
  }

  @Test("A new connection replaces the unknown engine's on save")
  func newConnectionReplacesUnknownEngine() throws {
    var workspace = try Self.decoder.decode(
      Workspace.self, from: workspaceData(engine: "FutureEngine"))
    workspace.connectionConfig = ConnectionConfig(databaseType: .sqlite, host: "", database: "x")

    let saved = try #require(
      JSONSerialization.jsonObject(with: Self.encoder.encode(workspace)) as? [String: Any])
    let connection = try #require(saved["connection"] as? [String: Any])
    #expect(connection["databaseType"] as? String == "SQLite")
    #expect(connection["futureOption"] == nil)
  }

  @Test("A malformed connection of a known engine still fails the workspace")
  func malformedKnownEngineThrows() throws {
    let data = try workspaceData(engine: DatabaseType.postgresql.rawValue, dropping: "host")
    #expect(throws: DecodingError.self) {
      try Self.decoder.decode(Workspace.self, from: data)
    }
  }

  /// A stored Recents or locked list: a known entry, one of an unknown engine, and one this build
  /// cannot read at all (no name)
  private func storedWorkspaceList(locked: Bool = false) throws -> Data {
    func object(_ entry: WorkspaceHistoryEntry) throws -> [String: Any] {
      var entry = entry
      entry.isLocked = locked
      return try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }
    let known = try object(
      WorkspaceHistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/known.sqlws"), name: "Known"))
    var future = try object(
      WorkspaceHistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/future.sqlws"), name: "Future"))
    future["databaseType"] = "FutureEngine"
    var broken = try object(
      WorkspaceHistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/broken.sqlws"), name: "Broken"))
    broken.removeValue(forKey: "name")
    return try JSONSerialization.data(withJSONObject: [known, future, broken])
  }

  /// The stored list at `key` as raw objects
  private func storedObjects(_ defaults: UserDefaults, _ key: String) throws -> [[String: Any]] {
    let data = try #require(defaults.data(forKey: key))
    return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  private func isolatedDefaults(_ name: String) throws -> (UserDefaults, String) {
    let suiteName = "ace.thi.Dblore.tests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }

  @Test("Recents with an unknown engine keep every entry and write it back on save")
  func recentsKeepUnknownEngineEntry() throws {
    let (defaults, suiteName) = try isolatedDefaults("unknown-engine-recents")
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "ace.thi.dblore.recentWorkspaces"
    defaults.set(try storedWorkspaceList(), forKey: key)

    let recents = RecentManager(defaults: defaults)
    #expect(recents.recentWorkspaces.map(\.name) == ["Known", "Future"])
    #expect(recents.recentWorkspaces.last?.databaseType == nil)

    recents.addWorkspace(
      WorkspaceHistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/new.sqlws"), name: "New"))
    recents.removeWorkspace(url: URL(fileURLWithPath: "/tmp/known.sqlws"))

    let stored = try storedObjects(defaults, key)
    #expect(stored.compactMap { $0["name"] as? String } == ["New", "Future"])
    #expect(
      stored.first { $0["name"] as? String == "Future" }?["databaseType"] as? String
        == "FutureEngine")
    #expect(stored.contains { ($0["fileURL"] as? String)?.hasSuffix("broken.sqlws") == true })
  }

  @Test("The locked list with an unknown engine keeps every entry and writes it back on save")
  func lockedListKeepsUnknownEngineEntry() throws {
    let (defaults, suiteName) = try isolatedDefaults("unknown-engine-locked")
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(try storedWorkspaceList(locked: true), forKey: LockedWorkspaceList.key)
    let list = LockedWorkspaceList(defaults: defaults)
    #expect(list.entries.map(\.name) == ["Known", "Future"])

    list.add(WorkspaceHistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/new.sqlws"), name: "New"))
    let known = try #require(list.entries.first)
    list.remove(id: known.id, fileURL: known.fileURL)

    #expect(list.entries.map(\.name) == ["Future", "New"])
    let stored = try storedObjects(defaults, LockedWorkspaceList.key)
    #expect(
      stored.first { $0["name"] as? String == "Future" }?["databaseType"] as? String
        == "FutureEngine")
    #expect(stored.contains { ($0["fileURL"] as? String)?.hasSuffix("broken.sqlws") == true })
  }
}
