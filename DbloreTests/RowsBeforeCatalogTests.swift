// RowsBeforeCatalogTests.swift
// The grid shows rows before the catalog answers: the edit target (and PostgreSQL's enriched
// column types) follow from a background read that patches only the result it was read for,
// never re-reads the page, keeps a staged set across a Reload while pending, and picks up a
// primary key changed outside the app before an edit is sent. The per-connection caches clear
// on a schema change; MCP's `execute` keeps awaiting the enriched types, read fresh. A cached
// PostgreSQL type is shown only while the driver reports the type it was read with, and the
// background read refreshes it.
// SQLite file (no server) with a held edit-table catalog read; a fake PostgreSQL session with a
// held column type catalog for the types.

import Foundation
import Testing

@testable import Dblore

@Suite("Rows before catalog enrichment")
@MainActor
struct RowsBeforeCatalogTests {
  /// Holds every edit-table catalog read while closed
  private actor CatalogGate {
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
      arrivals += 1
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

  /// Statements sent through the user path (`runUserStatements`)
  private actor StatementCount {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  private struct Fixture {
    let url: URL
    let manager: DatabaseConnectionManager
    let viewModel: NotebookViewModel
    let gate: CatalogGate
    let statements: StatementCount

    func close() async {
      await gate.release()
      await manager.disconnect()
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
  }

  /// `items` (`id` key, two rows) in a SQLite file, shown in a data viewer ordered by `id`, or
  /// in a plain SQL editor (`dataViewer` false)
  private static func fixture(dataViewer: Bool = true) async throws -> Fixture {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-rows-first-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    for statement in [
      "CREATE TABLE items (id INTEGER PRIMARY KEY, code TEXT NOT NULL, label TEXT)",
      "INSERT INTO items VALUES (1, 'a', 'x'), (2, 'b', 'y')",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    let gate = CatalogGate()
    let statements = StatementCount()
    await manager.setCatalogReadHook { await gate.pass() }
    await manager.setScriptCheckpointHook { checkpoint in
      if case .beforeStatement = checkpoint { await statements.increment() }
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    if dataViewer {
      var state = DataViewerState(schema: "main", name: "items", orderColumns: ["id"])
      state.databaseType = .sqlite
      viewModel.dataViewer = state
    }
    return Fixture(
      url: url, manager: manager, viewModel: viewModel, gate: gate, statements: statements)
  }

  /// Runs `load` in its own task and returns once the shown result satisfies `shown` (within
  /// 30 seconds: the catalog stays held until this returns, so a loaded suite only takes
  /// longer), with the task, or nil after recording an issue
  private static func published(
    _ viewModel: NotebookViewModel, _ step: String,
    _ shown: @escaping @MainActor (CellResult?) -> Bool,
    load: @escaping @MainActor () async -> Void
  ) async -> Task<Void, Never>? {
    let task = Task { @MainActor in await load() }
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
      if shown(viewModel.editorResult) { return task }
      try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("\(step): the rows were not shown while the catalog was held")
    return nil
  }

  /// The label stored for `code`
  private static func label(
    code: String, in manager: DatabaseConnectionManager
  ) async throws
    -> CellValue?
  {
    try await manager.executeInternal("SELECT label FROM items WHERE code = '\(code)'")
      .rows.first?.first
  }

  @Test("A table click shows the rows first, then the edit target, with one page read")
  func rowsBeforeEditTarget() async throws {
    let fixture = try await Self.fixture()
    let viewModel = fixture.viewModel
    await fixture.gate.hold()
    let load = await Self.published(
      viewModel, "First page", { $0?.rows.count == 2 },
      load: { await viewModel.loadDataViewerPage() })
    let shown = try #require(viewModel.editorResult)
    #expect(shown.typesPending)
    #expect(shown.editTarget == nil)
    #expect(!viewModel.canEdit(shown))
    #expect(viewModel.rowStagingUnavailableReason == NotebookViewModel.readingTableDefinition)
    #expect(
      viewModel.stageEdit(row: 0, column: "label", value: .string("z"))
        == NotebookViewModel.readingTableDefinition)

    await fixture.gate.release()
    await load?.value
    await viewModel.awaitResultTargets()
    let patched = try #require(viewModel.editorResult)
    #expect(!patched.typesPending)
    #expect(patched.editTarget?.primaryKeyColumns == ["id"])
    #expect(viewModel.canEdit(patched))
    #expect(viewModel.rowStagingUnavailableReason == nil)
    // The patch replaced nothing but the catalog's answer: same run, no second page read
    #expect(patched.timestamp == shown.timestamp)
    #expect(patched.rows == shown.rows)
    #expect(await fixture.statements.value == 2)  // the page and its count
    await fixture.close()
  }

  @Test("A background read never patches a result that replaced its own")
  func stalePatchSkipped() async throws {
    let fixture = try await Self.fixture(dataViewer: false)
    let viewModel = fixture.viewModel
    await fixture.gate.hold()
    let first = await Self.published(
      viewModel, "Table read", { $0?.rows.count == 2 },
      load: { await viewModel.executeEditorQuery("SELECT * FROM items") })
    #expect(viewModel.editorResult?.typesPending == true)
    await first?.value
    await viewModel.executeEditorQuery("SELECT 1 AS x")
    let replaced = try #require(viewModel.editorResult)
    #expect(!replaced.typesPending)

    await fixture.gate.release()
    await viewModel.awaitResultTargets()
    #expect(await fixture.gate.arrivals == 1)
    let shown = try #require(viewModel.editorResult)
    #expect(shown.columns.map(\.name) == ["x"])
    #expect(shown.timestamp == replaced.timestamp)
    #expect(shown.editTarget == nil)
    #expect(!shown.typesPending)
    await fixture.close()
  }

  @Test("Reload while the table definition is read keeps the staged edits and their Commit")
  func reloadKeepsStagedCommit() async throws {
    let fixture = try await Self.fixture()
    let viewModel = fixture.viewModel
    await viewModel.loadDataViewerPage()
    await viewModel.awaitResultTargets()
    #expect(viewModel.stageEdit(row: 0, column: "label", value: .string("draft")) == nil)
    let staged = try #require(viewModel.dataViewer?.changeSet)
    let firstRun = viewModel.editorResult?.timestamp

    await fixture.gate.hold()
    let reload = await Self.published(
      viewModel, "Reload", { $0 != nil && $0?.timestamp != firstRun },
      load: { await viewModel.reloadStaleDataViewer() })
    // The cached target is shown at once: the staged overlay keeps its target
    #expect(viewModel.editorResult?.typesPending == true)
    #expect(viewModel.dataViewer?.changeSet == staged)
    #expect(viewModel.stagedEditTarget != nil)

    await fixture.gate.release()
    await reload?.value
    await viewModel.awaitResultTargets()
    await viewModel.commitStaged()
    #expect(!viewModel.hasPendingStagedChanges)
    #expect(try await Self.label(code: "a", in: fixture.manager) == .string("draft"))
    await fixture.close()
  }

  @Test("A primary key changed outside the app is picked up before an edit is sent")
  func changedPrimaryKeyPickedUp() async throws {
    let fixture = try await Self.fixture()
    let viewModel = fixture.viewModel
    await viewModel.loadDataViewerPage()
    await viewModel.awaitResultTargets()
    #expect(viewModel.editorResult?.editTarget?.primaryKeyColumns == ["id"])
    // Another client rekeys the table on `code`; both rows now share `id` 1
    for statement in [
      "CREATE TABLE rekeyed (id INTEGER, code TEXT NOT NULL, label TEXT, PRIMARY KEY (code))",
      "INSERT INTO rekeyed SELECT 1, code, label FROM items",
      "DROP TABLE items",
      "ALTER TABLE rekeyed RENAME TO items",
    ] {
      _ = try await fixture.manager.executeInternal(statement)
    }

    await fixture.gate.hold()
    let firstRun = viewModel.editorResult?.timestamp
    let reload = await Self.published(
      viewModel, "Re-read", { $0 != nil && $0?.timestamp != firstRun },
      load: { await viewModel.reloadStaleDataViewer() })
    // The cached key is only shown: nothing can be edited with it
    let pending = try #require(viewModel.editorResult)
    #expect(pending.typesPending)
    #expect(!viewModel.canEdit(pending))

    await fixture.gate.release()
    await reload?.value
    await viewModel.awaitResultTargets()
    #expect(viewModel.editorResult?.editTarget?.primaryKeyColumns == ["code"])
    #expect(viewModel.stageEdit(row: 0, column: "label", value: .string("z")) == nil)
    await viewModel.commitStaged()
    #expect(!viewModel.hasPendingStagedChanges)
    #expect(try await Self.label(code: "a", in: fixture.manager) == .string("z"))
    #expect(try await Self.label(code: "b", in: fixture.manager) == .string("y"))
    await fixture.close()
  }

  @Test("A schema change clears the edit-table and column-type caches")
  func schemaChangeClearsCaches() async throws {
    let fixture = try await Self.fixture()
    let viewModel = fixture.viewModel
    await viewModel.loadDataViewerPage()
    await viewModel.awaitResultTargets()
    let manager = fixture.manager
    await manager.seedColumnType(ColumnOrigin(tableID: .postgresql(oid: 7), columnOrdinal: 1))
    #expect(await !manager.editTableCache.isEmpty)
    #expect(await !manager.columnTypeCache.isEmpty)

    _ = try await manager.executeGatedSchemaChange(
      ["CREATE TABLE extra (a INTEGER)"], policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: await manager.connectionEpoch)
    #expect(await manager.editTableCache.isEmpty)
    #expect(await manager.columnTypeCache.isEmpty)
    await fixture.close()
  }

  @Test("MCP's execute reads the enriched types fresh; only the app's opt-in defers them")
  func defaultExecuteKeepsEnrichedTypes() async throws {
    let catalog = TypeCatalog([1: "NUMERIC(10,2)"])
    let (manager, _) = try await Self.postgres(driverType: "numeric", catalog: catalog)
    let policy = ProtectionPolicy(protectionLevel: .none)
    let query = "SELECT amount FROM payments"

    let deferred = try await manager.execute(
      userSQL: query, policy: policy, deferEnrichment: true)
    #expect(deferred.typesDeferred)
    #expect(deferred.columns.map(\.type) == ["numeric"])
    #expect(await catalog.reads == 0)

    let awaited = try await manager.execute(userSQL: query, policy: policy)
    #expect(!awaited.typesDeferred)
    #expect(awaited.columns.map(\.type) == ["NUMERIC(10,2)"])
    // Changed by another client: the default path never answers from the cache
    await catalog.set([1: "NUMERIC(12,2)"])
    let fresh = try await manager.execute(userSQL: query, policy: policy)
    #expect(fresh.columns.map(\.type) == ["NUMERIC(12,2)"])
    #expect(await catalog.reads == 2)
    // The app's path keeps the driver's types for its background read and shows the cached ones
    let cached = try await manager.execute(userSQL: query, policy: policy, deferEnrichment: true)
    #expect(cached.typesDeferred)
    #expect(cached.columns.map(\.type) == ["numeric"])
    #expect(await manager.cachedColumnTypes(cached.columns)?.map(\.type) == ["NUMERIC(12,2)"])
    await manager.disconnect()
  }

  // MARK: - PostgreSQL column types

  /// Answers the PostgreSQL column type catalog read (`setColumnTypeReadHook`): `types` by
  /// attnum, held while closed
  private actor TypeCatalog {
    private var types: [Int: String]
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(_ types: [Int: String]) { self.types = types }

    func set(_ types: [Int: String]) { self.types = types }

    func hold() { holding = true }

    func release() {
      holding = false
      let resumed = waiters
      waiters = []
      for waiter in resumed { waiter.resume() }
    }

    func answer(_ columns: [ColumnInfo]) async -> [ColumnInfo] {
      reads += 1
      if holding { await withCheckedContinuation { waiters.append($0) } }
      return columns.map { column in
        guard let ordinal = column.tableOrigin?.columnOrdinal, let type = types[ordinal] else {
          return column
        }
        return ColumnInfo(
          name: column.name, type: type, origin: column.origin, wallClock: column.wallClock)
      }
    }
  }

  private static let amountOrigin = ColumnOrigin(
    tableID: .postgresql(oid: 42), columnOrdinal: 1)

  /// A fake PostgreSQL connection whose reads return one `amount` column of `driverType`, with
  /// its column type catalog answered by `catalog`, and a SQL editor on it
  private static func postgres(
    driverType: String, catalog: TypeCatalog
  ) async throws -> (DatabaseConnectionManager, NotebookViewModel) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities,
      columns: [ColumnInfo(name: "amount", type: driverType, origin: amountOrigin)],
      rows: [[.string("1.50")]])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "fake", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    try await manager.connect(config: config)
    await manager.setColumnTypeReadHook { await catalog.answer($0) }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    return (manager, viewModel)
  }

  /// Runs `SELECT amount FROM payments` with the type catalog held: returns the result shown
  /// before the catalog answers, then the result after the background read patched it
  private static func readAmounts(
    _ viewModel: NotebookViewModel, catalog: TypeCatalog
  ) async throws -> (shown: CellResult, patched: CellResult) {
    let before = viewModel.editorResult?.timestamp
    await catalog.hold()
    let run = await published(
      viewModel, "Amounts", { $0?.rows.count == 1 && $0?.timestamp != before },
      load: { await viewModel.executeEditorQuery("SELECT amount FROM payments") })
    let shown = try #require(viewModel.editorResult)
    await catalog.release()
    await run?.value
    await viewModel.awaitResultTargets()
    let patched = try #require(viewModel.editorResult)
    return (shown, patched)
  }

  @Test("PostgreSQL rows show with the driver's types, then the same result gets the catalog's")
  func postgresTypesPatched() async throws {
    let catalog = TypeCatalog([1: "NUMERIC(10,2)"])
    let (manager, viewModel) = try await Self.postgres(driverType: "numeric", catalog: catalog)
    let (shown, patched) = try await Self.readAmounts(viewModel, catalog: catalog)
    #expect(shown.typesPending)
    #expect(shown.columns.map(\.type) == ["numeric"])
    #expect(!patched.typesPending)
    #expect(patched.timestamp == shown.timestamp)
    #expect(patched.rows == shown.rows)
    #expect(patched.columns.map(\.type) == ["NUMERIC(10,2)"])
    await manager.disconnect()
  }

  @Test("A lazy PostgreSQL page keeps its deferred types for the background read")
  func lazyPageKeepsDeferredTypes() async throws {
    let catalog = TypeCatalog([:])
    let (manager, viewModel) = try await Self.postgres(driverType: "numeric", catalog: catalog)
    var state = DataViewerState(schema: "public", name: "payments", orderColumns: ["id"])
    state.databaseType = .postgresql
    state.lazyColumns = [
      DataViewerState.LazyColumn(name: "id", type: "int4", isPrimaryKey: true, isPrefixed: false),
      DataViewerState.LazyColumn(
        name: "payload", type: "bytea", isPrimaryKey: false, isPrefixed: true),
    ]
    var read = QueryResult(
      columns: [
        ColumnInfo(name: "id", type: "int4", origin: Self.amountOrigin),
        ColumnInfo(name: "payload", type: "bytea"),
        ColumnInfo(name: "dblore_byte_length_1", type: "int4"),
      ],
      rows: [[.int(1), .data(Data([1, 2])), .int(2)]], rowCount: 1, executionTime: 0,
      wasLimited: false, affectedRows: 0)
    read.typesDeferred = true
    let page = try await viewModel.strippedDataViewerPage(
      read, state: state, epoch: await manager.connectionEpoch, connectionManager: manager)
    #expect(page.result.columns.map(\.name) == ["id", "payload"])
    #expect(page.result.typesDeferred)
    await manager.disconnect()
  }

  @Test("A cached type is not shown once the driver reports another base type")
  func cachedTypeNeedsSameDriverType() async throws {
    let catalog = TypeCatalog([1: "BIGINT"])
    let (manager, viewModel) = try await Self.postgres(driverType: "int8", catalog: catalog)
    // Cached while the column was int4; another client altered it to bigint since
    await manager.seedColumnType(Self.amountOrigin, driver: "int4", type: "INTEGER")
    let (shown, patched) = try await Self.readAmounts(viewModel, catalog: catalog)
    #expect(shown.columns.map(\.type) == ["int8"])
    #expect(shown.typesPending)
    #expect(patched.columns.map(\.type) == ["BIGINT"])
    await manager.disconnect()
  }

  @Test("A modifier changed outside the app converges after one background read")
  func modifierChangeConverges() async throws {
    let catalog = TypeCatalog([1: "NUMERIC(12,2)"])
    let (manager, viewModel) = try await Self.postgres(driverType: "numeric", catalog: catalog)
    await manager.seedColumnType(Self.amountOrigin, driver: "numeric", type: "NUMERIC(10,2)")
    let first = try await Self.readAmounts(viewModel, catalog: catalog)
    // The cached type is shown at once, the catalog's after the read
    #expect(first.shown.columns.map(\.type) == ["NUMERIC(10,2)"])
    #expect(first.patched.columns.map(\.type) == ["NUMERIC(12,2)"])
    #expect(first.patched.timestamp == first.shown.timestamp)
    // The cache took the new type: the next read shows it at once
    let second = try await Self.readAmounts(viewModel, catalog: catalog)
    #expect(second.shown.columns.map(\.type) == ["NUMERIC(12,2)"])
    #expect(second.patched.columns.map(\.type) == ["NUMERIC(12,2)"])
    await manager.disconnect()
  }
}

extension DatabaseConnectionManager {
  /// Stores `type` for `origin`, read while the driver reported `driver`, as an enrichment
  /// read would
  fileprivate func seedColumnType(
    _ origin: ColumnOrigin, driver: String = "int4", type: String = "INTEGER"
  ) {
    columnTypeCache.store(
      driver: [ColumnInfo(name: "c", type: driver, origin: origin)],
      enriched: [ColumnInfo(name: "c", type: type, origin: origin)],
      readAt: columnTypeCache.generation)
  }
}
