// ObjectSourceUITests.swift
// Entry points and guards of the read-only source viewer: the trigger subtitle and banner
// name, View Source palette rows, the editable copy, and Run / Explain refusing to run a
// source tab. No server: a temporary SQLite file (triggers keep their CREATE text).

import Foundation
import Testing

@testable import Dblore

@Suite("Object source UI")
@MainActor
struct ObjectSourceUITests {
  private func sqliteWorkspace() async throws -> (WorkspaceManager, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-object-source-ui-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("CREATE TABLE audit (item_id INTEGER)")
    try handle.execute(
      """
      CREATE TRIGGER items_audit AFTER INSERT ON items
      BEGIN INSERT INTO audit (item_id) VALUES (new.id); END
      """)
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    workspace.connectionState = .connected
    await workspace.loadDatabaseSchema()
    return (workspace, url)
  }

  private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  /// Opens the first trigger and waits for its definition
  private func openLoadedTrigger(_ workspace: WorkspaceManager) async throws -> UUID {
    let trigger = try #require(workspace.databaseTriggers.first)
    let id = workspace.openObjectSource(.trigger(trigger))
    await workspace.objectSourceLoads[id]?.value
    #expect(workspace.viewModels[id]?.objectSourceLoad == .loaded)
    return id
  }

  // MARK: - Display helpers

  @Test("trigger subtitle names the table, timing and events")
  func triggerSubtitle() {
    let trigger = DatabaseTrigger(
      schema: "public", table: "orders", name: "audit", timing: .before,
      events: [.insert, .update], enabled: true)
    #expect(trigger.sidebarSubtitle == "on orders · BEFORE INSERT OR UPDATE")
  }

  @Test("a disabled trigger says so in its subtitle")
  func disabledTriggerSubtitle() {
    let trigger = DatabaseTrigger(
      schema: "public", table: "orders", name: "audit", timing: .insteadOf, events: [.delete],
      enabled: false)
    #expect(trigger.sidebarSubtitle == "on orders · INSTEAD OF DELETE · disabled")
  }

  @Test("the banner name is schema-qualified unless the engine has no schema")
  func qualifiedName() {
    let routine = ObjectSourceRef(
      kind: .function, schema: "public", name: "lower", arguments: "text")
    #expect(routine.qualifiedName == "public.lower(text)")
    let trigger = ObjectSourceRef(kind: .trigger, schema: "", name: "items_audit", table: "items")
    #expect(trigger.qualifiedName == "items_audit on items")
  }

  // MARK: - Palette

  @Test("the palette lists a View Source row per function, procedure and trigger")
  func paletteSourceRows() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.databaseFunctions = [
      DatabaseFunction(schema: "public", name: "lower", returnType: "text", arguments: "text")
    ]
    manager.databaseProcedures = [DatabaseProcedure(schema: "public", name: "archive")]
    manager.databaseTriggers = [
      DatabaseTrigger(
        schema: "public", table: "orders", name: "audit", timing: .after, events: [.insert],
        enabled: true)
    ]

    let sources = manager.paletteSources()

    #expect(sources.sources.map(\.kind) == [.function, .procedure, .trigger])
    #expect(sources.sources.map(\.title) == ["lower(text)", "archive()", "audit on orders"])
    let rows = sources.items.filter {
      if case .source = $0 { return true }
      return false
    }
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.searchTexts.contains("View Source") })
  }

  @Test("View Source for an object no longer in the schema keeps the palette open")
  func performUnknownSource() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let ref = ObjectSourceRef(kind: .procedure, schema: "public", name: "gone")
    #expect(!manager.perform(.source(ref)))
    #expect(manager.tabs.allSatisfy { !$0.isReadOnlySource })
  }

  @Test("View Source from the palette opens the read-only tab")
  func performOpensSource() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let ref = try #require(workspace.paletteSources().sources.first { $0.kind == .trigger })

    #expect(workspace.perform(.source(ref)))

    let tab = try #require(workspace.tabs.first { $0.id == workspace.activeTabId })
    #expect(tab.objectSource?.key == ref.key)
    await workspace.objectSourceLoads[tab.id]?.value
  }

  // MARK: - Editable copy

  @Test("an editable copy is a new dirty untitled SQL tab holding the source")
  func editableCopy() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let sourceId = try await openLoadedTrigger(workspace)
    let source = try #require(workspace.viewModels[sourceId]?.editorContent)

    let copyId = try #require(workspace.openEditableCopy(ofSourceTab: sourceId))

    let copy = try #require(workspace.tabs.first { $0.id == copyId })
    #expect(copyId != sourceId)
    #expect(workspace.activeTabId == copyId)
    #expect(copy.documentType == .sqlFile)
    #expect(!copy.isReadOnlySource)
    #expect(copy.isDirty)
    #expect(workspace.viewModels[copyId]?.editorContent == source)
    #expect(workspace.viewModels[copyId]?.isReadOnlySource == false)
    #expect(workspace.viewModels[copyId]?.editorResult == nil)
  }

  @Test("no editable copy before the source has loaded")
  func editableCopyWhileLoading() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let trigger = try #require(workspace.databaseTriggers.first)
    let id = workspace.openObjectSource(.trigger(trigger))
    let tabCount = workspace.tabs.count

    #expect(workspace.openEditableCopy(ofSourceTab: id) == nil)
    #expect(workspace.tabs.count == tabCount)
    await workspace.objectSourceLoads[id]?.value
  }

  // MARK: - Never run

  @Test("Run and Explain do nothing on a source tab")
  func sourceNeverRuns() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let id = try await openLoadedTrigger(workspace)
    let viewModel = try #require(workspace.viewModels[id])

    await viewModel.runEditorQuery()
    await viewModel.explainSelectedStatement(analyze: false)

    #expect(viewModel.editorResult == nil)
    #expect(viewModel.editorStatementResults.isEmpty)
  }

  // MARK: - AI and pinning

  @Test("AI quick actions get no SQL or error from a source tab")
  func aiContextHiddenOnSourceTab() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let id = try await openLoadedTrigger(workspace)
    let viewModel = try #require(workspace.viewModels[id])
    viewModel.editorResult = CellResult(error: "server says no")

    #expect(viewModel.aiCurrentSQL == nil)
    #expect(viewModel.aiLastError == nil)
    await workspace.performDisconnect()
  }

  @Test("AI insert leaves a source tab untouched")
  func aiInsertRefusedOnSourceTab() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let id = try await openLoadedTrigger(workspace)
    let viewModel = try #require(workspace.viewModels[id])
    let before = viewModel.editorContent

    viewModel.insertAISQL("SELECT 1")

    #expect(viewModel.editorContent == before)
    await workspace.performDisconnect()
  }

  @Test("a source tab cannot be pinned")
  func sourceTabNotPinnable() async throws {
    let (workspace, url) = try await sqliteWorkspace()
    defer { removeDatabase(url) }
    let id = try await openLoadedTrigger(workspace)

    workspace.setPinned(true, id: id)

    #expect(workspace.tabs.first { $0.id == id }?.isPinned == false)
    await workspace.performDisconnect()
  }
}
