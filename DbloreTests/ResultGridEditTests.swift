// ResultGridEditTests.swift
// Inline edit in the NSTableView grid: a commit delivers the displayed (sorted) row to the view
// model's handleCellValueEdit path; results that canEdit refuses (no PK, read-only) never edit.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Result grid - inline edit")
@MainActor
struct ResultGridEditTests {
  private let cellId = UUID()

  private func makeResult(primaryKeyColumns: [String]) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      rows: [[.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .string("b")]],
      rowCount: 3, sourceQuery: "SELECT * FROM users", tableName: "public.users",
      primaryKeyColumns: primaryKeyColumns,
      editTarget: EditTarget(
        qualifiedName: "public.users", oid: 16_400, primaryKeyColumns: primaryKeyColumns))
  }

  private func makeViewModel(result: CellResult, config: ConnectionConfig) -> NotebookViewModel {
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM users", executionCount: 1,
          result: result)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Grid edit"),
      connectionConfig: config, settings: NotebookSettings())
    return NotebookViewModel(notebook: notebook)
  }

  /// Grid sorted by id ascending, editable per the view model's canEdit, committing to the VM
  private func makeGrid(
    _ viewModel: NotebookViewModel, result: CellResult
  ) -> (ResultGridCoordinator, NSTableView) {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.isEditable = viewModel.canEdit(result)
    coordinator.onCommitEdit = { [cellId] row, column, newValue in
      viewModel.handleGridCellEdit(
        row: row, column: column, newValue: newValue, result: result, cellId: cellId,
        connectionManager: DatabaseConnectionManager())
    }
    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    return (coordinator, tableView)
  }

  @Test("A commit on a sorted grid reaches handleCellValueEdit with the displayed row's key")
  func commitReachesHandleCellValueEdit() {
    let result = makeResult(primaryKeyColumns: ["id"])
    let viewModel = makeViewModel(
      result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    let (coordinator, _) = makeGrid(viewModel, result: result)
    #expect(coordinator.isEditable)

    // Unchanged text sends nothing
    coordinator.commitEdit(row: 0, column: 1, newValue: "a")
    #expect(viewModel.rightSidebarContent == nil)

    // Displayed row 0 is id 1 (result.rows[1]), not result.rows[0] (id 3)
    coordinator.commitEdit(row: 0, column: 1, newValue: "new")
    guard case .cellInfo(_, _, let value, _, let rowData, _, _) = viewModel.rightSidebarContent
    else {
      Issue.record("the edit did not reach handleCellValueEdit")
      return
    }
    #expect(value == .string("new"))
    #expect(rowData?["id"] == .int(1))
  }

  @Test(
    "No primary key or a read-only connection: the grid refuses to edit",
    arguments: [
      (["id"], ConnectionProtectionLevel.readOnly), ([String](), ConnectionProtectionLevel.none),
    ])
  func notEditable(primaryKeyColumns: [String], protectionLevel: ConnectionProtectionLevel) {
    let result = makeResult(primaryKeyColumns: primaryKeyColumns)
    let viewModel = makeViewModel(
      result: result,
      config: ConnectionConfig(protectionLevel: protectionLevel, safeMode: .alertRead))
    let (coordinator, tableView) = makeGrid(viewModel, result: result)
    #expect(coordinator.isEditable == false)
    #expect(coordinator.beginEditing(tableView, row: 0, column: 1) == false)

    var delivered = false
    coordinator.onCommitEdit = { _, _, _ in delivered = true }
    coordinator.commitEdit(row: 0, column: 1, newValue: "new")
    #expect(delivered == false)
  }

  @Test("A data-viewer commit stages the edit and skips the immediate update")
  func dataViewerCommitStagesInsteadOfImmediateUpdate() {
    let result = makeResult(primaryKeyColumns: ["id"])
    let viewModel = makeViewModel(
      result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = result

    viewModel.handleGridCellEdit(
      row: [.int(1), .string("a")], column: 1, newValue: "neo", result: result, cellId: nil,
      connectionManager: DatabaseConnectionManager())

    let key = RowChangeSet.RowKey(values: [.int(1)])
    #expect(viewModel.dataViewer?.changeSet?.edits[key]?["name"] == .string("neo"))
    #expect(viewModel.rightSidebarContent == nil)
  }
}
