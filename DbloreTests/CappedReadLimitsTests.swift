// CappedReadLimitsTests.swift
// The per-row cap (`CappedReadLimits.cut`): MCP limits cut long cells a little past
// `maxCellCharacters`; limits that mark cut cells (`marksCutCells`) cut at exactly the limit and
// record where. Every kept cell counts toward the byte budget. Per-read limits
// (`execute(readLimits:)`) cut only the editor and notebook result reads that pass them, cursor
// reads row by row in one FETCH. Unit tests (pure, or a manager / tab over a fake session); the capped reads
// against a server are in DatabaseCappedReadTests.

import Foundation
import Testing

@testable import Dblore

@Suite("Capped read limits")
@MainActor
struct CappedReadLimitsTests {
  /// Small limits that mark cut cells, as the app's do
  private static let marking = CappedReadLimits(
    maxCellCharacters: 64, maxResultBytes: 4_096, marksCutCells: true)

  @Test("A long decimal is cut like text and counted as its UTF-8 bytes")
  func longDecimalIsCut() {
    let limits = CappedReadLimits(maxCellCharacters: 10, maxResultBytes: 1_000)
    let digits = String(repeating: "9", count: 50)
    let cut = limits.cut([.decimal(digits), .decimal("1.5")])
    #expect(cut.row == [.decimal(String(repeating: "9", count: 11)), .decimal("1.5")])
    #expect(cut.bytes == 11 + 3)
  }

  @Test("Marking limits cut text and binary at exactly the limit and name the cut columns")
  func markingCutsAtTheLimit() {
    let cut = Self.marking.cut([
      .string(String(repeating: "a", count: 65)), .string(String(repeating: "b", count: 64)),
      .data(Data(repeating: 1, count: 100)), .int(1),
    ])
    #expect(
      cut.row == [
        .string(String(repeating: "a", count: 64)), .string(String(repeating: "b", count: 64)),
        .data(Data(repeating: 1, count: 64)), .int(1),
      ])
    #expect(cut.cutColumns == [0, 2])
  }

  // MARK: - Reads through a manager

  private static let long = String(repeating: "x", count: 3_000) + "1234"

  private func manager(
    limits: CappedReadLimits?, columns: [String], rows: [[CellValue]],
    maskRules: [ColumnMaskRule] = []
  ) async throws -> DatabaseConnectionManager {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.sqlite.capabilities,
      columns: columns.map { ColumnInfo(name: $0, type: "TEXT") }, rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory, readLimits: limits)
    var config = ConnectionConfig(
      databaseType: .sqlite, host: "fake", port: 0, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.maskRules = maskRules
    try await manager.connect(config: config)
    return manager
  }

  private func read(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws
    -> QueryResult
  {
    let result = try await manager.execute(
      userSQL: sql, policy: ProtectionPolicy(protectionLevel: .none))
    await manager.disconnect()
    return result
  }

  @Test("A marking read keeps the limit, records each cut cell, and a script keeps the last's")
  func markingReadRecordsCutCells() async throws {
    let short = "short"
    let manager = try await manager(
      limits: Self.marking, columns: ["a", "b"],
      rows: [[.string(Self.long), .string(short)], [.string(short), .string(Self.long)]])
    let result = try await read(manager, "SELECT 1; SELECT a, b FROM t")
    let kept = CellValue.string(String(Self.long.prefix(64)))
    #expect(result.rows == [[kept, .string(short)], [.string(short), kept]])
    #expect(result.cutCells == [CellPosition(row: 0, column: 0), CellPosition(row: 1, column: 1)])
    #expect(!result.truncated)
    #expect(!result.stoppedAtByteBudget)
  }

  @Test("MCP limits keep one character past and record no cut cell")
  func mcpReadKeepsOnePast() async throws {
    let limits = CappedReadLimits(maxCellCharacters: 64, maxResultBytes: 4_096)
    let manager = try await manager(limits: limits, columns: ["a"], rows: [[.string(Self.long)]])
    let result = try await read(manager, "SELECT a FROM t")
    #expect(result.rows == [[.string(String(Self.long.prefix(65)))]])
    #expect(result.cutCells.isEmpty)
  }

  @Test("Kept cells past the byte budget stop the read, marked as a byte stop")
  func byteBudgetStopsTheRead() async throws {
    // 64 kept bytes per row: the 65th row passes 4 KiB
    let rows = Array(repeating: [CellValue.string(Self.long)], count: 100)
    let manager = try await manager(limits: Self.marking, columns: ["a"], rows: rows)
    let result = try await read(manager, "SELECT a FROM t")
    #expect(result.rows.count == 64)
    #expect(result.truncated)
    #expect(result.stoppedAtByteBudget)
    #expect(result.cutCells == Set((0..<64).map { CellPosition(row: $0, column: 0) }))
  }

  @Test("A cut cell under lastFour shows the full mask and leaves cutCells; others stay cut")
  func cutCellUnderLastFourMasksFully() async throws {
    let manager = try await manager(
      limits: Self.marking, columns: ["email", "note"],
      rows: [[.string(Self.long), .string(Self.long)], [.string("ab12345"), .string("n")]],
      maskRules: [try ColumnMaskRule(pattern: "email", style: .lastFour)])
    let result = try await read(manager, "SELECT email, note FROM t")
    #expect(result.rows[0][0] == .string(ColumnMaskRule.maskText))
    #expect(result.rows[1][0] == .string(ColumnMaskRule.maskText + "2345"))
    #expect(result.cutCells == [CellPosition(row: 0, column: 1)])
  }

  // MARK: - Per-read limits (editor and notebook results)

  @Test("Per-read limits cut a read; the same read without them stays whole")
  func perReadLimitsCutOnlyWhenPassed() async throws {
    let manager = try await manager(limits: nil, columns: ["a"], rows: [[.string(Self.long)]])
    let policy = ProtectionPolicy(protectionLevel: .none)
    let cut = try await manager.execute(
      userSQL: "SELECT a FROM t", policy: policy, readLimits: Self.marking)
    #expect(cut.rows == [[.string(String(Self.long.prefix(64)))]])
    #expect(cut.cutCells == [CellPosition(row: 0, column: 0)])
    let whole = try await read(manager, "SELECT a FROM t")
    #expect(whole.rows == [[.string(Self.long)]])
    #expect(whole.cutCells.isEmpty)
  }

  /// A PostgreSQL-shaped fake (server cursors) whose reads answer `rows` of one `a` column
  private func cursorManager(
    rows: [[CellValue]], protectedMode: Bool
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(supportsServerCursor: true),
      columns: [ColumnInfo(name: "a", type: "text")], rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: protectedMode))
    return (manager, factory)
  }

  @Test("A Protected mode cursor read sends one FETCH and stops at the budget mid-FETCH")
  func cursorReadStreamsOneFetch() async throws {
    // Long rows (cut to 64 bytes) and 1-byte rows by turns: row 200 passes the budget
    let rows = (0..<300).map { [CellValue.string($0.isMultiple(of: 2) ? Self.long : "x")] }
    let (manager, factory) = try await cursorManager(rows: rows, protectedMode: true)
    let limits = CappedReadLimits(maxCellCharacters: 64, maxResultBytes: 6_500, marksCutCells: true)
    let run = try await manager.executeDetailed(
      userSQL: "UPDATE t SET a = 'y' WHERE id = 1; SELECT a FROM t",
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true), maxRows: 1_000,
      readLimits: limits)
    let result = try #require(run.results.last?.result)
    let session = try #require(factory.sessions.last)
    #expect(await manager.cursorReadCount == 1)
    #expect(session.fetchCounts == [1_001])
    #expect(session.closeCursorCount == 1)
    #expect(result.rows.count == 200)
    #expect(result.rows[198] == [.string(String(Self.long.prefix(64)))])
    #expect(result.rows[199] == [.string("x")])
    #expect(result.truncated)
    #expect(result.stoppedAtByteBudget)
    #expect(
      result.cutCells
        == Set(stride(from: 0, to: 200, by: 2).map { CellPosition(row: $0, column: 0) }))
    await manager.disconnect()
  }

  private static func longRows(_ count: Int) -> [[CellValue]] {
    Array(repeating: [.string(long)], count: count)
  }

  @Test("A RETURNING read keeps its cut cells and byte stop")
  func returningReadKeepsCutCells() async throws {
    let (manager, _) = try await cursorManager(rows: Self.longRows(100), protectedMode: false)
    let result = try await manager.execute(
      userSQL: "INSERT INTO t (a) VALUES ('x') RETURNING a",
      policy: ProtectionPolicy(protectionLevel: .none), readLimits: Self.marking)
    #expect(result.rows.count == 64)
    #expect(result.stoppedAtByteBudget)
    #expect(result.cutCells == Set((0..<64).map { CellPosition(row: $0, column: 0) }))
    await manager.disconnect()
  }

  // MARK: - Which tab reads pass the app limits

  /// A tab on a fake `type` session whose reads answer `rows` of one `a` column, with the app
  /// limits replaced by `marking`
  private func tab(
    _ type: DatabaseType, rows: [[CellValue]], cell: String = ""
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager) {
    var config = ConnectionConfig(
      databaseType: type, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.applyCommitStyle(.immediate)
    let factory = FakeDatabaseSessionFactory(
      capabilities: type.capabilities, columns: [ColumnInfo(name: "a", type: "TEXT")],
      rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config
    viewModel.notebook.cells = [NotebookCell(cellType: .sql, content: cell)]
    viewModel.toastPresenter = { _, _ in }
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.appReadLimits = Self.marking
    return (viewModel, manager)
  }

  private func runCell(_ viewModel: NotebookViewModel) async throws -> CellResult {
    await viewModel.runCell(id: viewModel.notebook.cells[0].id)
    await viewModel.executionQueue.waitForIdle()
    let result = try #require(viewModel.notebook.cells[0].result)
    #expect(result.error == nil)
    return result
  }

  @Test("Editor runs, editor scripts and notebook cells are cut with the app limits")
  func editorAndNotebookReadsAreCut() async throws {
    let rows: [[CellValue]] = [[.string(Self.long)]]
    let (viewModel, manager) = try await tab(.sqlite, rows: rows, cell: "SELECT a FROM t")
    let cut = [CellPosition(row: 0, column: 0)]
    await viewModel.executeEditorQuery("SELECT a FROM t")
    #expect(viewModel.editorResult?.cutCells == Set(cut))
    await viewModel.executeEditorQuery("SELECT 1; SELECT a FROM t")
    #expect(viewModel.editorStatementResults.last?.result.cutCells == Set(cut))
    #expect(try await runCell(viewModel).cutCells == Set(cut))
    viewModel.notebook.cells[0].content = "SELECT 1; SELECT a FROM t"
    #expect(try await runCell(viewModel).cutCells == Set(cut))
    await manager.disconnect()
  }

  @Test("A data viewer page read through executeEditorQuery stays whole")
  func dataViewerPageIsNotCut() async throws {
    let (viewModel, manager) = try await tab(.sqlite, rows: [[.string(Self.long)]])
    viewModel.viewMode = .editor
    let state = DataViewerState(
      schema: "main", name: "t", orderColumns: ["a"], databaseType: .sqlite)
    viewModel.dataViewer = state
    await viewModel.executeEditorQuery(state.pageSQL, source: .internal, pageState: state)
    let page = try #require(viewModel.editorResult)
    #expect(page.rows == [[.string(Self.long)]])
    #expect(page.cutCells.isEmpty)
    await manager.disconnect()
  }

  @Test("MongoDB editor reads and mongosh cells stay whole")
  func mongoReadsAreNotCut() async throws {
    let (viewModel, manager) = try await tab(
      .mongodb, rows: [[.string(Self.long)]], cell: "db.t.find()")
    await viewModel.executeEditorQuery("db.t.find()")
    #expect(viewModel.editorResult?.rows == [[.string(Self.long)]])
    #expect(viewModel.editorResult?.cutCells.isEmpty == true)
    let cell = try await runCell(viewModel)
    #expect(cell.rows == [[.string(Self.long)]])
    #expect(cell.cutCells.isEmpty)
    await manager.disconnect()
  }
}
