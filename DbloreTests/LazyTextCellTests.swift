// LazyTextCellTests.swift
// Long text cells of a lazy data-viewer page: a full value is accepted only when its UTF-8 byte
// length is the page's and it starts with the page's prefix, scalar by scalar (never a grapheme
// or canonical-equivalence match); a JSON full value matches its text prefix; a SQLite value
// with an early NUL is cut and loads whole; a cut text column without a usable length throws;
// copies count text byte lengths against the bulk limit; the grid shows a cut text's prefix
// marked cut; a cut JSON opens the Cell Value sidebar, never the JSON viewer; a cut text is
// edited only once its full value loaded (grid, Cell Value, Row Details) and binds that value;
// ORDER BY, key and masked columns are read whole; copies, exports and Duplicate Row write the
// full values or nothing; a PostgreSQL page keeps a cut jsonb column's type and gives its whole
// values back as JSON. SQLite files, fake reads and a fake PostgreSQL session, no server.

import AppKit
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Lazy Text Cell Tests")
struct LazyTextCellTests {

  /// `docs`, with `meta JSON` when `json`
  private static func docsTable(json: Bool) -> DatabaseTable {
    DatabaseTable(
      schema: "main", name: "docs",
      columns: [
        DatabaseColumn(name: "id", type: "INTEGER", isPrimaryKey: true),
        DatabaseColumn(name: "body", type: "TEXT"),
      ] + (json ? [DatabaseColumn(name: "meta", type: "JSON")] : []))
  }

  private static let cell = LazyCell(row: RowChangeSet.RowKey(values: [.int(1)]), column: "body")

  /// A text value with a NUL at byte 10: SQLite `substr` stops there, its BLOB length is 14
  private static let nulText = "abcdefghi\u{0}tall"

  /// `full` read by key against the page's cut value `cut` of `length` bytes
  private static func load(
    _ full: CellValue, cut: CellValue, length: Int
  ) async throws
    -> CellValue
  {
    let expected = try #require(LazyCellExpectation(length: length, cut: cut))
    let source = LazyCellSource(
      relation: #""main"."docs""#, keyColumns: ["id"], dialect: .sqlite
    ) { _, _ in
      QueryResult(
        columns: [ColumnInfo(name: "body", type: "")], rows: [[full]], rowCount: 1,
        executionTime: 0)
    }
    return try await LazyCellLoader.load(cell, source: source, expected: expected)
  }

  /// `full` as text against the cut text `prefix`, `length` bytes in full (its own by default)
  private static func loadText(
    _ full: String, prefix: String, length: Int? = nil
  ) async throws
    -> CellValue
  {
    try await load(.string(full), cut: .string(prefix), length: length ?? full.utf8.count)
  }

  /// A SQLite data viewer on `main.docs`: row 1 20,000 "é" (40,000 bytes), row 2 short, row 3
  /// `nulText`; with `json`, a `meta JSON` column: row 1 a 20,003-byte array, rows 2 and 3
  /// short objects. Its first page is read `SELECT *` (whole values) and returned as `plain`;
  /// the lazy page is read next, its columns cut as `prefixes` (by default `body`, and `meta`
  /// with `json`). The connection has the mask rules `masks`. The file is closed and deleted
  /// afterwards.
  private func withDocs(
    json: Bool = false, masks: [ColumnMaskRule] = [],
    prefixes: [DataViewerState.LazyColumn.Prefix?]? = nil,
    _ body: (
      _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager, _ plain: CellResult
    ) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-lazy-text-\(UUID().uuidString).sqlite")
    var config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    config.maskRules = masks
    let manager = DatabaseConnectionManager()
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    try await manager.connect(config: config)
    var statements = [
      "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)",
      "INSERT INTO docs VALUES (1, replace(hex(zeroblob(20000)), '00', 'é')), (2, 'short'),"
        + " (3, CAST(x'6162636465666768690074616c6c' AS TEXT))",
    ]
    if json {
      statements += [
        "ALTER TABLE docs ADD COLUMN meta JSON",
        "UPDATE docs SET meta = CASE id WHEN 1 THEN '[' || replace(hex(zeroblob(10000)), '00',"
          + " '1,') || '1]' ELSE '{\"a\": ' || id || '}' END",
      ]
    }
    for statement in statements {
      _ = try await manager.executeInternal(statement)
    }
    let facts = try await manager.executeInternal(
      "SELECT typeof(body), length(CAST(body AS BLOB)) FROM docs WHERE id = 3")
    #expect(facts.rows == [[.string("text"), .int(14)]])
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    viewModel.toastPresenter = { _, _ in }
    let suiteName = "LazyTextCellTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = false
    settings.rewindEnabled = false
    viewModel.historySettings = settings
    var state = DataViewerState(schema: "main", name: "docs", orderColumns: ["id"])
    state.databaseType = .sqlite
    viewModel.dataViewer = state
    await viewModel.loadDataViewerPage()
    await viewModel.awaitResultTargets()
    let plain = try #require(viewModel.editorResult)
    // The session keeps the text after the NUL
    if masks.isEmpty { #expect(plain.rows[2][1] == .string(Self.nulText)) }
    viewModel.databaseTables = [Self.docsTable(json: json)]
    await viewModel.refreshDataViewer()
    await viewModel.awaitResultTargets()
    #expect(
      viewModel.dataViewer?.lazyColumns?.map(\.prefix)
        == prefixes ?? [nil, .characters] + (json ? [.characters] : []))
    do {
      try await body(viewModel, manager, plain)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  // MARK: - Expectation

  @Test("A full text value of the page's byte length and prefix is accepted, scalar by scalar")
  func acceptsExactFullText() async throws {
    let multiByte = "Grüße, 世界 👍🏽 done"
    #expect(try await Self.loadText(multiByte, prefix: "Grüße, 世") == .string(multiByte))
    // A prefix ending inside a grapheme (before a combining mark or an emoji modifier)
    let combining = "cafe\u{301} au lait"
    #expect(try await Self.loadText(combining, prefix: "cafe") == .string(combining))
    let modified = "ok 👍🏽"
    #expect(try await Self.loadText(modified, prefix: "ok 👍") == .string(modified))
    // Embedded NUL: the prefix stops before it, the byte length counts it
    #expect(
      try await Self.loadText(Self.nulText, prefix: "abcdefghi", length: 14)
        == .string(Self.nulText))
  }

  @Test("A full text value that is shorter, longer or has another prefix is refused")
  func refusesOtherText() async throws {
    let full = "Grüße, 世界"
    let length = full.utf8.count
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.loadText(full, prefix: "Grü", length: length + 1)
    }
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.loadText(full, prefix: "Grü", length: length - 1)
    }
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.loadText("Gro" + full.dropFirst(3), prefix: "Grü", length: length)
    }
    // The length is bytes, never characters
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.loadText("éé", prefix: "é", length: 2)
    }
    // Canonically equivalent but other scalars: `hasPrefix` would accept it
    let precomposed = "\u{E9}x and more"
    #expect(precomposed.hasPrefix("e\u{301}x"))
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.loadText(precomposed, prefix: "e\u{301}x", length: precomposed.utf8.count)
    }
    // Bytes for a text prefix and text for a bytes prefix
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.load(.data(Data(full.utf8)), cut: .string("Grü"), length: length)
    }
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.load(.string(full), cut: .data(Data("Grü".utf8)), length: length)
    }
  }

  @Test("A JSON full value is compared by its text with the cut text prefix")
  func jsonFullValueMatchesTextPrefix() async throws {
    let json = #"{"name": "Zoë", "tags": [1, 2]}"#
    let length = json.utf8.count
    #expect(
      try await Self.load(.json(json), cut: .string(#"{"name": "Zo"#), length: length)
        == .json(json))
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.load(.json(json), cut: .string(#"{"name": "Al"#), length: length)
    }
    await #expect(throws: LazyCellLoadError.rowChanged) {
      try await Self.load(.json(json), cut: .string(#"{"name": "Zo"#), length: length + 1)
    }
  }

  // MARK: - Page and loads

  @Test("A SQLite page cuts long text and text with an early NUL, and loads both whole")
  func sqlitePageCutsAndLoadsText() async throws {
    try await withDocs { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      #expect(
        lazy.truncation?.lengths == [
          RowChangeSet.RowKey(values: [.int(1)]): ["body": 40_000],
          RowChangeSet.RowKey(values: [.int(3)]): ["body": 14],
        ])
      #expect(
        lazy.rows[0][1]
          == .string(String(repeating: "é", count: DataViewerState.lazyPrefixCharacters)))
      #expect(lazy.rows[1][1] == .string("short"))
      #expect(lazy.rows[2][1] == .string("abcdefghi"))

      let loaded = try #require(await viewModel.fullyLoadedResult(lazy, action: "Copy"))
      #expect(loaded.rows == plain.rows)
      #expect(!viewModel.hasUnloadedCells(in: try #require(viewModel.editorResult)))
    }
  }

  @Test("The Cell Value viewer loads a cut text cell whole")
  func viewerLoadsCutText() async throws {
    try await withDocs { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      viewModel.showGridCellInSidebar(
        row: lazy.rows[2], originalRow: 2, column: 1, result: lazy, cellId: nil)
      let unloaded = try #require(viewModel.unloadedSidebarCell)
      #expect(unloaded.length == 14)
      #expect(await viewModel.loadSidebarCell(unloaded.cell, length: unloaded.length) == nil)
      #expect(viewModel.editorResult?.rows[2][1] == plain.rows[2][1])
    }
  }

  @Test("A cut text column whose length is missing or unusable throws")
  func missingTextLengthThrows() async throws {
    try await withDocs { viewModel, manager, _ in
      let state = try #require(viewModel.dataViewer)
      #expect(state.lengthColumns == ["dblore_byte_length_1"])
      let names = ["id", "body"] + state.lengthColumns
      func strip(_ rows: [[CellValue]]) async throws -> DataViewerState.Truncation? {
        let page = QueryResult(
          columns: names.map { ColumnInfo(name: $0, type: "") }, rows: rows,
          rowCount: rows.count, executionTime: 0)
        return try await viewModel.strippedDataViewerPage(
          page, state: state, epoch: 7, connectionManager: manager
        ).truncation
      }
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip([[.int(1), .string("x"), .null]])
      }
      await #expect(throws: NotebookViewModel.LazyPageError.unexpectedShape) {
        try await strip([[.int(1), .string("x"), .string("many")]])
      }
      // A NULL value and a whole value are not cut
      let truncation = try await strip([
        [.int(1), .null, .null], [.int(2), .string("é"), .int(2)],
      ])
      #expect(truncation?.lengths.isEmpty == true)
    }
  }

  @Test("Copies add the text byte lengths against the bulk limit")
  func bulkLimitCountsTextBytes() async throws {
    try await withDocs { viewModel, _, _ in
      let toasts = ToastLog()
      viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
      let half = LazyCellLoader.bulkLimitBytes / 2 + 1
      for id in [1, 3] {
        viewModel.editorResult?.truncation?.lengths[RowChangeSet.RowKey(values: [.int(id)])]?[
          "body"] = half
      }
      let lazy = try #require(viewModel.editorResult)
      #expect(await viewModel.fullyLoadedResult(lazy, action: "Copy") == nil)
      #expect(toasts.messages.contains { $0.hasPrefix("Copy refused") && $0.contains("limit") })
      #expect(viewModel.editorResult?.rows[0][1] == lazy.rows[0][1])
    }
  }

  // MARK: - Views and edits

  @Test("The grid shows a cut text's prefix on one line with a trailing marker")
  func gridMarksCutText() {
    let long = String(repeating: "é", count: DataViewerState.lazyPrefixCharacters)
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "body", type: "TEXT"),
        ColumnInfo(name: "payload", type: "BLOB"),
      ],
      rows: [
        [.int(1), .string("abc\ndefghi"), .data(Data(count: 8))], [.int(2), .string(long), .null],
      ],
      rowCount: 2)
    var model = ResultGridModel(
      result: result, sortColumn: nil, ascending: true,
      unloadedCells: [0: [1: 14, 2: 70_000], 1: [1: 40_000]])
    // A prefix shorter than the grid's text (a NUL stopped it) is marked too
    #expect(model.displayText(row: 0, column: 1) == "abc defghi…")
    #expect(model.displayText(row: 1, column: 1) == String(repeating: "é", count: 1000) + "…")
    #expect(model.displayText(row: 0, column: 2) == "<70000 bytes, not loaded>")
    model.fillLoaded([0: [1: .string("abc defghi and more")]])
    #expect(model.displayText(row: 0, column: 1) == "abc defghi and more")
  }

  @Test("An inline edit of a cut text cell opens the Cell Value sidebar, never the inline field")
  func gridEditOfCutTextOpensSidebar() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "body", type: "TEXT")],
      rows: [[.int(1), .string("abcdefghi")]], rowCount: 1)
    for unloaded in [[0: [1: 14]], [:]] {
      let coordinator = ResultGridCoordinator()
      let tableView = NSTableView()
      coordinator.isEditable = true
      _ = coordinator.update(
        tableView, result: result, sortColumn: nil, ascending: true, unloadedCells: unloaded)
      var shown: Int?
      coordinator.onShowCellDetails = { _, _, column, _ in shown = column }
      coordinator.beginEditing(tableView, row: 0, column: 1)
      #expect(coordinator.isEditing == unloaded.isEmpty)
      #expect(shown == (unloaded.isEmpty ? nil : 1))
    }
  }

  @Test("A cut JSON cell opens the Cell Value sidebar and loads whole; a whole one the JSON viewer")
  func cutJSONOpensCellValue() async throws {
    try await withDocs(json: true) { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      guard case .json(let full) = plain.rows[0][2] else {
        Issue.record("the plain read did not decode JSON")
        return
      }
      #expect(lazy.truncation?.lengths[RowChangeSet.RowKey(values: [.int(1)])]?["meta"] == 20_003)
      #expect(lazy.rows[0][2] == .string(String(full.prefix(DataViewerState.lazyPrefixCharacters))))
      #expect(lazy.rows[1][2] == plain.rows[1][2])
      viewModel.showGridCellInSidebar(
        row: lazy.rows[1], originalRow: 1, column: 2, result: lazy, cellId: nil)
      guard case .jsonViewer = viewModel.rightSidebarContent else {
        Issue.record("a whole JSON value did not open the JSON viewer")
        return
      }
      viewModel.showGridCellInSidebar(
        row: lazy.rows[0], originalRow: 0, column: 2, result: lazy, cellId: nil)
      guard case .cellInfo(_, _, let cut, _, _, _, _) = viewModel.rightSidebarContent else {
        Issue.record("a cut JSON value did not open the Cell Value sidebar")
        return
      }
      #expect(cut == lazy.rows[0][2])
      let unloaded = try #require(viewModel.unloadedSidebarCell)
      #expect(await viewModel.loadSidebarCell(unloaded.cell, length: unloaded.length) == nil)
      // Edit Value starts from the full value
      #expect(viewModel.unloadedSidebarCell == nil)
      guard case .cellInfo(_, _, let shown, _, _, _, _) = viewModel.rightSidebarContent else {
        Issue.record("the Cell Value sidebar closed")
        return
      }
      #expect(shown == plain.rows[0][2])
    }
  }

  @Test("Row Details loads a cut text whole before it can be edited and keeps drafts")
  func rowDetailLoadsCutText() async throws {
    try await withDocs(json: true) { viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      viewModel.showRowDetail(row: lazy.rows[2], originalRow: 2, result: lazy, cellId: nil)
      let cut = try #require(viewModel.rowDetail?.fields.first { $0.name == "body" })
      #expect(cut.isReadOnly)
      #expect(cut.unloadedLength == 14)
      let meta = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "meta" })
      viewModel.rowDetail?.fields[meta].text = #"{"a": 30}"#
      #expect(await viewModel.loadRowDetailCells() == nil)
      let fields = try #require(viewModel.rowDetail?.fields)
      let body = try #require(fields.first { $0.name == "body" })
      #expect(!body.isReadOnly)
      #expect(body.unloadedLength == nil)
      #expect(body.original == plain.rows[2][1])
      #expect(body.text == Self.nulText)
      #expect(fields[meta].text == #"{"a": 30}"#)
      #expect(fields[meta].isDirty)
      #expect(viewModel.editorResult?.rows[2][1] == plain.rows[2][1])
    }
  }

  @Test("A cut text whose full value cannot be loaded is never edited, and the error shows")
  func failedLoadStartsNoEdit() async throws {
    try await withDocs { viewModel, _, _ in
      // The page says 15 bytes, the row has 14: the read is refused
      viewModel.editorResult?.truncation?.lengths[RowChangeSet.RowKey(values: [.int(3)])]?[
        "body"] = 15
      let lazy = try #require(viewModel.editorResult)
      let refused = LazyCellLoadError.rowChanged.localizedDescription
      viewModel.showGridCellInSidebar(
        row: lazy.rows[2], originalRow: 2, column: 1, result: lazy, cellId: nil)
      let unloaded = try #require(viewModel.unloadedSidebarCell)
      #expect(await viewModel.loadSidebarCell(unloaded.cell, length: unloaded.length) == refused)
      // Edit Value stays hidden while the cell is cut
      #expect(viewModel.unloadedSidebarCell != nil)

      viewModel.showRowDetail(row: lazy.rows[2], originalRow: 2, result: lazy, cellId: nil)
      #expect(await viewModel.loadRowDetailCells() == refused)
      let body = try #require(viewModel.rowDetail?.fields.first { $0.name == "body" })
      #expect(body.isReadOnly)
      #expect(body.unloadedLength == 15)
      #expect(viewModel.editorResult?.rows[2][1] == .string("abcdefghi"))
    }
  }

  // MARK: - Select list, masks

  @Test("An ORDER BY or primary key text column is never cut; SQLite cuts by TEXT affinity")
  func orderAndKeyTextReadWhole() {
    let rules = DataViewerState.TextPrefixRules(masks: ColumnMaskRuleSet([]))
    let cases:
      [(
        DatabaseType, String, [String], [DataViewerState.LazyColumn.Prefix?], cutBody: String,
        cutMeta: String
      )] = [
        (
          .postgresql, "public", ["TEXT", "TEXT", "JSONB", "CHARACTER VARYING(50)"],
          [nil, nil, .characters, nil], #"pg_catalog.left("body""#,
          #"pg_catalog.left("meta"::pg_catalog.text, 16384) AS "meta""#
        ),
        (
          .mysql, "shop", ["VARCHAR(20000)", "LONGTEXT", "JSON", "VARCHAR(50)"],
          [nil, nil, .characters, nil], "LEFT(`body`",
          "LEFT(CAST(`meta` AS CHAR), 16384) AS `meta`"
        ),
        // By design: SQLite ignores a declared length, so VARCHAR(50) has TEXT affinity and
        // its long text values are cut like any other text
        (
          .sqlite, "main", ["TEXT", "TEXT", "JSON", "VARCHAR(50)"],
          [nil, nil, .characters, .characters], #"substr("main"."docs"."body""#,
          #"substr("main"."docs"."meta", 1, 16384)"#
        ),
      ]
    for (engine, schema, types, expected, cutBody, cutMeta) in cases {
      var viewer = DataViewerState(
        schema: schema, name: "docs", orderColumns: ["body"], databaseType: engine)
      viewer.lazyColumns = DataViewerState.lazyColumns(
        zip(["code", "body", "meta", "note"], types).map { ($0, $1, $0 == "code") },
        databaseType: engine, orderColumns: ["body"], text: rules)
      #expect(viewer.lazyColumns?.map(\.prefix) == expected, "\(engine)")
      #expect(!viewer.pageSQL.contains(cutBody), "\(engine)")
      #expect(viewer.pageSQL.contains(cutMeta), "\(engine)")
    }
  }

  @Test("A long text column with a lastFour mask rule is read whole and masked as before")
  func maskedTextReadWhole() async throws {
    let mask = try ColumnMaskRule(pattern: "body", style: .lastFour)
    try await withDocs(json: true, masks: [mask], prefixes: [nil, nil, .characters]) {
      viewModel, _, plain in
      let lazy = try #require(viewModel.editorResult)
      #expect(lazy.sourceQuery?.contains("dblore_byte_length_1") == true)
      #expect(lazy.columns[1].masked)
      // The whole value's mask, as a `SELECT *` page shows it, never a prefix's
      #expect(lazy.rows.map { $0[1] } == plain.rows.map { $0[1] })
      #expect(lazy.rows[0][1] != .string(String(repeating: "é", count: 40_000)))
      #expect(lazy.truncation?.lengths.values.allSatisfy { $0["body"] == nil } == true)
      #expect(lazy.truncation?.lengths[RowChangeSet.RowKey(values: [.int(1)])]?["meta"] == 20_003)
    }
  }

  // MARK: - Copies and writes

  @Test("Copy, export and Duplicate Row of a page with cut text write the full values")
  func copyExportDuplicateWriteFullText() async throws {
    try await withDocs { viewModel, manager, plain in
      /// The lazy page read again, its text cut
      @MainActor func reread() async throws -> CellResult {
        await viewModel.refreshDataViewer()
        await viewModel.awaitResultTargets()
        let lazy = try #require(viewModel.editorResult)
        #expect(viewModel.unloadedCells(in: lazy) == [0: [1: 40_000], 2: [1: 14]])
        return lazy
      }
      var lazy = try await reread()
      let copied = try #require(
        await QueryCopyBar.loadedResult(lazy, viewModel: viewModel, action: "Copy"))
      #expect(copied.rows == plain.rows)

      lazy = try await reread()
      let request = try #require(
        await QueryCopyBar.exportRequest(format: .json, result: lazy, viewModel: viewModel))
      #expect(request.result.rows == plain.rows)

      lazy = try await reread()
      let target = try #require(lazy.editTarget)
      #expect(await viewModel.stageDuplicate(rows: [0, 2]) == nil)
      let set = try #require(viewModel.dataViewer?.changeSet)
      #expect(set.inserts.map { $0.values["body"] } == [plain.rows[0][1], plain.rows[2][1]])
      let values = try RowChangeSQLBuilder.statements(
        for: set, target: target, columns: lazy.columns, dialect: .sqlite
      ).flatMap(\.values)
      for row in [0, 2] {
        #expect(
          values.contains(CellUpdateStatement.inputText(plain.rows[row][1], dialect: .sqlite)))
        #expect(
          !values.contains(CellUpdateStatement.inputText(lazy.rows[row][1], dialect: .sqlite)))
      }
      await viewModel.commitStaged()
      await viewModel.awaitResultTargets()
      #expect(viewModel.dataViewer?.changeSet == nil)
      let stored = try await manager.executeInternal(
        "SELECT length(CAST(body AS BLOB)), body FROM docs WHERE id > 3 ORDER BY id")
      #expect(stored.rows == [[.int(40_000), plain.rows[0][1]], [.int(14), plain.rows[2][1]]])
    }
  }

  @Test("Copy, export and Duplicate Row write nothing when a cut text cannot be loaded")
  func failedTextLoadWritesNothing() async throws {
    try await withDocs { viewModel, _, _ in
      let toasts = ToastLog()
      viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
      // The page says 15 bytes, the row has 14: the read is refused
      viewModel.editorResult?.truncation?.lengths[RowChangeSet.RowKey(values: [.int(3)])]?[
        "body"] = 15
      let lazy = try #require(viewModel.editorResult)
      #expect(await QueryCopyBar.loadedResult(lazy, viewModel: viewModel, action: "Copy") == nil)
      #expect(
        await QueryCopyBar.exportRequest(format: .csv, result: lazy, viewModel: viewModel) == nil)
      #expect(await viewModel.stageDuplicate(rows: [2]) == nil)
      #expect(viewModel.dataViewer?.changeSet == nil)
      for action in ["Copy", "Export", "Duplicate Row"] {
        #expect(toasts.messages.contains { $0.hasPrefix("\(action) refused") }, "\(action)")
      }
      #expect(viewModel.editorResult?.rows[2][1] == .string("abcdefghi"))
      #expect(viewModel.unloadedCells(in: try #require(viewModel.editorResult))[2] == [1: 15])
    }
  }

  @Test("An edit of a cut text binds the loaded full value, never the prefix")
  func editBindsLoadedFullText() async throws {
    try await withDocs { viewModel, _, plain in
      viewModel.notebook.connectionConfig?.applyCommitStyle(.confirm)
      guard case .string(let full) = plain.rows[0][1] else {
        Issue.record("the plain read did not decode text")
        return
      }
      let lazy = try #require(viewModel.editorResult)
      viewModel.showRowDetail(row: lazy.rows[0], originalRow: 0, result: lazy, cellId: nil)
      #expect(await viewModel.loadRowDetailCells() == nil)
      let body = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "body" })
      #expect(viewModel.rowDetail?.fields[body].text == full)
      viewModel.rowDetail?.fields[body].text = full + "!"
      viewModel.applyRowDetail()
      let edit = try #require(viewModel.pendingInlineEdit)
      #expect(edit.columnNames == ["body"])
      #expect(edit.statement.values == [full + "!", "1"])
      guard case .string(let prefix) = lazy.rows[0][1] else {
        Issue.record("the lazy page did not cut the text")
        return
      }
      #expect(!edit.statement.values.contains { $0?.hasPrefix(prefix + "!") == true })
    }
  }

  // MARK: - PostgreSQL jsonb (fake session)

  /// `public.docs(id integer PK, body text, meta jsonb)` on a fake PostgreSQL connection whose
  /// full-value read of `meta` answers `full`; its lazy page cuts `body` and `meta`
  private func withPostgresDocs(
    full: String,
    _ body: (
      _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager,
      _ state: DataViewerState, _ epoch: UInt64
    ) async throws -> Void
  ) async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities,
      queryAnswer: { sql, _ in
        guard sql.hasPrefix(#"SELECT "meta" FROM "public"."docs""#) else { return nil }
        return FakeQueryAnswer(
          columns: [ColumnInfo(name: "meta", type: "jsonb")], rows: [[.json(full)]])
      })
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.applyCommitStyle(.confirm)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    viewModel.toastPresenter = { _, _ in }
    let suiteName = "LazyTextCellTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = false
    settings.rewindEnabled = true
    viewModel.historySettings = settings
    var state = DataViewerState(
      schema: "public", name: "docs", orderColumns: ["id"], databaseType: .postgresql)
    state.lazyColumns = DataViewerState.lazyColumns(
      [("id", "integer", true), ("body", "text", false), ("meta", "jsonb", false)],
      databaseType: .postgresql, orderColumns: ["id"],
      text: DataViewerState.TextPrefixRules(masks: ColumnMaskRuleSet([])))
    #expect(state.lazyColumns?.map(\.prefix) == [nil, .characters, .characters])
    #expect(state.lengthColumns == ["dblore_byte_length_1", "dblore_byte_length_2"])
    viewModel.dataViewer = state
    let epoch = await manager.connectionEpoch
    do {
      try await body(viewModel, manager, state, epoch)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  @Test("A PostgreSQL page keeps a cut jsonb column's type and exports a whole value as JSON")
  func postgresJSONBKeepsTypeAndWholeJSON() async throws {
    let full = "[" + Array(repeating: "1", count: 10_001).joined(separator: ",") + "]"
    try await withPostgresDocs(full: full) { viewModel, manager, state, epoch in
      let prefix = String(full.prefix(DataViewerState.lazyPrefixCharacters))
      // As the server reads it: the prefix expression's type is text
      let page = QueryResult(
        columns: [
          ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "body", type: "text"),
          ColumnInfo(name: "meta", type: "text"),
          ColumnInfo(name: "dblore_byte_length_1", type: "int4"),
          ColumnInfo(name: "dblore_byte_length_2", type: "int4"),
        ],
        rows: [
          [.int(1), .string("a"), .string(prefix), .int(1), .int(full.utf8.count)],
          [.int(2), .string("b"), .string(#"{"a": 1}"#), .int(1), .int(8)],
        ], rowCount: 2, executionTime: 0)
      let stripped = try await viewModel.strippedDataViewerPage(
        page, state: state, epoch: epoch, connectionManager: manager)
      #expect(stripped.result.columns.map(\.type) == ["int4", "text", "jsonb"])
      #expect(stripped.result.rows[0][2] == .string(prefix))
      #expect(stripped.result.rows[1][2] == .json(#"{"a": 1}"#))
      let truncation = try #require(stripped.truncation)
      #expect(truncation.lengths == [RowChangeSet.RowKey(values: [.int(1)]): ["meta": 20_003]])

      // A page export as JSON: the whole value is an object, never a string
      let json = DataExporter.toJSON(
        result: CellResult(
          columns: stripped.result.columns, rows: [stripped.result.rows[1]], rowCount: 1),
        pretty: false)
      #expect(json == #"[{"id":2,"body":"b","meta":{"a":1}}]"#)

      // An edit of the cut cell loads it whole and keeps the jsonb type
      var result = CellResult(
        columns: stripped.result.columns, rows: stripped.result.rows, rowCount: 2,
        tableName: "docs", primaryKeyColumns: ["id"],
        editTarget: EditTarget(
          qualifiedName: "public.docs", tableID: .postgresql(oid: 16_600),
          primaryKeyColumns: ["id"], connectionEpoch: epoch, schema: "public", name: "docs"))
      result.truncation = truncation
      viewModel.editorResult = result
      viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
      let cut = try #require(viewModel.rowDetail?.fields.first { $0.name == "meta" })
      #expect(cut.isReadOnly)
      #expect(cut.field.type == "jsonb")
      #expect(await viewModel.loadRowDetailCells() == nil)
      let meta = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "meta" })
      #expect(viewModel.rowDetail?.fields[meta].original == .json(full))
      #expect(viewModel.rowDetail?.fields[meta].field.type == "jsonb")
      viewModel.rowDetail?.fields[meta].text = #"{"b": 2}"#
      viewModel.applyRowDetail()
      let edit = try #require(viewModel.pendingInlineEdit)
      #expect(edit.statement.values == [#"{"b": 2}"#, "1"])
      #expect(
        edit.rewindPlan?.columns.first { $0.name == "meta" }
          == RewindColumn(name: "meta", typeName: "jsonb"))
    }
  }
}

/// Toasts a test presented, in order
@MainActor
private final class ToastLog {
  var messages: [String] = []
}
