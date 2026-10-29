// LargeCatalogPerformanceTests.swift
// Baseline at LargeCatalogFixture's 50,000 tables: schema load, one sidebar filter keystroke,
// command palette open, autocomplete, AI table selection, the ER layout at 300 tables and the
// sheets that list every table (Find a Value, Copy Objects, Export SQL Dump, Compare Schemas),
// each recorded in a PERF line with the longest main-actor gap a ticker saw meanwhile. Every
// stage but the empty sidebar filter and S-SQL below has a budget.
// S-SQL compares today's per-table catalog read with one bulk statement per catalog part.
// Opt-in (requiresLargeCatalog). Results land in the runner's temp perf-results.txt.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("Large catalog performance", .requiresLargeCatalog, .serialized)
@MainActor
struct LargeCatalogPerformanceTests {
  private static var tables: Int { LargeCatalogFixture.tableCount }

  /// Budgets: 1.25x this Mac's post-fix medians (Debug, 2026-10-29, three LARGE_CATALOG runs).
  /// First listing: 13,709.1 / 14,430.5 / 13,744.3 ms, median 13,744.3 (main gap 5.8-6.8 ms),
  /// re-measured with the diagram cap and the sheet fixes in. Replaces 17,824 (phase 12's median
  /// 14,258.8), set from one session's runs and seen up to 16,003 ms since.
  private static let firstListingBudgetMs = 17_180.0
  /// Filter keystroke: 844.1 / 846.9 / 837.0 ms, median 844.1 (main gap 2.1-3.9 ms).
  private static let filterKeystrokeBudgetMs = 1_055.0
  /// Palette open: 14.0 / 16.2 / 15.6 ms, median 15.6 (main gap 2.1 ms). Stages under 20 ms
  /// get a 25 ms floor: 1.25x leaves them a few ms, within scheduler noise.
  private static let paletteOpenBudgetMs = 25.0
  /// Palette query "t04999": 602.1 / 615.1 / 603.1 ms, median 603.1 (main gap 2.1-3.1 ms).
  private static let paletteQueryBudgetMs = 754.0
  /// Autocomplete after FROM: 7.4 / 8.2 / 7.3 ms, median 7.4 (on main; 25 ms floor).
  private static let autocompleteAfterFromBudgetMs = 25.0
  /// Autocomplete with no context: 5.1 / 5.6 / 5.1 ms, median 5.1 (on main; 25 ms floor).
  private static let autocompleteNoContextBudgetMs = 25.0
  /// AI relevant tables: 499.7 / 494.2 / 488.4 ms, median 494.2 (main gap 2.1-2.5 ms).
  private static let aiRelevantTablesBudgetMs = 618.0
  /// ER layout at 300 tables: 5,705.4 / 5,788.8 / 5,743.5 ms, median 5,743.5 (main gap
  /// 2.1-2.6 ms).
  private static let erLayout300BudgetMs = 7_179.0
  /// Find a Value open: 0.04 / 0.04 / 0.03 ms, median 0.04 (main gap 2.0-2.1 ms; 25 ms floor).
  private static let findAValueOpenBudgetMs = 25.0
  /// Find a Value tables ready: 68.7 / 69.4 / 69.9 ms, median 69.4 (main gap 2.1-3.7 ms).
  private static let findAValueReadyBudgetMs = 87.0
  /// Copy Objects open: 34.2 / 30.4 / 29.2 ms, median 30.4 (main gap 30.8-35.6 ms; 60 ms floor:
  /// the hosted sheet layout includes ~25 ms of one-time SwiftUI setup and ran 39.5 ms on a busy
  /// Mac; 60 still fails the pre-fix 88 ms).
  private static let copyObjectsOpenBudgetMs = 60.0
  /// Copy Objects tables ready: 28.8 / 29.0 / 28.9 ms, median 28.9 (main gap 20.8-23.7 ms; 60 ms
  /// floor, as for open: 33.6 ms on a busy Mac).
  private static let copyObjectsReadyBudgetMs = 60.0
  /// Copy Objects filter keystroke: 36.9 / 36.4 / 36.6 ms, median 36.6 (main gap 2.1 ms).
  private static let copyObjectsFilterKeystrokeBudgetMs = 46.0
  /// Export SQL Dump open: 37.6 / 35.9 / 34.5 ms, median 35.9 (main gap 36.0-38.7 ms; 60 ms
  /// floor for the hosted sheet layout, as for Copy Objects; 60 still fails the pre-fix 206 ms).
  private static let dumpSheetOpenBudgetMs = 60.0
  /// Export SQL Dump parent redraw: 12.5 / 11.7 / 11.7 ms, median 11.7 (main gap 11.7-12.6 ms;
  /// 25 ms floor).
  private static let dumpSheetParentRedrawBudgetMs = 25.0
  /// Compare Schemas open: 7.5 / 7.7 / 7.2 ms, median 7.5 (main gap 7.4-7.8 ms; 25 ms floor).
  private static let schemaCompareOpenBudgetMs = 25.0
  /// Compare Schemas refusal: 418.9 / 425.6 / 419.2 ms, median 419.2 (main gap 2.1 ms).
  private static let schemaCompareRefusalBudgetMs = 524.0
  /// The longest main-actor gap any budgeted stage may cause
  private static let maxMainGapMs = 100.0

  /// A measured stage: its result, duration and the ticker's longest main-actor gap
  private struct Measured<T> {
    let value: T
    let ms: Double
    let maxMainGapMs: Double
  }

  /// The connected workspace the stages after the schema load share (connected once per run)
  private static var shared: WorkspaceManager?

  private static func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  /// Main-actor ticker: a gap between two 1 ms sleeps is time the main actor was busy
  private static func startTicker() -> Task<Duration, Never> {
    Task { @MainActor in
      var maxGap = Duration.zero
      while !Task.isCancelled {
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(1))
        maxGap = max(maxGap, ContinuousClock.now - start)
      }
      return maxGap
    }
  }

  /// Times `body` and records it with the ticker's longest main-actor gap meanwhile
  @discardableResult
  private func measure<T>(
    _ name: String, _ body: () async throws -> T
  ) async throws -> Measured<T> {
    let ticker = Self.startTicker()
    await Task.yield()
    let start = ContinuousClock.now
    let value: T
    do {
      value = try await body()
    } catch {
      ticker.cancel()
      throw error
    }
    let elapsed = ContinuousClock.now - start
    // A synchronous body held the main actor: let the ticker wake and see that gap
    try? await Task.sleep(for: .milliseconds(5))
    ticker.cancel()
    let measured = Measured(
      value: value, ms: Self.ms(elapsed), maxMainGapMs: Self.ms(await ticker.value))
    PerfReport.record("largeCatalog.\(name)", ms: measured.ms)
    PerfReport.record("largeCatalog.\(name).maxMainGap", ms: measured.maxMainGapMs)
    return measured
  }

  private static func config(_ url: URL) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: url.path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent
    )
  }

  private static func newWorkspace() -> WorkspaceManager {
    let workspace = WorkspaceManager(workspace: Workspace())
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    _ = workspace.newNotebook()
    return workspace
  }

  /// The shared workspace, connected with its schema loaded (not measured here)
  private func loadedWorkspace() async throws -> WorkspaceManager {
    if let shared = Self.shared { return shared }
    let workspace = Self.newWorkspace()
    try await workspace.connect(
      config: Self.config(try LargeCatalogFixture.url(tables: Self.tables)),
      defaultCommitStyle: .immediate)
    await workspace.awaitSchemaLoad()
    Self.shared = workspace
    return workspace
  }

  /// The sidebar's first listing: connect, schema load and its sidebar index, published with
  /// the arrays
  @Test("First listing (schema load to sidebar index)")
  func schemaLoad() async throws {
    let url = try LargeCatalogFixture.url(tables: Self.tables)
    let workspace = Self.newWorkspace()
    let load = try await measure("schemaLoad") {
      try await workspace.connect(config: Self.config(url), defaultCommitStyle: .immediate)
      await workspace.awaitSchemaLoad()
    }
    #expect(workspace.databaseTables.count == Self.tables)
    #expect(workspace.databaseViews.count == (Self.tables + 49) / 50)
    #expect(workspace.databaseForeignKeys.count == Self.tables / 10)
    #expect(
      Array(workspace.sidebarEntityIndex.counts.prefix(2)) == [
        Self.tables, (Self.tables + 49) / 50,
      ])
    #expect(load.ms <= Self.firstListingBudgetMs)
    #expect(load.maxMainGapMs <= Self.maxMainGapMs)
    if Self.shared == nil {
      Self.shared = workspace
    } else {
      await workspace.disconnect(resolution: .rollback)
    }
  }

  /// The sidebar's Public tab filter: the keyword split and the off-main
  /// SidebarEntityIndex.filterInBackground over every table and view, as the view awaits it
  @Test("Sidebar filter keystroke")
  func sidebarFilterKeystroke() async throws {
    let workspace = try await loadedWorkspace()
    let keystroke = try await measure("sidebarFilterKeystroke") {
      let result = await workspace.sidebarEntityIndex.filterInBackground(
        keywords: SidebarEntityFilter.keywords(in: "t1234"), hidden: [],
        temporarySchemas: ["temp"])
      return result.listed.tables.count + result.listed.views.count
    }
    #expect(keystroke.value > 0)
    #expect(keystroke.ms <= Self.filterKeystrokeBudgetMs)
    #expect(keystroke.maxMainGapMs <= Self.maxMainGapMs)
  }

  /// No filter, as the view draws it on the main actor until the background result lands
  @Test("Sidebar empty filter")
  func sidebarEmptyFilter() async throws {
    let workspace = try await loadedWorkspace()
    let listed = try await measure("sidebarEmptyFilter") {
      workspace.sidebarEntityIndex.filter(keywords: [], hidden: [], temporarySchemas: ["temp"])
        .listed.tables.count
    }.value
    #expect(listed == Self.tables)
  }

  /// Open on the cached catalog the schema load built, until the first results of the empty
  /// query (ranking runs detached)
  @Test("Command palette open")
  func paletteOpen() async throws {
    let workspace = try await loadedWorkspace()
    workspace.commandPalette = nil
    #expect(workspace.paletteCatalog != nil)
    let open = try await measure("paletteOpen") {
      workspace.openCommandPalette()
      let palette = try #require(workspace.commandPalette)
      while !palette.isRankFresh { try await Task.sleep(for: .milliseconds(1)) }
      return palette
    }
    #expect(!open.value.ranked.isEmpty)
    #expect(open.ms <= Self.paletteOpenBudgetMs)
    #expect(open.maxMainGapMs <= Self.maxMainGapMs)
    workspace.commandPalette = nil
  }

  /// A typed query through CommandPaletteModel, ranked on the catalog's stored lowercase keys
  @Test("Command palette query")
  func paletteQuery() async throws {
    let workspace = try await loadedWorkspace()
    workspace.commandPalette = nil
    #expect(workspace.paletteCatalog != nil)
    workspace.openCommandPalette()
    let palette = try #require(workspace.commandPalette)
    while !palette.isRankFresh { try await Task.sleep(for: .milliseconds(1)) }
    let query = try await measure("paletteQuery") {
      palette.query = "t04999"
      while !palette.isRankFresh { try await Task.sleep(for: .milliseconds(1)) }
    }
    #expect(query.ms <= Self.paletteQueryBudgetMs)
    #expect(query.maxMainGapMs <= Self.maxMainGapMs)
    if case .table(_, let name) = palette.ranked.first {
      #expect(name == "t04999")
    } else {
      Issue.record("No table ranked first: \(String(describing: palette.ranked.first))")
    }
    workspace.commandPalette = nil
  }

  @Test("Autocomplete after FROM")
  func autocompleteAfterFrom() async throws {
    let workspace = try await loadedWorkspace()
    let text = "SELECT * FROM t0"
    let suggestions = try await measure("autocompleteAfterFrom") {
      workspace.autocompleteProvider.getSuggestions(
        for: text, at: (text as NSString).length, dialect: .sqlite)
    }
    #expect(!suggestions.value.isEmpty)
    #expect(suggestions.ms <= Self.autocompleteAfterFromBudgetMs)
    #expect(suggestions.maxMainGapMs <= Self.maxMainGapMs)
  }

  @Test("Autocomplete with no context")
  func autocompleteNoContext() async throws {
    let workspace = try await loadedWorkspace()
    let text = "SELECT na"
    let suggestions = try await measure("autocompleteNoContext") {
      workspace.autocompleteProvider.getSuggestions(
        for: text, at: (text as NSString).length, dialect: .sqlite)
    }
    #expect(!suggestions.value.isEmpty)
    #expect(suggestions.ms <= Self.autocompleteNoContextBudgetMs)
    #expect(suggestions.maxMainGapMs <= Self.maxMainGapMs)
  }

  /// A question that names tables, so the foreign-key pass runs (no match takes the first 20)
  @Test("AI relevant tables")
  func aiRelevantTables() async throws {
    let workspace = try await loadedWorkspace()
    let request = try await measure("aiRelevantTables") {
      let snapshot = workspace.aiAssistant.schemaSource()
      return await AIAssistantViewModel.buildRequest(
        model: "large-catalog", question: "Total amount of t00019 rows per t00018 row",
        explicit: [], snapshot: snapshot, history: [], runsQueries: false, compactPrompt: false)
    }
    #expect(request.value.system.contains("t00019"))
    #expect(request.ms <= Self.aiRelevantTablesBudgetMs)
    #expect(request.maxMainGapMs <= Self.maxMainGapMs)
  }

  /// The diagram of the first 300 tables picked, as the picker's Show Diagram lays it out (off
  /// the main actor)
  @Test("ER layout at 300 tables")
  func erLayout300() async throws {
    let workspace = try await loadedWorkspace()
    let names = Set(
      workspace.databaseTables.prefix(SchemaLayoutEngine.maxTables).map(\.qualifiedName))
    workspace.schemaDiagramTables = names
    defer { workspace.schemaDiagramTables = nil }
    let layout = try await measure("erLayout300") { await workspace.loadSchemaGraph() }
    #expect(workspace.schemaGraph?.nodes.count == names.count)
    #expect(layout.ms <= Self.erLayout300BudgetMs)
    #expect(layout.maxMainGapMs <= Self.maxMainGapMs)
  }

  // MARK: - Sheets that list every table

  /// `view` in an offscreen window of the sheet's size, laid out once: the SwiftUI side of
  /// opening it (its body and the lazy list's first rows)
  private static func host<Content: View>(
    _ view: Content, width: CGFloat, height: CGFloat
  ) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return host
  }

  /// Find a Value in Every Table: the Cmd+K action (the sheet's model), then until its table
  /// count is read (off the main actor)
  @Test("Find a Value open")
  func findAValueOpen() async throws {
    let workspace = try await loadedWorkspace()
    workspace.dropCrossTableSearch()
    let open = try await measure("findAValueOpen") {
      workspace.openCrossTableSearch()
      return try #require(workspace.crossTableSearch)
    }
    let model = open.value
    let ready = try await measure("findAValueReady") {
      while model.isLoadingTargets { try await Task.sleep(for: .milliseconds(1)) }
      return model.totalTableCount
    }
    #expect(ready.value == Self.tables)
    #expect(open.ms <= Self.findAValueOpenBudgetMs)
    #expect(open.maxMainGapMs <= Self.maxMainGapMs)
    #expect(ready.ms <= Self.findAValueReadyBudgetMs)
    #expect(ready.maxMainGapMs <= Self.maxMainGapMs)
    workspace.dropCrossTableSearch()
  }

  /// File > Copy Objects: the model and the sheet's first layout, then until its table list is
  /// read (off the main actor) and laid out
  @Test("Copy Objects open")
  func copyObjectsOpen() async throws {
    let workspace = try await loadedWorkspace()
    workspace.closeCopyObjects()
    let open = try await measure("copyObjectsOpen") {
      workspace.openCopyObjects(ticking: [])
      let model = try #require(workspace.copyObjects)
      let host = Self.host(
        CopyObjectsSheet(model: model, isShown: { true }, onClose: {}), width: 920, height: 680)
      return (model, host)
    }
    let (model, host) = open.value
    let ready = try await measure("copyObjectsReady") {
      while model.isLoadingTables { try await Task.sleep(for: .milliseconds(1)) }
      host.layoutSubtreeIfNeeded()
      return model.tables.count
    }
    #expect(ready.value == Self.tables)
    #expect(open.ms <= Self.copyObjectsOpenBudgetMs)
    #expect(open.maxMainGapMs <= Self.maxMainGapMs)
    #expect(ready.ms <= Self.copyObjectsReadyBudgetMs)
    #expect(ready.maxMainGapMs <= Self.maxMainGapMs)
    workspace.closeCopyObjects()
  }

  /// One keystroke in the Copy Objects table filter, as the sheet filters its list (off the
  /// main actor)
  @Test("Copy Objects filter keystroke")
  func copyObjectsFilterKeystroke() async throws {
    let workspace = try await loadedWorkspace()
    workspace.closeCopyObjects()
    workspace.openCopyObjects(ticking: [])
    let model = try #require(workspace.copyObjects)
    while model.isLoadingTables { try await Task.sleep(for: .milliseconds(1)) }
    let keystroke = try await measure("copyObjectsFilterKeystroke") {
      await CopyObjectsModel.filtered(model.tables, text: "t4999", showsSchema: model.showsSchema)
    }
    #expect(keystroke.value?.count == 10)
    #expect(keystroke.ms <= Self.copyObjectsFilterKeystrokeBudgetMs)
    #expect(keystroke.maxMainGapMs <= Self.maxMainGapMs)
    workspace.closeCopyObjects()
  }

  /// File > Export SQL Dump: the sheet's first layout, then one more as its parent redraws
  @Test("Export SQL Dump open")
  func dumpSheetOpen() async throws {
    let workspace = try await loadedWorkspace()
    let viewModel = try #require(workspace.activeViewModel)
    func sheet() -> SQLDumpSheet {
      SQLDumpSheet(
        kind: .sqlDump, viewModel: viewModel, tables: workspace.databaseTables,
        isPresented: .constant(true), isBusy: .constant(false))
    }
    let open = try await measure("dumpSheetOpen") {
      Self.host(sheet(), width: SQLDumpSheet.panelWidth, height: 800)
    }
    let host = open.value
    let redraw = try await measure("dumpSheetParentRedraw") {
      host.rootView = sheet()
      host.layoutSubtreeIfNeeded()
    }
    #expect(open.ms <= Self.dumpSheetOpenBudgetMs)
    #expect(open.maxMainGapMs <= Self.maxMainGapMs)
    #expect(redraw.ms <= Self.dumpSheetParentRedrawBudgetMs)
    #expect(redraw.maxMainGapMs <= Self.maxMainGapMs)
  }

  /// File > Compare Schemas: the model the sheet opens on
  @Test("Compare Schemas open")
  func schemaCompareOpen() async throws {
    let workspace = try await loadedWorkspace()
    workspace.closeSchemaCompare()
    let open = try await measure("schemaCompareOpen") {
      workspace.openSchemaCompare()
      return try #require(workspace.schemaCompare).targetSchemas
    }
    #expect(open.value == ["main"])
    #expect(open.ms <= Self.schemaCompareOpenBudgetMs)
    #expect(open.maxMainGapMs <= Self.maxMainGapMs)
    workspace.closeSchemaCompare()
  }

  /// Compare's target read, refused for its table count before any structure is read
  @Test("Compare Schemas refusal")
  func schemaCompareRefusal() async throws {
    let workspace = try await loadedWorkspace()
    let refusal = try await measure("schemaCompareRefusal") {
      do {
        _ = try await SchemaSnapshotLoader.load(schema: "main", from: workspace.connectionManager)
        return SchemaCompareError?.none
      } catch let error as SchemaCompareError {
        return error
      }
    }
    #expect(refusal.value == .tooManyTables(Self.tables))
    #expect(refusal.ms <= Self.schemaCompareRefusalBudgetMs)
    #expect(refusal.maxMainGapMs <= Self.maxMainGapMs)
  }

  /// S-SQL: today's per-table reads (allColumns + foreignKeys) against BulkCatalogRead on the
  /// same session. GO needs identical columns, unique columns and foreign keys, and >= 10x.
  @Test("S-SQL: per-table catalog read vs one bulk statement per part")
  func bulkCatalogRead() async throws {
    let url = try LargeCatalogFixture.url(tables: Self.tables)
    let session = SQLiteSession(config: Self.config(url))
    try await session.open()
    let introspector = SQLiteSchemaIntrospector()
    var start = ContinuousClock.now
    let todayColumns: [String: [DatabaseColumn]]
    let todayKeys: [ForeignKey]
    let todayMs: Double
    let bulk: (columns: [String: [DatabaseColumn]], foreignKeys: [ForeignKey])
    let bulkMs: Double
    do {
      todayColumns = try await introspector.allColumns(in: session)
      todayKeys = try await introspector.foreignKeys(in: session)
      todayMs = Self.ms(ContinuousClock.now - start)

      start = ContinuousClock.now
      bulk = try await BulkCatalogRead(introspector: introspector).read(in: session)
      bulkMs = Self.ms(ContinuousClock.now - start)
    } catch {
      await session.close()
      throw error
    }
    await session.close()

    let columnsMatch = Self.signatures(todayColumns) == Self.signatures(bulk.columns)
    let uniqueMatch = Self.uniqueColumns(todayColumns) == Self.uniqueColumns(bulk.columns)
    let keysMatch = todayKeys.map(Self.signature) == bulk.foreignKeys.map(Self.signature)
    let speedup = bulkMs > 0 ? todayMs / bulkMs : 0
    PerfReport.record("largeCatalog.ssql.perTableRead", ms: todayMs)
    PerfReport.record("largeCatalog.ssql.bulkRead", ms: bulkMs)
    let verdict = columnsMatch && uniqueMatch && keysMatch && speedup >= 10 ? "GO" : "NO-GO"
    PerfReport.record(
      "largeCatalog.ssql.\(verdict) columns=\(columnsMatch) unique=\(uniqueMatch) "
        + "foreignKeys=\(keysMatch) speedup(x)", ms: speedup)
    #expect(todayColumns.count == Self.tables + (Self.tables + 49) / 50)
    #expect(todayKeys.count == Self.tables / 10)
  }

  // MARK: - Comparison

  private static func signatures(_ columns: [String: [DatabaseColumn]]) -> [String: [String]] {
    columns.mapValues { list in
      list.map {
        "\($0.name)|\($0.type)|\($0.isNullable)|\($0.isPrimaryKey)|\($0.isIdentity)|"
          + "\($0.isUnique)|\($0.isHidden)|\($0.isGenerated)"
      }
    }
  }

  private static func uniqueColumns(_ columns: [String: [DatabaseColumn]]) -> Set<String> {
    var unique: Set<String> = []
    for (relation, list) in columns {
      for column in list where column.isUnique { unique.insert("\(relation).\(column.name)") }
    }
    return unique
  }

  private static func signature(_ key: ForeignKey) -> String {
    [
      key.constraintName, key.sourceSchema, key.sourceTable,
      key.sourceColumns.joined(separator: ","), key.targetSchema, key.targetTable,
      key.targetColumns.joined(separator: ","), "\(key.onUpdate)", "\(key.onDelete)",
    ].joined(separator: "|")
  }
}

/// Test-side S-SQL prototype: per attached schema, one statement each for the columns of every
/// table and view (sqlite_schema joined with pragma_table_xinfo), the single-column unique
/// indexes (pragma_index_list + pragma_index_info) and the foreign keys
/// (pragma_foreign_key_list). Same mapping as SQLiteSchemaIntrospector; schema names are bound.
private nonisolated struct BulkCatalogRead {
  let introspector: SQLiteSchemaIntrospector

  private nonisolated struct XColumn {
    var name: String
    var type: String
    var notNull: Bool
    var pk: Int
    var hidden: Int
  }

  func read(
    in session: any DatabaseSession
  ) async throws -> (columns: [String: [DatabaseColumn]], foreignKeys: [ForeignKey]) {
    var columns: [String: [DatabaseColumn]] = [:]
    var foreignKeys: [ForeignKey] = []
    let schemas = try await introspector.rows(
      in: session, sql: "SELECT name FROM pragma_database_list ORDER BY seq"
    ).compactMap { SQLiteCatalogValue.string($0, 0) }
    for schema in schemas {
      let quoted = try SQLDialect.sqlite.quoteIdentifier(schema)
      let info = try await xinfo(schema: schema, quoted: quoted, in: session)
      let unique = try await uniqueColumns(schema: schema, quoted: quoted, in: session)
      for (relation, list) in info {
        let uniqueNames = unique[relation] ?? []
        columns["\(schema).\(relation)"] = list.map { column in
          DatabaseColumn(
            name: column.name,
            type: column.type,
            isNullable: !column.notNull,
            isPrimaryKey: column.pk > 0,
            isUnique: uniqueNames.contains(column.name) && column.pk == 0,
            isHidden: column.hidden == 1,
            isGenerated: column.hidden == 2 || column.hidden == 3)
        }
      }
      foreignKeys += try await keys(schema: schema, quoted: quoted, info: info, in: session)
    }
    return (columns, foreignKeys)
  }

  private func xinfo(
    schema: String, quoted: String, in session: any DatabaseSession
  ) async throws -> [String: [XColumn]] {
    let rows = try await introspector.rows(
      in: session,
      sql: """
        SELECT s.name, x.name, x.type, x."notnull", x.pk, x.hidden
        FROM \(quoted).sqlite_schema AS s
        JOIN pragma_table_xinfo(s.name, ?) AS x
        WHERE s.type IN ('table', 'view') AND s.name NOT GLOB 'sqlite_*'
        ORDER BY s.name, x.cid
        """,
      binds: [.text(schema)])
    var info: [String: [XColumn]] = [:]
    for row in rows {
      guard let relation = SQLiteCatalogValue.string(row, 0),
        let name = SQLiteCatalogValue.string(row, 1)
      else { continue }
      info[relation, default: []].append(
        XColumn(
          name: name,
          type: SQLiteCatalogValue.string(row, 2) ?? "",
          notNull: (SQLiteCatalogValue.int(row, 3) ?? 0) != 0,
          pk: SQLiteCatalogValue.int(row, 4) ?? 0,
          hidden: SQLiteCatalogValue.int(row, 5) ?? 0))
    }
    return info
  }

  /// Unique, non-partial, not-the-primary-key indexes on exactly one table column
  private func uniqueColumns(
    schema: String, quoted: String, in session: any DatabaseSession
  ) async throws -> [String: Set<String>] {
    let rows = try await introspector.rows(
      in: session,
      sql: """
        SELECT s.name, ii.name
        FROM \(quoted).sqlite_schema AS s
        JOIN pragma_index_list(s.name, ?) AS il
        JOIN pragma_index_info(il.name, ?) AS ii
        WHERE s.type = 'table' AND s.name NOT GLOB 'sqlite_*'
          AND il."unique" = 1 AND il.origin <> 'pk' AND il.partial = 0
        GROUP BY s.name, il.name
        HAVING COUNT(*) = 1 AND MIN(ii.cid) >= 0
        """,
      binds: [.text(schema), .text(schema)])
    var unique: [String: Set<String>] = [:]
    for row in rows {
      guard let relation = SQLiteCatalogValue.string(row, 0),
        let column = SQLiteCatalogValue.string(row, 1)
      else { continue }
      unique[relation, default: []].insert(column)
    }
    return unique
  }

  private func keys(
    schema: String, quoted: String, info: [String: [XColumn]], in session: any DatabaseSession
  ) async throws -> [ForeignKey] {
    let rows = try await introspector.rows(
      in: session,
      sql: """
        SELECT s.name, fk.id, fk."table", fk."from", fk."to", fk.on_update, fk.on_delete
        FROM \(quoted).sqlite_schema AS s
        JOIN pragma_foreign_key_list(s.name, ?) AS fk
        WHERE s.type = 'table' AND s.name NOT GLOB 'sqlite_*'
        ORDER BY s.name, fk.id, fk.seq
        """,
      binds: [.text(schema)])
    var keys: [ForeignKey] = []
    var index = rows.startIndex
    while index < rows.endIndex {
      guard let table = SQLiteCatalogValue.string(rows[index], 0),
        let id = SQLiteCatalogValue.int(rows[index], 1)
      else {
        index += 1
        continue
      }
      var end = index
      while end < rows.endIndex, SQLiteCatalogValue.string(rows[end], 0) == table,
        SQLiteCatalogValue.int(rows[end], 1) == id
      {
        end += 1
      }
      let group = rows[index..<end]
      index = end
      guard let first = group.first, let target = SQLiteCatalogValue.string(first, 2) else {
        continue
      }
      let sources = group.compactMap { SQLiteCatalogValue.string($0, 3) }
      // A NULL `to` names the target's primary key, in key order
      let targetKey = (info[target] ?? []).filter { $0.pk > 0 }.sorted { $0.pk < $1.pk }
        .map(\.name)
      var targets: [String] = []
      for (offset, row) in group.enumerated() {
        if let column = SQLiteCatalogValue.string(row, 4) {
          targets.append(column)
        } else if offset < targetKey.count {
          targets.append(targetKey[offset])
        }
      }
      guard sources.count == group.count, targets.count == sources.count, !sources.isEmpty
      else { continue }
      keys.append(
        ForeignKey(
          constraintName: String(id),
          sourceSchema: schema,
          sourceTable: table,
          sourceColumns: sources,
          targetSchema: schema,
          targetTable: target,
          targetColumns: targets,
          onUpdate: Self.action(SQLiteCatalogValue.string(first, 5) ?? "NO ACTION"),
          onDelete: Self.action(SQLiteCatalogValue.string(first, 6) ?? "NO ACTION")))
    }
    return keys
  }

  private static func action(_ text: String) -> ForeignKeyAction {
    switch text.uppercased() {
    case "CASCADE": .cascade
    case "RESTRICT": .restrict
    case "SET NULL": .setNull
    case "SET DEFAULT": .setDefault
    default: .noAction
    }
  }
}
