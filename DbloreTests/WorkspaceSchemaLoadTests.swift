// WorkspaceSchemaLoadTests.swift
// Non-blocking schema load (perf phase 3.5): connect returns before the schema is assigned,
// a disconnect / refresh cancels the background load, a load discarded by a Protected
// transaction is retried when the transaction ends. Docker test database (TestDatabase).
// Other suites run in parallel on the same database: only the own schema is asserted.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace Schema Load - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct WorkspaceSchemaLoadTests {
  private static func config(protectedMode: Bool = false) -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: protectedMode
    )
  }

  private struct Fixture {
    let workspace: WorkspaceManager
    let observer: DatabaseConnectionManager
    let schema: String
    let tableCount: Int

    @MainActor func ownTables() -> [String] {
      workspace.databaseTables.filter { $0.schema == schema }.map(\.name)
    }
  }

  /// A uniquely named schema with `tableCount` tables, created through an unprotected observer
  private func setUp(tableCount: Int = 40) async throws -> Fixture {
    let schema = "sl35_" + UUID().uuidString.prefix(8).lowercased()
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config())
    do {
      _ = try await observer.executeInternal("CREATE SCHEMA \(schema)")
      for index in 0..<tableCount {
        _ = try await observer.executeInternal(
          "CREATE TABLE \(schema).t\(index) (id int PRIMARY KEY, v int)")
      }
    } catch {
      // A failed setUp must not leak the schema or the connection
      _ = try? await observer.executeInternal("DROP SCHEMA IF EXISTS \(schema) CASCADE")
      await observer.disconnect()
      throw error
    }
    let workspace = WorkspaceManager(workspace: Workspace())
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    _ = workspace.newNotebook()
    return Fixture(
      workspace: workspace, observer: observer, schema: schema, tableCount: tableCount)
  }

  private func tearDown(_ fixture: Fixture) async {
    try? await fixture.workspace.connectionManager.rollbackAppTransaction()
    await fixture.workspace.disconnect(resolution: .rollback)
    _ = try? await fixture.observer.executeInternal(
      "DROP SCHEMA IF EXISTS \(fixture.schema) CASCADE")
    await fixture.observer.disconnect()
  }

  @Test("connect returns connected with a load task; awaitSchemaLoad fills the tables")
  func connectDoesNotBlockOnSchema() async throws {
    let fixture = try await setUp()
    try await fixture.workspace.connect(config: Self.config(), defaultCommitStyle: .immediate)
    // Deterministic halves: no await ran between connect's return and these reads
    #expect(fixture.workspace.connectionState == .connected)
    #expect(fixture.workspace.schemaLoadTask != nil)
    // Nothing suspended since connect started the load on this actor: not assigned yet
    #expect(fixture.ownTables().isEmpty)

    await fixture.workspace.awaitSchemaLoad()
    #expect(fixture.ownTables().count == fixture.tableCount)
    #expect(!fixture.workspace.isLoadingSchema)
    await tearDown(fixture)
  }

  @Test("disconnect during the load leaves the tables empty")
  func disconnectDuringLoad() async throws {
    let fixture = try await setUp()
    try await fixture.workspace.connect(config: Self.config(), defaultCommitStyle: .immediate)
    // disconnect drops the task reference: keep it to wait for the cancelled load to finish
    let load = try #require(fixture.workspace.schemaLoadTask)
    await fixture.workspace.disconnect(resolution: .rollback)
    await load.value
    await fixture.workspace.awaitSchemaLoad()

    #expect(fixture.workspace.connectionState == .disconnected)
    #expect(fixture.workspace.databaseTables.isEmpty)
    #expect(!fixture.workspace.isLoadingSchema)
    await tearDown(fixture)
  }

  @Test("Protected transaction right after connect: no schema while paused, rollback reloads")
  func protectedTransactionAfterConnect() async throws {
    let fixture = try await setUp(tableCount: 3)
    try await fixture.workspace.connect(
      config: Self.config(protectedMode: true), defaultCommitStyle: .immediate)
    // Open the app transaction before the load is awaited
    _ = try await fixture.workspace.connectionManager.execute(
      userSQL: "UPDATE \(fixture.schema).t0 SET v = 1",
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))
    await fixture.workspace.refreshPendingTransaction()
    #expect(fixture.workspace.isSchemaPaused)

    // Whatever the racing first load did, a load while paused assigns nothing new
    await fixture.workspace.awaitSchemaLoad()
    fixture.workspace.databaseTables = []
    fixture.workspace.startSchemaLoad()
    await fixture.workspace.awaitSchemaLoad()
    #expect(fixture.workspace.databaseTables.isEmpty)

    #expect(await fixture.workspace.rollback())
    #expect(!fixture.workspace.isSchemaPaused)
    await fixture.workspace.awaitSchemaLoad()
    #expect(fixture.ownTables().count == 3)
    await tearDown(fixture)
  }

  @Test("refresh cancels an in-flight background load; the latest data wins")
  func refreshCancelsBackgroundLoad() async throws {
    let fixture = try await setUp()
    try await fixture.workspace.connect(config: Self.config(), defaultCommitStyle: .immediate)
    let background = try #require(fixture.workspace.schemaLoadTask)

    _ = try await fixture.observer.executeInternal(
      "CREATE TABLE \(fixture.schema).late (id int)")
    await fixture.workspace.refreshDatabaseSchema()
    await background.value

    #expect(fixture.workspace.schemaLoadTask == nil)
    #expect(fixture.ownTables().count == fixture.tableCount + 1)
    #expect(fixture.ownTables().contains("late"))
    #expect(!fixture.workspace.isLoadingSchema)
    await tearDown(fixture)
  }

  @Test("a superseded background load neither clears isLoadingSchema nor assigns its data")
  func supersededLoadKeepsSpinner() async throws {
    let fixture = try await setUp(tableCount: 150)
    try await fixture.workspace.connect(config: Self.config(), defaultCommitStyle: .immediate)
    await fixture.workspace.awaitSchemaLoad()
    _ = try await fixture.observer.executeInternal(
      "CREATE TABLE \(fixture.schema).late (id int)")

    fixture.workspace.startSchemaLoad()
    let workspace = fixture.workspace
    // Make the first load genuinely in flight (started, first query issued) before the refresh
    // supersedes it: hop through the connection actor and let the load task run.
    _ = await workspace.connectionManager.isConnected
    for _ in 0..<5 { await Task.yield() }
    #expect(workspace.schemaLoadTask != nil)
    #expect(workspace.isLoadingSchema)
    var finished = false
    let refresh = Task { @MainActor in
      await workspace.refreshDatabaseSchema()
      finished = true
    }
    // Once the refresh is loading, the flag must stay true until it returns
    var sawLoading = false
    var clearedEarly = false
    let deadline = ContinuousClock.now + .seconds(30)
    while !finished {
      if ContinuousClock.now > deadline {
        Issue.record("refreshDatabaseSchema did not finish within 30s")
        break
      }
      if workspace.isLoadingSchema {
        sawLoading = true
      } else if sawLoading && !finished {
        clearedEarly = true
      }
      await Task.yield()
    }
    await refresh.value
    #expect(sawLoading)
    #expect(!clearedEarly)
    #expect(!workspace.isLoadingSchema)
    #expect(fixture.ownTables().contains("late"))
    await tearDown(fixture)
  }

  // MARK: - Auto-connect on open (3.6)

  /// A saved workspace file with a connection config; the password is in the Keychain only
  /// when `storePassword` (saved the way a successful connect does)
  private func savedWorkspace(config: ConnectionConfig, storePassword: Bool) throws -> URL {
    if storePassword { SessionManager.saveConnection(config) }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).sqlws")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Workspace(connectionConfig: config)).write(to: url)
    return url
  }

  @Test("load returns while connectionState is connecting, then becomes connected")
  func loadDoesNotAwaitAutoConnect() async throws {
    let url = try savedWorkspace(config: Self.config(), storePassword: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let manager = try await WorkspaceManager.load(from: url)
    // No suspension since load returned: the connect has not finished
    #expect(manager.connectionState == .connecting)
    #expect(manager.autoConnectTask != nil)

    await manager.awaitAutoConnect()
    #expect(manager.connectionState == .connected)
    await manager.awaitSchemaLoad()
    await manager.disconnect(resolution: .rollback)
  }

  @Test("auto-connect without a stored password ends disconnected, not stuck connecting")
  func autoConnectWithoutPassword() async throws {
    var config = Self.config()
    config.database = "sl36_" + UUID().uuidString.prefix(8).lowercased()  // unique Keychain key
    let url = try savedWorkspace(config: config, storePassword: false)
    defer { try? FileManager.default.removeItem(at: url) }

    let manager = try await WorkspaceManager.load(from: url)
    #expect(manager.connectionState == .connecting)
    await manager.awaitAutoConnect()
    #expect(manager.connectionState == .disconnected)
  }

  @Test("disconnect right after load cancels the auto-connect and stays disconnected")
  func disconnectCancelsAutoConnect() async throws {
    let url = try savedWorkspace(config: Self.config(), storePassword: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let manager = try await WorkspaceManager.load(from: url)
    let task = try #require(manager.autoConnectTask)
    await manager.disconnect(resolution: .rollback)
    await task.value

    #expect(manager.connectionState == .disconnected)
    #expect(manager.databaseTables.isEmpty)
    let stillConnected = await manager.connectionManager.isConnected
    #expect(!stillConnected)
  }

  // MARK: - Auto-connect vs manual connect

  /// Removes a Keychain entry the test added under its own unique key (never the shared docker key)
  private func removeSavedConnection(_ config: ConnectionConfig) {
    let key = "\(config.host):\(config.port):\(config.database):\(config.username)"
    for entry in SessionManager.loadHistory() where entry.keychainKey == key {
      SessionManager.removeConnection(id: entry.id)
    }
  }

  @Test("a manual connect during the auto-connect is not undone by it")
  func manualConnectWinsOverAutoConnect() async throws {
    // The docker key is shared with every integration suite: its Keychain entry is not deleted
    let url = try savedWorkspace(config: Self.config(), storePassword: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let manager = try await WorkspaceManager.load(from: url)
    try await manager.connect(config: Self.config(), defaultCommitStyle: .immediate)
    await manager.awaitAutoConnect()
    #expect(manager.connectionState == .connected)
    let connected = await manager.connectionManager.isConnected
    #expect(connected)
    await manager.awaitSchemaLoad()
    await manager.disconnect(resolution: .rollback)
  }

  @Test("a manual connect that throws before connecting does not leave the state connecting")
  func throwingManualConnectDoesNotStickConnecting() async throws {
    // Saved with the strictest settings; the manual connect weakens them: unlockRequired
    var strict = Self.config()
    strict.protectionLevel = .readOnly
    strict.safeMode = .safeAll
    strict.protectedMode = true
    let url = try savedWorkspace(config: strict, storePassword: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let manager = try await WorkspaceManager.load(from: url)
    #expect(manager.connectionState == .connecting)
    await #expect(throws: WorkspaceConnectError.unlockRequired) {
      try await manager.connect(
        config: Self.config(), defaultCommitStyle: .immediate, hasPassword: true)
    }
    await manager.awaitAutoConnect()
    #expect(manager.connectionState != .connecting)
    #expect(manager.connectionState == .disconnected)
    await manager.disconnect(resolution: .rollback)
  }

  @Test("a failing auto-connect does not overwrite a successful manual connect")
  func failedAutoConnectKeepsManualConnect() async throws {
    var unreachable = Self.config()
    unreachable.port = 1
    unreachable.database = "sl_auto_" + UUID().uuidString.prefix(8).lowercased()  // unique key
    let url = try savedWorkspace(config: unreachable, storePassword: true)
    defer {
      try? FileManager.default.removeItem(at: url)
      removeSavedConnection(unreachable)
    }

    let manager = try await WorkspaceManager.load(from: url)
    try await manager.connect(config: Self.config(), defaultCommitStyle: .immediate)
    await manager.awaitAutoConnect()
    #expect(manager.connectionState == .connected)
    let connected = await manager.connectionManager.isConnected
    #expect(connected)
    await manager.awaitSchemaLoad()
    await manager.disconnect(resolution: .rollback)
  }
}
