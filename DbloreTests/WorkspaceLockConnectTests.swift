// WorkspaceLockConnectTests.swift
// The workspace connect hold on locked connections: a blocked identity asks the unlock prompt
// before anything runs; cancel leaves the workspace disconnected, runs no script and reads no
// saved password; after the unlock a locked row loaded without its password connects with its
// saved one. The other workspace connect paths: a MongoDB database switch and Test ask, and
// auto-connect never connects a blocked identity nor reads its password (the locked banner's
// Unlock goes through the hold); a cancelled Reconnect keeps the connection-lost banner; a
// locked DuckDB file opened from Finder opens the form at once with the lock mark and its
// connect asks; Schema Compare marks a locked saved row and reads its password only after the
// unlock. Each test injects its own LockRegistry, prompter double, isolated UserDefaults
// suite and in-memory password store: no test touches LockRegistry.shared, the real Keychain or
// UserDefaults.standard. Sessions are fakes (no live database).

import AppKit
import Foundation
import Testing

@testable import Dblore

/// Answers every unlock with `answer` without showing anything; `onAsk` runs while it is open
@MainActor
private final class AnsweringUnlockPrompter: UnlockPrompter {
  var answer: Bool
  let onAsk: () -> Void
  private(set) var asked: [LockIdentity] = []

  init(answer: Bool, onAsk: @escaping () -> Void = {}) {
    self.answer = answer
    self.onAsk = onAsk
  }

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool {
    asked.append(item)
    onAsk()
    return answer
  }
}

/// Names of the connection scripts started, in order
private nonisolated final class StartedScripts: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  func append(_ name: String) { lock.withLock { names.append(name) } }
  var all: [String] { lock.withLock { names } }
}

/// Records its start and succeeds
private nonisolated final class RecordingScript: ConnectionScriptTask, @unchecked Sendable {
  var standardOutput: FileHandle?
  var standardError: FileHandle?
  let name: String
  let started: StartedScripts

  init(name: String, started: StartedScripts) {
    self.name = name
    self.started = started
  }

  func execute(
    withArguments arguments: [String]?, completionHandler handler: NSUserUnixTask.CompletionHandler?
  ) {
    started.append(name)
    DispatchQueue.global().async { handler?(nil) }
  }
}

/// The saved passwords Schema Compare read, in order
private nonisolated final class PasswordReads: @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String] = []
  func append(_ key: String) { lock.withLock { keys.append(key) } }
  var all: [String] { lock.withLock { keys } }
}

/// A Schema Compare target with one table; its source connections are itself, recorded
private actor CompareDatabase: SchemaCompareDatabase, SchemaCompareSourceConnection {
  private(set) var openedConfigs: [ConnectionConfig?] = []
  private let table = TableStructure(
    tableID: .postgresql(oid: 1), schema: "public", name: "orders",
    columns: [
      TableStructure.Column(
        ordinal: 1, name: "id", dataType: "integer", isNullable: false,
        defaultExpression: nil, identity: nil, generated: nil, comment: nil,
        columnType: nil, extra: nil, characterSet: nil, collation: nil)
    ],
    indexes: [], constraints: [])

  var databaseType: DatabaseType? { .postgresql }

  func structureEditorState() async -> StructureEditorConnectionState {
    StructureEditorConnectionState()
  }

  func fetchTables() async throws -> [DatabaseTable] {
    [DatabaseTable(schema: table.schema, name: table.name)]
  }

  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
    self.table
  }

  func fetchQualifiedTableStructures(
    schema: String, tables: [String], progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [TableStructure] { [table] }

  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
  ) async throws -> SchemaChangeResult {
    throw DatabaseError.notConnected
  }

  func openSchemaCompareSource(
    config: ConnectionConfig?, database: String?
  ) async throws -> any SchemaCompareSourceConnection {
    openedConfigs.append(config)
    return self
  }

  func disconnect() async {}
}

@Suite("Workspace Lock Connect")
@MainActor
struct WorkspaceLockConnectTests {
  /// A login on a host unique to this test, so rows never meet another test's
  private static func server() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "wslock-\(UUID().uuidString).example", port: 1,
      database: "db", username: "u", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
  }

  /// Saves `config` locked with `password`, as a row locked in an earlier session (blocked), and
  /// returns it as Recents load it: without its password
  private static func saveLocked(
    _ config: ConnectionConfig, password: String, defaults: UserDefaults,
    passwords: RecordingConnectionPasswordStore, registry: LockRegistry
  ) throws -> ConnectionConfig {
    var locked = config
    locked.isLocked = true
    locked.password = password
    #expect(
      SessionManager.saveConnection(
        locked, defaults: defaults, passwords: passwords, registry: registry))
    registry.relockAll()
    let row = try #require(
      SessionManager.loadHistory(
        defaults: defaults, passwords: NoPasswordStore(), registry: registry
      )
      .first { $0.keychainKey == ConnectionKeychainKey.password(for: config) })
    #expect(registry.refusal(for: row.config) != nil)
    #expect(row.config.password.isEmpty)
    return row.config
  }

  private static func workspace(
    for config: ConnectionConfig?, registry: LockRegistry, prompter: AnsweringUnlockPrompter,
    factory: FakeDatabaseSessionFactory, scripts: ConnectionScriptRunner = .app,
    defaults: UserDefaults, passwords: RecordingConnectionPasswordStore
  ) -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: factory, scripts: scripts, lockSource: registry),
      defaults: defaults, passwords: passwords, sanitizesFileConfig: false,
      lockCenter: LockCenter(
        registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
        prompter: prompter))
  }

  @Test("The connect hold asks; cancel connects nothing, runs no script and reads no password")
  func cancelledHoldConnectsNothing() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-wslock-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for script in ["up.sh", "down.sh"] {
      try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent(script))
    }
    let started = StartedScripts()
    let scripts = ConnectionScriptRunner(
      scriptsFolder: { folder },
      makeTask: { RecordingScript(name: $0.lastPathComponent, started: started) })
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    var server = Self.server()
    server.preConnectScript = "up.sh"
    server.postDisconnectScript = "down.sh"
    server.scriptTimeoutSeconds = 5
    let row = try Self.saveLocked(
      server, password: "secret", defaults: defaults, passwords: passwords, registry: registry)
    let prompter = AnsweringUnlockPrompter(answer: false)
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.workspace(
      for: row, registry: registry, prompter: prompter, factory: factory, scripts: scripts,
      defaults: defaults, passwords: passwords)

    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(config: row)
    }
    #expect(prompter.asked == [LockIdentity(row)])
    #expect(registry.refusal(for: row) != nil)
    #expect(started.all.isEmpty)
    #expect(passwords.loadedKeys.isEmpty)
    #expect(factory.sessions.isEmpty)
    #expect(manager.connectionState == .disconnected)
    #expect(manager.pendingWeakeningConnect == nil)
    #expect(manager.lastUnlockConnectError == nil)
    #expect(await !manager.connectionManager.isConnected)
  }

  @Test("After the unlock a locked row with an empty password connects with its saved password")
  func grantedHoldConnectsWithSavedPassword() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    let row = try Self.saveLocked(
      Self.server(), password: "secret", defaults: defaults, passwords: passwords,
      registry: registry)
    var readsWhileAsking: [String]?
    let prompter = AnsweringUnlockPrompter(answer: true) {
      readsWhileAsking = passwords.loadedKeys
    }
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.workspace(
      for: row, registry: registry, prompter: prompter, factory: factory, defaults: defaults,
      passwords: passwords)

    try await manager.connect(config: row)
    #expect(prompter.asked == [LockIdentity(row)])
    // Nothing was read before the grant
    #expect(readsWhileAsking == [])
    #expect(passwords.loadedKeys.contains(ConnectionKeychainKey.password(for: row)))
    #expect(manager.connectionState == .connected)
    #expect(await manager.connectionManager.config?.password == "secret")
    await manager.disconnect()
  }

  @Test("A MongoDB database switch of a relocked connection asks; cancel keeps the database")
  func mongoSwitchAsks() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    var mongo = ConnectionConfig(
      databaseType: .mongodb, host: "wslock-\(UUID().uuidString).example", port: 27017,
      database: "app", username: "ada", sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let row = try Self.saveLocked(
      mongo, password: "secret", defaults: defaults, passwords: passwords, registry: registry)
    mongo.password = "secret"
    let prompter = AnsweringUnlockPrompter(answer: false)
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = Self.workspace(
      for: mongo, registry: registry, prompter: prompter, factory: factory, defaults: defaults,
      passwords: passwords)
    // Unlocked earlier in the session, connected, then relocked
    registry.grant(LockIdentity(row))
    try await manager.connectWithoutUnlockCheck(config: mongo, savesConnection: false)
    registry.relockAll()

    #expect(await manager.switchMongoDatabase(to: "sales") != nil)
    #expect(prompter.asked == [LockIdentity(row)])
    #expect(factory.sessions.count == 1)
    #expect(manager.workspace.connectionConfig?.database == "app")

    prompter.answer = true
    #expect(await manager.switchMongoDatabase(to: "sales") == nil)
    #expect(prompter.asked.count == 2)
    #expect(manager.workspace.connectionConfig?.database == "sales")
    #expect(passwords.loadedKeys.isEmpty)
    await manager.disconnect()
  }

  @Test("Test of a locked connection asks; cancel tests nothing and reads no password")
  func testConnectionAsks() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    let row = try Self.saveLocked(
      Self.server(), password: "secret", defaults: defaults, passwords: passwords,
      registry: registry)
    let prompter = AnsweringUnlockPrompter(answer: false)
    let manager = Self.workspace(
      for: row, registry: registry, prompter: prompter,
      factory: FakeDatabaseSessionFactory(capabilities: .contract()), defaults: defaults,
      passwords: passwords)

    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.testConnection(config: row)
    }
    #expect(prompter.asked == [LockIdentity(row)])
    #expect(passwords.loadedKeys.isEmpty)
    #expect(registry.refusal(for: row) != nil)
  }

  @Test("Auto-connect (launch restore) of a locked connection connects nothing and shows Locked")
  func autoConnectStopsOnLock() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    let row = try Self.saveLocked(
      Self.server(), password: "secret", defaults: defaults, passwords: passwords,
      registry: registry)
    var readsWhileAsking: [String]?
    let prompter = AnsweringUnlockPrompter(answer: true) {
      readsWhileAsking = passwords.loadedKeys
    }
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = Self.workspace(
      for: row, registry: registry, prompter: prompter, factory: factory, defaults: defaults,
      passwords: passwords)

    // Launch restore of its window: it stays disconnected
    await manager.restoreLaunchTabs(overlays: [])
    #expect(manager.autoConnectTask != nil)
    await manager.autoConnectTask?.value
    #expect(prompter.asked.isEmpty)
    #expect(passwords.loadedKeys.isEmpty)
    #expect(factory.sessions.isEmpty)
    #expect(manager.connectionState == .disconnected)
    #expect(manager.isConnectLocked)

    // The banner's Unlock asks, reads the password after the grant, then connects
    await manager.unlockAndConnect()
    #expect(prompter.asked == [LockIdentity(row)])
    #expect(readsWhileAsking == [])
    #expect(manager.connectionState == .connected)
    #expect(await manager.connectionManager.config?.password == "secret")
    #expect(!manager.isConnectLocked)
    await manager.disconnect()
  }

  @Test("A Reconnect whose unlock is cancelled keeps the connection-lost banner")
  func cancelledReconnectKeepsLostBanner() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    let row = try Self.saveLocked(
      Self.server(), password: "secret", defaults: defaults, passwords: passwords,
      registry: registry)
    let prompter = AnsweringUnlockPrompter(answer: true)
    let manager = Self.workspace(
      for: row, registry: registry, prompter: prompter,
      factory: FakeDatabaseSessionFactory(capabilities: .contract()), defaults: defaults,
      passwords: passwords)
    try await manager.connect(config: row)
    await manager.performDisconnect(preserveCertificateForReconnect: true)
    manager.connectionLostMessage = "The server closed the connection"
    registry.relockAll()
    prompter.answer = false

    await manager.reconnectAfterConnectionLoss()
    #expect(prompter.asked.count == 2)
    #expect(manager.connectionLostMessage == "The server closed the connection")
    #expect(manager.connectionState == .disconnected)
  }

  @Test("A locked DuckDB file opens the form at once with the lock mark; its connect asks first")
  func lockedDuckDBFileOpensFormThenAsks() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-wslock-duckdb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("sales.duckdb")
    try Data().write(to: file)
    // Opened under another name of the locked file: only the lock's identity knows it
    let alias = folder.appendingPathComponent("alias.duckdb")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    let registry = LockRegistry()
    let passwords = RecordingConnectionPasswordStore()
    var saved = ConnectionFormContent.newFormDraft(databaseType: .duckdb)
    saved.database = file.path
    saved.name = "sales"
    saved.isLocked = true
    #expect(
      SessionManager.saveConnection(
        saved, defaults: defaults, passwords: passwords, registry: registry))
    registry.relockAll()
    let prompter = AnsweringUnlockPrompter(answer: false)
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.duckdb.capabilities)
    let manager = Self.workspace(
      for: nil, registry: registry, prompter: prompter, factory: factory, defaults: defaults,
      passwords: passwords)
    manager.accessHooks.makeBookmark = { _ in nil }

    manager.presentDuckDBFile(alias)
    // At once: the prefilled form with the lock mark, nothing asked yet
    #expect(manager.isConnectionFormModalVisible)
    let draft = manager.editingConnectionConfig
    #expect(draft.database == alias.path)
    #expect(draft.isLocked)
    #expect(prompter.asked.isEmpty)

    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(config: draft)
    }
    #expect(prompter.asked == [LockIdentity(draft)])
    #expect(factory.sessions.isEmpty)
    #expect(manager.connectionState == .disconnected)
    #expect(await !manager.connectionManager.isConnected)
  }

  @Test("Schema Compare marks a locked saved row and reads its password only after the unlock")
  func schemaCompareAsksBeforeReadingPassword() async throws {
    let name = "WorkspaceLockConnectTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let registry = LockRegistry()
    let row = try Self.saveLocked(
      Self.server(), password: "secret", defaults: defaults,
      passwords: RecordingConnectionPasswordStore(), registry: registry)
    let entries = SessionManager.loadHistory(
      defaults: defaults, passwords: NoPasswordStore(), registry: registry)
    let entry = try #require(entries.first { $0.config == row })
    let reads = PasswordReads()
    var readsWhileAsking: [[String]] = []
    let prompter = AnsweringUnlockPrompter(answer: false) { readsWhileAsking.append(reads.all) }
    let database = CompareDatabase()
    var context = SchemaCompareContext(
      database: database, databaseType: .postgresql,
      policy: { ProtectionPolicy(protectionLevel: .none) }, commitStyle: { .immediate },
      caller: nil, recordHistory: { _ in },
      password: {
        reads.append(ConnectionKeychainKey.password(for: $0))
        return "secret"
      })
    context.lockCenter = LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: prompter)
    let model = SchemaCompareModel(
      context: context, targetSchemas: ["public"], targetSchema: "public",
      savedConnections: entries)
    #expect(model.savedConnections.first { $0.id == entry.id }?.isLocked == true)
    model.sourceConnection = .saved(entry.id)
    model.sourceSchema = "public"

    // Cancel: nothing read, nothing opened or compared, no error
    await model.compare()
    #expect(prompter.asked == [LockIdentity(row)])
    #expect(reads.all.isEmpty)
    #expect(await database.openedConfigs.isEmpty)
    #expect(!model.hasResult)
    #expect(model.compareError == nil)
    #expect(!model.isComparing)

    // Granted: the password is read after the prompt, then the source opens with it
    prompter.answer = true
    await model.compare()
    #expect(prompter.asked.count == 2)
    #expect(readsWhileAsking == [[], []])
    #expect(reads.all == [ConnectionKeychainKey.password(for: row)])
    #expect(await database.openedConfigs.first??.password == "secret")
    #expect(model.hasResult)
  }
}
