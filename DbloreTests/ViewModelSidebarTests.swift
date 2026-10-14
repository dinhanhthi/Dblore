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
    coordinator.onShowCellDetails = { row, originalRow, column in
      viewModel.showGridCellInSidebar(
        row: row, originalRow: originalRow, column: column, result: result, cellId: nil)
    }
    // Displayed row 0 of the descending sort is original row 1 (id 3)
    coordinator.showCellDetails(row: 0, column: 1)
    #expect(
      viewModel.rightSidebarContent == .jsonViewer(json: "{\"a\":3}", path: "Row 2, Column 'doc'"))
  }
}
