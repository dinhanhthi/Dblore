// ViewModelPerformanceTests.swift
// Performance tests for ViewModel operations

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Performance Tests")
@MainActor
struct ViewModelPerformanceTests {

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

  // MARK: - Performance Tests

  @Test("Add cell performance", .timeLimit(.minutes(1)))
  func addCellPerformance() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    for _ in 0..<100 {
      viewModel.addCell(type: .sql, after: nil)
    }
  }

  @Test("Delete cell performance", .timeLimit(.minutes(1)))
  func deleteCellPerformance() {
    // Arrange - Create 100 cells
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    for _ in 0..<100 {
      viewModel.addCell(type: .sql, after: nil)
    }

    // Act
    let cellIds = viewModel.notebook.cells.map { $0.id }
    for cellId in cellIds {
      viewModel.deleteCell(id: cellId)
    }
  }

  @Test(
    "Grid data source for 10,000 x 20 builds under 200 ms, sorted too",
    .timeLimit(.minutes(1)))
  func resultGridBuildPerformance() {
    let columns = (0..<20).map { ColumnInfo(name: "c\($0)", type: "text") }
    let rows = (0..<10_000).map { row in
      (0..<20).map { column in column == 0 ? CellValue.int(row % 997) : .string("r\(row)c\(column)")
      }
    }
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()

    let elapsed = ContinuousClock().measure {
      coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
      #expect(coordinator.numberOfRows(in: tableView) == 10_000)
      coordinator.update(tableView, result: result, sortColumn: "c0", ascending: false)
      #expect(coordinator.numberOfRows(in: tableView) == 10_000)
    }
    #expect(elapsed < .milliseconds(200), "took \(elapsed)")
  }
}
