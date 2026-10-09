// ObjectSourceTabTests.swift
// Read-only object source tabs (routine and trigger definitions): a .sqlFile tab flagged with
// `objectSource`. It is never dirty, cannot be saved, closes without a prompt, and is left out
// of workspace persistence and the launch snapshot.

import Foundation
import Testing

@testable import Dblore

@Suite("Object source tab")
@MainActor
struct ObjectSourceTabTests {
  private static let function = ObjectSourceRef(
    kind: .function, schema: "public", name: "add_one", arguments: "x integer", oid: 16_401)
  private static let trigger = ObjectSourceRef(
    kind: .trigger, schema: "public", name: "audit_users", table: "users")

  private static func manager() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
  }

  /// A SQL tab turned into an object source tab (the open action arrives in 6.2)
  private static func sourceTab(
    in manager: WorkspaceManager, ref: ObjectSourceRef = function
  ) throws -> UUID {
    let id = manager.newSQLFile()
    let index = try #require(manager.tabs.firstIndex { $0.id == id })
    manager.tabs[index].objectSource = ref
    manager.tabs[index].isDirty = false
    manager.tabs[index].title = ref.title
    try #require(manager.viewModel(for: id)).editorContent = "create function add_one()"
    return id
  }

  // MARK: - Codable

  @Test("TabItem round-trips with an object source")
  func roundTripWithSource() throws {
    let tab = TabItem(
      documentType: .sqlFile, title: "add_one(x integer)", objectSource: Self.function)
    let decoded = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(tab))
    #expect(decoded.objectSource == Self.function)
    #expect(decoded.isReadOnlySource)
  }

  @Test("TabItem round-trips without an object source")
  func roundTripWithoutSource() throws {
    let tab = TabItem(documentType: .sqlFile, title: "a.sql")
    let decoded = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(tab))
    #expect(decoded.objectSource == nil)
    #expect(!decoded.isReadOnlySource)
  }

  @Test("An older payload without the objectSource key decodes")
  func legacyPayload() throws {
    let json = """
      {"id":"\(UUID().uuidString)","documentType":"sqlFile","title":"a.sql","isDirty":false}
      """
    let decoded = try JSONDecoder().decode(TabItem.self, from: Data(json.utf8))
    #expect(decoded.objectSource == nil)
    #expect(decoded.title == "a.sql")
  }

  // MARK: - Key and title

  @Test("Refs with the same kind and oid share a key")
  func keyByOid() {
    let renamed = ObjectSourceRef(
      kind: .function, schema: "other", name: "renamed", arguments: "", oid: 16_401)
    #expect(Self.function.key == renamed.key)
    let trigger = ObjectSourceRef(kind: .trigger, schema: "public", name: "t", oid: 16_401)
    #expect(Self.function.key != trigger.key)
  }

  @Test("Without an oid the key uses kind, schema, table, and name")
  func keyWithoutOid() {
    let same = ObjectSourceRef(
      kind: .trigger, schema: "public", name: "audit_users", table: "users")
    let otherTable = ObjectSourceRef(
      kind: .trigger, schema: "public", name: "audit_users", table: "orders")
    #expect(Self.trigger.key == same.key)
    #expect(Self.trigger.key != otherTable.key)
  }

  @Test("Titles read name(args) for routines and name on table for triggers")
  func titles() {
    #expect(Self.function.title == "add_one(x integer)")
    #expect(ObjectSourceRef(kind: .procedure, schema: "s", name: "p").title == "p()")
    #expect(Self.trigger.title == "audit_users on users")
  }

  // MARK: - Dirty, save, close

  @Test("markDirty leaves an object source tab clean")
  func neverDirty() throws {
    let manager = Self.manager()
    let id = try Self.sourceTab(in: manager)
    manager.markDirty(tabId: id)
    #expect(manager.tabs.first { $0.id == id }?.isDirty == false)
  }

  @Test("An object source tab is not save-eligible and saveTab does nothing")
  func notSaveable() async throws {
    let manager = Self.manager()
    let id = try Self.sourceTab(in: manager)
    let plain = manager.newSQLFile()
    #expect(!manager.canSave(tabId: id))
    #expect(manager.canSave(tabId: plain))

    try await manager.saveTab(id: id)
    #expect(manager.tabs.first { $0.id == id }?.fileURL == nil)
    #expect(manager.tabs.first { $0.id == id }?.isDirty == false)
  }

  @Test("Closing an object source tab never prompts")
  func closeWithoutPrompt() throws {
    let manager = Self.manager()
    let id = try Self.sourceTab(in: manager)
    manager.markDirty(tabId: id)
    manager.requestCloseTab(id: id)
    #expect(!manager.tabs.contains { $0.id == id })
    #expect(!manager.showingCloseConfirmation)
  }

  // MARK: - Persistence and launch snapshot

  @Test("Workspace persistence skips object source tabs and hands the active tab over")
  func persistenceSkips() throws {
    let manager = Self.manager()
    let plain = manager.newSQLFile()
    let source = try Self.sourceTab(in: manager)
    manager.selectTab(id: source)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let workspace = try decoder.decode(Workspace.self, from: manager.encodedWorkspaceData())
    #expect(workspace.tabs.map(\.id) == [plain])
    #expect(workspace.activeTabId == plain)
  }

  @Test("Launch capture writes no text overlay for an object source tab")
  func launchCaptureSkips() throws {
    let manager = Self.manager()
    let plain = manager.newSQLFile()
    let source = try Self.sourceTab(in: manager)

    let session = LaunchSessionCapture.session(
      windows: [
        LaunchSessionCapture.WindowDescriptor(
          frame: WindowFrame(x: 0, y: 0, width: 800, height: 600),
          isMiniaturized: false, groupID: "draft", tabIndex: 0, isSelectedInGroup: true,
          orderedIndex: 0, content: .workspace(manager.id))
      ],
      workspaces: [manager.id: manager])

    guard case .workspace(let workspace) = session.windows.first?.content else {
      Issue.record("Expected the captured window to be the draft workspace")
      return
    }
    let overlayIDs = workspace.textOverlays.map(\.tabId)
    #expect(overlayIDs.contains(plain))
    #expect(!overlayIDs.contains(source))
    #expect(workspace.workspace?.tabs.contains { $0.id == source } == false)
  }
}
