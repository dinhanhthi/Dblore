// DataViewerLoadTests.swift
// Data viewer paging actions on the tab view model: page/size/refresh update the state and
// reload; without a connection nothing runs (no DB needed).

import Foundation
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
      #expect(viewModel.editorResult?.sourceQuery?.hasPrefix("SELECT * FROM ") == true)
      #expect(viewModel.editorResult?.truncation == nil)
    }
  }

  @Test("A lazy page cuts the large blob and keeps the edit target of its SELECT * page")
  func lazyPageKeepsEditTarget() async throws {
    try await withLazyViewModel { viewModel in
      await viewModel.loadDataViewerPage()
      let plain = try #require(viewModel.editorResult)
      #expect(plain.editTarget != nil)
      #expect(plain.lookupRelation != nil)

      viewModel.databaseTables = [Self.itemsTable]
      await viewModel.refreshDataViewer()
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
      let first = try #require(viewModel.editorResult?.sourceQuery)
      #expect(first.contains("dblore_byte_length_1"))
      #expect(viewModel.editorResult?.columns.map(\.name) == ["id", "payload", "label"])

      viewModel.databaseTables = []
      await viewModel.refreshDataViewer()
      #expect(viewModel.editorResult?.sourceQuery == first)
      #expect(viewModel.dataViewer?.pageSQL == first)
    }
  }

  @Test("Refreshing a lazy page replaces its rows")
  func lazyPageRefresh() async throws {
    try await withLazyViewModel { viewModel in
      viewModel.databaseTables = [Self.itemsTable]
      await viewModel.loadDataViewerPage()
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
}
