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
    #expect(await waitUntil { model.loadState == .loaded })
    #expect(model.workingColumns.map(\.column.name) == ["id"])

    model.addColumn(
      StructureChange.NewColumn(
        name: "note", type: "TEXT", isNullable: true, defaultExpression: nil))
    await model.apply()
    #expect(model.applyError == nil)
    #expect(
      await waitUntil {
        workspace.databaseTables.first { $0.name == "items" }?.columns.count == 2
      })
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
    #expect(await waitUntil { model.loadState == .loaded })
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
    #expect(await waitUntil { model.loadState == .loaded })
    model.addColumn(
      StructureChange.NewColumn(
        name: "note", type: "TEXT", isNullable: true, defaultExpression: nil))
    await model.apply()
    #expect(model.resultMessage == StructureEditorModel.pendingMessage)
    #expect(model.disabledReason == StructureEditorModel.pausedMessage)
    #expect(!workspace.pendingTransaction.isIdle)

    #expect(await workspace.rollback())
    #expect(await waitUntil { model.disabledReason == nil })
    #expect(model.disabledReason == nil)
    #expect(model.workingColumns.map(\.column.name) == ["id"])
    #expect(model.resultMessage == nil)
  }

  @Test("A rename retargets the open structure editor and the table's data viewer tab")
  func renameRetargetsTabs() async throws {
    let url = try Self.makeDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    let workspace = try await Self.connectedWorkspace(Self.config(url: url))
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.openDataViewer(schema: "main", name: "items", orderColumns: [])
    let viewerID = try #require(workspace.tabs.first?.id)

    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)
    #expect(await waitUntil { model.loadState == .loaded })
    model.renameTable(to: "goods")
    await model.apply()
    #expect(model.applyError == nil)

    #expect(workspace.structureEditor === model)
    #expect(model.table == "goods")
    #expect(await waitUntil { model.loadState == .loaded })
    #expect(model.structure?.name == "goods")
    #expect(workspace.viewModel(for: viewerID)?.dataViewer?.name == "goods")
    #expect(workspace.tabs.first { $0.id == viewerID }?.title == "goods")
  }

  @Test("A pending rename retargets the editor and the data viewer tab on Commit")
  func pendingRenameRetargetsOnCommit() async throws {
    let url = try Self.makeDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Self.config(url: url)
    config.protectedMode = true
    let workspace = try await Self.connectedWorkspace(config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.openDataViewer(schema: "main", name: "items", orderColumns: [])
    let viewerID = try #require(workspace.tabs.first?.id)
    // Commit is refused while the viewer's page or count read is in flight
    try #require(await waitUntil { Self.viewerLoaded(workspace, viewerID) })
    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)
    try #require(await waitUntil { model.loadState == .loaded })

    model.renameTable(to: "goods")
    await model.apply()
    #expect(!workspace.pendingTransaction.isIdle)
    #expect(model.table == "items")
    #expect(workspace.viewModel(for: viewerID)?.dataViewer?.name == "items")

    workspace.requestCommit()
    #expect(await workspace.confirmCommit())
    #expect(model.table == "goods")
    #expect(workspace.viewModel(for: viewerID)?.dataViewer?.name == "goods")
    #expect(
      await waitUntil { model.structure?.name == "goods" && model.disabledReason == nil })
    #expect(model.structure?.name == "goods")
    #expect(model.disabledReason == nil)
  }

  @Test("A pending drop keeps the table's tabs open until Commit; after Rollback they stay")
  func pendingDropClosesTabsOnCommit() async throws {
    let url = try Self.makeDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Self.config(url: url)
    config.protectedMode = true
    let workspace = try await Self.connectedWorkspace(config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.openDataViewer(schema: "main", name: "items", orderColumns: [])
    let viewerID = try #require(workspace.tabs.first?.id)
    workspace.openStructureEditor(schema: "main", table: "items")
    let model = try #require(workspace.structureEditor)

    // Commit and Rollback are refused while the viewer's page or count read is in flight
    func dropPending() async throws {
      try #require(await waitUntil { Self.viewerLoaded(workspace, viewerID) })
      try #require(
        await waitUntil { model.loadState == .loaded && model.disabledReason == nil })
      model.requestDropTable()
      await model.confirmDropTable(typedName: "items")
      #expect(!workspace.pendingTransaction.isIdle)
    }

    try await dropPending()
    #expect(model.resultMessage == StructureEditorModel.pendingMessage)
    #expect(workspace.tabs.contains { $0.id == viewerID })
    #expect(await workspace.rollback())
    #expect(workspace.tabs.contains { $0.id == viewerID })
    #expect(workspace.structureEditor === model)

    try await dropPending()
    workspace.requestCommit()
    #expect(await workspace.confirmCommit())
    #expect(!workspace.tabs.contains { $0.id == viewerID })
    #expect(workspace.structureEditor == nil)
    let tables = try await workspace.connectionManager.executeInternal(
      "SELECT name FROM sqlite_master WHERE type = 'table'")
    #expect(tables.rows.isEmpty)
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

  /// The data viewer tab's first page and row count were read (neither is in flight any more)
  private static func viewerLoaded(_ workspace: WorkspaceManager, _ id: UUID) -> Bool {
    guard let viewer = workspace.viewModel(for: id) else { return false }
    return viewer.dataViewer?.totalRows != nil && !viewer.isEditorQueryRunning
  }

  /// Polls `condition` until it holds; false on timeout (generous: the full suite runs slowly)
  private func waitUntil(
    _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(30)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}
