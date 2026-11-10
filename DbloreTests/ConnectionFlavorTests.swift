// ConnectionFlavorTests.swift
// A flavor rides on its base engine: older builds read the config as that engine, and the
// flavor is an attribute of a saved row: it changes neither the row nor its Keychain key.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection flavor")
@MainActor
struct ConnectionFlavorTests {
  private func cockroach() -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "db.example.com", port: 26257, database: "app",
      username: "root")
    config.flavor = .cockroachdb
    return config
  }

  private func object(_ config: ConnectionConfig) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
  }

  @Test("A flavored config keeps its base engine and decodes as that engine without the key")
  func olderBuildContract() throws {
    var encoded = try object(cockroach())
    #expect(encoded["databaseType"] as? String == DatabaseType.postgresql.rawValue)
    #expect(encoded["databaseType"] as? String == "PostgreSQL")
    #expect(encoded["flavor"] as? String == "cockroachdb")
    #expect(try object(ConnectionConfig(host: "h", database: "d"))["flavor"] == nil)

    encoded.removeValue(forKey: "flavor")
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(decoded.databaseType == .postgresql)
    #expect(decoded.flavor == nil)

    let roundTrip = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONEncoder().encode(cockroach()))
    #expect(roundTrip == cockroach())
  }

  @Test(
    "An unknown, mismatched or wrong-typed flavor decodes as none",
    arguments: ["FutureDB", "tidb", 7] as [any Sendable])
  func lenientDecode(value: any Sendable) throws {
    var encoded = try object(cockroach())
    encoded["flavor"] = value
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(decoded.databaseType == .postgresql)
    #expect(decoded.flavor == nil)
  }

  @Test("Another flavor on the same endpoint is the same saved row with the same Keychain key")
  func identity() {
    let plain = ConnectionConfig(
      databaseType: .postgresql, host: "db.example.com", port: 26257, database: "app",
      username: "root")
    let row = ConnectionHistoryEntry(config: cockroach())
    #expect(row.isSavedRow(of: cockroach()))
    #expect(row.isSavedRow(of: plain))
    #expect(ConnectionHistoryEntry(config: plain).isSavedRow(of: cockroach()))
    #expect(
      ConnectionKeychainKey.password(for: cockroach())
        == ConnectionKeychainKey.password(for: plain))
    #expect(
      ConnectionKeychainKey.password(for: plain) == "db.example.com:26257:app:root")
  }

  @Test("Switching the form to a preset of another engine keeps the preset and its port")
  func engineChangeKeepsPreset() throws {
    let draft = try #require(
      ConnectionFormContent.formAfterEngineChange(
        fieldsEngine: .postgresql, newType: .mysql, flavor: .tidb))
    #expect(draft.databaseType == .mysql)
    #expect(draft.flavor == .tidb)
    #expect(draft.port == 4000)
  }

  @Test("A preset of the same engine keeps a port of the user's own, else takes its default")
  func presetKeepsOwnPort() {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "db.example.com", port: 15433, database: "app",
      username: "root")
    #expect(ConnectionFormModal.applying(.preset(.yugabytedb), to: config).port == 15433)
    config.port = 5432
    let yugabyte = ConnectionFormModal.applying(.preset(.yugabytedb), to: config)
    #expect(yugabyte.port == 5433)
    #expect(yugabyte.flavor == .yugabytedb)
  }

  @Test("Presets follow their base engine and only when it is listed")
  func pickerChoices() {
    let choices = EnginePickerChoice.choices(for: [.postgresql, .sqlite])
    #expect(
      choices == [
        .engine(.postgresql), .preset(.cockroachdb), .preset(.redshift), .preset(.yugabytedb),
        .engine(.sqlite),
      ])
  }

  @Test("CockroachDB cancels by reconnecting: its pg_stat_activity cannot match the session")
  func cockroachCancelReconnects() {
    var reconnects = DatabaseType.postgresql.capabilities
    reconnects.cancelStrategy = .reconnect
    #expect(PostgresSession(config: cockroach()).capabilities == reconnects)
    for flavor in [nil, .redshift, .yugabytedb] as [DatabaseFlavor?] {
      var config = cockroach()
      config.flavor = flavor
      #expect(PostgresSession(config: config).capabilities == DatabaseType.postgresql.capabilities)
    }
  }

  @Test("An unopened Redshift session keeps every brake: only the server can confirm Redshift")
  func unopenedRedshiftKeepsBrakes() {
    var config = cockroach()
    config.flavor = .redshift
    #expect(PostgresSession(config: config).brakeFlavor == nil)
  }
}
