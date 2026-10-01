// RowStagingViewModelTests.swift
// Data-viewer row staging on NotebookViewModel. No database: a disconnected
// connection manager only records whether commit reached executeGatedBatch.

import Foundation
import Testing

@testable import Dblore

@Suite("Row staging view model")
@MainActor
struct RowStagingViewModelTests {
  @Test("No primary key disables staging and names the primary key")
  func noPrimaryKeyDisablesStaging() {
    let viewModel = makeViewModel(primaryKey: [])

    #expect(
      viewModel.rowStagingUnavailableReason?.contains("Table has no primary key") == true)
    #expect(viewModel.stageInsert()?.contains("Table has no primary key") == true)
    #expect(
      viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))?
        .contains("Table has no primary key") == true)
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  @Test("A staged edit's preview names the column")
  func stagedEditPreviewNamesTheColumn() {
    let viewModel = makeViewModel(primaryKey: ["id"])

    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    #expect(viewModel.previewStagedSQL().contains("nickname"))
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("Discard clears the change set")
  func discardClearsTheSet() {
    let viewModel = makeViewModel(primaryKey: ["id"])
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)

    viewModel.discardStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(viewModel.previewStagedSQL().isEmpty)
  }

  @Test("Safe Mode holds the batch until confirm, then the connection is called")
  func safeModeConfirmCallsTheConnection() async {
    let viewModel = makeViewModel(primaryKey: ["id"], epoch: 1, safeMode: .alertRead)
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    WorkspaceWindowManager.shared.dismissToast()

    await viewModel.commitStaged()

    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast == nil)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)

    await viewModel.executePendingQuery()

    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("connection changed")
        == true)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("A connection failure keeps the change set")
  func connectionFailureKeepsTheSet() async {
    let viewModel = makeViewModel(primaryKey: ["id"], epoch: 0, safeMode: .silent)
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    WorkspaceWindowManager.shared.dismissToast()

    await viewModel.commitStaged()

    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("Not connected")
        == true)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("A result whose columns name another table cannot be staged")
  func otherTableIdentityCannotBeStaged() {
    let viewModel = makeViewModel(
      primaryKey: ["id"], columnTableID: .postgresql(oid: 99))
    #expect(viewModel.rowStagingUnavailableReason == NotebookViewModel.tableHasNoPrimaryKey)
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  private static let usersID = TableRef.postgresql(oid: 1)

  private func makeViewModel(
    primaryKey: [String], epoch: UInt64 = 0, safeMode: SafeMode = .silent,
    columnTableID: TableRef = RowStagingViewModelTests.usersID
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: safeMode, protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4",
          origin: ColumnOrigin(tableID: columnTableID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: columnTableID, columnOrdinal: 2)),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: primaryKey,
        connectionEpoch: epoch, updateOnly: true))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }
}
