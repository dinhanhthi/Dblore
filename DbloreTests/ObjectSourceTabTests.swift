// ObjectSourceTabTests.swift
// Read-only object source tabs (routine and trigger definitions): a .sqlFile tab flagged with
// `objectSource`. It is never dirty, cannot be saved, closes without a prompt, and is left out
// of workspace persistence and the launch snapshot. A loaded source re-read after an outside
// change swaps its text in place; an unchanged or failed read leaves the tab as it is.

import Foundation
import Observation
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

  // MARK: - Dirty, save, close

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

  // MARK: - Re-read after an outside change

  @Test("A changed source swaps in place without the loading text; an unchanged one is untouched")
  func refreshSwapsChangedSourceOnly() async throws {
    let (workspace, url) = try await Self.sqliteWorkspace()
    defer { Self.removeDatabase(url) }
    let audit = try await Self.openLoaded("items_audit", in: workspace)
    let log = try await Self.openLoaded("items_log", in: workspace)
    let logBefore = log.editorContent
    let outside = try SQLiteHandle(url: url)
    try outside.execute("DROP TRIGGER items_audit")
    try outside.execute(Self.auditTrigger(value: "new.id + 1"))

    let auditText = ValueLog { audit.editorContent }
    let auditState = ValueLog { audit.objectSourceLoad }
    let logText = ValueLog { log.editorContent }
    await workspace.refreshObjectSourcesIfChanged()

    #expect(audit.editorContent.contains("new.id + 1"))
    #expect(audit.objectSourceLoad == .loaded)
    // Straight from the old text to the new one: no loading text or state in between
    #expect(auditText.changes == 1)
    #expect(!auditState.values.contains(.loading))
    // The unchanged source is not written again (a write resets its editor)
    #expect(logText.changes == 0)
    #expect(log.editorContent == logBefore)
    await workspace.performDisconnect()
  }

  @Test("A background read that finds no source or fails leaves the loaded source in place")
  func refreshKeepsSourceOnFailure() async throws {
    let (workspace, url) = try await Self.sqliteWorkspace()
    defer { Self.removeDatabase(url) }
    let audit = try await Self.openLoaded("items_audit", in: workspace)
    let before = audit.editorContent
    let text = ValueLog { audit.editorContent }

    // Dropped outside: the loaded schema still lists it, the read finds no source
    let outside = try SQLiteHandle(url: url)
    try outside.execute("DROP TRIGGER items_audit")
    await workspace.refreshObjectSourcesIfChanged()
    #expect(audit.editorContent == before)
    #expect(audit.objectSourceLoad == .loaded)

    // The connection is gone (the loaded lists stay): the read fails
    await workspace.connectionManager.disconnect()
    await workspace.refreshObjectSourcesIfChanged()
    #expect(audit.editorContent == before)
    #expect(audit.objectSourceLoad == .loaded)
    #expect(text.changes == 0)
    await workspace.performDisconnect()
  }

  /// A connected workspace on a temporary SQLite file with two triggers on `items`
  private static func sqliteWorkspace() async throws -> (WorkspaceManager, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-object-source-tab-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("CREATE TABLE audit (item_id INTEGER)")
    try handle.execute(auditTrigger(value: "new.id"))
    try handle.execute(
      """
      CREATE TRIGGER items_log AFTER DELETE ON items
      BEGIN DELETE FROM audit WHERE item_id = old.id; END
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

  private static func auditTrigger(value: String) -> String {
    """
    CREATE TRIGGER items_audit AFTER INSERT ON items
    BEGIN INSERT INTO audit (item_id) VALUES (\(value)); END
    """
  }

  private static func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  /// Opens the trigger's source tab and waits for its source
  private static func openLoaded(
    _ name: String, in workspace: WorkspaceManager
  ) async throws -> NotebookViewModel {
    let trigger = try #require(workspace.databaseTriggers.first { $0.name == name })
    let id = workspace.openObjectSource(.trigger(trigger))
    await workspace.objectSourceLoads[id]?.value
    let viewModel = try #require(workspace.viewModels[id])
    try #require(viewModel.objectSourceLoad == .loaded)
    return viewModel
  }

  /// The value `read` returns at the start, then the value each change replaced (an observation
  /// fires before the write and once, so it re-arms each time)
  @MainActor
  private final class ValueLog<Value> {
    private(set) var values: [Value] = []
    private let read: @MainActor () -> Value

    init(_ read: @escaping @MainActor () -> Value) {
      self.read = read
      arm()
    }

    var changes: Int { values.count - 1 }

    private func arm() {
      withObservationTracking {
        values.append(read())
      } onChange: { [weak self] in
        MainActor.assumeIsolated { self?.arm() }
      }
    }
  }
}
