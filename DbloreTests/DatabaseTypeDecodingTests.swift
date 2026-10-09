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
}
