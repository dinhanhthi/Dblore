// ViewModelPerformanceTests.swift
// Performance tests for ViewModel operations

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Performance Tests")
@MainActor
struct ViewModelPerformanceTests {

  // Helper to create a test notebook
  func createTestNotebook() -> SQLNotebook {
    SQLNotebook(
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
}
