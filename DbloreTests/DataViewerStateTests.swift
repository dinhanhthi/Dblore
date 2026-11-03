// DataViewerStateTests.swift
// The data viewer tab pages a table or view with server-side LIMIT/OFFSET: the generated SQL
// must stay a single-relation SELECT (so inline edit keeps working) and quote every identifier.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Data Viewer State Tests")
struct DataViewerStateTests {
  private func state(
    schema: String = "public", name: String = "users", orderColumns: [String] = []
  ) -> DataViewerState {
    DataViewerState(schema: schema, name: name, orderColumns: orderColumns)
  }

  private func result(_ rows: [[CellValue]]) -> QueryResult {
    QueryResult(
      columns: [ColumnInfo(name: "count", type: "int8")], rows: rows, rowCount: rows.count,
      executionTime: 0)
  }

  @Test("Page 1 without order columns is the plain LIMIT query")
  func firstPageSQL() {
    #expect(state().pageSQL == #"SELECT * FROM "public"."users" LIMIT 100"#)
  }

  @Test("Order columns add a quoted ORDER BY")
  func orderBySQL() {
    #expect(
      state(orderColumns: ["id"]).pageSQL
        == #"SELECT * FROM "public"."users" ORDER BY "id" LIMIT 100"#)
  }

  @Test("Page 3 at page size 50 offsets by 100")
  func offsetSQL() {
    var viewer = state()
    viewer.page = 3
    viewer.pageSize = 50
    #expect(viewer.pageSQL.hasSuffix("LIMIT 50 OFFSET 100"))
  }

  @Test("Embedded double quotes are doubled")
  func quotedIdentifiers() {
    let viewer = state(schema: #"my"s"#, name: #"we"ird"#)
    #expect(viewer.pageSQL.hasPrefix(#"SELECT * FROM "my""s"."we""ird" "#))
    #expect(viewer.countSQL == #"SELECT count(*) FROM "my""s"."we""ird""#)
  }

  @Test("Empty schema gives an unqualified relation")
  func emptySchema() {
    #expect(state(schema: "").pageSQL == #"SELECT * FROM "users" LIMIT 100"#)
  }

  @Test("Page SQL stays a single-relation SELECT (editable)")
  func singleRelation() {
    var ordered = state(orderColumns: ["id", "name"])
    ordered.page = 2
    #expect(CellUpdateStatement.singleRelation(in: state().pageSQL) != nil)
    #expect(CellUpdateStatement.singleRelation(in: ordered.pageSQL) != nil)
  }

  @Test("pageCount rounds up and is at least 1", arguments: [(0, 1), (100, 1), (101, 2)])
  func pageCount(total: Int, expected: Int) {
    var viewer = state()
    viewer.totalRows = total
    #expect(viewer.pageCount == expected)
  }

  @Test("canGoNext is false on the last page")
  func lastPage() {
    var viewer = state()
    viewer.totalRows = 250
    viewer.page = 3
    #expect(!viewer.canGoNext)
    #expect(viewer.canGoPrevious)
    viewer.page = 2
    #expect(viewer.canGoNext)
  }

  @Test("total(from:) reads an int or numeric string first cell")
  func total() {
    #expect(DataViewerState.total(from: result([[.int(42)]])) == 42)
    #expect(DataViewerState.total(from: result([[.string("42")]])) == 42)
    #expect(DataViewerState.total(from: result([])) == nil)
    #expect(DataViewerState.total(from: result([[.string("abc")]])) == nil)
  }

  @Test("loadKey changes with page but not with hidden columns")
  func loadKey() {
    var viewer = state()
    let key = viewer.loadKey
    viewer.hiddenColumns = ["email"]
    #expect(viewer.loadKey == key)
    viewer.page = 2
    #expect(viewer.loadKey != key)
  }

  private func filtered(_ dialect: DatabaseType = .postgresql) -> DataViewerState {
    var viewer = state(orderColumns: ["id"])
    viewer.databaseType = dialect
    viewer.filter = TableFilter(conditions: [
      FilterCondition(column: "name", op: .equals, value: "o'brien")
    ])
    return viewer
  }

  @Test("Filter adds WHERE after the relation and before ORDER BY/LIMIT")
  func filterSQL() {
    var viewer = filtered()
    viewer.page = 2
    #expect(
      viewer.pageSQL
        == #"SELECT * FROM "public"."users" WHERE "name" = 'o''brien' ORDER BY "id" LIMIT 100 OFFSET 100"#
    )
    #expect(
      viewer.countSQL == #"SELECT count(*) FROM "public"."users" WHERE "name" = 'o''brien'"#)
    #expect(CellUpdateStatement.singleRelation(in: viewer.pageSQL) != nil)
  }

  @Test("A filter without a complete condition leaves the SQL unchanged")
  func incompleteFilterSQL() {
    var viewer = state()
    viewer.filter = TableFilter(conditions: [FilterCondition(column: "name", value: "")])
    #expect(viewer.pageSQL == state().pageSQL)
    #expect(viewer.countSQL == state().countSQL)
  }

  @Test("The dialect drives the filter literals")
  func filterDialect() {
    var viewer = filtered(.sqlite)
    viewer.filter.conditions[0].op = .ilike
    #expect(viewer.countSQL.hasSuffix(#"WHERE LOWER("name") LIKE LOWER('o''brien')"#))
    viewer.databaseType = .postgresql
    #expect(viewer.countSQL.hasSuffix(#"WHERE "name"::text ILIKE 'o''brien'"#))
  }

  @Test("loadKey changes with the applied filter")
  func loadKeyFilter() {
    let viewer = state()
    #expect(filtered().loadKey != viewer.loadKey)
  }

  // MARK: - Lazy binary columns

  /// `users` with a key, a binary column and a text column, lazy for `dialect`
  private func lazy(
    _ dialect: DatabaseType, schema: String = "public", binaryType: String = "BYTEA"
  ) -> DataViewerState {
    var viewer = state(schema: schema, orderColumns: ["id"])
    viewer.databaseType = dialect
    viewer.lazyColumns = DataViewerState.lazyColumns(
      [("id", "INTEGER", true), ("photo", binaryType, false), ("name", "TEXT", false)],
      databaseType: dialect, orderColumns: ["id"])
    return viewer
  }

  @Test("A lazy PostgreSQL page keeps the column order and appends the byte lengths")
  func lazyPostgreSQL() {
    let viewer = lazy(.postgresql)
    #expect(
      viewer.pageSQL
        == #"SELECT "id", substring("photo" from 1 for 65536) AS "photo", "name", "#
        + #"octet_length("photo") AS "dblore_byte_length_1" FROM "public"."users" "#
        + #"ORDER BY "id" LIMIT 100"#)
    #expect(viewer.lengthColumns == ["dblore_byte_length_1"])
    #expect(CellUpdateStatement.singleRelation(in: viewer.pageSQL) == #""public"."users""#)
  }

  @Test("A lazy MySQL page cuts BLOB and BINARY columns with LEFT")
  func lazyMySQL() {
    var viewer = lazy(.mysql, schema: "shop", binaryType: "LONGBLOB")
    viewer.lazyColumns = DataViewerState.lazyColumns(
      [("id", "INT", true), ("photo", "LONGBLOB", false), ("hash", "VARBINARY(64)", false)],
      databaseType: .mysql, orderColumns: ["id"])
    #expect(
      viewer.pageSQL
        == "SELECT `id`, LEFT(`photo`, 65536) AS `photo`, LEFT(`hash`, 65536) AS `hash`, "
        + "LENGTH(`photo`) AS `dblore_byte_length_1`, LENGTH(`hash`) AS `dblore_byte_length_2` "
        + "FROM `shop`.`users` ORDER BY `id` LIMIT 100")
    #expect(
      CellUpdateStatement.singleRelation(in: viewer.pageSQL, dialect: .mysql) == "`shop`.`users`")
  }

  @Test("A lazy SQLite page cuts only blob values")
  func lazySQLite() {
    let viewer = lazy(.sqlite, schema: "main", binaryType: "BLOB")
    #expect(
      viewer.pageSQL
        == #"SELECT "id", CASE WHEN typeof("photo") = 'blob' THEN substr("photo", 1, 65536) "#
        + #"ELSE "photo" END AS "photo", "name", CASE WHEN typeof("photo") = 'blob' THEN "#
        + #"length("photo") END AS "dblore_byte_length_1" FROM "main"."users" ORDER BY "id" "#
        + "LIMIT 100")
    #expect(CellUpdateStatement.singleRelation(in: viewer.pageSQL, dialect: .sqlite) != nil)
  }

  @Test("A SQLite column whose loaded values were blobs is cut whatever its declared type")
  func lazySQLiteBlobValues() {
    let columns = DataViewerState.lazyColumns(
      [("id", "INTEGER", true), ("anything", "", false)], databaseType: .sqlite,
      orderColumns: [], binaryValueColumns: ["anything"])
    #expect(columns?.map(\.isPrefixed) == [false, true])
    // Only SQLite: a PostgreSQL or MySQL value type is fixed by the column
    #expect(
      DataViewerState.lazyColumns(
        [("id", "INT", true), ("shape", "GEOMETRY", false)], databaseType: .mysql,
        orderColumns: [], binaryValueColumns: ["shape"]) == nil)
  }

  @Test("No primary key, no binary column, another engine or no columns read SELECT *")
  func lazyFallsBackToSelectStar() {
    #expect(
      DataViewerState.lazyColumns(
        [("id", "INTEGER", false), ("photo", "BYTEA", false)], databaseType: .postgresql,
        orderColumns: []) == nil)
    #expect(
      DataViewerState.lazyColumns(
        [("id", "INTEGER", true), ("name", "TEXT", false)], databaseType: .postgresql,
        orderColumns: []) == nil)
    #expect(
      DataViewerState.lazyColumns(
        [("id", "INTEGER", true), ("photo", "BLOB", false)], databaseType: .duckdb,
        orderColumns: []) == nil)
    #expect(DataViewerState.lazyColumns([], databaseType: .postgresql, orderColumns: []) == nil)
    #expect(state().pageSQL.hasPrefix("SELECT * FROM "))
  }

  @Test("Key and ORDER BY columns are never cut")
  func lazyKeepsKeyAndOrderColumns() {
    let columns = DataViewerState.lazyColumns(
      [("id", "BYTEA", true), ("version", "BYTEA", false), ("photo", "BYTEA", false)],
      databaseType: .postgresql, orderColumns: ["id", "version"])
    #expect(columns?.map(\.isPrefixed) == [false, false, true])
  }

  @Test("A table column named like a length alias reads SELECT *")
  func lazyAliasCollision() {
    #expect(
      DataViewerState.lazyColumns(
        [
          ("id", "INTEGER", true), ("photo", "BYTEA", false),
          ("dblore_byte_length_1", "INT", false),
        ],
        databaseType: .postgresql, orderColumns: []) == nil)
  }

  @Test("loadKey does not change with the lazy columns")
  func lazyLoadKey() {
    var viewer = state(orderColumns: ["id"])
    let key = viewer.loadKey
    viewer = lazy(.postgresql)
    #expect(viewer.loadKey == key)
  }

  // MARK: - Row locators (keyless tables)

  @Test("A keyless page reads its locator as dblore_* columns, stripped into one key per page row")
  func locatorPageAndStrip() async throws {
    var postgres = state()
    postgres.rowLocator = .pgLocator
    #expect(
      postgres.pageSQL
        == #"SELECT *, tableoid::text AS "dblore_tableoid", ctid::text AS "dblore_ctid", "#
        + #"xmin::text AS "dblore_xmin" FROM "public"."users" LIMIT 100"#)
    #expect(CellUpdateStatement.singleRelation(in: postgres.pageSQL) == #""public"."users""#)

    var sqlite = state(schema: "main", name: "notes")
    sqlite.databaseType = .sqlite
    let kind = RowLocatorKind.sqliteRowid(alias: .rowid, matchColumns: ["body"])
    sqlite.rowLocator = kind
    #expect(sqlite.pageSQL == #"SELECT *, rowid AS "dblore_rowid" FROM "main"."notes" LIMIT 100"#)

    // Two identical rows: the strip keys them by their own rowid, by page row
    let viewModel = NotebookViewModel()
    let page = QueryResult(
      columns: [
        ColumnInfo(name: "body", type: "TEXT"), ColumnInfo(name: "dblore_rowid", type: ""),
      ],
      rows: [[.string("same"), .int(1)], [.string("same"), .int(2)]], rowCount: 2,
      executionTime: 0)
    let (stripped, truncation) = try await viewModel.strippedDataViewerPage(
      page, state: sqlite, epoch: 1, connectionManager: DatabaseConnectionManager())
    #expect(stripped.columns.map(\.name) == ["body"])
    #expect(stripped.rows == [[.string("same")], [.string("same")]])
    #expect(truncation?.rowLocator == kind)
    #expect(truncation?.locators.map(\.values) == [[.string("1")], [.string("2")]])
    #expect(truncation?.locators.first?.locator?.row["body"] == .string("same"))
    #expect(
      truncation?.locatorKey(row: 1, kind: kind) != truncation?.locatorKey(row: 0, kind: kind))

    // A page without the locator columns it asked for is never shown as editable
    let missing = QueryResult(
      columns: [page.columns[0]], rows: page.rows.map { [$0[0]] }, rowCount: 2, executionTime: 0)
    await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
      _ = try await viewModel.strippedDataViewerPage(
        missing, state: sqlite, epoch: 1, connectionManager: DatabaseConnectionManager())
    }
  }

  @Test("First open of a keyless table: one automatic re-read adds the locator, editing after it")
  func firstKeylessPageReReadsOnce() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-keyless-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    for statement in [
      "CREATE TABLE notes (body TEXT)", "INSERT INTO notes VALUES ('same'), ('same')",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    let reads = StatementCounter()
    await manager.setScriptCheckpointHook { checkpoint in
      if case .beforeStatement = checkpoint { await reads.increment() }
    }
    let gate = CatalogHold()
    await gate.hold()
    await manager.setCatalogReadHook { await gate.pass() }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    var viewer = DataViewerState(schema: "main", name: "notes", orderColumns: [])
    viewer.databaseType = .sqlite
    viewModel.dataViewer = viewer

    // The first page is a plain `*`: nothing is known of the table yet
    await viewModel.loadDataViewerPage()
    let first = try #require(viewModel.editorResult)
    #expect(first.rows.count == 2)
    #expect(first.truncation?.rowLocator == nil)
    #expect(!viewModel.canEdit(first))

    await gate.release()
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if let shown = viewModel.editorResult, !shown.typesPending,
        shown.truncation?.rowLocator != nil
      {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    let shown = try #require(viewModel.editorResult)
    #expect(shown.columns.map(\.name) == ["body"])
    #expect(shown.truncation?.locators.count == 2)
    #expect(viewModel.canEdit(shown))
    #expect(viewModel.rowStagingUnavailableReason == nil)
    // The keyless target alone, on the page read without the locator columns: not editable
    var unlocated = first
    unlocated.editTarget = shown.editTarget
    unlocated.typesPending = false
    #expect(shown.editTarget?.rowLocator != nil)
    #expect(!viewModel.canEdit(unlocated))
    // The page, its count, and one re-read with the locator columns
    #expect(await reads.value == 3)

    // The second of the identical rows is edited, the first is left alone
    #expect(viewModel.stageEdit(row: 1, column: "body", value: .string("other")) == nil)
    await viewModel.commitStaged()
    #expect(!viewModel.hasPendingStagedChanges)
    let stored = try await manager.executeInternal("SELECT body FROM notes ORDER BY rowid")
    #expect(stored.rows == [[.string("same")], [.string("other")]])

    await gate.release()
    await manager.disconnect()
    for suffix in ["", "-journal", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
}

/// Statements sent through the user path (`setScriptCheckpointHook`)
private actor StatementCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Holds every edit-table catalog read while closed
private actor CatalogHold {
  private var holding = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func pass() async {
    guard holding else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func hold() { holding = true }

  func release() {
    holding = false
    let resumed = waiters
    waiters = []
    for waiter in resumed { waiter.resume() }
  }
}
