// DataViewerLoadTests.swift
// Data viewer paging actions on the tab view model: page/size/refresh update the state and
// reload; without a connection nothing runs (no DB needed). Lazy pages on SQLite files and a
// fake PostgreSQL session: text is cut only where its byte lengths are UTF-8.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@MainActor
@Suite("Data Viewer Load Tests")
struct DataViewerLoadTests {

  private func makeViewModel(
    page: Int = 1, pageSize: Int = 100, totalRows: Int? = nil
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"], page: page, pageSize: pageSize,
      totalRows: totalRows)
    return viewModel
  }

  @Test("Loading without a connection manager runs nothing")
  func loadWithoutConnection() async {
    let viewModel = makeViewModel()
    await viewModel.loadDataViewerPage()
    #expect(viewModel.editorResult == nil)
    #expect(viewModel.isEditorQueryRunning == false)
  }

  @Test("Loading while a run is in flight runs nothing")
  func loadWhileRunning() async {
    let viewModel = makeViewModel()
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.isEditorQueryRunning = true
    await viewModel.loadDataViewerPage()
    #expect(viewModel.editorResult == nil)
    #expect(viewModel.dataViewer?.totalRows == nil)
    #expect(viewModel.isEditorQueryRunning == true)
  }

  @Test("Changing the page size goes back to page 1")
  func setPageSizeResetsPage() async {
    let viewModel = makeViewModel(page: 3)
    await viewModel.setPageSize(250)
    #expect(viewModel.dataViewer?.page == 1)
    #expect(viewModel.dataViewer?.pageSize == 250)
  }

  @Test("goToPage clamps below 1")
  func goToPageLowerBound() async {
    let viewModel = makeViewModel(page: 2)
    await viewModel.goToPage(0)
    #expect(viewModel.dataViewer?.page == 1)
  }

  @Test("goToPage clamps to the page count when the total is known")
  func goToPageUpperBound() async {
    let viewModel = makeViewModel(totalRows: 250)
    await viewModel.goToPage(9)
    #expect(viewModel.dataViewer?.page == 3)
  }

  @Test("goToPage is not capped while the total is unknown")
  func goToPageUnknownTotal() async {
    let viewModel = makeViewModel()
    await viewModel.goToPage(9)
    #expect(viewModel.dataViewer?.page == 9)
  }

  @Test("Refresh forgets the row count")
  func refreshResetsTotal() async {
    let viewModel = makeViewModel(totalRows: 250)
    await viewModel.refreshDataViewer()
    #expect(viewModel.dataViewer?.totalRows == nil)
  }

  @Test("The all-rows export SQL keeps the filter and order, without paging or cut columns")
  func exportSQLReadsWholeColumnsWithoutPaging() {
    var viewer = DataViewerState(
      schema: "public", name: "docs", orderColumns: ["id"], page: 3, pageSize: 50,
      databaseType: .postgresql)
    viewer.filter = TableFilter(conditions: [
      FilterCondition(column: "body", op: .equals, value: "o'brien")
    ])
    #expect(
      viewer.exportSQL
        == #"SELECT * FROM "public"."docs" WHERE "body" OPERATOR(pg_catalog.=) 'o''brien' ORDER BY "id""#
    )
    viewer.lazyColumns = [
      .init(name: "id", type: "integer", isPrimaryKey: true, prefix: nil),
      .init(name: "body", type: "text", isPrimaryKey: false, prefix: .characters),
      .init(name: "payload", type: "bytea", isPrimaryKey: false, prefix: .bytes),
    ]
    viewer.rowLocator = .pgLocator
    #expect(viewer.pageSQL.contains("dblore_byte_length_1"))
    #expect(
      viewer.exportSQL
        == #"SELECT "id", "body", "payload" FROM "public"."docs" WHERE "body" OPERATOR(pg_catalog.=) 'o''brien' ORDER BY "id""#
    )
    // SQLite names each column through its table: a stale name fails, never reads a literal
    viewer.databaseType = .sqlite
    viewer.filter = TableFilter(conditions: [])
    viewer.rowLocator = nil
    #expect(
      viewer.exportSQL
        == #"SELECT "public"."docs"."id", "public"."docs"."body", "public"."docs"."payload" FROM "public"."docs" ORDER BY "id""#
    )
  }

  // MARK: - Lazy binary columns (SQLite file, no server)

  /// `main.items` with a 70,000-byte blob (row 1), a short one (row 2) and a text column,
  /// shown in a SQLite data viewer ordered by `id`. The file is closed and deleted afterwards.
  private func withLazyViewModel(
    _ body: (_ viewModel: NotebookViewModel) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lazy-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    try await manager.connect(config: config)
    for statement in [
      "CREATE TABLE items (id INTEGER PRIMARY KEY, payload BLOB, label TEXT)",
      "INSERT INTO items VALUES (1, zeroblob(70000), 'a'), (2, x'0102', 'b')",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    var state = DataViewerState(schema: "main", name: "items", orderColumns: ["id"])
    state.databaseType = .sqlite
    viewModel.dataViewer = state
    do {
      try await body(viewModel)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  private static let itemsTable = DatabaseTable(
    schema: "main", name: "items",
    columns: [
      DatabaseColumn(name: "id", type: "INTEGER", isPrimaryKey: true),
      DatabaseColumn(name: "payload", type: "BLOB"),
      DatabaseColumn(name: "label", type: "TEXT"),
    ])

  @Test("Without cached columns the first page reads SELECT *")
  func lazyNeedsCachedColumns() async throws {
    try await withLazyViewModel { viewModel in
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      #expect(viewModel.editorResult?.sourceQuery?.hasPrefix("SELECT * FROM ") == true)
      #expect(viewModel.editorResult?.truncation == nil)
    }
  }

  @Test("A lazy page cuts the large blob and keeps the edit target of its SELECT * page")
  func lazyPageKeepsEditTarget() async throws {
    try await withLazyViewModel { viewModel in
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      let plain = try #require(viewModel.editorResult)
      #expect(plain.editTarget != nil)
      #expect(plain.lookupRelation != nil)

      viewModel.databaseTables = [Self.itemsTable]
      await viewModel.refreshDataViewer()
      await viewModel.awaitResultTargets()
      let lazy = try #require(viewModel.editorResult)
      #expect(lazy.sourceQuery?.contains("substr(") == true)
      #expect(lazy.columns == plain.columns)
      // Every field but `generation`, which is new for each result
      let lazyTarget = try #require(lazy.editTarget)
      let plainTarget = try #require(plain.editTarget)
      #expect(
        EditTarget(
          qualifiedName: lazyTarget.qualifiedName, tableID: lazyTarget.tableID,
          primaryKeyColumns: lazyTarget.primaryKeyColumns,
          connectionEpoch: lazyTarget.connectionEpoch, updateOnly: lazyTarget.updateOnly,
          generation: plainTarget.generation, schema: lazyTarget.schema, name: lazyTarget.name,
          generatedColumns: lazyTarget.generatedColumns) == plainTarget)
      #expect(lazy.lookupRelation == plain.lookupRelation)
      #expect(lazy.rows[0][1] == .data(Data(count: DataViewerState.lazyPrefixBytes)))
      #expect(lazy.rows[1] == plain.rows[1])
      let truncation = try #require(viewModel.editorResult?.truncation)
      #expect(truncation.keyColumns == ["id"])
      #expect(truncation.lengths == [RowChangeSet.RowKey(values: [.int(1)]): ["payload": 70_000]])
    }
  }

  @Test("The page SQL built from a lazy page's result is the first lazy page SQL")
  func lazyPageSQLFromResult() async throws {
    try await withLazyViewModel { viewModel in
      viewModel.databaseTables = [Self.itemsTable]
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      let first = try #require(viewModel.editorResult?.sourceQuery)
      #expect(first.contains("dblore_byte_length_1"))
      #expect(viewModel.editorResult?.columns.map(\.name) == ["id", "payload", "label"])

      viewModel.databaseTables = []
      await viewModel.refreshDataViewer()
      await viewModel.awaitResultTargets()
      #expect(viewModel.editorResult?.sourceQuery == first)
      #expect(viewModel.dataViewer?.pageSQL == first)
    }
  }

  @Test("Refreshing a lazy page replaces its rows")
  func lazyPageRefresh() async throws {
    try await withLazyViewModel { viewModel in
      viewModel.databaseTables = [Self.itemsTable]
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      let target = try #require(viewModel.editorResult?.editTarget)
      let manager = try #require(viewModel.connectionManager)
      _ = try await manager.executeInternal(
        "UPDATE items SET label = 'z', payload = zeroblob(80000) WHERE id = 2")

      await viewModel.refreshDataViewerRows(
        target: target, connectionManager: manager, done: "Done")
      let rows = try #require(viewModel.editorResult?.rows)
      #expect(rows[1][2] == .string("z"))
      #expect(rows[1][1] == .data(Data(count: DataViewerState.lazyPrefixBytes)))
      #expect(
        viewModel.editorResult?.truncation?.lengths == [
          RowChangeSet.RowKey(values: [.int(1)]): ["payload": 70_000],
          RowChangeSet.RowKey(values: [.int(2)]): ["payload": 80_000],
        ])
    }
  }

  // MARK: - Text encodings

  /// `main.docs(id, body TEXT, payload BLOB)` in a new SQLite file created with `PRAGMA
  /// encoding = <encoding>` (before its first table: the encoding is fixed then), row 1 a
  /// 20,000-character body and a 70,000-byte blob; a data viewer on it with its columns cached.
  /// The file is closed and deleted afterwards.
  private func withEncodedDocs(
    _ encoding: String,
    _ body: (_ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager) async throws
      -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-encoding-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let script =
      "PRAGMA encoding = '\(encoding)';"
      + "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, payload BLOB);"
      + "INSERT INTO docs VALUES (1, replace(hex(zeroblob(20000)), '00', 'é'), zeroblob(70000)),"
      + " (2, 'short', x'01');"
    #expect(sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)

    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    let read = try await manager.executeInternal("PRAGMA encoding")
    #expect(read.rows == [[.string(encoding)]])
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    var state = DataViewerState(schema: "main", name: "docs", orderColumns: ["id"])
    state.databaseType = .sqlite
    viewModel.dataViewer = state
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "main", name: "docs",
        columns: [
          DatabaseColumn(name: "id", type: "INTEGER", isPrimaryKey: true),
          DatabaseColumn(name: "body", type: "TEXT"),
          DatabaseColumn(name: "payload", type: "BLOB"),
        ])
    ]
    do {
      try await body(viewModel, manager)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  @Test(
    "A SQLite file whose encoding is not UTF-8 reads its text whole; a UTF-8 one cuts it",
    arguments: ["UTF-16le", "UTF-8"])
  func sqliteEncodingDecidesTextPrefix(encoding: String) async throws {
    try await withEncodedDocs(encoding) { viewModel, manager in
      let utf8 = encoding == "UTF-8"
      #expect(await manager.textLengthsAreUTF8() == utf8)
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      #expect(
        viewModel.dataViewer?.lazyColumns?.map(\.prefix) == [nil, utf8 ? .characters : nil, .bytes])
      let page = try #require(viewModel.editorResult)
      let body = String(repeating: "é", count: utf8 ? DataViewerState.lazyPrefixCharacters : 20_000)
      #expect(page.rows[0][1] == .string(body))
      #expect(
        page.truncation?.lengths[RowChangeSet.RowKey(values: [.int(1)])]
          == (utf8 ? ["body": 40_000, "payload": 70_000] : ["payload": 70_000]))
    }
  }

  @Test("A PostgreSQL session whose server_encoding is not known as UTF8 reads its text whole")
  func postgresWithoutUTF8EncodingReadsTextWhole() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    #expect(await manager.textLengthsAreUTF8() == false)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    viewModel.toastPresenter = { _, _ in }
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "docs", orderColumns: ["id"], databaseType: .postgresql)
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "public", name: "docs",
        columns: [
          DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true),
          DatabaseColumn(name: "body", type: "text"),
          DatabaseColumn(name: "meta", type: "jsonb"),
          DatabaseColumn(name: "payload", type: "bytea"),
        ])
    ]
    // The first page only: the fake's catalog gives no edit target to read a later one by
    await viewModel.loadDataViewerPage()
    #expect(viewModel.dataViewer?.lazyColumns?.map(\.prefix) == [nil, nil, nil, .bytes])
    let pages = factory.sessions.flatMap(\.queries).filter { $0.contains(#"FROM "public"."docs""#) }
    #expect(pages.contains { $0.contains(#"substring("payload" from 1 for 65536)"#) })
    #expect(!pages.contains { $0.contains("pg_catalog.left(") })
    await manager.disconnect()
  }
}
