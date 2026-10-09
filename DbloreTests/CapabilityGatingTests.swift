// CapabilityGatingTests.swift
// SQLite skips Keychain save/load/delete. PostgreSQL still uses host:port:database:username.
// Staged and inline row edits, table import and foreign key lookup follow the engine's
// capability flags: DuckDB refuses them with a clear message, PostgreSQL keeps them.

import Foundation
import Testing

@testable import Dblore

@Suite("Capability gating")
@MainActor
struct CapabilityGatingTests {
  private static let usersID = TableRef.postgresql(oid: 1)

  @Test("SQLite does not save, load, or delete a connection password")
  func sqliteSkipsPasswordStore() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let config = ConnectionConfig(
      databaseType: .sqlite,
      host: "db.example",
      port: 5432,
      database: "app",
      username: "ada",
      password: "should-not-be-stored",
      rememberConnection: true
    )

    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    let entry = try #require(loaded.first)
    #expect(entry.config.password.isEmpty)
    SessionManager.removeConnection(
      id: entry.id, defaults: harness.defaults, passwords: harness.store)

    #expect(harness.store.savedKeys.isEmpty)
    #expect(harness.store.loadedKeys.isEmpty)
    #expect(harness.store.deletedKeys.isEmpty)
  }

  @Test("PostgreSQL still stores the password under host:port:database:username")
  func postgresqlUsesExistingKey() throws {
    let harness = try Harness()
    defer { harness.cleanup() }
    let key = "db.example:5432:app:ada"
    let config = ConnectionConfig(
      databaseType: .postgresql,
      host: "db.example",
      port: 5432,
      database: "app",
      username: "ada",
      password: "s3cret",
      rememberConnection: true
    )

    SessionManager.saveConnection(config, defaults: harness.defaults, passwords: harness.store)
    let loaded = SessionManager.loadHistory(defaults: harness.defaults, passwords: harness.store)
    #expect(loaded.first?.config.password == "s3cret")
    #expect(loaded.first?.keychainKey == key)
    let entry = try #require(loaded.first)
    SessionManager.removeConnection(
      id: entry.id, defaults: harness.defaults, passwords: harness.store)

    #expect(harness.store.savedKeys == [key])
    #expect(!harness.store.loadedKeys.isEmpty)
    #expect(harness.store.loadedKeys.allSatisfy { $0 == key })
    #expect(harness.store.deletedKeys == [key])
  }

  // MARK: - Row edits

  @Test("DuckDB refuses staged and inline row edits; PostgreSQL stages them")
  func rowEditsFollowCapability() async throws {
    let duck = makeDataViewer(.duckdb)
    let message = "Editing rows is not available for DuckDB connections"
    #expect(duck.rowStagingUnavailableReason == message)
    #expect(!duck.stagingEnabled)
    #expect(duck.stageInsert() == message)
    #expect(await duck.addStagedRow() == message)
    #expect(duck.stageEdit(row: 0, column: "nickname", value: .string("neo")) == message)
    #expect(duck.stageDelete(rows: [0]) == message)
    #expect(duck.dataViewer?.changeSet == nil)
    #expect(!duck.canEdit(try #require(duck.editorResult)))

    let postgres = makeDataViewer(.postgresql)
    #expect(postgres.rowStagingUnavailableReason == nil)
    #expect(postgres.canEdit(try #require(postgres.editorResult)))
    #expect(postgres.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
  }

  // MARK: - Import

  @Test("DuckDB refuses a table import before reading the file")
  func importFollowsCapability() async {
    let model = TableImportModel(chooseFile: { nil })
    let duck = NotebookViewModel()
    duck.notebook.connectionConfig = config(.duckdb)
    duck.connectionManager = DatabaseConnectionManager()
    #expect(await model.submit(to: duck) == false)
    #expect(model.errorMessage == "Importing data is not available for DuckDB connections")

    let postgres = NotebookViewModel()
    postgres.notebook.connectionConfig = config(.postgresql)
    postgres.connectionManager = DatabaseConnectionManager()
    #expect(await model.submit(to: postgres) == false)
    #expect(model.errorMessage == TableImportError.noFile.localizedDescription)
  }

  @Test("The workspace offers Import Data only for a connected engine that supports it")
  func workspaceImportEntryPoint() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.workspace.connectionConfig = config(.postgresql)
    #expect(!manager.canImportData)
    manager.connectionState = .connected
    #expect(manager.canImportData)
    manager.workspace.connectionConfig = config(.duckdb)
    #expect(!manager.canImportData)
  }

  // MARK: - Foreign key lookup

  @Test("DuckDB hides and refuses foreign key lookup; PostgreSQL keeps it")
  func foreignKeyLookupFollowsCapability() async throws {
    let key = ForeignKey(
      constraintName: "orders_user", sourceSchema: "main", sourceTable: "orders",
      sourceColumns: ["user_id"], targetSchema: "main", targetTable: "users",
      targetColumns: ["id"])
    var opened = 0
    let duck = NotebookViewModel()
    duck.notebook.connectionConfig = config(.duckdb)
    duck.databaseForeignKeys = [key]
    duck.onOpenDataViewer = { _, _, _, _ in opened += 1 }
    #expect(duck.lookupForeignKeys.isEmpty)
    // No connection manager: a lookup that got past the gate would throw notConnected.
    let looked = try await duck.lookupReferencedRow(
      column: "user_id", schema: "main", table: "orders", rowColumns: ["user_id"],
      values: ["user_id": .int(7)])
    #expect(looked == nil)
    #expect(
      !duck.jumpToReferencedRow(
        column: "user_id", schema: "main", table: "orders", rowColumns: ["user_id"],
        values: ["user_id": .int(7)]))
    #expect(opened == 0)

    let postgres = NotebookViewModel()
    postgres.notebook.connectionConfig = config(.postgresql)
    postgres.databaseForeignKeys = [key]
    postgres.onOpenDataViewer = { _, _, _, _ in opened += 1 }
    #expect(postgres.lookupForeignKeys.map(\.id) == [key.id])
    #expect(
      postgres.jumpToReferencedRow(
        column: "user_id", schema: "main", table: "orders", rowColumns: ["user_id"],
        values: ["user_id": .int(7)]))
    #expect(opened == 1)
  }

  // MARK: - Helpers

  private func config(_ type: DatabaseType) -> ConnectionConfig {
    switch type {
    case .postgresql:
      ConnectionConfig(
        host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
        protectionLevel: .none, safeMode: .silent, protectedMode: false)
    case .sqlite, .duckdb:
      ConnectionConfig(
        databaseType: type, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: false)
    }
  }

  /// A data viewer on `users` with a primary-key edit target, as a live result would give.
  private func makeDataViewer(_ type: DatabaseType) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = config(type)
    var state = DataViewerState(schema: "main", name: "users", orderColumns: ["id"])
    state.databaseType = type
    viewModel.dataViewer = state
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4", origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2)),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "main.users", tableID: Self.usersID, primaryKeyColumns: ["id"]))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingConnectionPasswordStore

    init() throws {
      suiteName = "ace.thi.Dblore.tests.capability-gating.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      store = RecordingConnectionPasswordStore()
    }

    func cleanup() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}

/// Records password save/load/delete. Never opens the Keychain.
@MainActor
final class RecordingConnectionPasswordStore: ConnectionPasswordStore {
  private(set) var savedKeys: [String] = []
  private(set) var loadedKeys: [String] = []
  private(set) var deletedKeys: [String] = []
  private var passwords: [String: String] = [:]

  func savePassword(_ password: String, forKey key: String) {
    savedKeys.append(key)
    passwords[key] = password
  }

  func loadPassword(forKey key: String) -> String? {
    loadedKeys.append(key)
    return passwords[key]
  }

  func deletePassword(forKey key: String) {
    deletedKeys.append(key)
    passwords[key] = nil
  }
}
