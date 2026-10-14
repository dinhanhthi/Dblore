// WorkspaceStructureEditorTests.swift
// The sidebar entry point: opening the structure editor builds it on the active tab (a new one
// when none is open) and loads the table; Apply reloads the sidebar schema; close hides it.

import Foundation
import Testing

@testable import Dblore

@Suite("WorkspaceStructureEditorTests")
@MainActor
struct WorkspaceStructureEditorTests {
  @Test("Open loads the table, Apply reloads the sidebar schema, Close hides the editor")
  func openApplyClose() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-structure-workspace-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.connectionState = .connected
    workspace.workspace.connectionConfig = config
    await workspace.loadDatabaseSchema()

    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)
    #expect(workspace.activeViewModel != nil)
    await waitUntil { model.loadState == .loaded }
    #expect(model.workingColumns.map(\.column.name) == ["id"])

    model.addColumn(
      StructureChange.NewColumn(
        name: "note", type: "TEXT", isNullable: true, defaultExpression: nil))
    await model.apply()
    #expect(model.applyError == nil)
    await waitUntil {
      workspace.databaseTables.first { $0.name == "items" }?.columns.count == 2
    }
    #expect(
      workspace.databaseTables.first { $0.name == "items" }?.columns.map(\.name) == [
        "id", "note",
      ])

    workspace.closeStructureEditor()
    #expect(workspace.structureEditor == nil)
  }

  @Test("Closing during the Safe Mode step cancels it: a late confirm sends nothing")
  func closeCancelsConfirmation() async throws {
    let url = try Self.makeDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Self.config(url: url)
    config.commitStyle = .password
    let workspace = try await Self.connectedWorkspace(config)
    defer { Task { await workspace.connectionManager.disconnect() } }

    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)
    await waitUntil { model.loadState == .loaded }
    model.addColumn(
      StructureChange.NewColumn(
        name: "note", type: "TEXT", isNullable: true, defaultExpression: nil))
    await model.apply()
    #expect(model.pendingConfirmation != nil)

    workspace.closeStructureEditor()
    #expect(workspace.structureEditor == nil)
    #expect(model.pendingConfirmation == nil)
    await model.confirmApply()
    let table = try await workspace.connectionManager.fetchTableStructure(
      schema: "main", table: "items")
    #expect(table.columns.map(\.name) == ["id"])
  }

  @Test("A pending (Protected) change makes the editor view-only until the transaction ends")
  func pendingReEnablesAfterRollback() async throws {
    let url = try Self.makeDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Self.config(url: url)
    config.protectedMode = true
    let workspace = try await Self.connectedWorkspace(config)
    defer { Task { await workspace.connectionManager.disconnect() } }

    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)
    await waitUntil { model.loadState == .loaded }
    model.addColumn(
      StructureChange.NewColumn(
        name: "note", type: "TEXT", isNullable: true, defaultExpression: nil))
    await model.apply()
    #expect(model.resultMessage == StructureEditorModel.pendingMessage)
    #expect(model.disabledReason == StructureEditorModel.pausedMessage)
    #expect(!workspace.pendingTransaction.isIdle)

    #expect(await workspace.rollback())
    await waitUntil { model.disabledReason == nil }
    #expect(model.disabledReason == nil)
    #expect(model.workingColumns.map(\.column.name) == ["id"])
    #expect(model.resultMessage == nil)
  }

  private static func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-structure-workspace-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    return url
  }

  private static func config(url: URL) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
  }

  private static func connectedWorkspace(
    _ config: ConnectionConfig
  ) async throws
    -> WorkspaceManager
  {
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    workspace.connectionState = .connected
    workspace.workspace.connectionConfig = config
    await workspace.loadDatabaseSchema()
    return workspace
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(10)
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
