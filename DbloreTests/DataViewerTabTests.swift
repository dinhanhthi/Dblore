// DataViewerTabTests.swift
// Table/view data viewer tabs: a preview tab is reused by the next table, pinned tabs and the
// transaction origin are kept, viewer tabs are never dirty or reopened, and only pinned ones
// are persisted. Disconnected manager: page loads return early.
// Staleness (SQLite file): a write in another tab marks the other data viewers of that table
// stale (never the writer), Reload keeps the staged edits, and a write inside a Protected mode
// or user transaction marks them only once it is committed. An import reads the page again in
// the clean tabs instead (the active one at once, a hidden one when shown); a tab with staged
// changes or a page read in flight still shows Reload.

import Foundation
import Testing

@testable import Dblore

@Suite("Data viewer tab")
@MainActor
struct DataViewerTabTests {
  private static func manager() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  /// Stages one document insert in `viewModel`'s data viewer
  private static func stageInsert(in viewModel: NotebookViewModel) throws {
    var set = try MongoDocumentChangeSet(
      target: EditTarget(
        qualifiedName: "orders", tableID: .mongodb(database: "shop", collection: "orders"),
        primaryKeyColumns: ["_id"], name: "orders"),
      columns: [])
    _ = try set.stageInsert(.document([MongoValue.Field("n", .int64(1))]))
    viewModel.dataViewer?.documentChangeSet = set
    #expect(viewModel.hasPendingStagedChanges)
  }

  @Test("First open adds one active preview tab titled with the table")
  func firstOpen() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: ["id"])

    #expect(manager.tabs.count == 1)
    let tab = try #require(manager.tabs.first)
    #expect(tab.documentType == .dataViewer)
    #expect(tab.isPreview)
    #expect(tab.title == "users")
    #expect(tab.fileURL == nil)
    #expect(manager.activeTabId == tab.id)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    #expect(viewModel.dataViewer?.name == "users")
    #expect(viewModel.dataViewer?.orderColumns == ["id"])
  }

  @Test("Opening another table replaces the preview tab")
  func replacesPreview() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)

    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [])
    #expect(manager.tabs.count == 1)
    #expect(manager.tabs.first?.id == id)
    #expect(manager.tabs.first?.title == "orders")
    #expect(manager.viewModel(for: id)?.dataViewer?.name == "orders")
    #expect(manager.activeTabId == id)
  }

  @Test("Opening a table already shown selects its tab and reloads the page")
  func reopenSelectsExisting() async throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let viewerId = try #require(manager.tabs.first?.id)
    let sqlId = manager.newSQLFile()
    #expect(manager.activeTabId == sqlId)

    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.activeTabId == viewerId)

    let viewModel = try #require(manager.viewModel(for: viewerId))
    viewModel.connectionManager = nil
    viewModel.dataViewer?.totalRows = 40
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    for _ in 0..<50 {
      if viewModel.dataViewer?.totalRows == nil { break }
      await Task.yield()
    }
    #expect(viewModel.dataViewer?.totalRows == nil)
  }

  @Test("The transaction origin preview is pinned instead of replaced")
  func transactionOriginIsPinned() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let originId = try #require(manager.tabs.first?.id)
    manager.transactionOriginTabId = originId

    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.tabs[0].id == originId)
    #expect(manager.tabs[0].isPreview == false)
    #expect(manager.viewModel(for: originId)?.dataViewer?.name == "users")
    #expect(manager.tabs[1].isPreview)
    #expect(manager.tabs[1].title == "orders")
  }

  @Test("Save and markDirty leave a data viewer clean and file-less")
  func neverDirty() async throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)

    manager.markDirty(tabId: id)
    #expect(manager.tabs.first?.isDirty == false)
    try await manager.saveTab(id: id)
    #expect(manager.tabs.first?.fileURL == nil)
    #expect(manager.tabs.first?.isDirty == false)
  }

  @Test("Closing the tabs of a dropped collection discards staged edits without a prompt")
  func closeAfterDropDiscardsStaged() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "shop", name: "orders", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)
    try Self.stageInsert(in: #require(manager.viewModel(for: id)))

    manager.closeDataViewerTabs(schema: "shop", name: "orders")
    #expect(manager.tabs.isEmpty)
  }

  @Test("A pinned tab of a dropped collection stays open with nothing staged")
  func pinnedTabAfterDropDiscardsStaged() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "shop", name: "orders", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)
    manager.setPinned(true, id: id)
    let viewModel = try #require(manager.viewModel(for: id))
    try Self.stageInsert(in: viewModel)

    manager.closeDataViewerTabs(schema: "shop", name: "orders")
    #expect(manager.tabs.map(\.id) == [id])
    #expect(!viewModel.hasPendingStagedChanges)
  }

  @Test("Renaming a collection discards the staged edits of its tabs")
  func renameDiscardsStaged() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "shop", name: "orders", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)
    let viewModel = try #require(manager.viewModel(for: id))
    try Self.stageInsert(in: viewModel)

    manager.renameDataViewerTabs(schema: "shop", from: "orders", to: "sales")
    #expect(viewModel.dataViewer?.name == "sales")
    #expect(!viewModel.hasPendingStagedChanges)
  }

  @Test("Encoded workspace keeps a pinned data viewer with its relation")
  func persistencePinnedViewer() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "sales", name: "orders", orderColumns: ["id"])
    let id = try #require(manager.tabs.first?.id)
    manager.pinTab(id: id)

    let workspace = try Self.decode(manager.encodedWorkspaceData())
    #expect(workspace.tabs.map(\.id) == [id])
    #expect(
      workspace.tabs.first?.dataViewer
        == .init(schema: "sales", name: "orders", orderColumns: ["id"]))
    #expect(workspace.activeTabId == id)
  }

  @Test("Loading a workspace restores a pinned data viewer tab")
  func restoresPinnedViewer() async throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "sales", name: "orders", orderColumns: ["id"])
    let id = try #require(manager.tabs.first?.id)
    manager.pinTab(id: id)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).sqlws")
    try manager.encodedWorkspaceData().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let loaded = try await WorkspaceManager.load(from: url)
    let tab = try #require(loaded.tabs.first)
    #expect(loaded.tabs.count == 1)
    #expect(tab.id == id)
    #expect(tab.documentType == .dataViewer)
    #expect(!tab.isPreview)
    #expect(tab.title == "sales.orders")
    #expect(loaded.activeTabId == id)
    let state = try #require(loaded.viewModel(for: id)?.dataViewer)
    #expect(state.schema == "sales" && state.name == "orders" && state.orderColumns == ["id"])
  }

  @Test("Encoded workspace drops preview data viewers and points at a persisted tab")
  func persistenceDropsViewers() throws {
    let manager = Self.manager()
    let sqlId = manager.newSQLFile()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    #expect(manager.activeTabId != sqlId)

    let workspace = try Self.decode(manager.encodedWorkspaceData())
    #expect(workspace.tabs.map(\.id) == [sqlId])
    #expect(workspace.activeTabId == sqlId)
  }

  // MARK: - Stale tabs

  /// A workspace on a SQLite file with `items` (two rows) and `other`: data viewers A and B on
  /// `items`, C on `other`, and an SQL tab, every page loaded
  private struct StaleFixture {
    let workspace: WorkspaceManager
    let url: URL
    let first: NotebookViewModel
    let second: NotebookViewModel
    let otherTable: NotebookViewModel
    let sql: NotebookViewModel

    func close() async {
      await workspace.disconnect(resolution: .rollback)
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func staleFixture(protectedMode: Bool) async throws -> StaleFixture {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-stale-tabs-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("INSERT INTO items (label) VALUES ('a'), ('b')")
    try handle.execute("CREATE TABLE other (id INTEGER PRIMARY KEY, v TEXT)")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: protectedMode)
    let workspace = WorkspaceManager(workspace: Workspace())
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    try await workspace.connect(config: config, defaultCommitStyle: .immediate)

    workspace.openDataViewer(schema: "main", name: "items", orderColumns: ["id"])
    let firstId = try #require(workspace.activeTabId)
    workspace.setPinned(true, id: firstId)
    let ref = WorkspaceTabReference.DataViewerReference(
      schema: "main", name: "items", orderColumns: ["id"])
    let secondRef = WorkspaceTabReference(
      documentType: .dataViewer, title: "items", dataViewer: ref)
    workspace.restoreDataViewer(tabRef: secondRef, ref: ref)
    workspace.openDataViewer(schema: "main", name: "other", orderColumns: ["id"])
    let otherId = try #require(workspace.activeTabId)
    let sqlId = workspace.newSQLFile()

    let fixture = StaleFixture(
      workspace: workspace, url: url,
      first: try #require(workspace.viewModel(for: firstId)),
      second: try #require(workspace.viewModel(for: secondRef.id)),
      otherTable: try #require(workspace.viewModel(for: otherId)),
      sql: try #require(workspace.viewModel(for: sqlId)))
    for viewer in [fixture.first, fixture.second, fixture.otherTable] {
      try await loaded(viewer)
    }
    return fixture
  }

  /// Waits for the page and the count of `viewer` (a load already running is awaited)
  private static func loaded(_ viewer: NotebookViewModel) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if !viewer.isEditorQueryRunning {
        if viewer.dataViewer?.totalRows != nil, viewer.editorResult != nil {
          await viewer.awaitResultTargets()
          return
        }
        await viewer.loadDataViewerPage()
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for the data viewer to load")
  }

  private static func shows(_ viewer: NotebookViewModel, _ label: String) -> Bool {
    viewer.editorResult?.rows.contains { $0.contains(.string(label)) } == true
  }

  @Test("An UPDATE in an SQL tab marks the data tabs of that table stale, not another table's")
  func sqlTabWriteMarksOtherTabs() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(fixture.first.dataViewer?.isStale == true)
    #expect(fixture.second.dataViewer?.isStale == true)
    #expect(fixture.otherTable.dataViewer?.isStale == false)
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    await fixture.close()
  }

  @Test("A data tab's own staged commit marks the other tab of its table, not itself")
  func writerIsNotMarked() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    #expect(fixture.first.stageEdit(row: 0, column: "label", value: .string("z")) == nil)
    await fixture.first.commitStaged()
    #expect(!fixture.first.hasPendingStagedChanges)
    #expect(fixture.first.dataViewer?.isStale == false)
    #expect(fixture.second.dataViewer?.isStale == true)
    await fixture.close()
  }

  @Test("Reload reads the page again and keeps the staged edits")
  func reloadKeepsStagedEdits() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.second
    #expect(viewer.stageEdit(row: 1, column: "label", value: .string("draft")) == nil)
    let staged = viewer.dataViewer?.changeSet
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(viewer.dataViewer?.isStale == true)
    #expect(!Self.shows(viewer, "x"))

    await viewer.reloadStaleDataViewer()
    #expect(viewer.dataViewer?.isStale == false)
    #expect(Self.shows(viewer, "x"))
    #expect(viewer.dataViewer?.totalRows == 2)
    #expect(viewer.dataViewer?.changeSet == staged)
    #expect(viewer.hasPendingStagedChanges)
    await fixture.close()
  }

  @Test("Reload while a run is in flight reads nothing and keeps the banner")
  func reloadDuringRunKeepsStale() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.second
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(viewer.dataViewer?.isStale == true)

    viewer.isEditorQueryRunning = true
    await viewer.reloadStaleDataViewer()
    #expect(viewer.dataViewer?.isStale == true)
    #expect(viewer.dataViewer?.totalRows == 2)
    #expect(!Self.shows(viewer, "x"))
    viewer.isEditorQueryRunning = false
    await fixture.close()
  }

  @Test("A Protected mode write marks the tabs stale only after Commit")
  func protectedWriteMarksAtCommit() async throws {
    let fixture = try await Self.staleFixture(protectedMode: true)
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(!fixture.workspace.pendingTransaction.isIdle)
    #expect(fixture.first.dataViewer?.isStale == false)
    #expect(fixture.second.dataViewer?.isStale == false)
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)

    fixture.workspace.requestCommit()
    #expect(await fixture.workspace.confirmCommit(defaultCommitStyle: .immediate))
    #expect(fixture.first.dataViewer?.isStale == true)
    #expect(fixture.second.dataViewer?.isStale == true)
    #expect(fixture.otherTable.dataViewer?.isStale == false)
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    await fixture.close()
  }

  @Test("A Protected mode write rolled back marks nothing")
  func protectedWriteDroppedAtRollback() async throws {
    let fixture = try await Self.staleFixture(protectedMode: true)
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)

    #expect(await fixture.workspace.rollback())
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(fixture.first.dataViewer?.isStale == false)
    #expect(fixture.second.dataViewer?.isStale == false)
    await fixture.close()
  }

  @Test("A user transaction's write marks the tabs at its COMMIT")
  func userTransactionMarksAtCommit() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    await fixture.sql.executeEditorQuery("BEGIN; UPDATE items SET label = 'x' WHERE id = 1")
    #expect(fixture.second.dataViewer?.isStale == false)
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)

    await fixture.sql.executeEditorQuery("COMMIT")
    #expect(fixture.second.dataViewer?.isStale == true)
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    await fixture.close()
  }

  @Test("A held table whose transaction ended with no step is marked after the next run")
  func heldTableResolvedWhenTransactionClosed() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    // A transaction that ended unseen (a failed COMMIT, a CALL that committed) left it held
    fixture.workspace.heldWrittenRelations[.init(schema: "main", name: "other")] = fixture.sql.id
    await fixture.sql.executeEditorQuery("SELECT 1")
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(fixture.otherTable.dataViewer?.isStale == true)
    #expect(fixture.second.dataViewer?.isStale == false)

    // No transaction is open: the UPDATE autocommitted, the ROLLBACK undid nothing
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1; ROLLBACK")
    #expect(fixture.second.dataViewer?.isStale == true)
    await fixture.close()
  }

  @Test("Disconnect drops the tables written in the open user transaction")
  func disconnectClearsHeldRelations() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    await fixture.sql.executeEditorQuery("BEGIN; UPDATE items SET label = 'x' WHERE id = 1")
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)

    #expect(await fixture.workspace.disconnect())
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(fixture.second.dataViewer?.isStale == false)
    try? FileManager.default.removeItem(at: fixture.url)
  }

  // MARK: - Refresh after import

  /// The tab of `viewer` in the fixture's workspace
  private static func tabId(_ viewer: NotebookViewModel, in fixture: StaleFixture) throws -> UUID {
    try #require(fixture.workspace.viewModels.first { $0.value === viewer }?.key)
  }

  /// Imports one row labelled `label` into `items` from the SQL tab, as the import sheet does
  private static func importRow(_ label: String, in fixture: StaleFixture) async throws {
    let manager = try #require(fixture.sql.connectionManager)
    let reason = await fixture.sql.beginImportBatch(
      PendingStagedBatch(
        statements: [
          BoundStatement(sql: "INSERT INTO items (label) VALUES (?1)", values: [label])
        ],
        preview: "INSERT INTO items (label) -- 1 rows from file",
        connectionEpoch: await manager.connectionEpoch, historySource: .dataImport,
        rowRanges: [1...1]))
    #expect(reason == nil)
  }

  /// Waits until `viewer` shows `label` with `rows` counted, never reading the page itself: only
  /// a read the app started gets there
  private static func reloaded(_ viewer: NotebookViewModel, showing label: String, rows: Int) async
  {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if !viewer.isEditorQueryRunning, viewer.dataViewer?.totalRows == rows, shows(viewer, label) {
        await viewer.awaitResultTargets()
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The page was not read again: '\(label)' is not shown")
  }

  /// Gives a page read the app may have started the time to land
  private static func settle() async {
    try? await Task.sleep(for: .milliseconds(200))
  }

  private static func grouped(_ viewModel: NotebookViewModel, _ action: () -> Void) {
    viewModel.undoManager.beginUndoGrouping()
    action()
    viewModel.undoManager.endUndoGrouping()
  }

  @Test("An import reloads the active clean data tab of its table, also one showing Reload")
  func importReloadsActiveCleanTab() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.first
    fixture.workspace.selectTab(id: try Self.tabId(viewer, in: fixture))

    try await Self.importRow("imported", in: fixture)
    #expect(viewer.dataViewer?.isStale == false)
    await Self.reloaded(viewer, showing: "imported", rows: 3)
    #expect(viewer.dataViewer?.reloadsWhenShown == false)

    // An earlier write already showed the Reload banner
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 1")
    #expect(viewer.dataViewer?.isStale == true)
    try await Self.importRow("again", in: fixture)
    #expect(viewer.dataViewer?.isStale == false)
    await Self.reloaded(viewer, showing: "again", rows: 4)
    #expect(viewer.dataViewer?.isStale == false)
    await fixture.close()
  }

  @Test("An import marks a hidden clean data tab to reload when shown, with no Reload banner")
  func importMarksHiddenCleanTab() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.second

    try await Self.importRow("imported", in: fixture)
    #expect(viewer.dataViewer?.isStale == false)
    #expect(viewer.dataViewer?.reloadsWhenShown == true)
    #expect(fixture.otherTable.dataViewer?.reloadsWhenShown == false)
    await Self.settle()
    #expect(viewer.dataViewer?.totalRows == 2)
    #expect(!Self.shows(viewer, "imported"))

    let id = try Self.tabId(viewer, in: fixture)
    fixture.workspace.selectTab(id: id)
    fixture.workspace.reloadIfMarked(tabId: id)
    #expect(viewer.dataViewer?.reloadsWhenShown == false)
    await Self.reloaded(viewer, showing: "imported", rows: 3)
    #expect(viewer.dataViewer?.isStale == false)

    // A tab that is not marked reads nothing when shown
    do {
      let handle = try SQLiteHandle(url: fixture.url)
      try handle.execute("INSERT INTO other (v) VALUES ('outside')")
    }
    let otherId = try Self.tabId(fixture.otherTable, in: fixture)
    fixture.workspace.selectTab(id: otherId)
    fixture.workspace.reloadIfMarked(tabId: otherId)
    await Self.settle()
    #expect(fixture.otherTable.dataViewer?.totalRows == 0)
    await fixture.close()
  }

  @Test("An import marks a data tab with staged changes stale and keeps them")
  func importKeepsStagedTabStale() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.first
    fixture.workspace.selectTab(id: try Self.tabId(viewer, in: fixture))
    Self.grouped(viewer) {
      #expect(viewer.stageEdit(row: 1, column: "label", value: .string("draft")) == nil)
    }
    let staged = viewer.dataViewer?.changeSet

    try await Self.importRow("imported", in: fixture)
    #expect(viewer.dataViewer?.isStale == true)
    #expect(viewer.dataViewer?.reloadsWhenShown == false)
    #expect(viewer.dataViewer?.changeSet == staged)
    #expect(viewer.hasPendingStagedChanges)
    await Self.settle()
    #expect(viewer.dataViewer?.totalRows == 2)
    #expect(!Self.shows(viewer, "imported"))
    await fixture.close()
  }

  @Test("An import marks a clean data tab whose page read is in flight stale, not reloaded")
  func importMarksLoadingTabStale() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.first
    fixture.workspace.selectTab(id: try Self.tabId(viewer, in: fixture))
    viewer.isEditorQueryRunning = true

    try await Self.importRow("imported", in: fixture)
    #expect(viewer.dataViewer?.isStale == true)
    #expect(viewer.dataViewer?.reloadsWhenShown == false)
    viewer.isEditorQueryRunning = false
    #expect(!Self.shows(viewer, "imported"))
    await fixture.close()
  }

  @Test("A write that is not an import only shows Reload, also on the active tab")
  func nonImportWriteOnlyMarksStale() async throws {
    let fixture = try await Self.staleFixture(protectedMode: false)
    let viewer = fixture.second
    fixture.workspace.selectTab(id: try Self.tabId(viewer, in: fixture))

    // A data tab's staged commit, then an SQL tab's UPDATE
    Self.grouped(fixture.first) {
      #expect(fixture.first.stageEdit(row: 0, column: "label", value: .string("z")) == nil)
    }
    await fixture.first.commitStaged()
    #expect(!fixture.first.hasPendingStagedChanges)
    #expect(viewer.dataViewer?.isStale == true)
    await fixture.sql.executeEditorQuery("UPDATE items SET label = 'x' WHERE id = 2")
    #expect(viewer.dataViewer?.reloadsWhenShown == false)
    #expect(fixture.first.dataViewer?.isStale == true)
    #expect(fixture.first.dataViewer?.reloadsWhenShown == false)
    await Self.settle()
    #expect(viewer.dataViewer?.isStale == true)
    #expect(!Self.shows(viewer, "z"))
    #expect(!Self.shows(viewer, "x"))
    await fixture.close()
  }

  @Test("A held import follows the import rule at Commit and changes nothing at Rollback")
  func heldImportAtCommitAndRollback() async throws {
    let fixture = try await Self.staleFixture(protectedMode: true)
    let viewer = fixture.first
    fixture.workspace.selectTab(id: try Self.tabId(viewer, in: fixture))

    try await Self.importRow("dropped", in: fixture)
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(await fixture.workspace.rollback())
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    for tab in [viewer, fixture.second] {
      #expect(tab.dataViewer?.isStale == false)
      #expect(tab.dataViewer?.reloadsWhenShown == false)
    }
    // The Rollback's own page reads
    try await Self.loaded(viewer)
    try await Self.loaded(fixture.second)

    try await Self.importRow("imported", in: fixture)
    #expect(!fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(viewer.dataViewer?.isStale == false)
    #expect(fixture.second.dataViewer?.reloadsWhenShown == false)
    fixture.workspace.requestCommit()
    #expect(await fixture.workspace.confirmCommit(defaultCommitStyle: .immediate))
    #expect(fixture.workspace.heldWrittenRelations.isEmpty)
    #expect(viewer.dataViewer?.isStale == false)
    await Self.reloaded(viewer, showing: "imported", rows: 3)
    #expect(fixture.second.dataViewer?.isStale == false)
    #expect(fixture.second.dataViewer?.reloadsWhenShown == true)
    await fixture.close()
  }

  private static func decode(_ data: Data) throws -> Workspace {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Workspace.self, from: data)
  }
}
