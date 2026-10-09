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

  @Test("The DuckDB raw value decodes")
  func duckdbRawValueDecodes() throws {
    let data = try JSONEncoder().encode(["DuckDB"])
    #expect(try JSONDecoder().decode([DatabaseType].self, from: data) == [.duckdb])
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
}
