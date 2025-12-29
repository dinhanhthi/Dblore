// ViewModelTests.swift
// Unit tests for NotebookViewModel business logic
// Converted to Swift Testing framework

import Testing
@testable import SQLNotebook
import Foundation

@Suite("ViewModel Tests")
struct ViewModelTests {

    // Helper to create a test notebook
    func createTestNotebook() -> SQLNotebook {
        SQLNotebook(
            id: UUID(),
            metadata: NotebookMetadata(
                title: "Test Notebook",
                createdAt: Date(),
                modifiedAt: Date()
            ),
            cells: [
                NotebookCell(
                    id: UUID(),
                    type: .code,
                    content: "SELECT 1;",
                    result: nil,
                    executionCount: 0
                )
            ],
            connectionConfig: nil,
            settings: NotebookSettings()
        )
    }

    // MARK: - Cell Management Tests

    @Test("Add cell to notebook")
    func addCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.addCell(type: .code, after: nil)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 1)
        #expect(viewModel.notebook.cells.last?.type == .code)
        #expect(viewModel.notebook.cells.last?.content == "")
    }

    @Test("Add cell after specific cell")
    func addCellAfterSpecificCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let firstCellId = viewModel.notebook.cells[0].id
        viewModel.addCell(type: .code, after: nil) // Add a second cell
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.addCell(type: .code, after: firstCellId)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 1)
        // New cell should be at index 1 (right after first cell)
        #expect(viewModel.notebook.cells[1].type == .code)
    }

    @Test("Delete cell from notebook")
    func deleteCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.addCell(type: .code, after: nil)
        viewModel.addCell(type: .code, after: nil)
        let cellToDelete = viewModel.notebook.cells[1].id
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.deleteCell(id: cellToDelete)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount - 1)
        #expect(!viewModel.notebook.cells.contains(where: { $0.id == cellToDelete }))
    }

    @Test("Delete non-existent cell does not crash")
    func deleteNonExistentCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialCount = viewModel.notebook.cells.count
        let nonExistentId = UUID()

        // Act
        viewModel.deleteCell(id: nonExistentId)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount)
    }

    @Test("Move cell to different position")
    func moveCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.addCell(type: .code, after: nil) // Cell 1
        viewModel.addCell(type: .code, after: nil) // Cell 2
        viewModel.notebook.cells[0].content = "First"
        viewModel.notebook.cells[1].content = "Second"
        viewModel.notebook.cells[2].content = "Third"

        // Act - Move first cell to last position
        viewModel.moveCell(from: IndexSet(integer: 0), to: 3)

        // Assert
        #expect(viewModel.notebook.cells.count == 3)
        #expect(viewModel.notebook.cells[0].content == "Second")
        #expect(viewModel.notebook.cells[1].content == "Third")
        #expect(viewModel.notebook.cells[2].content == "First")
    }

    // MARK: - Cell Selection Tests

    @Test("Select cell by ID")
    func selectCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id

        // Act
        viewModel.selectCell(id: cellId)

        // Assert
        #expect(viewModel.selectedCellId == cellId)
    }

    @Test("Deselect cell")
    func deselectCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.selectCell(id: cellId)
        #expect(viewModel.selectedCellId != nil)

        // Act
        viewModel.deselectCell()

        // Assert
        #expect(viewModel.selectedCellId == nil)
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
            #expect(cell.executionCount == 0)
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
        #expect(viewModel.notebook.cells[0].executionCount == 0)
    }

    // MARK: - Execution Count Tests

    @Test("Increment execution count")
    func incrementExecutionCount() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        let initialCount = viewModel.notebook.cells[0].executionCount

        // Act
        viewModel.incrementExecutionCount(cellId: cellId)

        // Assert
        #expect(viewModel.notebook.cells[0].executionCount == initialCount + 1)
    }

    // MARK: - Running State Tests

    @Test("Set cell running state to true")
    func setCellRunning() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id

        // Act
        viewModel.setCellRunning(cellId: cellId, isRunning: true)

        // Assert
        #expect(viewModel.runningCells.contains(cellId))
    }

    @Test("Set cell running state to false")
    func setCellNotRunning() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.setCellRunning(cellId: cellId, isRunning: true)

        // Act
        viewModel.setCellRunning(cellId: cellId, isRunning: false)

        // Assert
        #expect(!viewModel.runningCells.contains(cellId))
    }

    @Test("Check if cell is running")
    func isCellRunning() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id

        // Assert - Initially not running
        #expect(!viewModel.isCellRunning(cellId: cellId))

        // Act
        viewModel.setCellRunning(cellId: cellId, isRunning: true)

        // Assert - Now running
        #expect(viewModel.isCellRunning(cellId: cellId))
    }

    // MARK: - Sidebar Tests

    @Test("Toggle right sidebar")
    func toggleRightSidebar() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialState = viewModel.isRightSidebarVisible

        // Act
        viewModel.toggleRightSidebar()

        // Assert
        #expect(viewModel.isRightSidebarVisible == !initialState)

        // Act again
        viewModel.toggleRightSidebar()

        // Assert - Back to initial state
        #expect(viewModel.isRightSidebarVisible == initialState)
    }

    @Test("Toggle left sidebar")
    func toggleLeftSidebar() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialState = viewModel.isLeftSidebarVisible

        // Act
        viewModel.toggleLeftSidebar()

        // Assert
        #expect(viewModel.isLeftSidebarVisible == !initialState)
    }

    @Test("Show sidebar content")
    func showSidebarContent() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let content = SidebarContent.connectionInfo

        // Act
        viewModel.showSidebarContent(content)

        // Assert
        #expect(viewModel.isRightSidebarVisible == true)
        #expect(viewModel.sidebarContent == content)
    }

    // MARK: - Connection State Tests

    @Test("Connection state initially disconnected")
    func connectionStateInitiallyDisconnected() {
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        #expect(viewModel.connectionState == .disconnected)
    }

    // MARK: - Notebook Metadata Tests

    @Test("Notebook metadata accessible")
    func notebookMetadataAccessible() {
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        #expect(viewModel.notebook.metadata.title == "Test Notebook")
        #expect(viewModel.notebook.metadata.createdAt != nil)
        #expect(viewModel.notebook.metadata.modifiedAt != nil)
    }

    @Test("Notebook settings accessible")
    func notebookSettings() {
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        #expect(viewModel.notebook.settings != nil)
        #expect(viewModel.notebook.settings.maxResultTableHeight > 0)
    }

    // MARK: - Cell Content Tests

    @Test("Update cell content")
    func updateCellContent() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        let newContent = "SELECT * FROM users;"

        // Act
        if let index = viewModel.notebook.cells.firstIndex(where: { $0.id == cellId }) {
            viewModel.notebook.cells[index].content = newContent
        }

        // Assert
        #expect(viewModel.notebook.cells[0].content == newContent)
    }

    // MARK: - Multiple Cells Tests

    @Test("Add multiple cells")
    func addMultipleCells() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialCount = viewModel.notebook.cells.count

        // Act
        for _ in 0..<10 {
            viewModel.addCell(type: .code, after: nil)
        }

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 10)
    }

    @Test("Delete all cells")
    func deleteAllCells() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.addCell(type: .code, after: nil)
        viewModel.addCell(type: .code, after: nil)

        // Act
        let cellIds = viewModel.notebook.cells.map { $0.id }
        for cellId in cellIds {
            viewModel.deleteCell(id: cellId)
        }

        // Assert
        #expect(viewModel.notebook.cells.count == 0)
    }

    // MARK: - Edge Cases

    @Test("Add cell to empty notebook")
    func addCellToEmptyNotebook() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.notebook.cells = []

        // Act
        viewModel.addCell(type: .code, after: nil)

        // Assert
        #expect(viewModel.notebook.cells.count == 1)
    }

    @Test("Select non-existent cell")
    func selectNonExistentCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let nonExistentId = UUID()

        // Act
        viewModel.selectCell(id: nonExistentId)

        // Assert
        #expect(viewModel.selectedCellId == nonExistentId)
    }

    // MARK: - Performance Tests

    @Test("Add cell performance", .timeLimit(.seconds(5)))
    func addCellPerformance() {
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        for _ in 0..<100 {
            viewModel.addCell(type: .code, after: nil)
        }
    }

    @Test("Delete cell performance", .timeLimit(.seconds(5)))
    func deleteCellPerformance() {
        // Arrange - Create 100 cells
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        for _ in 0..<100 {
            viewModel.addCell(type: .code, after: nil)
        }

        // Act
        let cellIds = viewModel.notebook.cells.map { $0.id }
        for cellId in cellIds {
            viewModel.deleteCell(id: cellId)
        }
    }
}
