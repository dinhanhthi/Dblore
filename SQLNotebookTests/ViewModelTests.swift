// ViewModelTests.swift
// Unit tests for NotebookViewModel business logic
// Converted to Swift Testing framework

import Foundation
import Testing

@testable import SQLNotebook

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
    viewModel.addCell(type: .sql, after: nil)  // Add a second cell
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
    viewModel.addCell(type: .sql, after: nil)  // Cell 1
    viewModel.addCell(type: .sql, after: nil)  // Cell 2
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

  @Test("Detect DROP query as modification")
  func detectDropQueryAsModification() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - DROP is a destructive schema modification
    #expect(viewModel.isModificationQuery("DROP TABLE users"))
    #expect(viewModel.isModificationQuery("DROP DATABASE mydb"))
    #expect(viewModel.isModificationQuery("DROP INDEX idx_name"))
    #expect(viewModel.isModificationQuery("DROP VIEW my_view"))
    #expect(viewModel.isModificationQuery("drop table users"))
  }

  @Test("Detect TRUNCATE query as modification")
  func detectTruncateQueryAsModification() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - TRUNCATE deletes all rows (destructive)
    #expect(viewModel.isModificationQuery("TRUNCATE TABLE users"))
    #expect(viewModel.isModificationQuery("TRUNCATE users"))
    #expect(viewModel.isModificationQuery("truncate table users"))
  }

  @Test("Detect ALTER query as modification")
  func detectAlterQueryAsModification() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - ALTER can be destructive (DROP COLUMN, etc.)
    #expect(viewModel.isModificationQuery("ALTER TABLE users ADD COLUMN age INT"))
    #expect(viewModel.isModificationQuery("ALTER TABLE users DROP COLUMN email"))
    #expect(viewModel.isModificationQuery("ALTER TABLE users RENAME TO customers"))
    #expect(viewModel.isModificationQuery("alter table users add column age int"))
  }

  @Test("CREATE and other DDL queries are not modifications")
  func createAndOtherDdlQueriesAreNotModifications() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - CREATE is not destructive (doesn't modify existing data)
    #expect(!viewModel.isModificationQuery("CREATE TABLE users (id INT)"))
    #expect(!viewModel.isModificationQuery("CREATE INDEX idx_name ON users(name)"))
    #expect(!viewModel.isModificationQuery("CREATE VIEW user_view AS SELECT * FROM users"))
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
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "UPDATE users SET name = 'John'")
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
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "DELETE FROM users WHERE id = 1")
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
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(
      viewModel.queryConfirmationState.pendingQuery == "INSERT INTO users (name) VALUES ('John')")
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")
  }

  @Test("Cancel pending query clears state")
  func cancelPendingQueryClearsState() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users"
    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog == true)

    // Act
    viewModel.cancelPendingQuery()

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")
  }

  // MARK: - Safe Mode Tests (Query Execution Behavior)

  @Test("Safe Mode defaults to alertRead")
  func safeModeDefaultsToAlertRead() {
    // Reset to default first
    AppSettings.shared.safeMode = .alertRead

    // Arrange & Assert
    #expect(AppSettings.shared.safeMode == .alertRead)
  }

  @Test("Safe Mode silent executes UPDATE directly without confirmation")
  func safeModesilentExecutesUpdateDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes DELETE directly without confirmation")
  func safeModesilentExecutesDeleteDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes INSERT directly without confirmation")
  func safeModesilentExecutesInsertDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode alertRead shows dialog for UPDATE")
  func safeModeAlertReadShowsDialogForUpdate() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertRead
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "UPDATE users SET name = 'John'")

    // Cleanup
    viewModel.cancelPendingQuery()
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode alertAll shows dialog for SELECT")
  func safeModeAlertAllShowsDialogForSelect() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertAll (confirm all queries)
    AppSettings.shared.safeMode = .alertAll

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Dialog should be shown for SELECT in alertAll mode
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "SELECT * FROM users")

    // Cleanup
    viewModel.cancelPendingQuery()
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode alertRead does NOT show dialog for SELECT")
  func safeModeAlertReadDoesNotShowDialogForSelect() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertRead
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown for SELECT in alertRead mode
    #expect(viewModel.queryConfirmationState.showDialog == false)

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Reset settings resets Safe Mode to alertRead")
  func resetSettingsResetsSafeMode() {
    // Arrange
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .silent
    #expect(AppSettings.shared.safeMode == .silent)

    // Act
    AppSettings.shared.resetToDefaults()

    // Assert
    #expect(AppSettings.shared.safeMode == .alertRead)

    // Cleanup (not strictly needed since we reset to defaults)
    AppSettings.shared.safeMode = previousSafeMode
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
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
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    // Note: Toast may not be set to error (it could be nil or info)
    if let toast = viewModel.toastState.currentToast {
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
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)

    // Cleanup
    viewModel.cancelPendingQuery()
  }

  @Test("Read-only mode blocks DROP query")
  func readOnlyModeBlocksDropQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DROP TABLE users"

    // Set connection config with read-only mode enabled
    viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
  }

  @Test("Read-only mode blocks TRUNCATE query")
  func readOnlyModeBlocksTruncateQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "TRUNCATE TABLE users"

    // Set connection config with read-only mode enabled
    viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
  }

  @Test("Read-only mode blocks ALTER query")
  func readOnlyModeBlocksAlterQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "ALTER TABLE users ADD COLUMN age INT"

    // Set connection config with read-only mode enabled
    viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
  }

  @Test("Read-only mode blocks CREATE query")
  func readOnlyModeBlocksCreateQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "CREATE TABLE new_users (id INT)"

    // Set connection config with read-only mode enabled
    viewModel.notebook.connectionConfig = ConnectionConfig(readOnly: true)

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
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

  // MARK: - isBlockedInReadOnlyMode Tests

  @Test("isBlockedInReadOnlyMode returns true for modification queries")
  func isBlockedInReadOnlyModeReturnsTrueForModificationQueries() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - All modification queries should be blocked
    #expect(viewModel.isBlockedInReadOnlyMode("UPDATE users SET name = 'x'"))
    #expect(viewModel.isBlockedInReadOnlyMode("DELETE FROM users"))
    #expect(viewModel.isBlockedInReadOnlyMode("INSERT INTO users VALUES (1)"))
    #expect(viewModel.isBlockedInReadOnlyMode("DROP TABLE users"))
    #expect(viewModel.isBlockedInReadOnlyMode("TRUNCATE TABLE users"))
    #expect(viewModel.isBlockedInReadOnlyMode("ALTER TABLE users ADD COLUMN age INT"))
  }

  @Test("isBlockedInReadOnlyMode returns true for CREATE query")
  func isBlockedInReadOnlyModeReturnsTrueForCreateQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - CREATE should be blocked in read-only mode
    #expect(viewModel.isBlockedInReadOnlyMode("CREATE TABLE users (id INT)"))
    #expect(viewModel.isBlockedInReadOnlyMode("CREATE INDEX idx ON users(name)"))
    #expect(viewModel.isBlockedInReadOnlyMode("CREATE VIEW user_view AS SELECT * FROM users"))
  }

  @Test("isBlockedInReadOnlyMode returns false for SELECT query")
  func isBlockedInReadOnlyModeReturnsFalseForSelectQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - SELECT should NOT be blocked
    #expect(!viewModel.isBlockedInReadOnlyMode("SELECT * FROM users"))
    #expect(!viewModel.isBlockedInReadOnlyMode("SELECT id, name FROM users WHERE id = 1"))
  }

  @Test("isBlockedInReadOnlyMode returns false for EXPLAIN query")
  func isBlockedInReadOnlyModeReturnsFalseForExplainQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act & Assert - EXPLAIN should NOT be blocked
    #expect(!viewModel.isBlockedInReadOnlyMode("EXPLAIN SELECT * FROM users"))
    #expect(!viewModel.isBlockedInReadOnlyMode("EXPLAIN ANALYZE SELECT * FROM users"))
  }

  // MARK: - Safe Mode Tests

  @Test("SafeMode enum has correct values")
  func safeModeEnumHasCorrectValues() {
    // Verify all 5 levels exist with correct raw values
    #expect(SafeMode.silent.rawValue == 0)
    #expect(SafeMode.alertRead.rawValue == 1)
    #expect(SafeMode.alertAll.rawValue == 2)
    #expect(SafeMode.safeRead.rawValue == 3)
    #expect(SafeMode.safeAll.rawValue == 4)
  }

  @Test("SafeMode display names are correct")
  func safeModeDisplayNamesAreCorrect() {
    #expect(SafeMode.silent.displayName == "Silent")
    #expect(SafeMode.alertRead.displayName == "Alert (Read)")
    #expect(SafeMode.alertAll.displayName == "Alert (All)")
    #expect(SafeMode.safeRead.displayName == "Safe (Read)")
    #expect(SafeMode.safeAll.displayName == "Safe (All)")
  }

  @Test("SafeMode requiresConfirmationForSelect is correct")
  func safeModeRequiresConfirmationForSelectIsCorrect() {
    // Only alertAll and safeAll require confirmation for SELECT
    #expect(SafeMode.silent.requiresConfirmationForSelect == false)
    #expect(SafeMode.alertRead.requiresConfirmationForSelect == false)
    #expect(SafeMode.alertAll.requiresConfirmationForSelect == true)
    #expect(SafeMode.safeRead.requiresConfirmationForSelect == false)
    #expect(SafeMode.safeAll.requiresConfirmationForSelect == true)
  }

  @Test("SafeMode requiresConfirmationForModification is correct")
  func safeModeRequiresConfirmationForModificationIsCorrect() {
    // All modes except silent require confirmation for modification
    #expect(SafeMode.silent.requiresConfirmationForModification == false)
    #expect(SafeMode.alertRead.requiresConfirmationForModification == true)
    #expect(SafeMode.alertAll.requiresConfirmationForModification == true)
    #expect(SafeMode.safeRead.requiresConfirmationForModification == true)
    #expect(SafeMode.safeAll.requiresConfirmationForModification == true)
  }

  @Test("SafeMode requiresPassword is correct")
  func safeModeRequiresPasswordIsCorrect() {
    // Only safeRead and safeAll require password
    #expect(SafeMode.silent.requiresPassword == false)
    #expect(SafeMode.alertRead.requiresPassword == false)
    #expect(SafeMode.alertAll.requiresPassword == false)
    #expect(SafeMode.safeRead.requiresPassword == true)
    #expect(SafeMode.safeAll.requiresPassword == true)
  }

  @Test("SafeMode allCases contains all modes")
  func safeModeAllCasesContainsAllModes() {
    let allCases = SafeMode.allCases
    #expect(allCases.count == 5)
    #expect(allCases.contains(.silent))
    #expect(allCases.contains(.alertRead))
    #expect(allCases.contains(.alertAll))
    #expect(allCases.contains(.safeRead))
    #expect(allCases.contains(.safeAll))
  }
}
