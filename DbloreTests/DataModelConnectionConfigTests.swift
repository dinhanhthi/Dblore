// DataModelConnectionConfigTests.swift
// Unit tests for ConnectionConfig data model

import Foundation
import Testing

@testable import Dblore

@Suite("Data Model - ConnectionConfig Tests")
@MainActor
struct DataModelConnectionConfigTests {

  // MARK: - ConnectionConfig Tests

  @Test("ConnectionConfig encoding and decoding")
  func connectionConfigEncodingDecoding() throws {
    // Arrange
    let config = ConnectionConfig(
      databaseType: .postgresql,
      host: "localhost",
      port: 5432,
      database: "testdb",
      username: "testuser",
      password: "secret123",
      sslMode: .disable,
      timeoutSeconds: 30
    )

    // Act
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(config)
    let jsonString = String(data: data, encoding: .utf8)!

    // Assert - Verify basic encoding works
    #expect(jsonString.contains("localhost"))
    #expect(jsonString.contains("testdb"))
    #expect(jsonString.contains("testuser"))
    #expect(jsonString.contains("30"))  // Verify timeoutSeconds is encoded

    // Decode
    let decoder = JSONDecoder()
    let decodedConfig = try decoder.decode(ConnectionConfig.self, from: data)
    #expect(decodedConfig.host == "localhost")
    #expect(decodedConfig.database == "testdb")
    #expect(decodedConfig.username == "testuser")
    #expect(decodedConfig.timeoutSeconds == 30)
  }

  @Test("ConnectionConfig default timeout value")
  func connectionConfigDefaultTimeout() {
    // Arrange & Act - Create config without specifying timeout
    let config = ConnectionConfig(
      host: "localhost",
      database: "test"
    )

    // Assert - Default timeout should be 30 seconds
    #expect(config.timeoutSeconds == 30)
  }

  @Test("ConnectionConfig custom timeout value")
  func connectionConfigCustomTimeout() {
    // Arrange & Act - Create config with custom timeout
    let config = ConnectionConfig(
      host: "localhost",
      database: "test",
      timeoutSeconds: 60
    )

    // Assert - Custom timeout should be preserved
    #expect(config.timeoutSeconds == 60)
  }

  @Test("ConnectionConfig timeout encoding preserves value")
  func connectionConfigTimeoutEncodingPreservesValue() throws {
    // Arrange - Create configs with different timeout values
    let testCases = [10, 30, 60, 120, 300]

    for timeout in testCases {
      let config = ConnectionConfig(
        host: "localhost",
        database: "test",
        timeoutSeconds: timeout
      )

      // Act - Encode and decode
      let encoder = JSONEncoder()
      let data = try encoder.encode(config)
      let decoder = JSONDecoder()
      let decoded = try decoder.decode(ConnectionConfig.self, from: data)

      // Assert - Timeout value should be preserved
      #expect(decoded.timeoutSeconds == timeout)
    }
  }

  // MARK: - Safety / Session Settings

  @Test("New config has no timeout overrides and follows the global timeouts")
  func safetySessionDefaults() {
    let config = ConnectionConfig(host: "localhost", database: "test")

    #expect(config.protectedMode == true)
    #expect(config.statementTimeoutSeconds == nil)
    #expect(config.lockTimeoutSeconds == nil)
    #expect(config.idleInTransactionTimeoutSeconds == nil)
    #expect(config.rowCapOverride == nil)
  }

  @Test("Legacy JSON without timeout keys decodes with no overrides")
  func legacyJSONDecodesWithDefaults() throws {
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "db.example.com",
        "port": 5432,
        "database": "legacy",
        "username": "admin",
        "password": "",
        "sslMode": "prefer",
        "rememberConnection": true,
        "timeoutSeconds": 30,
        "name": "Old",
        "readOnly": false,
        "blockSchemaChanges": true
      }
      """
    let data = try #require(json.data(using: .utf8))

    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded.protectionLevel == .schemaOnly)
    #expect(decoded.safeMode == nil)
    #expect(decoded.protectedMode == true)
    #expect(decoded.statementTimeoutSeconds == nil)
    #expect(decoded.lockTimeoutSeconds == nil)
    #expect(decoded.idleInTransactionTimeoutSeconds == nil)
    #expect(decoded.rowCapOverride == nil)
    #expect(decoded.fileBookmark == nil)
    #expect(decoded.readOnlyFile == false)
  }

  @Test("SQLite config round-trips the file path, bookmark, and read-only flag")
  func sqliteFileConfigRoundTrip() throws {
    let bookmark = Data([0xAB, 0xCD, 0x01, 0x02])
    let config = ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      database: "/Users/me/Library/notes.sqlite",
      fileBookmark: bookmark,
      readOnlyFile: true
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded.databaseType == .sqlite)
    #expect(decoded.database == "/Users/me/Library/notes.sqlite")
    #expect(decoded.fileBookmark == bookmark)
    #expect(decoded.readOnlyFile == true)
    #expect(decoded == config)
  }

  @Test("Validation does not require a host or username for SQLite")
  func sqliteValidationDoesNotRequireHost() {
    let missingHost = ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      database: "/tmp/notes.sqlite",
      username: ""
    )
    #expect(ConnectionFormContent.isFormInputValid(missingHost))

    let missingFile = ConnectionConfig(
      databaseType: .sqlite,
      host: "localhost",
      database: "",
      username: "file"
    )
    #expect(!ConnectionFormContent.isFormInputValid(missingFile))
  }

  @Test("Encode/decode round trip preserves custom safety/session values")
  func safetySessionRoundTrip() throws {
    let config = ConnectionConfig(
      host: "localhost",
      database: "test",
      protectedMode: false,
      statementTimeoutSeconds: 30,
      lockTimeoutSeconds: 3,
      idleInTransactionTimeoutSeconds: 120,
      rowCapOverride: 5000
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.protectedMode == false)
    #expect(decoded.statementTimeoutSeconds == 30)
    #expect(decoded.lockTimeoutSeconds == 3)
    #expect(decoded.idleInTransactionTimeoutSeconds == 120)
    #expect(decoded.rowCapOverride == 5000)
  }

  @Test("Non-positive brake timeouts decode as no override; rowCapOverride as-is")
  func nonPositiveTimeoutsDecodeAsDefaults() throws {
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "",
        "password": "",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "name": "",
        "protectionLevel": "none",
        "statementTimeoutSeconds": 0,
        "lockTimeoutSeconds": -1,
        "idleInTransactionTimeoutSeconds": -3,
        "rowCapOverride": -4
      }
      """
    let data = try #require(json.data(using: .utf8))

    let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: data)

    #expect(decoded.statementTimeoutSeconds == nil)
    #expect(decoded.lockTimeoutSeconds == nil)
    #expect(decoded.idleInTransactionTimeoutSeconds == nil)
    #expect(decoded.rowCapOverride == -4)
  }

  @Test("Legacy timeouts equal to the old defaults follow global; others stay overrides")
  func legacyDefaultTimeoutsFollowGlobal() throws {
    let json = """
      {
        "databaseType": "PostgreSQL", "host": "h", "port": 5432, "database": "d",
        "username": "", "password": "", "sslMode": "prefer", "rememberConnection": false,
        "timeoutSeconds": 30, "name": "", "protectionLevel": "none",
        "statementTimeoutSeconds": 60, "lockTimeoutSeconds": 9,
        "idleInTransactionTimeoutSeconds": 600
      }
      """
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: try #require(json.data(using: .utf8)))

    #expect(decoded.statementTimeoutSeconds == nil)
    #expect(decoded.lockTimeoutSeconds == 9)
    #expect(decoded.idleInTransactionTimeoutSeconds == nil)
  }

  @Test("An override equal to the default survives a round trip")
  func explicitDefaultOverrideRoundTrips() throws {
    let config = ConnectionConfig(statementTimeoutSeconds: 60)

    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: try JSONEncoder().encode(config))

    #expect(decoded.statementTimeoutSeconds == 60)
    #expect(decoded.lockTimeoutSeconds == nil)
  }

  @Test("resolvingBrakes fills only the missing timeouts from global")
  func resolvingBrakesUsesGlobalForMissing() {
    let config = ConnectionConfig(statementTimeoutSeconds: 15)
    let resolved = config.resolvingBrakes(
      SessionBrakeDefaults(statement: 90, lock: 7, idle: 300))

    #expect(resolved.statementTimeoutSeconds == 15)
    #expect(resolved.lockTimeoutSeconds == 7)
    #expect(resolved.idleInTransactionTimeoutSeconds == 300)
  }

  @Test("Recent connections stay on the selected engine")
  func recentConnectionsFilterByEngine() {
    let postgres = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .postgresql, database: "postgres", name: "Ideta Rag Local"))
    let sqlite = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .sqlite, database: "/tmp/notes.sqlite", name: "Notes"))

    let history = [postgres, sqlite]
    #expect(
      ConnectionFormContent.history(matching: .sqlite, in: history).map(\.config.name) == ["Notes"]
    )
    #expect(
      ConnectionFormContent.history(matching: .postgresql, in: history).map(\.config.name)
        == ["Ideta Rag Local"])
  }

  @Test("Switching to SQLite drops a PostgreSQL database name")
  func switchingEngineClearsOtherEngineFields() throws {
    let replacement = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .postgresql, newType: .sqlite)

    let config = try #require(replacement)
    #expect(config.databaseType == .sqlite)
    #expect(config.database.isEmpty)
    #expect(config.name.isEmpty)
  }

  @Test("Loading a history row of the new engine keeps that row")
  func switchingEngineKeepsMatchingHistoryEntry() {
    let replacement = ConnectionFormContent.formAfterEngineChange(
      fieldsEngine: .sqlite, newType: .sqlite)
    #expect(replacement == nil)
  }

  @Test("Browsing a different SQLite file replaces the loaded recent connection")
  func browsingDifferentSQLiteFileReplacesLoadedConnection() {
    let bookmark = Data([0x01])
    let loaded = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .sqlite,
        host: "",
        database: "/tmp/notes.sqlite",
        name: "Notes",
        fileBookmark: bookmark
      ))
    var config = loaded.config
    config.password = ""

    let applied = ConnectionFormContent.applyingSQLiteFile(
      path: "/tmp/reports.sqlite",
      bookmark: Data([0x02]),
      to: config,
      selected: loaded
    )

    #expect(applied.config.database == "/tmp/reports.sqlite")
    #expect(applied.config.name == "reports")
    #expect(applied.selectedHistoryId == nil)
  }

  @Test("Browsing a SQLite file keeps a name the user already typed")
  func browsingSQLiteFileKeepsCustomName() {
    let loaded = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .sqlite,
        host: "",
        database: "/tmp/notes.sqlite",
        name: "Notes"
      ))
    var config = loaded.config
    config.name = "Work"

    let applied = ConnectionFormContent.applyingSQLiteFile(
      path: "/tmp/reports.sqlite",
      bookmark: nil,
      to: config,
      selected: loaded
    )

    #expect(applied.config.name == "Work")
    #expect(applied.selectedHistoryId == nil)
  }

  @Test("Browsing the same SQLite file keeps the recent connection")
  func browsingSameSQLiteFileKeepsRecentConnection() {
    let loaded = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .sqlite,
        host: "",
        database: "/tmp/notes.sqlite",
        name: "Notes"
      ))

    let applied = ConnectionFormContent.applyingSQLiteFile(
      path: "/tmp/notes.sqlite",
      bookmark: Data([0x03]),
      to: loaded.config,
      selected: loaded
    )

    #expect(applied.config.name == "Notes")
    #expect(applied.selectedHistoryId == loaded.id)
  }

  @Test("A blank SQLite name is filled from the chosen file")
  func blankSQLiteNameFillsFromFile() {
    let applied = ConnectionFormContent.applyingSQLiteFile(
      path: "/tmp/archive.db",
      bookmark: nil,
      to: ConnectionConfig(databaseType: .sqlite, host: "", database: ""),
      selected: nil
    )

    #expect(applied.config.name == "archive")
    #expect(applied.selectedHistoryId == nil)
  }

  @Test("Editing a PostgreSQL target drops the loaded recent connection")
  func editingPostgresTargetDropsRecentConnection() {
    let loaded = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .postgresql,
        host: "localhost",
        database: "postgres",
        username: "thi",
        name: "Local"
      ))
    var edited = loaded.config
    edited.database = "other"

    #expect(
      ConnectionFormContent.retainedHistoryId(
        selectedId: loaded.id,
        history: [loaded],
        config: edited
      ) == nil)

    edited.database = "postgres"
    edited.name = "Renamed"
    #expect(
      ConnectionFormContent.retainedHistoryId(
        selectedId: loaded.id,
        history: [loaded],
        config: edited
      ) == loaded.id)
  }

  // MARK: - Commit style storage

  @Test("JSON without commitStyle stays legacy and re-encodes without the key")
  func jsonWithoutCommitStyleStaysLegacy() throws {
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: savedConnectionJSON())

    #expect(decoded.hasStoredCommitStyle == false)
    #expect(decoded.safeMode == .alertRead)
    #expect(decoded.protectedMode == false)

    let object = try encodedObject(decoded)
    #expect(object["commitStyle"] == nil)
    #expect(object["safeMode"] as? Int == 1)
    #expect(object["protectedMode"] as? Bool == false)
  }

  @Test(
    "Null or unknown commitStyle decodes as if the key were absent",
    arguments: ["null", "\"not-a-style\""]
  )
  func nullOrUnknownCommitStyleDecodesAsAbsent(literal: String) throws {
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: savedConnectionJSON(commitStyleValue: literal))

    #expect(decoded.hasStoredCommitStyle == false)
    #expect(decoded.safeMode == .alertRead)
    #expect(decoded.protectedMode == false)
  }

  @Test(
    "A known commitStyle string is stored and re-encoded with the saved pair",
    arguments: [
      ("immediate", CommitStyle.immediate),
      ("confirm", CommitStyle.confirm),
      ("review", CommitStyle.review),
      ("password", CommitStyle.password),
    ]
  )
  func knownCommitStyleStringIsStored(raw: String, style: CommitStyle) throws {
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: savedConnectionJSON(commitStyleValue: "\"\(raw)\""))

    #expect(decoded.hasStoredCommitStyle == true)
    #expect(decoded.commitStyle == style)
    #expect(decoded.safeMode == .alertRead)
    #expect(decoded.protectedMode == false)

    let object = try encodedObject(decoded)
    #expect(object["commitStyle"] as? String == raw)
    #expect(object["safeMode"] as? Int == 1)
    #expect(object["protectedMode"] as? Bool == false)
  }

  @Test("A legacy protected connection resolves to review without changing the stored pair")
  func legacyProtectedResolvesToReview() {
    let config = ConnectionConfig(safeMode: .safeAll, protectedMode: true)

    #expect(config.resolvedCommitStyle(fallback: .immediate) == .review)
    #expect(config.hasStoredCommitStyle == false)
    #expect(config.safeMode == .safeAll)
    #expect(config.protectedMode == true)
  }

  @Test("A legacy unprotected connection with no safe mode uses the fallback")
  func legacyUnprotectedNilSafeModeUsesFallback() {
    let config = ConnectionConfig(safeMode: nil, protectedMode: false)

    #expect(config.resolvedCommitStyle(fallback: .immediate) == .immediate)
    #expect(config.resolvedCommitStyle(fallback: .confirm) == .confirm)
    #expect(config.resolvedCommitStyle(fallback: .password) == .password)
    #expect(config.resolvedCommitStyle(fallback: .review) == .confirm)
    #expect(config.hasStoredCommitStyle == false)
    #expect(config.safeMode == nil)
    #expect(config.protectedMode == false)
  }

  @Test("applyCommitStyle projects password onto a legacy protected connection")
  func applyCommitStyleProjectsPassword() throws {
    var config = ConnectionConfig(safeMode: .safeAll, protectedMode: true)
    config.applyCommitStyle(.password)

    #expect(config.hasStoredCommitStyle == true)
    #expect(config.commitStyle == .password)
    #expect(config.protectedMode == false)
    #expect(config.safeMode == .safeRead)

    let object = try encodedObject(config)
    #expect(object["commitStyle"] as? String == CommitStyle.password.rawValue)
    #expect(object["safeMode"] as? Int == SafeMode.safeRead.rawValue)
    #expect(object["protectedMode"] as? Bool == false)
  }

  @Test("applyCommitStyle projects review onto protected mode and silent safe mode")
  func applyCommitStyleProjectsReview() {
    var config = ConnectionConfig(safeMode: .safeAll, protectedMode: false)
    config.applyCommitStyle(.review)

    #expect(config.commitStyle == .review)
    #expect(config.protectedMode == true)
    #expect(config.safeMode == .silent)
  }

  @Test("Encoding a legacy connection omits commitStyle until applyCommitStyle")
  func encodingLegacyConnectionOmitsCommitStyle() throws {
    let config = ConnectionConfig(safeMode: .safeAll, protectedMode: true)

    #expect(config.hasStoredCommitStyle == false)
    let object = try encodedObject(config)
    #expect(object["commitStyle"] == nil)
    #expect(object["safeMode"] as? Int == SafeMode.safeAll.rawValue)
    #expect(object["protectedMode"] as? Bool == true)
  }

  @Test("Protected mode is the gate for the resolved style")
  func protectedModeGatesResolvedStyle() {
    var storedReview = ConnectionConfig(safeMode: .silent, protectedMode: false)
    storedReview.commitStyle = .review
    #expect(storedReview.resolvedCommitStyle(fallback: .password) == .confirm)

    var storedImmediate = ConnectionConfig(safeMode: .silent, protectedMode: true)
    storedImmediate.commitStyle = .immediate
    #expect(storedImmediate.resolvedCommitStyle(fallback: .password) == .review)

    var storedPassword = ConnectionConfig(safeMode: .safeRead, protectedMode: true)
    storedPassword.commitStyle = .password
    #expect(storedPassword.resolvedCommitStyle(fallback: .immediate) == .review)
  }

  private func savedConnectionJSON(commitStyleValue: String? = nil) -> Data {
    let styleField = commitStyleValue.map { ",\n        \"commitStyle\": \($0)" } ?? ""
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "user",
        "password": "",
        "sslMode": "prefer",
        "rememberConnection": true,
        "timeoutSeconds": 30,
        "name": "Saved",
        "protectionLevel": "none",
        "safeMode": 1,
        "protectedMode": false\(styleField)
      }
      """
    return Data(json.utf8)
  }

  private func encodedObject(_ config: ConnectionConfig) throws -> [String: Any] {
    let data = try JSONEncoder().encode(config)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
