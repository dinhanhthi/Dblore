// WorkspaceSchemaGraphConnectTests.swift
// The diagram belongs to one database: a connect to another one or a disconnect forgets it, so
// the visualizer never reopens on the previous database's tables, and nothing is laid out until
// the new database's schema landed.

import Foundation
import Testing

@testable import Dblore

@Suite("Workspace schema graph connect")
@MainActor
struct WorkspaceSchemaGraphConnectTests {
  private static func config(host: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: host, port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  /// Connected to `host` with one table (its schema read) laid out in the diagram
  private static func managerWithDiagram(host: String) async throws -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config(host: host)), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract())))
    try await manager.connectWithoutUnlockCheck(config: config(host: host), savesConnection: false)
    manager.cancelSchemaLoad()
    manager.databaseTables = [
      DatabaseTable(
        schema: "public", name: "orders", columns: [DatabaseColumn(name: "id", type: "int4")])
    ]
    manager.schemaConnectionEpoch = 1
    await manager.loadSchemaGraph()
    return manager
  }

  @Test("A connect to another database forgets the previous database's diagram")
  func connectClearsDiagram() async throws {
    let manager = try await Self.managerWithDiagram(host: "a.example")
    #expect(manager.schemaGraph?.nodes.count == 1)

    try await manager.connectWithoutUnlockCheck(
      config: Self.config(host: "b.example"), savesConnection: false)
    manager.cancelSchemaLoad()
    #expect(manager.schemaGraph == nil)
  }

  @Test("Until the new database's schema lands nothing is laid out; then the open diagram is")
  func connectLaysOutOnlyTheNewSchema() async throws {
    let manager = try await Self.managerWithDiagram(host: "a.example")
    manager.isSchemaVisualizerActive = true

    try await manager.connectWithoutUnlockCheck(
      config: Self.config(host: "b.example"), savesConnection: false)
    // Before B's schema landed: the tables are still A's
    #expect(manager.schemaConnectionEpoch == nil)
    #expect(manager.databaseTables.map(\.name) == ["orders"])
    await manager.loadSchemaGraph()
    manager.showSchemaDiagram(tables: ["public.orders"])
    #expect(manager.schemaGraph == nil)
    #expect(manager.schemaDiagramTables == nil)
    #expect(!manager.isLoadingSchemaGraph)

    // B's (empty) schema lands: the open visualizer lays it out
    await manager.awaitSchemaLoad()
    #expect(manager.schemaConnectionEpoch != nil)
    for _ in 0..<500 where manager.schemaGraph == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(manager.schemaGraph?.nodes.isEmpty == true)
    await manager.performDisconnect()
  }

  @Test("A disconnect forgets the diagram")
  func disconnectClearsDiagram() async throws {
    let manager = try await Self.managerWithDiagram(host: "a.example")
    #expect(manager.schemaGraph?.nodes.count == 1)

    await manager.performDisconnect()
    #expect(manager.schemaGraph == nil)
  }
}
