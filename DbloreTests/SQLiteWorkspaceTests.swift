// SQLiteWorkspaceTests.swift
// A temporary SQLite file: the sidebar schema model loads its tables, a capped read keeps
// a temp table, and inline edit follows the column-origin table identity.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("SQLiteWorkspaceTests")
@MainActor
struct SQLiteWorkspaceTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("A temp-file connection loads tables into the sidebar schema model")
  func loadsTablesIntoSidebarSchema() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let config = sqliteConfig(path: url.path)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.connectionState = .connected
    workspace.workspace.connectionConfig = config

    await workspace.loadDatabaseSchema()

    let items = try #require(workspace.databaseTables.first { $0.name == "items" })
    #expect(items.schema == "main")
    #expect(items.columns.contains { $0.name == "id" && $0.isPrimaryKey })
    #expect(items.columns.contains { $0.name == "label" })
    #expect(workspace.databaseFunctions.isEmpty)
    #expect(workspace.databaseRoles.isEmpty)
  }

  @Test("A capped read does not drop a temp table")
  func cappedReadKeepsTempTable() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }

    _ = try await manager.execute(userSQL: "CREATE TEMP TABLE scratch (n INTEGER)", policy: open)
    _ = try await manager.execute(userSQL: "INSERT INTO scratch VALUES (7)", policy: open)

    let capped = try await manager.execute(
      userSQL: "SELECT id FROM items", policy: open, maxRows: 1)
    #expect(capped.truncated)
    #expect(!capped.sessionReset)

    let kept = try await manager.execute(userSQL: "SELECT n FROM scratch", policy: open)
    #expect(kept.rows == [[.int(7)]])
  }

  @Test("Inline edit resolves a keyed table by column origin and skips a table with no key")
  func editTargetUsesColumnOrigin() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionEpoch
    let viewModel = NotebookViewModel(notebook: .newDocument())

    let keyed = try await manager.execute(
      userSQL: "SELECT id, label FROM items", policy: open)
    let target = await viewModel.editTarget(
      for: "SELECT id, label FROM items", result: keyed, connectionManager: manager, epoch: epoch)
    let resolved = try #require(target)
    #expect(resolved.tableID == TableRef.sqlite(schema: "main", table: "items"))
    #expect(resolved.primaryKeyColumns == ["id"])

    let heap = try await manager.execute(userSQL: "SELECT id, note FROM heap", policy: open)
    let heapTarget = await viewModel.editTarget(
      for: "SELECT id, note FROM heap", result: heap, connectionManager: manager, epoch: epoch)
    #expect(heapTarget == nil)
  }

  @Test("A generated column before a plain column keeps origin ordinals on the table's columns")
  func generatedColumnKeepsOriginIdentity() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute(
      "CREATE TABLE gen (id INTEGER PRIMARY KEY, g INTEGER AS (id * 2), name TEXT)")
    try handle.execute("INSERT INTO gen (id, name) VALUES (1, 'a')")
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionEpoch
    let viewModel = NotebookViewModel(notebook: .newDocument())

    // `name` renamed to the generated column's name is not that column
    let aliased = "SELECT id, name AS g FROM gen"
    let renamed = try await manager.execute(userSQL: aliased, policy: open)
    let renamedTarget = await viewModel.editTarget(
      for: aliased, result: renamed, connectionManager: manager, epoch: epoch)
    #expect(renamedTarget == nil)

    let plain = "SELECT id, name FROM gen"
    let direct = try await manager.execute(userSQL: plain, policy: open)
    let directTarget = await viewModel.editTarget(
      for: plain, result: direct, connectionManager: manager, epoch: epoch)
    #expect(directTarget?.primaryKeyColumns == ["id"])
  }

  @Test("An aliased key column offers the referenced row and stays read-only")
  func aliasedKeyColumnLooksUpReferencedRow() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute(
      "CREATE TABLE refs (id INTEGER PRIMARY KEY, item_id INTEGER REFERENCES items (id))")
    try handle.execute("INSERT INTO refs (id, item_id) VALUES (1, 2)")
    let config = sqliteConfig(path: url.path)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionEpoch
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config))
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.databaseForeignKeys = try await manager.fetchForeignKeys()

    let sql = "SELECT id, item_id AS i FROM refs"
    let queried = try await manager.execute(userSQL: sql, policy: open)
    let targets = await viewModel.resultTargets(
      for: sql, result: queried, connectionManager: manager, epoch: epoch)
    #expect(targets.editTarget == nil)
    let lookup = try #require(targets.lookupRelation)
    #expect(lookup.schema == "main")
    #expect(lookup.table == "refs")
    #expect(lookup.baseColumns == ["id", "item_id"])

    let coordinator = ResultGridCoordinator()
    let result = CellResult(
      columns: queried.columns, rows: queried.rows, rowCount: queried.rows.count,
      lookupRelation: lookup)
    coordinator.update(NSTableView(), result: result, sortColumn: nil, ascending: true)
    let relation = try #require(
      referencedRelation(dataViewer: nil, editTarget: nil, lookupRelation: lookup))
    coordinator.relationSchema = relation.schema
    coordinator.relationTable = relation.table
    coordinator.baseColumnNames = relation.baseColumns
    coordinator.foreignKeys = viewModel.databaseForeignKeys
    let request = try #require(coordinator.referencedRowRequest(row: 0, column: 1))
    #expect(request.foreignKey.targetTable == "items")

    let found = try await viewModel.lookupReferencedRow(
      column: request.column, schema: request.schema, table: request.table,
      rowColumns: request.rowColumns, values: request.values,
      expectedEpoch: lookup.connectionEpoch)
    #expect(found?.rows == [[.int(2), .string("b")]])
  }

  @Test("A generated column is read-only while the other columns of the row stay editable")
  func generatedColumnIsReadOnly() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute(
      "CREATE TABLE gen (id INTEGER PRIMARY KEY, g INTEGER AS (id * 2), name TEXT)")
    try handle.execute("INSERT INTO gen (id, name) VALUES (1, 'a')")
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let epoch = await manager.connectionEpoch
    let viewModel = NotebookViewModel(notebook: .newDocument())

    let sql = "SELECT id, g, name FROM gen"
    let queried = try await manager.execute(userSQL: sql, policy: open)
    let target = try #require(
      await viewModel.editTarget(
        for: sql, result: queried, connectionManager: manager, epoch: epoch))
    #expect(target.generatedColumns == ["g"])
    let result = CellResult(
      columns: queried.columns, rows: queried.rows, rowCount: queried.rows.count,
      editTarget: target)
    #expect(viewModel.canEdit(result))
    #expect(viewModel.readOnlyColumnIndexes(result) == [1])

    viewModel.cellDetailEditTarget = target
    let names: Set<String> = ["id", "g", "name"]
    #expect(
      !viewModel.canEdit(
        tableName: "gen", primaryKeyColumns: ["id"], columnNames: names, columnName: "g"))
    #expect(
      viewModel.canEdit(
        tableName: "gen", primaryKeyColumns: ["id"], columnNames: names, columnName: "name"))
  }

  @Test("Add Row and Duplicate in the data viewer never write a generated column")
  func stagedRowsOmitGeneratedColumn() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute(
      "CREATE TABLE gen (id INTEGER PRIMARY KEY, g INTEGER AS (id * 2), name TEXT)")
    try handle.execute("INSERT INTO gen (id, name) VALUES (1, 'a')")
    let config = sqliteConfig(path: url.path)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionState = .connected
    viewModel.connectionManager = manager
    viewModel.dataViewer = DataViewerState(
      schema: "main", name: "gen", orderColumns: ["id"], databaseType: .sqlite)
    await viewModel.loadDataViewerPage()
    #expect(viewModel.editorResult?.editTarget?.generatedColumns == ["g"])

    #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
    #expect(await viewModel.addStagedRow() == nil)
    let preview = viewModel.previewStagedSQL()
    #expect(preview.contains("INSERT"))
    #expect(!preview.contains("\"g\""))

    await viewModel.commitStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    let stored = try await manager.executeInternal("SELECT id, g, name FROM gen ORDER BY id")
    #expect(stored.rows.count == 3)
    #expect(stored.rows.first == [.int(1), .int(2), .string("a")])
    #expect(stored.rows.dropFirst().first?[2] == .string("a"))
  }

  @Test(
    "View mode sends a loaded row by commit style and keeps a staged insert",
    .serialized,
    .timeLimit(.minutes(1)),
    arguments: [CommitStyle.immediate, .review], [false, true])
  func viewerInlineEditCommitsImmediately(style: CommitStyle, withStagedInsert: Bool) async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute(
      "ALTER TABLE items ADD COLUMN label_length INTEGER GENERATED ALWAYS AS (length(label))")
    var config = sqliteConfig(path: url.path)
    config.applyCommitStyle(style)
    let manager = DatabaseConnectionManager()
    let observer = DatabaseConnectionManager()
    try await manager.connect(config: config)
    try await observer.connect(config: config)
    defer {
      Task {
        await manager.disconnect()
        await observer.disconnect()
      }
    }
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config))
    viewModel.viewMode = .editor
    viewModel.connectionState = .connected
    viewModel.connectionManager = manager
    viewModel.dataViewer = DataViewerState(
      schema: "main", name: "items", orderColumns: ["id"], databaseType: .sqlite)
    await viewModel.loadDataViewerPage()
    let result = try #require(viewModel.editorResult)
    let column = try #require(result.columns.firstIndex { $0.name == "label" })
    if withStagedInsert {
      #expect(viewModel.stageEdit(row: 0, column: "label", value: .string("previous draft")) == nil)
      #expect(viewModel.stageInsert(values: ["label": .string("draft")]) == nil)
      #expect(viewModel.undoManager.canUndo)
    }
    let editsBefore = viewModel.dataViewer?.changeSet?.edits
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      viewModel.onStatementsExecuted = {
        viewModel.onStatementsExecuted = nil
        continuation.resume()
      }
      viewModel.handleStagedGridCellEdit(
        row: 0, column: column, newValue: "edited", result: result)
      // A staged loaded row returns here. Waiting would hang: nothing was sent.
      if viewModel.dataViewer?.changeSet?.edits != editsBefore {
        viewModel.onStatementsExecuted = nil
        continuation.resume()
      }
    }

    let stored = try await observer.executeInternal("SELECT label FROM items WHERE id = 1")
    let snapshot = await manager.transactionSnapshot()
    if style.opensReviewTransaction {
      #expect(stored.rows == [[.string("a")]])
      #expect(snapshot.pending.count == 1)
      #expect(snapshot.pending.first?.kindLabel == "UPDATE")
    } else {
      #expect(stored.rows == [[.string("edited")]])
      #expect(snapshot == .idle)
    }
    if withStagedInsert {
      let refreshed = try #require(viewModel.editorResult)
      #expect(refreshed.editTarget?.generation == result.editTarget?.generation)
      #expect(refreshed.rows[0][column] == .string("edited"))
      let generated = try #require(refreshed.columns.firstIndex { $0.name == "label_length" })
      #expect(refreshed.rows[0][generated] == .int(6))
      #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["label"] == .string("draft"))
      #expect(viewModel.dataViewer?.changeSet?.edits.isEmpty == true)
      try #require(viewModel.dataViewer?.changeSet?.edits.isEmpty == true)
      #expect(!viewModel.undoManager.canUndo)
      viewModel.handleStagedGridCellEdit(
        row: refreshed.rows.count, column: column, newValue: "updated draft", result: refreshed)
      #expect(
        viewModel.dataViewer?.changeSet?.inserts.first?.values["label"] == .string("updated draft"))
      let count = try await observer.executeInternal("SELECT COUNT(*) FROM items")
      #expect(count.rows == [[.int(3)]])
    } else {
      #expect(viewModel.dataViewer?.changeSet == nil)
      try #require(viewModel.dataViewer?.changeSet == nil)
    }
  }

  private func sqliteConfig(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent,
      protectedMode: false
    )
  }

  private func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-workspace-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("INSERT INTO items (label) VALUES ('a'), ('b'), ('c')")
    try handle.execute("CREATE TABLE heap (id INTEGER, note TEXT)")
    try handle.execute("INSERT INTO heap (id, note) VALUES (1, 'loose')")
    return url
  }

  private func removeDatabase(_ url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
