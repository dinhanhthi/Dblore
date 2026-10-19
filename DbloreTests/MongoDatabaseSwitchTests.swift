// MongoDatabaseSwitchTests.swift
// Switching the MongoDB database keeps the identity of the saved connection: with the
// `mongoHomeDatabase` pin the password key, client certificate account, SSH account and default
// authSource are those of the original database; without a pin every key is the legacy one.

import Foundation
import Testing

@testable import Dblore

@Suite @MainActor
struct MongoDatabaseSwitchTests {
  static func config(
    database: String = "app", home: String? = nil, uri: String? = nil, tunnel: Bool = false
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "db.example.com", port: 27017, database: database,
      username: "ada", password: "secret", sslMode: .disable,
      sshTunnel: tunnel ? SSHTunnelConfig(host: "bastion.example.com", username: "ops") : nil)
    config.mongoURI = uri
    config.mongoHomeDatabase = home
    return config
  }

  static func authSource(
    _ config: ConnectionConfig,
    resolver: any MongoSRVResolving = MongoSessionTests.FakeResolver(srv: [])
  ) async throws -> String {
    try await MongoSession.plan(config: config, material: nil, resolver: resolver).authSource
  }

  // MARK: - Keychain identity

  @Test("A switched config keeps the password key, certificate account and SSH account")
  func pinKeepsIdentity() {
    let original = Self.config(database: "app", tunnel: true)
    let switched = Self.config(database: "sales", home: "app", tunnel: true)
    #expect(switched.identityDatabase == "app")
    #expect(
      ConnectionKeychainKey.password(for: switched) == ConnectionKeychainKey.password(for: original)
    )
    #expect(
      ConnectionKeychainKey.certificateAccount(for: switched)
        == ConnectionKeychainKey.certificateAccount(for: original))
    #expect(
      SSHCredentialStoreFactory.account(for: switched)
        == SSHCredentialStoreFactory.account(for: original))
    #expect(SSHCredentialStoreFactory.account(for: switched) != nil)
  }

  @Test("Without a pin every key is the legacy one, byte for byte")
  func nilPinIsLegacy() {
    let config = Self.config(database: "app", tunnel: true)
    #expect(config.mongoHomeDatabase == nil)
    #expect(config.identityDatabase == "app")
    #expect(
      ConnectionKeychainKey.password(for: config)
        == "v2|7:MongoDB|14:db.example.com|5:27017|3:app|3:ada")
    #expect(
      ConnectionKeychainKey.certificateAccount(for: config)
        == "v2|7:MongoDB|14:db.example.com|5:27017|3:app|3:ada")
    #expect(
      SSHCredentialStoreFactory.account(for: config)
        == "v2|7:MongoDB|14:db.example.com|5:27017|3:app|3:ada|19:bastion.example.com|2:22|3:ops")
  }

  @Test("The pin is encoded only when set and survives a round trip")
  func pinCodable() throws {
    let legacy = try JSONEncoder().encode(Self.config())
    let object = try JSONSerialization.jsonObject(with: legacy) as? [String: Any]
    #expect(object?["mongoHomeDatabase"] == nil)
    #expect(try JSONDecoder().decode(ConnectionConfig.self, from: legacy).mongoHomeDatabase == nil)

    let pinned = Self.config(database: "sales", home: "app")
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: try JSONEncoder().encode(pinned))
    #expect(decoded.mongoHomeDatabase == "app")
    #expect(decoded == pinned)
  }

  // MARK: - authSource

  @Test("authSource: the URI wins over the pin; the pin replaces the database; empty home is admin")
  func authSourceOrder() async throws {
    let explicit = Self.config(
      database: "sales", home: "app", uri: "mongodb://db.example.com/sales?authSource=admin")
    #expect(try await Self.authSource(explicit) == "admin")

    let pinned = Self.config(database: "sales", home: "app", uri: "mongodb://db.example.com/app")
    #expect(try await Self.authSource(pinned) == "app")
    let plan = try await MongoSession.plan(
      config: pinned, material: nil, resolver: MongoSessionTests.FakeResolver(srv: []))
    #expect(plan.database == "sales")

    let emptyHome = Self.config(database: "sales", home: "", uri: "mongodb://db.example.com")
    #expect(try await Self.authSource(emptyHome) == "admin")

    // Legacy: no pin, the connection's database, else admin.
    #expect(try await Self.authSource(Self.config(database: "app")) == "app")
    #expect(try await Self.authSource(Self.config(database: "")) == "admin")
  }

  @Test("The TXT record's authSource wins over the pin")
  func txtAuthSourceWinsOverPin() async throws {
    let resolver = MongoSessionTests.FakeResolver(
      srv: [
        MongoSRVRecord(
          priority: 0, weight: 0, port: 27017, target: "shard-00.cluster0.example.com")
      ],
      txt: ["authSource=admin"])
    var config = Self.config(
      database: "sales", home: "shop", uri: "mongodb+srv://cluster0.example.com/shop")
    config.sslMode = .verifyFull
    #expect(try await Self.authSource(config, resolver: resolver) == "admin")
  }
}

// MARK: - Switching the database

extension MongoDatabaseSwitchTests {
  private static let historyKey = "ace.thi.dblore.connectionHistory"

  /// Remember on (so a save would show) and no password (so nothing reaches the Keychain); a
  /// unique host finds this test's rows in the shared recent list.
  private static func home() -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "switch-\(UUID().uuidString).example", port: 27017,
      database: "app", username: "ada", sslMode: .disable)
    config.protectedMode = false
    config.applyCommitStyle(.immediate)
    return config
  }

  private static func recentListMentions(_ host: String) -> Bool {
    guard let data = UserDefaults.standard.data(forKey: historyKey) else { return false }
    return String(decoding: data, as: UTF8.self).contains(host)
  }

  /// A workspace connected to `config` through a fake session, without saving it.
  private static func connected(_ config: ConnectionConfig) async throws -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(
        connectionConfig: config,
        connectionKeychainKey: ConnectionKeychainKey.password(for: config)),
      restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
      ))
    try await manager.connectWithoutUnlockCheck(config: config, savesConnection: false)
    return manager
  }

  @Test("The switched config pins the home database, copies every field and clears on return")
  func switchedConfig() {
    var original = Self.config(database: "app", tunnel: true)
    original.name = "Prod"
    let switched = WorkspaceManager.switchedMongoConfig(original, to: "sales")
    #expect(switched.database == "sales")
    #expect(switched.mongoHomeDatabase == "app")
    #expect(switched.password == "secret")
    var expected = original
    expected.database = "sales"
    expected.mongoHomeDatabase = "app"
    #expect(switched == expected)

    let further = WorkspaceManager.switchedMongoConfig(switched, to: "orders")
    #expect(further.mongoHomeDatabase == "app")
    #expect(WorkspaceManager.switchedMongoConfig(further, to: "app") == original)

    // A blank saved database reads the session's default: going back to it clears the pin
    let blank = Self.config(database: "")
    let away = WorkspaceManager.switchedMongoConfig(blank, to: "sales")
    #expect(away.mongoHomeDatabase == "")
    #expect(WorkspaceManager.switchedMongoConfig(away, to: MongoSession.defaultDatabase) == blank)
  }

  @Test("A form connect to another server drops the pin and keys on the new connection")
  func formConnectElsewhereDropsPin() async throws {
    let manager = try await Self.connected(Self.home())
    #expect(await manager.switchMongoDatabase(to: "sales") == nil)
    var edited = try #require(manager.workspace.connectionConfig)
    edited.host = "other-\(UUID().uuidString).example"
    edited.rememberConnection = false  // Nothing reaches the recent list
    try await manager.connect(
      config: edited, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
    let config = try #require(manager.workspace.connectionConfig)
    #expect(config.mongoHomeDatabase == nil)
    #expect(config.database == "sales")
    #expect(manager.workspace.connectionKeychainKey == ConnectionKeychainKey.password(for: config))
  }

  @Test("A rename while switched saves the home entry under the new name")
  func renameWhileSwitched() async throws {
    let suiteName = "MongoDatabaseSwitchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let manager = try await Self.connected(Self.home())
    #expect(await manager.switchMongoDatabase(to: "sales") == nil)

    manager.renameConnection(
      to: "Renamed", defaults: defaults, passwords: RecordingConnectionPasswordStore())
    let saved = SessionManager.loadHistory(
      defaults: defaults, passwords: RecordingConnectionPasswordStore())
    #expect(saved.count == 1)
    #expect(saved.first?.config.database == "app")
    #expect(saved.first?.config.mongoHomeDatabase == nil)
    #expect(saved.first?.config.name == "Renamed")
    #expect(manager.workspace.connectionConfig?.mongoHomeDatabase == "app")
  }

  @Test("A switch reconnects pinned, adds no recent entry and closes the old database's viewers")
  func switchReconnects() async throws {
    let home = Self.home()
    let manager = try await Self.connected(home)
    let keychainKey = manager.workspace.connectionKeychainKey
    manager.openDataViewer(schema: "app", name: "orders", orderColumns: ["_id"])
    let pinned = try #require(manager.tabs.first?.id)
    manager.setPinned(true, id: pinned)
    manager.openDataViewer(schema: "app", name: "users", orderColumns: ["_id"])
    #expect(manager.tabs.count == 2)

    #expect(await manager.switchMongoDatabase(to: "sales") == nil)
    #expect(manager.connectionState == .connected)
    #expect(
      manager.workspace.connectionConfig == WorkspaceManager.switchedMongoConfig(home, to: "sales"))
    #expect(manager.workspace.connectionKeychainKey == keychainKey)
    #expect(manager.tabs.isEmpty)
    #expect(!Self.recentListMentions(home.host))

    // A reconnect with the pinned config (connection loss, reopen) never saves it either
    let switched = try #require(manager.workspace.connectionConfig)
    try await manager.connect(
      config: switched, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
    #expect(!Self.recentListMentions(home.host))

    #expect(await manager.switchMongoDatabase(to: "sales") != nil)
    #expect(await manager.switchMongoDatabase(to: "bad.name") != nil)
    #expect(await manager.switchMongoDatabase(to: "admin") == nil)
    #expect(await manager.switchMongoDatabase(to: "app") == nil)
    #expect(manager.workspace.connectionConfig == home)
  }

  @Test("A switch is refused while a tab has staged document changes")
  func refusedWhileStaged() async throws {
    let home = Self.home()
    let manager = try await Self.connected(home)
    manager.openDataViewer(schema: "app", name: "orders", orderColumns: ["_id"])
    let viewModel = try #require(manager.tabs.first.flatMap { manager.viewModel(for: $0.id) })
    var set = try MongoDocumentChangeSet(
      target: EditTarget(
        qualifiedName: "orders", tableID: .mongodb(database: "app", collection: "orders"),
        primaryKeyColumns: ["_id"], name: "orders"),
      columns: [])
    _ = try set.stageInsert(.document([MongoValue.Field("n", .int64(1))]))
    viewModel.dataViewer?.documentChangeSet = set

    #expect(
      await manager.switchMongoDatabase(to: "sales") == "Apply or discard the staged changes first")
    #expect(manager.workspace.connectionConfig == home)
    #expect(manager.tabs.count == 1)
  }

  @Test("A switch is refused on another engine and while an app transaction is pending")
  func refusedOffMongoAndInTransaction() async throws {
    let postgres = ConnectionConfig(
      databaseType: .postgresql, host: "db.example.com", port: 5432, database: "app",
      username: "ada")
    let other = WorkspaceManager(
      workspace: Workspace(connectionConfig: postgres), restoreTabs: false)
    #expect(
      await other.switchMongoDatabase(to: "sales")
        == "Only a MongoDB connection can switch databases")
    #expect(other.workspace.connectionConfig == postgres)

    let home = Self.home()
    let manager = try await Self.connected(home)
    manager.pendingTransaction = .appTx(pending: [])
    #expect(
      await manager.switchMongoDatabase(to: "sales")
        == NotebookViewModel.transactionPendingElsewhereMessage)
    #expect(manager.workspace.connectionConfig == home)
  }

  @Test("Restore skips a MongoDB viewer of another database")
  func restoreSkipsOtherDatabase() {
    let switched = WorkspaceManager.switchedMongoConfig(Self.home(), to: "sales")
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: switched), restoreTabs: false)
    for schema in ["app", "sales"] {
      let ref = WorkspaceTabReference.DataViewerReference(
        schema: schema, name: "orders", orderColumns: ["_id"])
      manager.restoreDataViewer(
        tabRef: WorkspaceTabReference(documentType: .dataViewer, title: "orders", dataViewer: ref),
        ref: ref)
    }
    #expect(manager.tabs.count == 1)
    #expect(
      manager.tabs.first.flatMap { manager.viewModel(for: $0.id)?.dataViewer?.schema } == "sales")
  }
}
