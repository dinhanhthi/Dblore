// ExportAllRowsTests.swift
// The Export sheet's "All rows" source: offered for a partial editor or notebook result (row
// cap, byte budget, cut cells) whose query is one read without `:name` parameters, and for every
// SQL data viewer page (its `exportSQL`); refused with a reason otherwise. A result whose cells
// cannot all be loaded opens the sheet at once: "Shown rows" is refused then, "All rows" runs the
// read again on a separate connection (a SQLite file, no server) and writes every row, its masked
// columns redacted.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Export all rows")
struct ExportAllRowsTests {
  private static let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "email", type: "text"),
  ]

  /// An editor tab on `type` (no connection)
  private func editorViewModel(_ type: DatabaseType = .postgresql) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      databaseType: type, host: "localhost", port: 5432, database: "app", username: "ana",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    return viewModel
  }

  /// One row of `sql`, row-capped unless `limited` is false
  private func result(
    _ sql: String, limited: Bool = true, stopped: Bool = false, cut: Bool = false
  ) -> CellResult {
    var result = CellResult(
      columns: Self.columns, rows: [[.int(1), .string("a@x.io")]], rowCount: 1,
      wasLimited: limited, sourceQuery: sql)
    result.stoppedAtByteBudget = stopped
    if cut { result.cutCells = [CellPosition(row: 0, column: 1)] }
    return result
  }

  @Test("A partial result offers all rows only for one read without parameters")
  func editorEligibility() {
    let viewModel = editorViewModel()
    let plain = "SELECT id, email FROM users"
    for partial in [
      result(plain), result(plain, limited: false, stopped: true),
      result(plain, limited: false, cut: true),
    ] {
      #expect(viewModel.allRowsExportOffer(for: partial, cellId: nil)?.source?.sql == plain)
    }
    // Every row is shown: nothing to offer
    #expect(viewModel.allRowsExportOffer(for: result(plain, limited: false), cellId: nil) == nil)

    func reason(_ sql: String) -> String? {
      viewModel.allRowsExportOffer(for: result(sql), cellId: UUID())?.reason
    }
    #expect(
      reason("SELECT id, email FROM users WHERE id = :id")
        == ResultExportError.parameters.errorDescription)
    #expect(
      reason("UPDATE users SET email = 'b' RETURNING id, email")
        == NotebookViewModel.allRowsNotReadReason)
    #expect(
      reason("SELECT id, email FROM users; SELECT 1")
        == NotebookViewModel.allRowsMultipleStatementsReason)
    #expect(
      editorViewModel(.mysql).allRowsExportOffer(
        for: result("SELECT id, email FROM users WHERE id > @min"), cellId: nil)?.reason
        == ResultExportError.sessionVariables.errorDescription)
    #expect(
      editorViewModel(.mongodb).allRowsExportOffer(for: result("db.users.find({})"), cellId: nil)?
        .reason == NotebookViewModel.allRowsMongoDBReason)
  }

  @Test("A data viewer page over the bulk limit opens the sheet at once with all rows")
  func dataViewerPageOffersExportSQL() throws {
    let viewModel = editorViewModel()
    let toasts = ToastLog()
    viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
    viewModel.connectionManager = DatabaseConnectionManager()
    let viewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"], page: 2)
    viewModel.dataViewer = viewer
    var page = result(viewer.shownPageSQL, limited: false)
    page.truncation = DataViewerState.Truncation(
      keyColumns: ["id"],
      lengths: [
        RowChangeSet.RowKey(values: [.int(1)]): ["email": LazyCellLoader.bulkLimitBytes + 1]
      ],
      relation: viewer.relation)
    viewModel.editorResult = page
    #expect(viewModel.hasUnloadedCells(in: page))

    let request = try #require(
      QueryCopyBar.openingExportRequest(
        format: .json, result: page, viewModel: viewModel, cellId: nil))
    #expect(
      request.allRows?.source
        == AllRowsExportSource(
          sql: viewer.exportSQL, columns: page.columns, schema: "public", name: "users"))
    // Nothing was loaded
    #expect(request.result.truncation == page.truncation)
    #expect(toasts.messages.isEmpty)

    // MongoDB: no all-rows source
    viewModel.dataViewer?.databaseType = .mongodb
    #expect(
      viewModel.allRowsExportOffer(for: page, cellId: nil)?.reason
        == NotebookViewModel.allRowsMongoDBReason)
  }

  @Test("Cut cells: Shown rows is refused, All rows writes every row with masked columns redacted")
  func cutCellsExportAllRows() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-export-all-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = ConnectionConfig(
      databaseType: .sqlite, database: directory.appendingPathComponent("people.sqlite").path,
      username: "", protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.maskRules = [try ColumnMaskRule(pattern: "email", style: .email)]
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    for statement in [
      "CREATE TABLE people (id INTEGER PRIMARY KEY, email TEXT)",
      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 25)"
        + " INSERT INTO people SELECT i, 'p' || i || '@x.io' FROM n",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager
    let toasts = ToastLog()
    viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
    // The grid showed 10 of the 25 rows, the last email cut. Its columns are not flagged
    // masked: the export reads the rules again.
    var shown = CellResult(
      columns: [ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "email", type: "TEXT")],
      rows: (1...10).map { [.int($0), .string("p\($0)@x.io")] }, rowCount: 10, wasLimited: true,
      sourceQuery: "SELECT id, email FROM people ORDER BY id")
    shown.cutCells = [CellPosition(row: 9, column: 1)]
    viewModel.editorResult = shown

    let request = try #require(
      QueryCopyBar.openingExportRequest(
        format: .csv, result: shown, viewModel: viewModel, cellId: nil))
    #expect(request.result.cutCells == shown.cutCells)
    #expect(toasts.messages.isEmpty)

    // Shown rows: the cut cell cannot be loaded
    #expect(
      await QueryCopyBar.loadedResult(request.result, viewModel: viewModel, action: "Export")
        == nil)
    #expect(toasts.messages == ["Export refused: " + NotebookViewModel.cutCellsMessage(count: 1)])

    // All rows: every row, the masked email redacted as the shown rows' export does
    let source = try #require(request.allRows?.source)
    let destination = directory.appendingPathComponent("people.csv")
    let written = try await viewModel.exportAllRows(
      source, options: ExportOptions(format: .csv), to: destination)
    #expect(written == 25)
    let lines = try String(contentsOf: destination, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    #expect(lines.count == 26)
    #expect(lines.first == "id,email")
    #expect(lines.dropFirst().allSatisfy { $0.hasSuffix("," + ExportOptions.mask) })
    #expect(lines.last == "25," + ExportOptions.mask)
    await manager.disconnect()
  }
}

/// Toasts a test presented, in order
@MainActor
private final class ToastLog {
  var messages: [String] = []
}
