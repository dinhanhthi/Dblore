// LazyBinaryCellTests.swift
// Large binary cells of a lazy data-viewer page: the full value is read by key as bytes, a
// newer viewer request cancels the older one, copies and the Export sheet get full values, a
// missing row is an error, the grid never shows a cut value as whole, and no write binds a cut
// value (Duplicate Row loads it first or stages nothing, edits leave its column out, Row
// Details never edits it). Bytes are written as blobs. Loads fail closed: never on another
// connection, never past the bulk limit, never for a page of an unexpected shape or an earlier
// read. SQLite files, no server.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Lazy Binary Cell Tests")
struct LazyBinaryCellTests {

  /// Row 1's full 70,000 random bytes, as the `SELECT *` page read them
  private static func fullPayload(_ plain: CellResult) -> CellValue {
    plain.rows[0][1]
  }

  private static let itemsTable = DatabaseTable(
    schema: "main", name: "items",
    columns: [
      DatabaseColumn(name: "id", type: "INTEGER", isPrimaryKey: true),
      DatabaseColumn(name: "payload", type: "BLOB"),
      DatabaseColumn(name: "label", type: "TEXT"),
    ])

  private static let cutCell = LazyCell(
    row: RowChangeSet.RowKey(values: [.int(1)]), column: "payload")

  /// A SQLite data viewer on `main.items` (row 1 large, row 2 small), its first page read
  /// `SELECT *` (no cached columns: whole values) and returned as `plain`; `lazy` then reads the
  /// lazy page. The file is closed and deleted afterwards. History and Data Rewind are off.
  private func withItems(
    _ body: (
      _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager, _ plain: CellResult
    ) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lazy-cells-\(UUID().uuidString).sqlite")
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
      "INSERT INTO items VALUES (1, randomblob(70000), 'a'), (2, x'0102', 'b')",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    viewModel.toastPresenter = { _, _ in }
    let suiteName = "LazyBinaryCellTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = false
    settings.rewindEnabled = false
    viewModel.historySettings = settings
    var state = DataViewerState(schema: "main", name: "items", orderColumns: ["id"])
    state.databaseType = .sqlite
    viewModel.dataViewer = state
    await viewModel.loadDataViewerPage()
    let plain = try #require(viewModel.editorResult)
    guard case .data(let full) = plain.rows[0][1] else {
      Issue.record("The large value was not read as bytes")
      return
    }
    #expect(full.count == 70_000)
    viewModel.databaseTables = [Self.itemsTable]
    await viewModel.refreshDataViewer()
    #expect(
      viewModel.editorResult?.rows[0][1]
        == .data(Data(full.prefix(DataViewerState.lazyPrefixBytes))))
    do {
      try await body(viewModel, manager, plain)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  // MARK: - Loader

  @Test("The loader binds the row key and returns the full bytes, not hex text")
  func loadsFullValueByKey() async throws {
    try await withItems { viewModel, _, plain in
      let source = try viewModel.lazyCellSource(
        for: try #require(viewModel.editorResult?.truncation))
      let read = try LazyCellLoader.statement(Self.cutCell, source: source)
      #expect(read.sql == #"SELECT "payload" FROM "main"."items" WHERE "id" = :k1"#)
      #expect(read.parameters == ["k1": .text("1")])
      let value = try await LazyCellLoader.load(Self.cutCell, source: source)
      #expect(value == Self.fullPayload(plain))
    }
  }

  @Test("A composite key ANDs every key column; MySQL binds key bytes through UNHEX")
  func compositeKeyStatement() throws {
    let source = LazyCellSource(
      relation: "`shop`.`files`", keyColumns: ["owner", "digest"], dialect: .mysql
    ) { _, _ in QueryResult(columns: [], rows: [], rowCount: 0, executionTime: 0) }
    let cell = LazyCell(
      row: RowChangeSet.RowKey(values: [.int(7), .data(Data([0xAB, 0x01]))]), column: "body")
    let read = try LazyCellLoader.statement(cell, source: source)
    #expect(
      read.sql == "SELECT `body` FROM `shop`.`files` WHERE `owner` = :k1 AND `digest` = UNHEX(:k2)")
    #expect(read.parameters == ["k1": .text("7"), "k2": .text("ab01")])
    _ = try ReadOnlyQueryGuard.check(read.sql, dialect: .mysql)

    let postgres = LazyCellSource(
      relation: #""public"."items""#, keyColumns: ["id"], dialect: .postgresql
    ) { _, _ in QueryResult(columns: [], rows: [], rowCount: 0, executionTime: 0) }
    let postgresRead = try LazyCellLoader.statement(
      LazyCell(row: RowChangeSet.RowKey(values: [.int(1)]), column: "payload"), source: postgres)
    #expect(postgresRead.sql == #"SELECT "payload" FROM "public"."items" WHERE "id" = :k1"#)
    _ = try ReadOnlyQueryGuard.check(postgresRead.sql, dialect: .postgresql)

    let nullKey = LazyCell(row: RowChangeSet.RowKey(values: [.int(7), .null]), column: "body")
    #expect(throws: LazyCellLoadError.noKey) {
      try LazyCellLoader.statement(nullKey, source: source)
    }
  }

  @Test("A missing row is an error: nothing is loaded, copied or exported")
  func missingRowIsAnError() async throws {
    try await withItems { viewModel, manager, _ in
      let lazy = try #require(viewModel.editorResult)
      _ = try await manager.executeInternal("DELETE FROM items WHERE id = 1")
      let source = try viewModel.lazyCellSource(
        for: try #require(viewModel.editorResult?.truncation))
      await #expect(throws: LazyCellLoadError.rowMissing) {
        try await LazyCellLoader.load(Self.cutCell, source: source)
      }
      #expect(
        await QueryCopyBar.exportRequest(format: .csv, result: lazy, viewModel: viewModel) == nil)
      #expect(await QueryCopyBar.loadedResult(lazy, viewModel: viewModel, action: "Copy") == nil)
      // The cut cell is still marked, its prefix untouched
      #expect(viewModel.unloadedCells(in: lazy) == [0: [1: 70_000]])
      #expect(viewModel.editorResult?.rows[0][1] == lazy.rows[0][1])
    }
  }

  @Test("A newer viewer request for another cell cancels the older one")
  func newerRequestCancelsOlder() async throws {
    let gate = Gate()
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let source = LazyCellSource(relation: #""t""#, keyColumns: ["id"], dialect: .sqlite) {
      _, parameters in
      let isFirst = parameters["k1"] == .text("1")
      if isFirst {
        startedContinuation.yield()
        await gate.wait()
      }
      return QueryResult(
        columns: [ColumnInfo(name: "payload", type: "BLOB")],
        rows: [[.data(Data([isFirst ? 1 : 2]))]], rowCount: 1, executionTime: 0)
    }
    let loader = LazyCellLoader()
    let other = LazyCell(row: RowChangeSet.RowKey(values: [.int(2)]), column: "payload")
    let first = Task { try await loader.value(for: Self.cutCell, source: source) }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()

    let second = try await loader.value(for: other, source: source)
    #expect(second == .data(Data([2])))
    await gate.open()
    await #expect(throws: CancellationError.self) { try await first.value }
  }

  @Test("The Cell Value viewer loads the cut cell and the page keeps the full value")
  func viewerLoadsCutCell() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      viewModel.showGridCellInSidebar(
        row: lazy.rows[0], originalRow: 0, column: 1, result: lazy, cellId: nil)
      let unloaded = try #require(viewModel.unloadedSidebarCell)
      #expect(unloaded.cell == Self.cutCell)
      #expect(unloaded.length == 70_000)

      #expect(await viewModel.loadSidebarCell(unloaded.cell, length: unloaded.length) == nil)
      #expect(viewModel.unloadedSidebarCell == nil)
      guard case .cellInfo(_, _, let value, _, _, _, _) = viewModel.rightSidebarContent else {
        Issue.record("The sidebar no longer shows the cell")
        return
      }
      #expect(value == Self.fullPayload(plain))
      #expect(viewModel.editorResult?.rows[0][1] == Self.fullPayload(plain))
      #expect(viewModel.editorResult?.truncation?.lengths.isEmpty == true)
      #expect(viewModel.unloadedCells(in: try #require(viewModel.editorResult)).isEmpty)
    }
  }

  // MARK: - Copy and export

  @Test("The result bar's copy as INSERT of a cut row carries the full value")
  func copyInsertCarriesFullValue() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      let expected = DataExporter.sqlInsert(result: plain, table: "items", dialect: .sqlite)
      #expect(DataExporter.sqlInsert(result: lazy, table: "items", dialect: .sqlite) != expected)

      let copied = try #require(
        await QueryCopyBar.loadedResult(lazy, viewModel: viewModel, action: "Copy"))
      #expect(copied.rows[0][1] == Self.fullPayload(plain))
      #expect(DataExporter.sqlInsert(result: copied, table: "items", dialect: .sqlite) == expected)
      // Loaded once: the page now holds the full value and nothing is cut
      #expect(viewModel.editorResult?.rows[0][1] == Self.fullPayload(plain))
      #expect(!viewModel.hasUnloadedCells(in: try #require(viewModel.editorResult)))
    }
  }

  @Test("The Export sheet receives the fully loaded result")
  func exportSheetGetsFullResult() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      let request = try #require(
        await QueryCopyBar.exportRequest(format: .csv, result: lazy, viewModel: viewModel))
      #expect(request.format == .csv)
      #expect(request.result.rows == plain.rows)
    }
  }

  @Test("A result taken before a load's write-back still copies the loaded value")
  func staleResultUsesLoadedValue() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      _ = try #require(await viewModel.fullyLoadedResult(lazy, action: "Copy"))
      // `lazy` still holds the prefix, and the page no longer marks it
      #expect(viewModel.hasUnloadedCells(in: lazy))
      let copied = try #require(
        await QueryCopyBar.loadedResult(lazy, viewModel: viewModel, action: "Copy"))
      #expect(copied.rows == plain.rows)
    }
  }

  // MARK: - Writes

  @Test("Duplicate Row of a cut row stages and binds the full value, never the prefix")
  func duplicateStagesFullValue() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      let target = try #require(lazy.editTarget)
      #expect(await viewModel.stageDuplicate(rows: [0, 1]) == nil)
      let set = try #require(viewModel.dataViewer?.changeSet)
      #expect(set.inserts.count == 2)
      #expect(set.inserts[0].values["payload"] == Self.fullPayload(plain))
      #expect(set.inserts[0].values["label"] == .string("a"))
      #expect(set.inserts[1].values["payload"] == plain.rows[1][1])

      let statements = try RowChangeSQLBuilder.statements(
        for: set, target: target, columns: lazy.columns, dialect: .sqlite)
      let full = CellUpdateStatement.inputText(Self.fullPayload(plain), dialect: .sqlite)
      let prefix = CellUpdateStatement.inputText(lazy.rows[0][1], dialect: .sqlite)
      #expect(statements.first?.values.contains(full) == true)
      #expect(!statements.contains { $0.values.contains(prefix) })
      #expect(viewModel.editorResult?.truncation?.lengths.isEmpty == true)
    }
  }

  @Test("Duplicate Row stages nothing when the full value cannot be loaded")
  func duplicateRefusesWithoutFullValue() async throws {
    try await withItems { viewModel, manager, _ in
      let toasts = ToastLog()
      viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
      _ = try await manager.executeInternal("DELETE FROM items WHERE id = 1")
      #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(toasts.messages.contains { $0.hasPrefix("Duplicate Row refused") })
      #expect(viewModel.unloadedCells(in: try #require(viewModel.editorResult)) == [0: [1: 70_000]])
    }
  }

  @Test("An edit of another column of a cut row neither sets nor matches the cut column")
  func editOfAnotherColumnLeavesCutColumnOut() async throws {
    try await withItems { viewModel, manager, plain in
      let lazy = try #require(viewModel.editorResult)
      let target = try #require(lazy.editTarget)

      // Sent at once (grid or sidebar edit): SET the edited column, WHERE the key
      let inline = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, assignments: [(column: "label", value: "z")],
        primaryKeyColumns: target.primaryKeyColumns,
        rowData: CellResult.rowData(columns: lazy.columns, row: lazy.rows[0]),
        updateOnly: target.updateOnly, dialect: .sqlite)
      #expect(!inline.sql.contains("payload"))
      #expect(inline.values == ["z", "1"])

      // Staged (Set Value): the same, then committed
      #expect(
        viewModel.stageEdits(rows: [0], column: "label", values: [.value(.string("z"))]) == nil)
      let set = try #require(viewModel.dataViewer?.changeSet)
      let statements = try RowChangeSQLBuilder.statements(
        for: set, target: target, columns: lazy.columns, dialect: .sqlite)
      #expect(statements.count == 1)
      #expect(!(statements.first?.sql.contains("payload") ?? true))
      #expect(statements.first?.values == ["z", "1"])

      await viewModel.commitStaged()
      #expect(viewModel.dataViewer?.changeSet == nil)
      let stored = try await manager.executeInternal(
        "SELECT payload, label FROM items WHERE id = 1")
      #expect(stored.rows.first?[0] == Self.fullPayload(plain))
      #expect(stored.rows.first?[1] == .string("z"))
    }
  }

  @Test("Row Details shows a cut value as not loaded and never edits it")
  func rowDetailsMarksCutValue() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      viewModel.showRowDetail(row: lazy.rows[0], originalRow: 0, result: lazy, cellId: nil)
      let cut = try #require(viewModel.rowDetail?.fields.first { $0.name == "payload" })
      #expect(cut.isReadOnly)
      #expect(cut.text == "<70000 bytes, not loaded>")
      #expect(!cut.isDirty)
      #expect(viewModel.rowDetail?.fields.first { $0.name == "label" }?.isReadOnly == false)
      #expect(!viewModel.rowDetailHasChanges)

      // Loaded: the panel takes the full value, editable again
      _ = try #require(await viewModel.fullyLoadedResult(lazy, action: "Copy"))
      let whole = try #require(viewModel.rowDetail?.fields.first { $0.name == "payload" })
      #expect(whole.original == Self.fullPayload(plain))
      #expect(whole.unloadedLength == nil)
      #expect(!whole.isReadOnly)
    }
  }

  @Test("A staged UPDATE and INSERT of bytes store a blob with the same bytes")
  func stagedBytesStoreBlob() async throws {
    try await withItems { viewModel, manager, _ in
      let bytes = Data([0x00, 0x15, 0x71, 0x34, 0xFF])
      #expect(
        viewModel.stageEdits(rows: [1], column: "payload", values: [.value(.data(bytes))])
          == nil)
      await viewModel.commitStaged()
      #expect(viewModel.dataViewer?.changeSet == nil)
      let updated = try await manager.executeInternal(
        "SELECT typeof(payload), payload FROM items WHERE id = 2")
      #expect(updated.rows.first == [.string("blob"), .data(bytes)])

      #expect(await viewModel.stageDuplicate(rows: [1]) == nil)
      await viewModel.commitStaged()
      let inserted = try await manager.executeInternal(
        "SELECT typeof(payload), payload FROM items WHERE id = 3")
      #expect(inserted.rows.first == [.string("blob"), .data(bytes)])
    }
  }

  @Test("Duplicate Row of a cut row stores the full bytes as a blob")
  func duplicateOfCutRowStoresBlob() async throws {
    try await withItems { viewModel, manager, plain in
      #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
      await viewModel.commitStaged()
      #expect(viewModel.dataViewer?.changeSet == nil)
      let copy = try await manager.executeInternal(
        "SELECT typeof(payload), length(payload), payload FROM items WHERE id = 3")
      #expect(copy.rows.first?[0] == .string("blob"))
      #expect(copy.rows.first?[1] == .int(70_000))
      #expect(copy.rows.first?[2] == Self.fullPayload(plain))
    }
  }

  // MARK: - Fail closed

  @Test("After a reconnect to another database, no full value is read there")
  func reconnectNeverReadsAnotherDatabase() async throws {
    let other = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lazy-other-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: other.path + suffix)
      }
    }
    try await withItems { viewModel, manager, _ in
      let lazy = try #require(viewModel.editorResult)
      let config = ConnectionConfig(
        databaseType: .sqlite, database: other.path, username: "", protectionLevel: .none,
        safeMode: .silent, protectedMode: false)
      await manager.disconnect()
      try await manager.connect(config: config)
      for statement in [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, payload BLOB, label TEXT)",
        "INSERT INTO items VALUES (1, randomblob(80000), 'other')",
      ] {
        _ = try await manager.executeInternal(statement)
      }
      viewModel.invalidateEditTargets()

      let source = try viewModel.lazyCellSource(
        for: try #require(viewModel.editorResult?.truncation))
      await #expect(throws: (any Error).self) {
        try await LazyCellLoader.load(Self.cutCell, source: source)
      }
      #expect(await viewModel.fullyLoadedResult(lazy, action: "Copy") == nil)
      #expect(await viewModel.loadSidebarCell(Self.cutCell, length: 70_000) != nil)
      // Still cut, its prefix untouched
      #expect(viewModel.unloadedCells(in: lazy) == [0: [1: 70_000]])
      #expect(viewModel.editorResult?.rows[0][1] == lazy.rows[0][1])

      // A page without its connection reads nothing
      var unpinned = try #require(lazy.truncation)
      unpinned.connectionEpoch = nil
      #expect(throws: LazyCellLoadError.noConnection) {
        try viewModel.lazyCellSource(for: unpinned)
      }
    }
  }

  @Test("A lazy page of an unexpected shape throws instead of showing prefixes as whole")
  func unexpectedLazyPageThrows() async throws {
    try await withItems { viewModel, manager, _ in
      let state = try #require(viewModel.dataViewer)
      #expect(state.lazyColumns != nil)
      #expect(state.lengthColumns == ["dblore_byte_length_1"])
      let prefix = CellValue.data(Data(count: DataViewerState.lazyPrefixBytes))
      let lazyNames = ["id", "payload", "label"]
      func page(_ names: [String], _ rows: [[CellValue]]) -> QueryResult {
        QueryResult(
          columns: names.map { ColumnInfo(name: $0, type: "") }, rows: rows,
          rowCount: rows.count, executionTime: 0)
      }
      func strip(_ result: QueryResult) async throws -> DataViewerState.Truncation? {
        try await viewModel.strippedDataViewerPage(
          result, state: state, epoch: 7, connectionManager: manager
        ).truncation
      }
      // Columns other than the lazy ones (here the raw `SELECT *` columns)
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip(page(lazyNames, [[.int(1), prefix, .string("a")]]))
      }
      // A row of another width
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip(
          page(lazyNames + state.lengthColumns, [[.int(1), prefix, .string("a")]]))
      }
      // A prefix-sized value without a usable length
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip(
          page(lazyNames + state.lengthColumns, [[.int(1), prefix, .string("a"), .null]]))
      }
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip(
          page(
            lazyNames + state.lengthColumns,
            [[.int(1), prefix, .string("a"), .string("many")]]))
      }
      // A decimal length is a length
      let truncation = try await strip(
        page(
          lazyNames + state.lengthColumns,
          [[.int(1), prefix, .string("a"), .double(70_000)], [.int(2), .null, .null, .null]]))
      #expect(truncation?.lengths == [RowChangeSet.RowKey(values: [.int(1)]): ["payload": 70_000]])
      #expect(truncation?.connectionEpoch == 7)
      #expect(truncation?.relation == #""main"."items""#)
    }
  }

  @Test("Copies loading more than the limit are refused before anything is read")
  func bulkLoadOverLimitIsRefused() async throws {
    try await withItems { viewModel, _, _ in
      let toasts = ToastLog()
      viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
      let key = RowChangeSet.RowKey(values: [.int(1)])
      viewModel.editorResult?.truncation?.lengths[key]?["payload"] =
        LazyCellLoader.bulkLimitBytes + 1
      let lazy = try #require(viewModel.editorResult)
      #expect(await viewModel.fullyLoadedResult(lazy, action: "Copy") == nil)
      #expect(toasts.messages.contains { $0.hasPrefix("Copy refused") && $0.contains("limit") })
      #expect(viewModel.editorResult?.rows[0][1] == lazy.rows[0][1])
      #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
      #expect(viewModel.dataViewer?.changeSet == nil)
    }
  }

  @Test("A copy of the page as an earlier read gave it still loads its own cut values")
  func earlierReadLoadsItsOwnCells() async throws {
    try await withItems { viewModel, _, plain in
      let earlier = try #require(viewModel.editorResult)
      let target = try #require(earlier.editTarget)
      let manager = try #require(viewModel.connectionManager)
      await viewModel.refreshDataViewerRows(
        target: target, connectionManager: manager, done: "Saved")
      #expect(viewModel.editorResult?.dataRevision == earlier.dataRevision + 1)
      #expect(viewModel.hasUnloadedCells(in: earlier))
      let copied = try #require(
        await QueryCopyBar.loadedResult(earlier, viewModel: viewModel, action: "Copy"))
      #expect(copied.rows == plain.rows)
      #expect(!viewModel.hasUnloadedCells(in: copied))
    }
  }

  @Test("A result keeps its cut cells after the tab moved to another table")
  func cutCellsTravelWithTheResult() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      var other = DataViewerState(schema: "main", name: "other", orderColumns: [])
      other.databaseType = .sqlite
      viewModel.dataViewer = other
      viewModel.editorResult = nil
      #expect(viewModel.hasUnloadedCells(in: lazy))
      #expect(viewModel.unloadedCells(in: lazy) == [0: [1: 70_000]])
      #expect(
        viewModel.rowsMarkingUnloadedCells(of: lazy, limit: 10)[0][1]
          == .string("<70000 bytes, not loaded>"))
      let copied = try #require(await viewModel.fullyLoadedResult(lazy, action: "Copy"))
      #expect(copied.rows == plain.rows)

      // Cut cells that cannot be read are never copied as whole
      var unreadable = lazy
      unreadable.truncation?.relation = ""
      #expect(await viewModel.fullyLoadedResult(unreadable, action: "Copy") == nil)
    }
  }

  @Test("A page read for a table the tab has left is not shown")
  func pageForAnotherTableIsDropped() async throws {
    try await withItems { viewModel, _, _ in
      let state = try #require(viewModel.dataViewer)
      let shown = try #require(viewModel.editorResult)
      var other = DataViewerState(schema: "main", name: "other", orderColumns: [])
      other.databaseType = .sqlite
      viewModel.dataViewer = other
      viewModel.editorResult = nil
      await viewModel.executeEditorQuery(
        state.pageSQL, maxRows: 100, source: .internal, pageState: state)
      #expect(viewModel.editorResult == nil)

      // A page of the same table at another page number is not shown either
      viewModel.dataViewer = state
      viewModel.editorResult = shown
      viewModel.dataViewer?.page = 2
      await viewModel.executeEditorQuery(
        state.pageSQL, maxRows: 100, source: .internal, pageState: state)
      #expect(viewModel.editorResult == shown)
    }
  }

  @Test("A pin compared with a lazy page does not mark its cut values as changed")
  func comparisonIgnoresCutValues() async throws {
    try await withItems { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      #expect(ResultComparison.compare(baseline: plain, current: lazy).changedRows.count == 1)
      viewModel.editorResult = plain
      #expect(viewModel.pinEditorResult())
      viewModel.editorResult = lazy
      viewModel.isEditorComparing = true
      await viewModel.refreshEditorComparison().value
      guard case .rows(let diff) = viewModel.displayedEditorComparison else {
        Issue.record("No row comparison")
        return
      }
      #expect(diff.changedRows.isEmpty)
      #expect(!diff.hasChanges)
    }
  }

  @Test("The capped preview of a large value is a syntax error, never a cut insert")
  func cappedPreviewNeverRuns() async throws {
    try await withItems { viewModel, manager, _ in
      let lazy = try #require(viewModel.editorResult)
      let target = try #require(lazy.editTarget)
      var set = RowChangeSet(target: target)
      set.stageInsert(values: ["id": .int(9), "payload": .data(Data(count: 1_000))])
      let preview = try RowChangeSQLBuilder.previewText(
        for: set, target: target, columns: lazy.columns, dialect: .sqlite)
      #expect(preview.contains(" ... /* 1000 bytes */"))
      await #expect(throws: (any Error).self) {
        try await manager.executeInternal(preview)
      }
      let stored = try await manager.executeInternal("SELECT count(*) FROM items WHERE id = 9")
      #expect(stored.rows.first == [.int(0)])
    }
  }

  @Test("A lazy page is stripped by the state it was built from, even after the state changed")
  func pageStripsWithItsOwnState() async throws {
    try await withItems { viewModel, _, _ in
      let state = try #require(viewModel.dataViewer)
      #expect(state.lazyColumns != nil)
      // A sort click while the page is read: the state's SQL no longer equals the query
      viewModel.dataViewer?.orderColumns = ["label"]
      #expect(viewModel.dataViewer?.pageSQL != state.pageSQL)
      await viewModel.executeEditorQuery(
        state.pageSQL, maxRows: 100, source: .internal, pageState: state)
      let page = try #require(viewModel.editorResult)
      #expect(page.error == nil)
      #expect(page.columns.map(\.name) == ["id", "payload", "label"])
      #expect(viewModel.unloadedCells(in: page) == [0: [1: 70_000]])

      // A lazy page SQL without its state, or not its state's SQL, is never shown
      await viewModel.executeEditorQuery(state.pageSQL, maxRows: 100, source: .internal)
      #expect(viewModel.editorResult?.error != nil)
      await viewModel.executeEditorQuery(
        state.pageSQL, maxRows: 100, source: .internal,
        pageState: try #require(viewModel.dataViewer))
      #expect(viewModel.editorResult?.error != nil)
      // Explain of the page SQL is a user run: not refused
      await viewModel.executeEditorQuery("EXPLAIN QUERY PLAN " + state.pageSQL)
      #expect(viewModel.editorResult?.error == nil)
    }
  }

  @Test("A page with cut values is not pinned")
  func pinRefusesCutPage() async throws {
    try await withItems { viewModel, _, _ in
      #expect(!viewModel.pinEditorResult())
      #expect(viewModel.editorPinnedResult == nil)
      let page = try #require(viewModel.editorResult)
      _ = try #require(await viewModel.fullyLoadedResult(page, action: "Copy"))
      #expect(viewModel.pinEditorResult())
    }
  }

  @Test("A cached column list that differs from the shown page never reads a wrong column")
  func staleCacheFollowsShownColumns() async throws {
    try await withItems { viewModel, _, _ in
      let id = DatabaseColumn(name: "id", type: "INTEGER", isPrimaryKey: true)
      let payload = DatabaseColumn(name: "payload", type: "BLOB")
      let label = DatabaseColumn(name: "label", type: "TEXT")
      let gone = DatabaseColumn(name: "gone", type: "TEXT")
      // The cache lacks a column, or lists one the table no longer has: the shown page's
      // columns are read
      for columns in [[id, payload], [id, payload, label, gone]] {
        viewModel.databaseTables = [DatabaseTable(schema: "main", name: "items", columns: columns)]
        await viewModel.refreshDataViewer()
        let page = try #require(viewModel.editorResult)
        #expect(page.error == nil)
        #expect(page.columns.map(\.name) == ["id", "payload", "label"])
        #expect(viewModel.unloadedCells(in: page) == [0: [1: 70_000]])
      }
      // With no page shown, a dropped column fails once; the next load reads SELECT *, then
      // the shown page's columns, with no failure after
      viewModel.editorResult = nil
      await viewModel.refreshDataViewer()
      #expect(viewModel.editorResult?.error != nil)
      await viewModel.refreshDataViewer()
      #expect(viewModel.editorResult?.sourceQuery?.hasPrefix("SELECT * FROM ") == true)
      for _ in 0..<2 {
        await viewModel.refreshDataViewer()
        let page = try #require(viewModel.editorResult)
        #expect(page.error == nil)
        #expect(viewModel.unloadedCells(in: page) == [0: [1: 70_000]])
      }
    }
  }

  @Test("The AI's @results shows a cut cell as not loaded, never its prefix")
  func aiResultMarksCutCell() async throws {
    try await withItems { viewModel, _, _ in
      let result = try #require(viewModel.aiCurrentResult)
      #expect(result.rows.first?[1] == "<70000 bytes, not loaded>")
    }
  }

  // MARK: - Grid

  @Test("The grid shows a cut cell as not loaded under every Display As, then its full value")
  func gridMarksCutCell() {
    let prefix = CellValue.data(Data(count: DataViewerState.lazyPrefixBytes))
    let full = CellValue.data(Data(count: 70_000))
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "payload", type: "BLOB"),
      ],
      rows: [[.int(1), prefix], [.int(2), .data(Data([1, 2]))]], rowCount: 2)
    for format in BinaryDisplayFormat.allCases {
      let model = ResultGridModel(
        result: result, sortColumn: nil, ascending: true, binaryFormats: ["payload": format],
        unloadedCells: [0: [1: 70_000]])
      #expect(
        model.displayText(row: 0, column: 1, requestsDecode: true) == "<70000 bytes, not loaded>")
      #expect(
        model.unloadedCells(rows: IndexSet([0, 1]), columns: [0, 1]) == [.init(row: 0, column: 1)])
    }
    var model = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, unloadedCells: [0: [1: 70_000]])
    model.fillLoaded([0: [1: full]])
    #expect(model.unloadedLength(row: 0, column: 1) == nil)
    #expect(model.value(row: 0, column: 1) == full)
    #expect(model.displayText(row: 0, column: 1) == "<70000 bytes>")
  }
}

/// Toasts a test presented, in order
@MainActor
private final class ToastLog {
  var messages: [String] = []
}

/// Holds a read until `open()`
private actor Gate {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
