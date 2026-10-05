// RowStagingUndoTests.swift
// Undo and redo of staged data-viewer changes through NotebookViewModel.undoManager.

import Foundation
import Testing

@testable import Dblore

@Suite("Row staging undo")
@MainActor
struct RowStagingUndoTests {
  @Test("Edit Cell undo and redo restore each staged value")
  func editCellUndoRestoresEachValue() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    #expect(viewModel.undoManager.undoActionName == "Edit Cell")
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("leo"))
    }

    viewModel.undoCellChange()
    #expect(viewModel.previewStagedSQL().contains("neo"))
    #expect(viewModel.undoManager.redoActionName == "Edit Cell")
    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)

    viewModel.redoCellChange()
    #expect(viewModel.previewStagedSQL().contains("neo"))
    viewModel.redoCellChange()
    #expect(viewModel.previewStagedSQL().contains("leo"))
  }

  @Test("Add Row undo drops the staged insert")
  func addRowUndoDropsTheInsert() {
    let viewModel = makeViewModel()
    grouped(viewModel) { _ = viewModel.stageInsert(values: ["nickname": .string("neo")]) }
    #expect(viewModel.undoManager.undoActionName == "Add Row")
    #expect(viewModel.previewStagedSQL().contains("neo"))

    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)
    viewModel.redoCellChange()
    #expect(viewModel.previewStagedSQL().contains("neo"))
  }

  @Test("Delete Rows undo restores the staged delete")
  func deleteRowsUndoRestoresTheDelete() {
    let viewModel = makeViewModel()
    grouped(viewModel) { _ = viewModel.stageDelete(rows: [0]) }
    #expect(viewModel.undoManager.undoActionName == "Delete Rows")
    #expect(viewModel.previewStagedSQL().contains("DELETE"))

    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)
    viewModel.redoCellChange()
    #expect(viewModel.previewStagedSQL().contains("DELETE"))
  }

  @Test("Revert undo puts the staged edit back")
  func revertUndoRestoresTheEdit() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    grouped(viewModel) { _ = viewModel.revertStaged(rows: [0]) }
    #expect(viewModel.undoManager.undoActionName == "Revert")
    #expect(viewModel.dataViewer?.changeSet == nil)

    viewModel.undoCellChange()
    #expect(viewModel.previewStagedSQL().contains("neo"))
    #expect(viewModel.undoManager.redoActionName == "Revert")
  }

  @Test("A refused edit or a no-op revert does not register a staged action")
  func unchangedSetDoesNotRegisterUndo() {
    let viewModel = makeViewModel()
    let refused = viewModel.stageEdit(row: 0, column: "id", value: .int(9))
    #expect(refused?.contains("Primary key") == true)
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)

    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    #expect(viewModel.revertStaged(rows: []) == nil)
    #expect(viewModel.undoManager.undoActionName == "Edit Cell")
    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("Discard clears staged undo and redo")
  func discardClearsTheStack() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    viewModel.undoCellChange()
    #expect(viewModel.undoManager.canRedo)

    viewModel.discardStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
    #expect(!viewModel.undoManager.canRedo)
  }

  @Test("Invalidation clears the stack instead of staging another edit")
  func invalidationClearsTheStack() {
    let viewModel = makeViewModel()
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    viewModel.editorResult?.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
      connectionEpoch: 0, updateOnly: true)

    let reason = viewModel.stageEdit(row: 0, column: "nickname", value: .string("leo"))

    #expect(reason?.contains("table changed") == true)
    #expect(toasts.contains { $0.contains("table changed") })
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
    #expect(!viewModel.undoManager.canRedo)
  }

  @Test("Commit invalidation clears the stack and does not send")
  func commitInvalidationClearsTheStack() async {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    viewModel.editorResult?.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
      connectionEpoch: 0, updateOnly: true)

    await viewModel.commitStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("Leaving the page clears staged undo and redo")
  func leavingThePageClearsTheStack() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    viewModel.undoCellChange()
    #expect(viewModel.undoManager.canRedo)

    viewModel.dataViewer?.page = 2

    #expect(!viewModel.undoManager.canUndo)
    #expect(!viewModel.undoManager.canRedo)
  }

  @Test("Changing the filter clears staged undo")
  func changingTheFilterClearsTheStack() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }

    viewModel.dataViewer?.filter = TableFilter(
      conditions: [FilterCondition(column: "nickname", value: "neo")])

    #expect(viewModel.undoManager.canUndo == false)
  }

  @Test("A highlight or row-count change keeps staged undo")
  func samePageKeepsTheStack() {
    let viewModel = makeViewModel()
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }

    viewModel.dataViewer?.highlight = TableHighlight(
      filter: TableFilter(conditions: [FilterCondition(column: "nickname", value: "neo")]))
    viewModel.dataViewer?.totalRows = 10

    #expect(viewModel.undoManager.undoActionName == "Edit Cell")
    #expect(viewModel.previewStagedSQL().contains("neo"))
  }

  @Test("A failed commit keeps the staged undo, including a filled key")
  func failedCommitKeepsUndo() async {
    let viewModel = makeViewModel()
    grouped(viewModel) { _ = viewModel.stageInsert() }

    await viewModel.commitStaged()

    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
    #expect(viewModel.undoManager.undoActionName == "Add Row")
    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("Undo while Safe Mode is open drops the captured batch")
  func undoWhileConfirmingDropsTheBatch() async {
    let viewModel = makeViewModel()
    viewModel.notebook.connectionConfig?.safeMode = .alertRead
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("leo"))
    }

    await viewModel.commitStaged()

    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.pendingQuery.contains("leo"))

    viewModel.undoCellChange()

    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingQuery.isEmpty)
    #expect(viewModel.previewStagedSQL().contains("neo"))
    #expect(viewModel.undoManager.canRedo)

    await viewModel.executePendingQuery()

    #expect(toasts.isEmpty)
    #expect(viewModel.previewStagedSQL().contains("neo"))
    #expect(viewModel.undoManager.canRedo)
    #expect(viewModel.undoManager.redoActionName == "Edit Cell")
  }

  @Test("A successful commit clears staged undo")
  func commitSuccessClearsTheStack() async throws {
    let viewModel = makeViewModel()
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: false))
    // disconnect() inside connect advances the epoch once, then a successful open advances it again.
    let epoch = await manager.connectionEpoch
    viewModel.connectionManager = manager
    viewModel.editorResult?.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
      connectionEpoch: epoch, updateOnly: true)
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }

    await viewModel.commitStaged()

    #expect(toasts.isEmpty)
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
    #expect(!viewModel.undoManager.canRedo)
  }

  @Test("A successful import clears staged redo so it cannot target imported rows")
  func importSuccessClearsTheStack() async throws {
    let viewModel = makeViewModel()
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
        protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let epoch = await manager.connectionEpoch
    viewModel.connectionManager = manager
    grouped(viewModel) {
      _ = viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))
    }
    viewModel.undoCellChange()
    #expect(viewModel.undoManager.canRedo)

    let reason = await viewModel.beginImportBatch(
      PendingStagedBatch(
        statements: [
          BoundStatement(
            sql: "INSERT INTO public.users (nickname) VALUES ($1)", values: ["a"])
        ],
        preview: "INSERT INTO public.users (nickname) -- 1 rows from file",
        connectionEpoch: epoch, historySource: .dataImport, rowRanges: [1...1]))

    #expect(reason == nil)
    #expect(!viewModel.undoManager.canUndo)
    #expect(!viewModel.undoManager.canRedo)
  }

  private static let usersID = TableRef.postgresql(oid: 1)

  private func makeViewModel() -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.undoManager.groupsByEvent = false
    viewModel.toastPresenter = { _, _ in }
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2)),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
        connectionEpoch: 0, updateOnly: true))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }

  private func grouped(_ viewModel: NotebookViewModel, _ action: () -> Void) {
    viewModel.undoManager.beginUndoGrouping()
    action()
    viewModel.undoManager.endUndoGrouping()
  }
}
