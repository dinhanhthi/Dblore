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

  // MARK: - SSH tunnel

  private func tunnelConfig(
    sshHost: String = "bastion.example.com", sshPort: Int = 2222
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "db.internal", database: "app", username: "ada", password: "db-secret")
    config.sshTunnel = SSHTunnelConfig(
      host: sshHost, port: sshPort, username: "ops", authMethod: .privateKey,
      keyAlgorithm: "ssh-ed25519", keyFingerprint: "SHA256:abc")
    return config
  }

  @Test("A config with an SSH tunnel round-trips")
  func sshTunnelRoundTrip() throws {
    let config = tunnelConfig()
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded.sshTunnel == config.sshTunnel)
    #expect(decoded == config)
  }

  @Test("The encoded SSH tunnel holds only non-secret display fields")
  func sshTunnelEncodesNoSecrets() throws {
    let object = try encodedObject(tunnelConfig())
    let tunnel = try #require(object["sshTunnel"] as? [String: Any])
    #expect(
      Set(tunnel.keys)
        == ["host", "port", "username", "authMethod", "keyAlgorithm", "keyFingerprint"])
    let tunnelJSON = String(
      decoding: try JSONSerialization.data(withJSONObject: tunnel), as: UTF8.self)
    #expect(!tunnelJSON.contains("db-secret"))
    #expect(!tunnelJSON.lowercased().contains("passphrase"))
  }

  @Test("The SSH credential account is nil without a tunnel and depends on the bastion")
  func sshCredentialAccountForConfig() {
    let plain = ConnectionConfig(host: "db.internal", database: "app", username: "ada")
    #expect(SSHCredentialStoreFactory.account(for: plain) == nil)

    let account = SSHCredentialStoreFactory.account(for: tunnelConfig())
    #expect(
      account
        == SSHCredentialStoreFactory.account(
          databaseType: .postgresql, host: "db.internal", port: 5432, database: "app",
          username: "ada", sshHost: "bastion.example.com", sshPort: 2222, sshUsername: "ops"))
    #expect(account != SSHCredentialStoreFactory.account(for: tunnelConfig(sshHost: "other")))
    #expect(account != SSHCredentialStoreFactory.account(for: tunnelConfig(sshPort: 22)))
  }

  // MARK: - DuckDB form

  @Test("Opening a DuckDB file is read-only, creating one is read-write")
  func duckDBOpenAndCreateReadOnlyDefaults() {
    let bookmark = Data([0x02])
    let draft = ConnectionConfig(databaseType: .duckdb, readOnlyFile: false)

    let opened = ConnectionFormContent.applyingDuckDBChoice(
      .open(path: "/tmp/sales.duckdb", bookmark: bookmark), to: draft, selected: nil
    ).config
    #expect(opened.database == "/tmp/sales.duckdb")
    #expect(opened.fileBookmark == bookmark)
    #expect(opened.readOnlyFile)
    #expect(opened.name == "sales")

    let created = ConnectionFormContent.applyingDuckDBChoice(
      .create(path: "/tmp/new.duckdb", bookmark: nil), to: opened, selected: nil
    ).config
    #expect(created.database == "/tmp/new.duckdb")
    #expect(created.fileBookmark == nil)
    #expect(!created.readOnlyFile)
  }

  @Test("In-memory DuckDB has no bookmark and is not a read-only file")
  func duckDBInMemory() {
    let opened = ConnectionConfig(
      databaseType: .duckdb, database: "/tmp/sales.duckdb", fileBookmark: Data([0x03]))

    let config = ConnectionFormContent.applyingDuckDBChoice(.inMemory, to: opened, selected: nil)
      .config
    #expect(config.database == DuckDBSession.inMemoryPath)
    #expect(config.fileBookmark == nil)
    #expect(!config.readOnlyFile)
    #expect(config.name == "In-memory")
  }

  @Test("Switching between SQLite and DuckDB re-applies the engine's read-only default")
  func switchingEngineReDefaultsReadOnlyFile() throws {
    let toDuckDB = try #require(
      ConnectionFormContent.formAfterEngineChange(fieldsEngine: .sqlite, newType: .duckdb))
    #expect(toDuckDB.readOnlyFile)

    let toSQLite = try #require(
      ConnectionFormContent.formAfterEngineChange(fieldsEngine: .duckdb, newType: .sqlite))
    #expect(!toSQLite.readOnlyFile)
  }

  // MARK: - MongoDB URI

  /// A config the way the form hands it on: parsed URI fields plus the in-memory password.
  private func mongoConfig(_ text: String) throws -> ConnectionConfig {
    let uri = try MongoURIParser.parse(text)
    var config = uri.applied(to: ConnectionConfig(databaseType: .mongodb, name: "Mongo"))
    config.password = uri.password ?? ""
    return config
  }

  private static let mongoSecret = "s3cr%40t%2Fpw"

  @Test("A MongoDB config round-trips +srv, tls, authSource and replicaSet")
  func mongoURIRoundTrip() throws {
    let config = try mongoConfig(
      "mongodb+srv://ada:\(Self.mongoSecret)@cluster0.example.net/app?tls=true"
        + "&authSource=admin&replicaSet=rs0&retryWrites=true")
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded == config)

    let uri = try MongoURIParser.parse(try #require(decoded.mongoURI))
    #expect(uri.isSRV)
    #expect(uri.tls == true)
    #expect(uri.authSource == "admin")
    #expect(uri.replicaSet == "rs0")
    #expect(decoded.sslMode == .verifyFull)
  }

  @Test("The encoded mongoURI has no userinfo and no unknown options")
  func mongoURIEncodesNoSecrets() throws {
    let object = try encodedObject(
      try mongoConfig("mongodb://ada:\(Self.mongoSecret)@h1,h2/app?w=majority&appName=x"))
    let stored = try #require(object["mongoURI"] as? String)
    #expect(stored == "mongodb://h1,h2/app?appName=x")
    #expect(!stored.contains("ada"))
    #expect(!stored.contains("s3cr"))
    #expect(!stored.contains("majority"))
  }

  @Test("A config without mongoURI encodes without the key and legacy JSON decodes to nil")
  func mongoURIAbsent() throws {
    #expect(try encodedObject(ConnectionConfig(host: "h"))["mongoURI"] == nil)
    let legacy = try JSONDecoder().decode(ConnectionConfig.self, from: savedConnectionJSON())
    #expect(legacy.mongoURI == nil)
  }

  @Test("History, workspace and launch session strip a MongoDB password")
  func mongoPasswordStripPoints() throws {
    let config = try mongoConfig(
      "mongodb://ada:\(Self.mongoSecret)@db.example.com/app?authSource=admin")
    #expect(config.password == "s3cr@t/pw")
    let secrets = ["s3cr@t/pw", "s3cr@t\\/pw", Self.mongoSecret]

    func expectNoSecret(_ data: Data) {
      let json = String(decoding: data, as: UTF8.self)
      for secret in secrets { #expect(!json.contains(secret)) }
    }

    let history = ConnectionHistoryEntry(config: config)
    #expect(history.config.password == "")
    #expect(history.config.mongoURI == config.mongoURI)
    expectNoSecret(try JSONEncoder().encode(history))

    let workspace = Workspace(connectionConfig: config)
    expectNoSecret(try JSONEncoder().encode(workspace))

    let session = LaunchSession(windows: [
      LaunchWindow(
        frame: WindowFrame(x: 0, y: 0, width: 800, height: 600), isMiniaturized: false,
        groupIndex: 0, tabIndex: 0, isSelectedInGroup: true,
        content: .workspace(LaunchWorkspace(workspace: workspace)))
    ]).clearingPasswords()
    guard case .workspace(let launched) = try #require(session.windows.first).content else {
      Issue.record("Expected a workspace window")
      return
    }
    #expect(launched.workspace?.connectionConfig?.password == "")
    #expect(launched.workspace?.connectionConfig?.mongoURI == config.mongoURI)
    expectNoSecret(try JSONEncoder().encode(session))
  }

  private func encodedObject(_ config: ConnectionConfig) throws -> [String: Any] {
    let data = try JSONEncoder().encode(config)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
