// RowDetailTests.swift
// Row Details sidebar state on NotebookViewModel: fields, read-only rules, drafts, Cancel.
// No database: results and edit targets are built in memory.

import Foundation
import Testing

@testable import Dblore

@Suite("Row details")
@MainActor
struct RowDetailTests {
  private static let usersID = TableRef("users")

  @Test("Fields follow the column order with the row's values as originals")
  func fieldsInColumnOrder() {
    let viewModel = makeViewModel()
    let result = makeResult()

    viewModel.showRowDetail(
      row: result.rows[0], originalRow: 0, result: result, cellId: nil)

    let fields = viewModel.rowDetail?.fields ?? []
    #expect(fields.map(\.id) == ["id", "age", "nickname", "slug"])
    #expect(fields.map(\.original) == [.int(1), .int(30), .null, .string("ana-1")])
    #expect(fields[1].text == "30")
  }

  @Test("NULL original starts as NULL and is not dirty")
  func nullOriginal() {
    let viewModel = makeViewModel()
    let result = makeResult()

    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)

    let nickname = viewModel.rowDetail?.fields[2]
    #expect(nickname?.isNull == true)
    #expect(nickname?.isDirty == false)
    #expect(nickname?.bindText == nil)
  }

  @Test("Primary key of a loaded row and generated columns are read-only")
  func readOnlyColumns() {
    let viewModel = makeViewModel()
    let result = makeResult()

    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)

    #expect(viewModel.rowDetail?.fields.map(\.isReadOnly) == [true, false, false, true])
  }

  @Test("A result without an edit target is read-only")
  func noEditTargetIsReadOnly() {
    let viewModel = makeViewModel()
    var result = makeResult()
    result.editTarget = nil

    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)

    #expect(viewModel.rowDetail?.fields.allSatisfy(\.isReadOnly) == true)
  }

  @Test("Drafts are dirty and validated by column type")
  func dirtyAndValidation() {
    let viewModel = makeViewModel()
    let result = makeResult()
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    #expect(viewModel.rowDetailHasChanges == false)

    viewModel.rowDetail?.fields[1].text = "abc"
    #expect(viewModel.rowDetail?.fields[1].isDirty == true)
    #expect(viewModel.rowDetail?.fields[1].validationError != nil)
    #expect(viewModel.rowDetailHasErrors)

    viewModel.rowDetail?.fields[1].text = ""
    #expect(viewModel.rowDetail?.fields[1].validationError == "Enter a value or set NULL")

    viewModel.rowDetail?.fields[1].text = "31"
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = ""
    #expect(viewModel.rowDetail?.fields[2].validationError == nil)
    #expect(viewModel.rowDetail?.fields[2].bindText == "")
    #expect(viewModel.rowDetailHasChanges)
    #expect(!viewModel.rowDetailHasErrors)
  }

  @Test("Cancel resets every field to its original and keeps the sidebar open")
  func cancelResets() {
    let viewModel = makeViewModel()
    let result = makeResult()
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "99"
    viewModel.rowDetail?.fields[2].isNull = false

    viewModel.cancelRowDetailEdits()

    #expect(viewModel.rowDetail?.fields[1].text == "30")
    #expect(viewModel.rowDetail?.fields[2].isNull == true)
    #expect(!viewModel.rowDetailHasChanges)
    #expect(viewModel.isRightSidebarVisible)
  }

  @Test("State names the row by number and primary key, and the sidebar shows it")
  func stateAndSidebar() {
    let viewModel = makeViewModel()
    let result = makeResult()
    let cellId = UUID()

    viewModel.showRowDetail(row: result.rows[1], originalRow: 1, result: result, cellId: cellId)

    let state = viewModel.rowDetail
    #expect(state?.tableName == "users")
    #expect(state?.rowNumber == 2)
    #expect(state?.keyPairs == [RowDetailKey(name: "id", value: .int(2))])
    #expect(state?.stagedInsertID == nil)
    #expect(viewModel.cellDetailRow == 1)
    #expect(viewModel.cellDetailEditTarget == result.editTarget)
    #expect(viewModel.rightSidebarContent == .rowDetail(cellId: cellId))
    #expect(viewModel.isRightSidebarVisible)
  }

  @Test("A staged insert reads the change set and its primary key is editable")
  func stagedInsert() {
    let viewModel = makeViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = makeResult()
    viewModel.editorResult = result
    #expect(viewModel.stageInsert(values: ["id": .int(7), "nickname": .string("new")]) == nil)

    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)

    let state = viewModel.rowDetail
    #expect(state?.stagedInsertID == viewModel.dataViewer?.changeSet?.inserts.first?.tempID)
    #expect(state?.stagedInsertID != nil)
    #expect(state?.fields.map(\.original) == [.int(7), .null, .string("new"), .null])
    #expect(state?.fields[0].isReadOnly == false)
  }

  @Test("A DATE opens as yyyy-MM-dd, clean, and is checked once edited")
  func dateOpensAsPlainDate() {
    let viewModel = makeViewModel()
    let day = Date(timeIntervalSince1970: 1_709_078_400)  // 2024-02-28 00:00 UTC
    let base = makeResult()
    let result = CellResult(
      columns: base.columns + [
        ColumnInfo(
          name: "born", type: "date",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 5))
      ],
      rows: base.rows.map { $0 + [.date(day)] }, rowCount: 2, tableName: "users",
      primaryKeyColumns: ["id"], editTarget: base.editTarget)
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)

    let born = viewModel.rowDetail?.fields[4]
    #expect(born?.isReadOnly == false)
    #expect(born?.text == "2024-02-28")
    #expect(born?.isDirty == false)
    #expect(born?.validationError == nil)

    viewModel.rowDetail?.fields[4].text = "2024-02-30"
    #expect(viewModel.rowDetail?.fields[4].validationError != nil)
    viewModel.rowDetail?.fields[4].text = "2024-02-29"
    #expect(viewModel.rowDetail?.fields[4].validationError == nil)
    viewModel.cancelRowDetailEdits()
    #expect(viewModel.rowDetail?.fields[4].text == "2024-02-28")
  }

  @Test("An unset key of a staged insert is NULL but not an error while untouched")
  func unsetStagedKeyIsNotAnError() {
    let viewModel = makeViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = makeResult()
    viewModel.editorResult = result
    #expect(viewModel.stageInsert(values: ["nickname": .string("new")]) == nil)

    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)

    let id = viewModel.rowDetail?.fields[0]
    #expect(id?.isNull == true)
    #expect(id?.field.validationError != nil)
    #expect(id?.validationError == nil)
    #expect(!viewModel.rowDetailHasErrors)
  }

  // MARK: - Apply

  @Test("Apply sends one UPDATE of every dirty editable field through one confirmation")
  func applyBuildsOneUpdate() {
    let viewModel = makeEditorViewModel()
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "31"
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = "hi"
    viewModel.rowDetail?.fields[3].text = "changed"

    viewModel.applyRowDetail()

    let edit = viewModel.pendingInlineEdit
    #expect(edit?.columnNames == ["age", "nickname"])
    #expect(
      edit?.statement.sql
        == #"UPDATE ONLY public.users SET "age" = $1, "nickname" = $2 WHERE "id" = $3"#)
    #expect(edit?.statement.values == ["31", "hi", "1"])
    #expect(viewModel.queryConfirmationState.showDialog)
  }

  @Test("Apply sends empty text, not NULL, for a NULL text column switched to the typed value")
  func applyEmptyTextOverNull() {
    let viewModel = makeEditorViewModel()
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = ""

    viewModel.applyRowDetail()

    #expect(viewModel.pendingInlineEdit?.columnNames == ["nickname"])
    #expect(viewModel.pendingInlineEdit?.statement.values == ["", "1"])
  }

  @Test("Apply without a dirty editable field does nothing")
  func applyWithoutChangesIsNoOp() {
    let viewModel = makeEditorViewModel()
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[3].text = "changed"

    viewModel.applyRowDetail()

    #expect(viewModel.pendingInlineEdit == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(toasts.isEmpty)
  }

  @Test("Apply on a staged insert stages the values, sends nothing and clears the drafts")
  func applyStagedInsert() {
    let viewModel = makeEditorViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = viewModel.editorResult!
    #expect(viewModel.stageInsert(values: ["id": .int(7), "nickname": .string("new")]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].isNull = false
    viewModel.rowDetail?.fields[1].text = "5"
    viewModel.rowDetail?.fields[2].text = "newer"

    viewModel.applyRowDetail()

    let values = viewModel.dataViewer?.changeSet?.inserts.first?.values
    #expect(values?["age"]?.fullString == "5")
    #expect(values?["nickname"] == .string("newer"))
    #expect(viewModel.pendingInlineEdit == nil)
    #expect(viewModel.rowDetail?.fields[1].original.fullString == "5")
    #expect(viewModel.rowDetail?.fields[2].original == .string("newer"))
    #expect(!viewModel.rowDetailHasChanges)
  }

  @Test("Apply on a staged insert stages empty text, not NULL, over a NULL text column")
  func applyStagedInsertEmptyText() {
    let viewModel = makeEditorViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = viewModel.editorResult!
    #expect(viewModel.stageInsert(values: ["id": .int(7)]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = ""

    viewModel.applyRowDetail()

    #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["nickname"] == .string(""))
  }

  @Test("Apply on a loaded row staged for deletion is refused")
  func applyDeletedRowRefused() {
    let viewModel = makeEditorViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    var toasts: [(String, ToastMessage.ToastType)] = []
    viewModel.toastPresenter = { message, type in toasts.append((message, type)) }
    let result = viewModel.editorResult!
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "31"

    viewModel.applyRowDetail()

    #expect(viewModel.pendingInlineEdit == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(toasts.map(\.0) == [RowChangeError.deletedRow.message])
    #expect(toasts.first?.1 == .error)
  }

  @Test("Apply on a staged insert follows the insert after an earlier one is reverted")
  func applyStagedInsertAfterRevert() {
    let viewModel = makeEditorViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = viewModel.editorResult!
    #expect(viewModel.stageInsert(values: ["id": .int(7)]) == nil)
    #expect(viewModel.stageInsert(values: ["id": .int(8)]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 3, result: result, cellId: nil)
    #expect(viewModel.revertStaged(rows: [2]) == nil)
    #expect(viewModel.stageInsert(values: ["id": .int(9)]) == nil)
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = "eight"

    viewModel.applyRowDetail()

    let inserts = viewModel.dataViewer?.changeSet?.inserts ?? []
    #expect(inserts.map { $0.values["id"] } == [.int(8), .int(9)])
    #expect(inserts.first?.values["nickname"] == .string("eight"))
    #expect(inserts.last?.values["nickname"] == nil)
    #expect(viewModel.rowDetail?.originalRow == 2)
    #expect(!viewModel.rowDetailHasChanges)
  }

  @Test("Apply on a staged insert that is gone stages nothing and drops the panel")
  func applyRemovedStagedInsert() {
    let viewModel = makeEditorViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    var toasts: [(String, ToastMessage.ToastType)] = []
    viewModel.toastPresenter = { message, type in toasts.append((message, type)) }
    let result = viewModel.editorResult!
    #expect(viewModel.stageInsert(values: ["id": .int(7)]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)
    #expect(viewModel.revertStaged(rows: [2]) == nil)
    #expect(viewModel.stageInsert(values: ["id": .int(9)]) == nil)
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = "stale"

    viewModel.applyRowDetail()

    #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["nickname"] == nil)
    #expect(toasts.map(\.1) == [.error])
    #expect(viewModel.rowDetail == nil)
    #expect(!viewModel.isRightSidebarVisible)
  }

  @Test("A sent edit of the open editor row becomes its originals")
  func sentEditBecomesOriginals() throws {
    let viewModel = makeEditorViewModel()
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "31"
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = "hi"
    viewModel.applyRowDetail()
    let edit = try #require(viewModel.pendingInlineEdit)

    viewModel.rowDetailSent(edit, target: try #require(result.editTarget))

    #expect(!viewModel.rowDetailHasChanges)
    #expect(viewModel.rowDetail?.fields[1].original == .int(31))
    #expect(viewModel.rowDetail?.fields[2].original == .string("hi"))
    #expect(viewModel.rowDetail?.rowData["age"] == .int(31))
    viewModel.cancelRowDetailEdits()
    #expect(viewModel.rowDetail?.fields[1].text == "31")
  }

  @Test("A sent empty text over NULL becomes an empty original, not NULL")
  func sentEmptyTextOverNullStaysNonNull() throws {
    let viewModel = makeEditorViewModel()
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[2].isNull = false
    viewModel.rowDetail?.fields[2].text = ""
    viewModel.applyRowDetail()
    let edit = try #require(viewModel.pendingInlineEdit)

    viewModel.rowDetailSent(edit, target: try #require(result.editTarget))

    #expect(!viewModel.rowDetailHasChanges)
    #expect(viewModel.rowDetail?.fields[2].isNull == false)
    #expect(viewModel.rowDetail?.fields[2].original == .string(""))
    #expect(viewModel.rowDetail?.rowData["nickname"] == .string(""))
  }

  @Test("A sent edit of another row leaves the panel's drafts")
  func sentEditOfAnotherRowKeepsDrafts() throws {
    let viewModel = makeEditorViewModel()
    let result = viewModel.editorResult!
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "31"
    viewModel.applyRowDetail()
    let edit = try #require(viewModel.pendingInlineEdit)
    viewModel.showRowDetail(row: result.rows[1], originalRow: 1, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "31"

    viewModel.rowDetailSent(edit, target: try #require(result.editTarget))

    #expect(viewModel.rowDetailHasChanges)
    #expect(viewModel.rowDetail?.fields[1].original == .int(40))
  }

  // MARK: - Sync

  @Test("A new result rebuilds the panel from the same primary key, drafts cleared")
  func syncRebuildsByPrimaryKey() {
    let viewModel = makeViewModel()
    let result = makeResult()
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "99"
    let moved = makeResult(rows: [
      [.int(2), .int(40), .string("bo"), .string("bo-2")],
      [.int(1), .int(31), .null, .string("ana-1")],
    ])

    viewModel.syncRowDetail(cellId: nil, result: moved)

    #expect(viewModel.rowDetail?.originalRow == 1)
    #expect(viewModel.rowDetail?.rowNumber == 2)
    #expect(viewModel.rowDetail?.fields[1].original == .int(31))
    #expect(viewModel.rowDetail?.fields[1].text == "31")
    #expect(!viewModel.rowDetailHasChanges)
    #expect(viewModel.cellDetailRow == 1)
  }

  @Test("A result of another cell leaves the panel as it is")
  func syncIgnoresOtherCell() {
    let viewModel = makeViewModel()
    let result = makeResult()
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    viewModel.rowDetail?.fields[1].text = "99"
    let before = viewModel.rowDetail
    let changed = makeResult(rows: [[.int(1), .int(31), .null, .string("ana-1")]])

    viewModel.syncRowDetail(cellId: UUID(), result: changed)

    #expect(viewModel.rowDetail == before)
  }

  @Test("A new result drops the panel of a staged insert that is no longer staged")
  func syncDropsGoneStagedInsert() {
    let viewModel = makeViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = makeResult()
    viewModel.editorResult = result
    #expect(viewModel.stageInsert(values: ["id": .int(7)]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 2, result: result, cellId: nil)

    viewModel.dataViewer?.changeSet = nil
    viewModel.syncRowDetail(cellId: nil, result: result)

    #expect(viewModel.rowDetail == nil)
  }

  @Test("A new result keeps a staged insert by its id, at its current position")
  func syncFollowsStagedInsert() {
    let viewModel = makeViewModel()
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = makeResult()
    viewModel.editorResult = result
    #expect(viewModel.stageInsert(values: ["id": .int(7)]) == nil)
    #expect(viewModel.stageInsert(values: ["id": .int(8)]) == nil)
    viewModel.showRowDetail(row: [], originalRow: 3, result: result, cellId: nil)
    #expect(viewModel.revertStaged(rows: [2]) == nil)

    viewModel.syncRowDetail(cellId: nil, result: result)

    #expect(viewModel.rowDetail?.originalRow == 2)
    #expect(viewModel.rowDetail?.fields[0].original == .int(8))
  }

  // MARK: - Helpers

  private func makeViewModel() -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    return viewModel
  }

  /// Editor tab showing `makeResult()` (live target), confirm commit style
  private func makeEditorViewModel() -> NotebookViewModel {
    let viewModel = makeViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig?.applyCommitStyle(.confirm)
    viewModel.editorResult = makeResult()
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }

  /// users(id PK, age, nickname, slug generated), two loaded rows unless `rows` is given
  private func makeResult(rows: [[CellValue]]? = nil) -> CellResult {
    let columns = [("id", "int4"), ("age", "int4"), ("nickname", "text"), ("slug", "text")]
    return CellResult(
      columns: columns.enumerated().map { index, column in
        ColumnInfo(
          name: column.0, type: column.1,
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: index + 1))
      },
      rows: rows ?? [
        [.int(1), .int(30), .null, .string("ana-1")],
        [.int(2), .int(40), .string("bo"), .string("bo-2")],
      ],
      rowCount: rows?.count ?? 2,
      tableName: "users",
      primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
        updateOnly: true, schema: "public", name: "users", generatedColumns: ["slug"]))
  }
}
