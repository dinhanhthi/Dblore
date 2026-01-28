// ViewModelQueryConfirmationTests.swift
// Tests for query confirmation dialog functionality (Phase 6.0.3)

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Query Confirmation Tests")
@MainActor
struct ViewModelQueryConfirmationTests {

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

  // MARK: - Modification Query Detection Tests

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

  // MARK: - Confirmation Dialog Tests

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

    // Ensure SafeMode is alertRead (only confirms modification queries, not SELECT)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown for SELECT in alertRead mode
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
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
}
