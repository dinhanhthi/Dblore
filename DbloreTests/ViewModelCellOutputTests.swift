// ViewModelCellOutputTests.swift
// Tests for cell output clearing and running state

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Cell Output Tests")
@MainActor
struct ViewModelCellOutputTests {

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

  // MARK: - Clear Outputs Tests

  @Test("Clear all cell outputs")
  func clearAllOutputs() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Add results to cells
    for i in 0..<viewModel.notebook.cells.count {
      viewModel.notebook.cells[i].result = CellResult(
        columns: [ColumnInfo(name: "id", type: "integer")],
        rows: [[.int(1)]],
        executionTime: 0.1,
        timestamp: Date(),
        error: nil
      )
      viewModel.notebook.cells[i].executionCount = 5
    }

    // Act
    viewModel.clearAllOutputs()

    // Assert
    for cell in viewModel.notebook.cells {
      #expect(cell.result == nil)
      #expect(cell.executionCount == nil)
    }
  }

  @Test("Clear single cell output")
  func clearSingleCellOutput() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].result = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: [[.int(1)]],
      executionTime: 0.1,
      timestamp: Date(),
      error: nil
    )
    viewModel.notebook.cells[0].executionCount = 3

    // Act
    viewModel.clearCellOutput(id: cellId)

    // Assert
    #expect(viewModel.notebook.cells[0].result == nil)
    #expect(viewModel.notebook.cells[0].executionCount == nil)
  }

  // MARK: - Running State Tests

  @Test("Cell running state defaults to false")
  func cellRunningStateDefaultsToFalse() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Assert
    #expect(viewModel.notebook.cells[0].isRunning == false)
  }

  @Test("Set cell running state directly")
  func setCellRunningState() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act
    viewModel.notebook.cells[0].isRunning = true

    // Assert
    #expect(viewModel.notebook.cells[0].isRunning == true)

    // Act
    viewModel.notebook.cells[0].isRunning = false

    // Assert
    #expect(viewModel.notebook.cells[0].isRunning == false)
  }
}
