// CutCellRefusalTests.swift
// Cells a capped read cut (`CellResult.cutCells`, no lazy-page `truncation`) hold only a
// prefix, so the unloaded-cell helpers treat them as unloaded: Duplicate Row and a Row Details
// edit of a cut cell stage and send nothing; copy, export and pin are refused; the AI's
// `@results` never reads the prefix as the whole value. A result without cut cells behaves as
// before. No database server: a disconnected connection manager.

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
