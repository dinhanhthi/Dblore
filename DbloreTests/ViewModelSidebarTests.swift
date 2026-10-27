// ViewModelSidebarTests.swift
// Tests for sidebar, connection state, and notebook metadata

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Sidebar Tests")
@MainActor
struct ViewModelSidebarTests {

  // Helper to create a test notebook
  func createTestNotebook() -> DbloreNotebook {
    DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: UUID(),
          cellType: .sql,
          content: "SELECT 1;",
          executionCount: 0,
          result: nil
        )
      ],
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Test Notebook"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )
  }

  // MARK: - Sidebar Tests

  // Note: Left sidebar is now owned by WorkspaceManager, not NotebookViewModel
  // The test for toggleLeftSidebar() has been removed as the functionality moved to WorkspaceManager

  // Note: Settings is now a modal at workspace level, not in the right sidebar
  // The test for showSettings() has been removed as the functionality moved to WorkspaceManager

  // MARK: - Connection State Tests

  // MARK: - Notebook Metadata Tests

  @Test("A JSON cell shown from a sorted grid shows its original row number in the path")
  func gridJSONPathUsesOriginalRow() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "doc", type: "jsonb")],
      rows: [[.int(1), .json("{\"a\":1}")], [.int(3), .json("{\"a\":3}")], [.int(2), .null]],
      rowCount: 3)
    let coordinator = ResultGridCoordinator()
    coordinator.update(NSTableView(), result: result, sortColumn: "id", ascending: false)
    coordinator.onShowCellDetails = { row, originalRow, column, _ in
      viewModel.showGridCellInSidebar(
        row: row, originalRow: originalRow, column: column, result: result, cellId: nil)
    }
    // Displayed row 0 of the descending sort is original row 1 (id 3)
    coordinator.showCellDetails(row: 0, column: 1)
    #expect(
      viewModel.rightSidebarContent == .jsonViewer(json: "{\"a\":3}", path: "Row 2, Column 'doc'"))
  }

  @Test("A JSON cell over the highlight limit opens raw in Cell Value, not the JSON viewer")
  func largeGridJSONOpensCellValue() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let padding = CellInfoContent.maxHighlightedBytes - 4
    let atLimit = "[\"" + String(repeating: "a", count: padding) + "\"]"
    let overLimit = "[\"" + String(repeating: "a", count: padding + 1) + "\"]"
    let result = CellResult(
      columns: [ColumnInfo(name: "doc", type: "jsonb")],
      rows: [[.json(atLimit)], [.json(overLimit)]], rowCount: 2)
    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: 0, result: result, cellId: nil)
    #expect(
      viewModel.rightSidebarContent == .jsonViewer(json: atLimit, path: "Row 1, Column 'doc'"))
    viewModel.showGridCellInSidebar(
      row: result.rows[1], originalRow: 1, column: 0, result: result, cellId: nil)
    guard case .cellInfo(_, _, let value, _, _, _, _) = viewModel.rightSidebarContent else {
      Issue.record("expected Cell Value, got \(String(describing: viewModel.rightSidebarContent))")
      return
    }
    #expect(value == .json(overLimit))
  }

  @Test("Row details shown from a sorted grid open the original row with its key")
  func gridRowDetailsUseOriginalRow() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let result = makeUsersResult()
    let cellId = UUID()
    let coordinator = ResultGridCoordinator()
    coordinator.update(NSTableView(), result: result, sortColumn: "id", ascending: false)
    coordinator.onShowRowDetails = { row, originalRow in
      viewModel.showRowDetail(row: row, originalRow: originalRow, result: result, cellId: cellId)
    }
    // Displayed row 0 of the descending sort is original row 1 (id 3)
    coordinator.showRowDetails(row: 0)
    #expect(viewModel.rightSidebarContent == .rowDetail(cellId: cellId))
    #expect(viewModel.isRightSidebarVisible)
    #expect(viewModel.rowDetail?.originalRow == 1)
    #expect(viewModel.rowDetail?.rowNumber == 2)
    #expect(viewModel.rowDetail?.keyPairs == [RowDetailKey(name: "id", value: .int(3))])
    #expect(viewModel.rowDetail?.fields.map(\.original) == [.int(3), .string("cy")])
  }

  @Test("Row details shown on a staged insert row of the data viewer read the change set")
  func gridRowDetailsOfStagedInsert() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    let result = makeUsersResult()
    viewModel.editorResult = result
    #expect(viewModel.stageInsert(values: ["id": .int(7), "name": .string("new")]) == nil)
    let coordinator = ResultGridCoordinator()
    coordinator.update(
      NSTableView(), result: result, sortColumn: nil, ascending: true,
      changeSet: viewModel.dataViewer?.changeSet)
    coordinator.onShowRowDetails = { row, originalRow in
      viewModel.showRowDetail(row: row, originalRow: originalRow, result: result, cellId: nil)
    }
    // The staged insert is appended after the three loaded rows
    coordinator.showRowDetails(row: 3)
    let insertID = viewModel.dataViewer?.changeSet?.inserts.first?.tempID
    #expect(insertID != nil)
    #expect(viewModel.rowDetail?.stagedInsertID == insertID)
    #expect(viewModel.rowDetail?.originalRow == 3)
    #expect(viewModel.rowDetail?.fields.map(\.original) == [.int(7), .string("new")])
    #expect(viewModel.rightSidebarContent == .rowDetail(cellId: nil))
  }

  /// users(id PK, name) with an edit target, rows id 1, 3, 2
  private func makeUsersResult() -> CellResult {
    let usersID = TableRef("users")
    return CellResult(
      columns: [("id", "int4"), ("name", "text")].enumerated().map { index, column in
        ColumnInfo(
          name: column.0, type: column.1,
          origin: ColumnOrigin(tableID: usersID, columnOrdinal: index + 1))
      },
      rows: [[.int(1), .string("ana")], [.int(3), .string("cy")], [.int(2), .string("bo")]],
      rowCount: 3,
      tableName: "users",
      primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: usersID, primaryKeyColumns: ["id"],
        updateOnly: true, schema: "public", name: "users"))
  }
}
