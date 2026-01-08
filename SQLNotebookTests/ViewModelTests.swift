// ViewModelTests.swift
// Unit tests for NotebookViewModel business logic
// Converted to Swift Testing framework

import Testing
@testable import SQLNotebook
import Foundation

@Suite("ViewModel Tests")
@MainActor
struct ViewModelTests {

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

    // MARK: - Cell Management Tests

    @Test("Add cell to notebook")
    func addCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.addCell(type: .sql, after: nil)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 1)
        #expect(viewModel.notebook.cells.last?.cellType == .sql)
        #expect(viewModel.notebook.cells.last?.content == "")
    }

    @Test("Add cell after specific cell")
    func addCellAfterSpecificCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let firstCellId = viewModel.notebook.cells[0].id
        viewModel.addCell(type: .sql, after: nil) // Add a second cell
        let initialCount = viewModel.notebook.cells.count

        // Act
        viewModel.addCell(type: .sql, after: firstCellId)

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 1)
        // New cell should be at index 1 (right after first cell)
        #expect(viewModel.notebook.cells[1].cellType == .sql)
    }

    @Test("Delete cell from notebook")
    func deleteCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.addCell(type: .sql, after: nil)
        viewModel.addCell(type: .sql, after: nil)
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
        viewModel.addCell(type: .sql, after: nil) // Cell 1
        viewModel.addCell(type: .sql, after: nil) // Cell 2
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
        viewModel.selectedCellId = cellId

        // Assert
        #expect(viewModel.selectedCellId == cellId)
    }

    @Test("Deselect cell")
    func deselectCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.selectedCellId = cellId
        #expect(viewModel.selectedCellId != nil)

        // Act
        viewModel.selectedCellId = nil

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

    // MARK: - Sidebar Tests

    @Test("Toggle right sidebar")
    func toggleRightSidebar() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let initialState = viewModel.isRightSidebarVisible

        // Act
        viewModel.toggleSidebar()

        // Assert
        #expect(viewModel.isRightSidebarVisible == !initialState)

        // Act again
        viewModel.toggleSidebar()

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

    @Test("Show connection details in sidebar")
    func showSidebarContent() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act
        viewModel.showConnectionDetails()

        // Assert
        #expect(viewModel.isRightSidebarVisible == true)
        #expect(viewModel.rightSidebarContent == .connectionDetails)
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
    }

    @Test("Notebook settings accessible")
    func notebookSettings() {
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Just verify settings exists and has keyboardShortcuts
        #expect(viewModel.notebook.settings.keyboardShortcuts.isEmpty == true)
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
            viewModel.addCell(type: .sql, after: nil)
        }

        // Assert
        #expect(viewModel.notebook.cells.count == initialCount + 10)
    }

    @Test("Delete all cells keeps at least one")
    func deleteAllCells() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.addCell(type: .sql, after: nil)
        viewModel.addCell(type: .sql, after: nil)

        // Act - Try to delete all cells
        let cellIds = viewModel.notebook.cells.map { $0.id }
        for cellId in cellIds {
            viewModel.deleteCell(id: cellId)
        }

        // Assert - Should keep at least 1 cell (business logic)
        #expect(viewModel.notebook.cells.count == 1)
    }

    // MARK: - Edge Cases

    @Test("Add cell to empty notebook")
    func addCellToEmptyNotebook() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        viewModel.notebook.cells = []

        // Act
        viewModel.addCell(type: .sql, after: nil)

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
        viewModel.selectedCellId = nonExistentId

        // Assert
        #expect(viewModel.selectedCellId == nonExistentId)
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

    // MARK: - Query Confirmation Tests (Phase 6.0.3)

    @Test("Detect UPDATE query as modification")
    func detectUpdateQueryAsModification() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act & Assert
        #expect(viewModel.isModificationQuery("UPDATE users SET name = 'John' WHERE id = 1"))
        #expect(viewModel.isModificationQuery("  UPDATE users SET name = 'John'  "))
        #expect(viewModel.isModificationQuery("update users SET name = 'John'"))
    }

    @Test("Detect DELETE query as modification")
    func detectDeleteQueryAsModification() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act & Assert
        #expect(viewModel.isModificationQuery("DELETE FROM users WHERE id = 1"))
        #expect(viewModel.isModificationQuery("  DELETE FROM users  "))
        #expect(viewModel.isModificationQuery("delete from users"))
    }

    @Test("Detect INSERT query as modification")
    func detectInsertQueryAsModification() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act & Assert
        #expect(viewModel.isModificationQuery("INSERT INTO users (name) VALUES ('John')"))
        #expect(viewModel.isModificationQuery("  INSERT INTO users VALUES (1, 'John')  "))
        #expect(viewModel.isModificationQuery("insert into users (name) values ('John')"))
    }

    @Test("SELECT query is not a modification")
    func selectQueryIsNotModification() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act & Assert
        #expect(!viewModel.isModificationQuery("SELECT * FROM users"))
        #expect(!viewModel.isModificationQuery("  SELECT id, name FROM users WHERE id = 1  "))
        #expect(!viewModel.isModificationQuery("select * from users"))
    }

    @Test("Other queries are not modifications")
    func otherQueriesAreNotModifications() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)

        // Act & Assert
        #expect(!viewModel.isModificationQuery("CREATE TABLE users (id INT)"))
        #expect(!viewModel.isModificationQuery("DROP TABLE users"))
        #expect(!viewModel.isModificationQuery("ALTER TABLE users ADD COLUMN age INT"))
        #expect(!viewModel.isModificationQuery("TRUNCATE TABLE users"))
    }

    @Test("Confirm and run shows dialog for UPDATE query")
    func confirmAndRunShowsDialogForUpdate() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert
        #expect(viewModel.showQueryConfirmationDialog == true)
        #expect(viewModel.pendingQueryCellId == cellId)
        #expect(viewModel.pendingQuery == "UPDATE users SET name = 'John'")
    }

    @Test("Confirm and run shows dialog for DELETE query")
    func confirmAndRunShowsDialogForDelete() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert
        #expect(viewModel.showQueryConfirmationDialog == true)
        #expect(viewModel.pendingQueryCellId == cellId)
        #expect(viewModel.pendingQuery == "DELETE FROM users WHERE id = 1")
    }

    @Test("Confirm and run shows dialog for INSERT query")
    func confirmAndRunShowsDialogForInsert() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert
        #expect(viewModel.showQueryConfirmationDialog == true)
        #expect(viewModel.pendingQueryCellId == cellId)
        #expect(viewModel.pendingQuery == "INSERT INTO users (name) VALUES ('John')")
    }

    @Test("Confirm and run executes directly for SELECT query")
    func confirmAndRunExecutesDirectlyForSelect() async {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "SELECT * FROM users"

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - No dialog should be shown for SELECT
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")
    }

    @Test("Cancel pending query clears state")
    func cancelPendingQueryClearsState() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "DELETE FROM users"
        viewModel.confirmAndRunCell(id: cellId)
        #expect(viewModel.showQueryConfirmationDialog == true)

        // Act
        viewModel.cancelPendingQuery()

        // Assert
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")
    }

    @Test("Confirm and run with non-existent cell does nothing")
    func confirmAndRunWithNonExistentCell() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let nonExistentId = UUID()

        // Act
        viewModel.confirmAndRunCell(id: nonExistentId)

        // Assert - Nothing should happen
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")
    }

    // MARK: - Bypass Confirmation Setting Tests

    @Test("Bypass confirmation setting defaults to false")
    func bypassConfirmationDefaultsToFalse() {
        // Arrange & Assert
        #expect(AppSettings.shared.bypassDestructiveQueryConfirmation == false)
    }

    @Test("Bypass confirmation when enabled executes UPDATE directly")
    func bypassConfirmationExecutesUpdateDirectly() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

        // Enable bypass
        AppSettings.shared.bypassDestructiveQueryConfirmation = true

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - No dialog should be shown
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")

        // Cleanup
        AppSettings.shared.bypassDestructiveQueryConfirmation = false
    }

    @Test("Bypass confirmation when enabled executes DELETE directly")
    func bypassConfirmationExecutesDeleteDirectly() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"

        // Enable bypass
        AppSettings.shared.bypassDestructiveQueryConfirmation = true

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - No dialog should be shown
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")

        // Cleanup
        AppSettings.shared.bypassDestructiveQueryConfirmation = false
    }

    @Test("Bypass confirmation when enabled executes INSERT directly")
    func bypassConfirmationExecutesInsertDirectly() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"

        // Enable bypass
        AppSettings.shared.bypassDestructiveQueryConfirmation = true

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - No dialog should be shown
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.pendingQuery == "")

        // Cleanup
        AppSettings.shared.bypassDestructiveQueryConfirmation = false
    }

    @Test("Bypass confirmation when disabled shows dialog for UPDATE")
    func bypassConfirmationDisabledShowsDialogForUpdate() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

        // Ensure bypass is disabled
        AppSettings.shared.bypassDestructiveQueryConfirmation = false

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Dialog should be shown
        #expect(viewModel.showQueryConfirmationDialog == true)
        #expect(viewModel.pendingQueryCellId == cellId)
        #expect(viewModel.pendingQuery == "UPDATE users SET name = 'John'")

        // Cleanup
        viewModel.cancelPendingQuery()
    }

    @Test("Reset settings resets bypass confirmation to false")
    func resetSettingsResetsBypassConfirmation() {
        // Arrange
        AppSettings.shared.bypassDestructiveQueryConfirmation = true
        #expect(AppSettings.shared.bypassDestructiveQueryConfirmation == true)

        // Act
        AppSettings.shared.resetToDefaults()

        // Assert
        #expect(AppSettings.shared.bypassDestructiveQueryConfirmation == false)
    }

    // MARK: - Read-Only Mode Tests

    @Test("Read-only mode blocks UPDATE query")
    func readOnlyModeBlocksUpdateQuery() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

        // Set connection config with read-only mode enabled
        viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Should show toast error, not dialog
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.currentToast?.type == .error)
    }

    @Test("Read-only mode blocks DELETE query")
    func readOnlyModeBlocksDeleteQuery() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"

        // Set connection config with read-only mode enabled
        viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Should show toast error, not dialog
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.currentToast?.type == .error)
    }

    @Test("Read-only mode blocks INSERT query")
    func readOnlyModeBlocksInsertQuery() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"

        // Set connection config with read-only mode enabled
        viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Should show toast error, not dialog
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        #expect(viewModel.currentToast?.type == .error)
    }

    @Test("Read-only mode allows SELECT query")
    func readOnlyModeAllowsSelectQuery() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "SELECT * FROM users"

        // Set connection config with read-only mode enabled
        viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Should not show error toast or confirmation dialog for SELECT
        #expect(viewModel.showQueryConfirmationDialog == false)
        #expect(viewModel.pendingQueryCellId == nil)
        // Note: Toast may not be set to error (it could be nil or info)
        if let toast = viewModel.currentToast {
            #expect(toast.type != .error)
        }
    }

    @Test("Read-only mode disabled allows UPDATE query")
    func readOnlyModeDisabledAllowsUpdateQuery() {
        // Arrange
        let notebook = createTestNotebook()
        let viewModel = NotebookViewModel(notebook: notebook)
        let cellId = viewModel.notebook.cells[0].id
        viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

        // Set connection config with read-only mode disabled
        viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: false)

        // Disable bypass confirmation to ensure dialog is shown
        AppSettings.shared.bypassDestructiveQueryConfirmation = false

        // Act
        viewModel.confirmAndRunCell(id: cellId)

        // Assert - Should show confirmation dialog (not error)
        #expect(viewModel.showQueryConfirmationDialog == true)
        #expect(viewModel.pendingQueryCellId == cellId)

        // Cleanup
        viewModel.cancelPendingQuery()
    }

    @Test("ConnectionConfig readOnly property defaults to false")
    func connectionConfigReadOnlyDefaultsToFalse() {
        // Arrange & Act
        let config = ConnectionConfig()

        // Assert
        #expect(config.readOnly == false)
    }

    @Test("ConnectionConfig readOnly property can be set to true")
    func connectionConfigReadOnlyCanBeSetToTrue() {
        // Arrange & Act
        let config = ConnectionConfig(readOnly: true)

        // Assert
        #expect(config.readOnly == true)
    }
}
