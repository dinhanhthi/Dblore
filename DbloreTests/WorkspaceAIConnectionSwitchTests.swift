// WorkspaceAIConnectionSwitchTests.swift
// A direct switch from a connection that is private to AI to an allowed one: nothing read from
// the first connection (schema, picked tables, MongoDB screen, tab errors) reaches the assistant
// under the second one's permission.

import Foundation
import Testing

@testable import Dblore

/// Records every request and answers "ok"
nonisolated private final class CapturingAIClient: AIChatClient, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [AIChatRequest] = []

  var requests: [AIChatRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    lock.lock()
    captured.append(request)
    lock.unlock()
    return AsyncThrowingStream { continuation in
      continuation.yield(.text("ok"))
      continuation.finish()
    }
  }

  func listModels() async throws -> [String] { [] }
}

@Suite("Workspace AI connection switch")
@MainActor
struct WorkspaceAIConnectionSwitchTests {
  /// Table or collection name that only the first connection has
  private static let secret = "zq_payroll_secret"

  private static func config(
    _ type: DatabaseType = .postgresql, host: String, _ policy: AIAccessPolicy
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: type, host: host, port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.aiAccess = policy
    return config
  }

  /// A workspace connected to `config` through `factory`, without saving it. The AI access
  /// follows the live config on its own gate, so the saved list stays out of it.
  private static func connected(
    _ config: ConnectionConfig, factory: FakeDatabaseSessionFactory
  ) async throws -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
    let gate = AIAccessGate()
    manager.aiAccessSource = { [weak manager] in
      manager?.workspace.connectionConfig.map {
        AIAccessContext(config: $0, savedPolicies: [], gate: gate)
      }
    }
    try await manager.connectWithoutUnlockCheck(config: config, savesConnection: false)
    manager.cancelSchemaLoad()
    return manager
  }

  /// Connects `manager` to `config`; the new schema load does not land
  private static func switchTo(
    _ manager: WorkspaceManager, _ config: ConnectionConfig
  )
    async throws
  {
    try await manager.connectWithoutUnlockCheck(config: config, savesConnection: false)
    manager.cancelSchemaLoad()
  }

  private static func settings() -> AISettings {
    let defaults = UserDefaults(suiteName: "WorkspaceAIConnectionSwitchTests-\(UUID().uuidString)")!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")])
    return settings
  }

  @Test("Until the new schema lands, a send carries no table or pick of the previous connection")
  func switchSendsNoPreviousSchema() async throws {
    // Every catalog read fails: the new connection's schema load never lands
    let manager = try await Self.connected(
      Self.config(host: "a.example", .never),
      factory: FakeDatabaseSessionFactory(capabilities: .contract(), failingQuery: "pg_namespace"))
    manager.databaseTables = [
      DatabaseTable(
        schema: "public", name: Self.secret, columns: [DatabaseColumn(name: "id", type: "int4")])
    ]
    manager.databaseForeignKeys = [
      ForeignKey(
        constraintName: "fk", sourceSchema: "public", sourceTable: Self.secret,
        sourceColumns: ["id"], targetSchema: "public", targetTable: Self.secret,
        targetColumns: ["id"])
    ]
    manager.schemaConnectionEpoch = 1
    manager.aiAssistant.selectedTableNames = ["public.\(Self.secret)"]

    try await manager.connectWithoutUnlockCheck(
      config: Self.config(host: "b.example", .always), savesConnection: false)
    await manager.awaitSchemaLoad()  // failed: the arrays still hold the first one's schema
    #expect(manager.databaseTables.map(\.name) == [Self.secret])
    #expect(manager.databaseForeignKeys.count == 1)
    #expect(manager.aiAssistant.schemaSource().tables.isEmpty)
    #expect(manager.aiAssistant.schemaSource().foreignKeys.isEmpty)
    #expect(manager.aiAssistant.selectedTableNames.isEmpty)

    // The workspace assistant's sources, sent through a scripted provider
    let client = CapturingAIClient()
    let vm = AIAssistantViewModel(settings: Self.settings(), makeClient: { _, _, _ in client })
    vm.schemaSource = manager.aiAssistant.schemaSource
    vm.mongoScreenSource = manager.aiAssistant.mongoScreenSource
    vm.aiAccessSource = manager.aiAssistant.aiAccessSource
    vm.selectedTableNames = manager.aiAssistant.selectedTableNames
    vm.draft = "average id of \(Self.secret)"
    vm.send()
    for _ in 0..<500 where vm.isGenerating { try? await Task.sleep(for: .milliseconds(10)) }

    let system = try #require(client.requests.last?.system)
    #expect(!system.contains(Self.secret))
    await manager.performDisconnect()
  }

  @Test(
    "A MongoDB tab still showing the previous connection's collection gets no screen or one-shot")
  func switchDropsPreviousMongoScreen() async throws {
    let manager = try await Self.connected(
      Self.config(.mongodb, host: "a.example", .never),
      factory: FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities))
    manager.openDataViewer(schema: "hr", name: Self.secret, orderColumns: [])
    manager.databaseTables = [DatabaseTable(schema: "hr", name: Self.secret)]
    manager.schemaConnectionEpoch = 1
    #expect(manager.aiAssistant.mongoScreenSource()?.collection == Self.secret)
    let model = try #require(manager.activeViewModel?.mongoCollection)

    // The workspace assistant's sources, sent through a scripted provider
    let client = CapturingAIClient()
    let vm = AIAssistantViewModel(settings: Self.settings(), makeClient: { _, _, _ in client })
    vm.schemaSource = manager.aiAssistant.schemaSource
    vm.aiAccessSource = manager.aiAssistant.aiAccessSource
    vm.isCurrentMongoCollection = manager.aiAssistant.isCurrentMongoCollection
    let oneShot = {
      try await vm.mongoAssist(
        .filter, prompt: "rows", database: model.database, collection: model.collection,
        current: "{salary: {$gt: 1}}")
    }

    try await Self.switchTo(manager, Self.config(.mongodb, host: "b.example", .always))
    #expect(manager.aiAssistant.mongoScreenSource() == nil)
    await #expect(throws: AIAssistantViewModel.AIAccessError.otherConnection) {
      _ = try await oneShot()
    }
    // The new schema landed without that collection
    manager.databaseTables = [DatabaseTable(schema: "shop", name: "orders")]
    manager.schemaConnectionEpoch = 2
    #expect(manager.aiAssistant.mongoScreenSource() == nil)
    await #expect(throws: AIAssistantViewModel.AIAccessError.otherConnection) {
      _ = try await oneShot()
    }
    #expect(client.requests.isEmpty)

    // The new connection has that collection too: it is its own
    manager.databaseTables = [DatabaseTable(schema: "hr", name: Self.secret)]
    _ = try await oneShot()
    #expect(client.requests.count == 1)
    await manager.performDisconnect()
  }

  @Test("A tab error of the previous connection offers no Fix after a switch; a reconnect keeps it")
  func switchDropsPreviousTabError() async throws {
    let first = Self.config(host: "a.example", .never)
    let manager = try await Self.connected(
      first,
      factory: FakeDatabaseSessionFactory(capabilities: .contract(), failingQuery: Self.secret))
    manager.newSQLFile()
    let tab = try #require(manager.activeViewModel)
    await tab.executeEditorQuery("SELECT \(Self.secret)")
    #expect(tab.aiLastError != nil)

    try await Self.switchTo(manager, first)  // same connection: the error stays its own
    #expect(tab.aiLastError != nil)

    try await Self.switchTo(manager, Self.config(host: "b.example", .always))
    #expect(tab.aiLastError == nil)  // the Fix chip hides and fills nothing
    await manager.performDisconnect()
  }

  @Test("A Fix filled from a tab not yet on the new connection is held at send")
  func fixFromTabBeforeSyncIsHeld() async throws {
    let manager = try await Self.connected(
      Self.config(host: "a.example", .never),
      factory: FakeDatabaseSessionFactory(capabilities: .contract(), failingQuery: Self.secret))
    manager.newSQLFile()
    let tab = try #require(manager.activeViewModel)
    tab.editorContent = "SELECT \(Self.secret)"
    await tab.executeEditorQuery(tab.editorContent)

    // The connect window: the workspace is on the second connection, the tab still on the first
    manager.workspace.connectionConfig = Self.config(host: "b.example", .always)
    manager.aiAssistant.connectionDidChange()
    let sql = try #require(tab.aiCurrentSQL)
    let error = try #require(tab.aiLastError)

    let client = CapturingAIClient()
    let vm = AIAssistantViewModel(settings: Self.settings(), makeClient: { _, _, _ in client })
    vm.aiAccessSource = manager.aiAssistant.aiAccessSource
    vm.fixError(sql: sql, error: error, sessionKey: tab.aiSessionKey)  // as the panel does
    vm.send()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(client.requests.isEmpty)
    #expect(vm.draft.contains(Self.secret))
    #expect(vm.privateNote == .draftFromOtherConnection)
    await manager.performDisconnect()
  }
}
