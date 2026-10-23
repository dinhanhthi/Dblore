// WorkspaceCrossTableSearchConnectTests.swift
// Find a Value in Every Table belongs to one connection: a connect to another server without a
// disconnect first drops the search, so its table list is never searched on the new server, and
// a side connect for the pinned connection never carries another connection's secret.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace cross-table search connect")
@MainActor
struct WorkspaceCrossTableSearchConnectTests {
  private static func config(host: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: host, port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  @Test("A connect without a disconnect drops the search of the previous connection")
  func connectDropsSearch() async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.config(host: "a.example")), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract())))
    try await manager.connectWithoutUnlockCheck(
      config: Self.config(host: "a.example"), savesConnection: false)
    manager.cancelSchemaLoad()
    manager.databaseTables = [
      DatabaseTable(
        schema: "public", name: "orders", columns: [DatabaseColumn(name: "id", type: "int4")])
    ]
    manager.schemaConnectionEpoch = 1
    manager.openCrossTableSearch()
    #expect(manager.crossTableSearch != nil)
    #expect(manager.isCrossTableSearchPresented)

    try await manager.connectWithoutUnlockCheck(
      config: Self.config(host: "b.example"), savesConnection: false)
    manager.cancelSchemaLoad()
    #expect(manager.crossTableSearch == nil)
    #expect(!manager.isCrossTableSearchPresented)
  }

  /// Records the scoped certificate's account each new session is opened under
  nonisolated private final class ScopeRecordingFactory: DatabaseSessionFactory,
    @unchecked Sendable
  {
    let inner = FakeDatabaseSessionFactory(capabilities: .contract())
    private let lock = NSLock()
    private var recorded: [String?] = []

    var accounts: [String?] { lock.withLock { recorded } }

    func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
      let account = ClientCertificateStoreFactory.operationMaterial?.account
      lock.withLock { recorded.append(account) }
      return inner.makeSession(config: config)
    }
  }

  @Test("A side connect for the pinned connection never gets the next one's certificate")
  func sideConnectKeepsThePinnedIdentitysSecrets() async throws {
    let factory = ScopeRecordingFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let pinned = Self.config(host: "a.example")
    try await manager.connect(config: pinned)
    var next = Self.config(host: "b.example")
    next.rememberConnection = false
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: next),
      material: ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key"))
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await manager.connect(config: next)
    }
    scoped.clear()
    #expect(await manager.activeUnrememberedCertificate != nil)

    let side = manager.makeReadOnlySideManager()
    try await manager.connectSideManager(side, config: pinned, identity: pinned)
    await side.disconnect()

    #expect(factory.accounts.count == 3)
    #expect(factory.accounts.last == .some(nil))
  }
}
