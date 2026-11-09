// CutCellRefusalTests.swift
// Cells a capped read cut (`CellResult.cutCells`, no lazy-page `truncation`) hold only a
// prefix, so the unloaded-cell helpers treat them as unloaded: Duplicate Row and a Row Details
// edit of a cut cell stage and send nothing; copy, export and pin are refused; the AI's
// `@results` never reads the prefix as the whole value. Row Details shows a cut field's refusal,
// a notebook grid or Cell Value edit of a cut cell sends nothing, and a notebook cell with cut
// cells is never pinned or compared. A result without cut cells behaves as before. No database
// server: a disconnected connection manager.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Cut cell refusals")
struct CutCellRefusalTests {
  private static let usersID = TableRef.postgresql(oid: 1)

  /// users(id PK, nickname, bio) on a data viewer page, editor tab with confirm commit style:
  /// row 0's `bio` (and row 1's when `bothRows`) cut to "abc", row 1 whole. Toasts go to `log`.
  private func makeViewModel(bothRows: Bool = false, log: ToastLog) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    viewModel.notebook.connectionConfig?.applyCommitStyle(.confirm)
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let columns = [("id", "int4"), ("nickname", "text"), ("bio", "text")]
    var result = CellResult(
      columns: columns.enumerated().map { index, column in
        ColumnInfo(
          name: column.0, type: column.1,
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: index + 1))
      },
      rows: [[.int(1), .string("ana"), .string("abc")], [.int(2), .string("bo"), .string("hi")]],
      rowCount: 2,
      tableName: "users",
      primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
        updateOnly: true, schema: "public", name: "users"))
    result.cutCells = [CellPosition(row: 0, column: 2)]
    if bothRows { result.cutCells.insert(CellPosition(row: 1, column: 2)) }
    result.aiSessionKey = viewModel.aiSessionKey
    viewModel.editorResult = result
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.toastPresenter = { message, _ in log.messages.append(message) }
    return viewModel
  }

  /// A notebook with one SQL cell whose users(id PK, nickname, bio) result has row 0's `bio`
  /// cut to "abc" and row 1 whole; confirm commit style. Toasts go to `log`.
  private func makeNotebook(log: ToastLog) -> (NotebookViewModel, UUID) {
    let cellId = UUID()
    var result = CellResult(
      columns: [("id", "int4"), ("nickname", "text"), ("bio", "text")].enumerated().map {
        index, column in
        ColumnInfo(
          name: column.0, type: column.1,
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: index + 1))
      },
      rows: [[.int(1), .string("ana"), .string("abc")], [.int(2), .string("bo"), .string("hi")]],
      rowCount: 2, sourceQuery: "SELECT * FROM users", tableName: "users",
      primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"]))
    result.cutCells = [CellPosition(row: 0, column: 2)]
    var config = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.applyCommitStyle(.confirm)
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM users", executionCount: 1,
          result: result)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Cut cells"),
      connectionConfig: config, settings: NotebookSettings())
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.toastPresenter = { message, _ in log.messages.append(message) }
    return (viewModel, cellId)
  }

  @Test("Duplicate Row of a row with a cut cell stages nothing; a whole row still stages")
  func duplicateRefusesCutRow() async throws {
    let log = ToastLog()
    let viewModel = makeViewModel(log: log)
    #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(
      log.messages == [
        "Duplicate Row refused: 1 value in this selection was cut at 1 MiB,"
          + " so it cannot be copied whole."
      ])

    #expect(await viewModel.stageDuplicate(rows: [1]) == nil)
    let inserts = try #require(viewModel.dataViewer?.changeSet?.inserts)
    #expect(inserts.count == 1)
    #expect(inserts.first?.values["bio"] == .string("hi"))
  }

  @Test("Row Details never edits a cut cell: its field is read-only and Apply sends nothing")
  func rowDetailNeverEditsCutCell() throws {
    let viewModel = makeViewModel(log: ToastLog())
    let result = try #require(viewModel.editorResult)
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    let index = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "bio" })
    #expect(viewModel.rowDetail?.fields[index].isReadOnly == true)
    viewModel.rowDetail?.fields[index].text = "abc and more"

    viewModel.applyRowDetail()

    #expect(viewModel.pendingInlineEdit == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)

    // Control: row 1's whole `bio` is editable and its Apply arms the UPDATE
    viewModel.showRowDetail(row: result.rows[1], originalRow: 1, result: result, cellId: nil)
    let whole = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "bio" })
    #expect(viewModel.rowDetail?.fields[whole].isReadOnly == false)
    #expect(viewModel.rowDetail?.fields[whole].isCut == false)
    viewModel.rowDetail?.fields[whole].text = "hi there"

    viewModel.applyRowDetail()

    #expect(viewModel.pendingInlineEdit != nil)
  }

  @Test("Row Details shows a cut value's refusal, never \"Loading full value…\"")
  func rowDetailShowsCutRefusal() async throws {
    let viewModel = makeViewModel(log: ToastLog())
    let result = try #require(viewModel.editorResult)
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    let field = try #require(viewModel.rowDetail?.fields.first { $0.name == "bio" })
    #expect(field.isCut)
    #expect(field.isReadOnly)
    #expect(!RowDetailContent.showsLoading(field, lazyLoadError: nil))
    #expect(
      RowDetailContent.error(of: field, lazyLoadError: nil)
        == "This value was cut at 1 MiB. Open the table in the data viewer to read it whole,"
        + " or export all rows.")
    #expect(await viewModel.loadRowDetailCells() == nil)
    #expect(viewModel.rowDetail?.fields.first { $0.name == "bio" }?.isReadOnly == true)
  }

  // MARK: - Notebook cells and the Cell Value sidebar

  @Test("A notebook grid edit of a cut cell sends nothing; a whole cell's edit is armed")
  func notebookGridEditRefusesCutCell() throws {
    let log = ToastLog()
    let (viewModel, cellId) = makeNotebook(log: log)
    let result = try #require(viewModel.notebook.cells.first?.result)

    viewModel.handleGridCellEdit(
      row: result.rows[0], column: 2, newValue: "abc and more", result: result, cellId: cellId,
      connectionManager: DatabaseConnectionManager())

    #expect(viewModel.pendingInlineEdit == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(log.messages == ["Edit refused: " + NotebookViewModel.cutCellsMessage(count: 1)])

    viewModel.handleGridCellEdit(
      row: result.rows[1], column: 2, newValue: "hi there", result: result, cellId: cellId,
      connectionManager: DatabaseConnectionManager())

    #expect(viewModel.pendingInlineEdit != nil)
    #expect(log.messages.count == 1)
  }

  @Test("The Cell Value sidebar of a cut cell disables Copy and its edit sends nothing")
  func cellValueSidebarRefusesCutCell() throws {
    let log = ToastLog()
    let (viewModel, cellId) = makeNotebook(log: log)
    let result = try #require(viewModel.notebook.cells.first?.result)

    viewModel.showGridCellInSidebar(
      row: result.rows[1], originalRow: 1, column: 2, result: result, cellId: cellId)
    #expect(!viewModel.sidebarCellIsCut)
    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: 2, result: result, cellId: cellId)
    #expect(viewModel.sidebarCellIsCut)
    let shown = viewModel.rightSidebarContent

    viewModel.handleCellValueEdit(
      columnName: "bio", columnType: "text", newValue: "abc and more",
      originalValue: .string("abc"), tableName: "users",
      rowData: CellResult.rowData(columns: result.columns, row: result.rows[0]),
      primaryKeyColumns: ["id"], cellId: cellId, connectionManager: DatabaseConnectionManager(),
      wallClock: false)

    #expect(viewModel.pendingInlineEdit == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.rightSidebarContent == shown)
    #expect(viewModel.sidebarCellIsCut)
    #expect(log.messages == ["Edit refused: " + NotebookViewModel.cutCellsMessage(count: 1)])
  }

  @Test("A cut JSON cell opens the Cell Value sidebar, never the JSON viewer")
  func cutJSONOpensCellValue() throws {
    let (viewModel, cellId) = makeNotebook(log: ToastLog())
    let cut = try #require(viewModel.notebook.cells.first?.result)
    var rows = cut.rows
    rows[0][2] = .json(#"{"a":"#)
    var result = CellResult(
      columns: cut.columns, rows: rows, rowCount: 2, timestamp: cut.timestamp,
      tableName: cut.tableName, primaryKeyColumns: cut.primaryKeyColumns,
      editTarget: cut.editTarget)
    result.cutCells = cut.cutCells
    viewModel.notebook.cells[0].result = result

    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: 2, result: result, cellId: cellId)

    guard case .cellInfo = viewModel.rightSidebarContent else {
      Issue.record("a cut JSON value did not open the Cell Value sidebar")
      return
    }
    #expect(viewModel.sidebarCellIsCut)
  }

  @Test("A notebook cell with cut cells is never pinned or compared; a whole one is")
  func notebookPinAndCompareRefused() throws {
    let log = ToastLog()
    let (viewModel, cellId) = makeNotebook(log: log)
    let cut = try #require(viewModel.notebook.cells.first?.result)

    #expect(!viewModel.pinResult(cellID: cellId))
    #expect(viewModel.notebook.cells[0].pinnedResult == nil)

    var whole = cut
    whole.cutCells = []
    viewModel.notebook.cells[0].pinnedResult = PinnedResult(
      result: whole, pinnedAt: Date(), sourceQuery: "SELECT * FROM users")
    viewModel.toggleCompare(cellID: cellId)
    #expect(!viewModel.isComparing(cellID: cellId))
    #expect(viewModel.cellComparisons[cellId] == nil)
    #expect(
      log.messages == [
        "Pin refused: " + NotebookViewModel.cutCellsMessage(count: 1),
        "Compare refused: " + NotebookViewModel.cutCellsMessage(count: 1),
      ])

    viewModel.notebook.cells[0].result = whole
    viewModel.notebook.cells[0].pinnedResult = nil
    #expect(viewModel.pinResult(cellID: cellId))
    viewModel.toggleCompare(cellID: cellId)
    #expect(viewModel.isComparing(cellID: cellId))
    #expect(log.messages.count == 2)
  }

  @Test("The editor pin of a result with cut cells gives the cut reason")
  func editorPinGivesCutReason() {
    let log = ToastLog()
    let viewModel = makeViewModel(bothRows: true, log: log)
    #expect(!viewModel.pinEditorResult())
    #expect(log.messages == ["Pin refused: " + NotebookViewModel.cutCellsMessage(count: 2)])
  }

  @Test("Copy, export and pin of a result with cut cells are refused")
  func copyExportAndPinRefused() async throws {
    let log = ToastLog()
    let viewModel = makeViewModel(bothRows: true, log: log)
    let result = try #require(viewModel.editorResult)
    #expect(viewModel.hasUnloadedCells(in: result))
    #expect(viewModel.cutCells(in: result) == [0: [2: 3], 1: [2: 2]])

    #expect(await QueryCopyBar.loadedResult(result, viewModel: viewModel, action: "Copy") == nil)
    #expect(
      await QueryCopyBar.exportRequest(format: .csv, result: result, viewModel: viewModel) == nil)
    #expect(
      log.messages == [
        "Copy refused: 2 values in this selection were cut at 1 MiB,"
          + " so they cannot be copied whole.",
        "Export refused: 2 values in this selection were cut at 1 MiB,"
          + " so they cannot be copied whole.",
      ])
    #expect(!viewModel.pinEditorResult())
    #expect(viewModel.editorPinnedResult == nil)
  }

  @Test("The AI's @results shows a cut cell as not loaded, never its prefix as whole")
  func aiResultMarksCutCell() throws {
    let viewModel = makeViewModel(log: ToastLog())
    let result = try #require(viewModel.aiCurrentResult)
    #expect(result.rows.first?[2] == "<3 bytes, not loaded>")
    #expect(result.rows.last?[2] == "hi")
  }

  @Test("Values written into a result keep its cut cells marked")
  func replacingCellsKeepsCutCells() throws {
    var result = try #require(makeViewModel(log: ToastLog()).editorResult)
    result.stoppedAtByteBudget = true
    let replaced = result.replacingCells([1: [1: .string("b")]])
    #expect(replaced.cutCells == result.cutCells)
    #expect(replaced.stoppedAtByteBudget)
  }

  @Test("A result without cut cells copies and pins as before")
  func resultWithoutCutCellsUnchanged() async throws {
    let log = ToastLog()
    let viewModel = makeViewModel(log: log)
    viewModel.editorResult?.cutCells = []
    let result = try #require(viewModel.editorResult)
    #expect(!viewModel.hasUnloadedCells(in: result))
    #expect(viewModel.unloadedCells(in: result).isEmpty)
    let copied = try #require(
      await QueryCopyBar.loadedResult(result, viewModel: viewModel, action: "Copy"))
    #expect(copied.rows == result.rows)
    #expect(viewModel.pinEditorResult())
    #expect(log.messages.isEmpty)
  }
}

/// Toasts a test presented, in order
@MainActor
private final class ToastLog {
  var messages: [String] = []
}
