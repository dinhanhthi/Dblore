// ViewModelReadOnlyTests.swift
// Tests for Read-Only Mode functionality

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Read-Only Mode Tests")
@MainActor
struct ViewModelReadOnlyTests {

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

  // MARK: - Read-Only Mode Blocking Tests

  @Test("Read-only mode blocks UPDATE query")
  func readOnlyModeBlocksUpdateQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

    // Set connection config with read-only mode enabled
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

    // Ensure SafeMode is alertRead (only confirms modification queries, not SELECT)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should not show error toast or confirmation dialog for SELECT
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    // Note: Toast may not be set to error (it could be nil or info)
    if let toast = viewModel.toastState.currentToast {
      #expect(toast.type != .error)
    }

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Read-only mode disabled allows UPDATE query")
  func readOnlyModeDisabledAllowsUpdateQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

    // Set connection config with read-only mode disabled
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .none)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

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
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.toastState.currentToast?.type == .error)
  }

  // MARK: - ConnectionConfig Protection Level Property Tests

  @Test("ConnectionConfig protectionLevel property defaults to none")
  func connectionConfigProtectionLevelDefaultsToNone() {
    // Arrange & Act
    let config = ConnectionConfig()

    // Assert
    #expect(config.protectionLevel == .none)
    #expect(config.isReadOnly == false)
  }

  @Test("ConnectionConfig protectionLevel can be set to readOnly")
  func connectionConfigProtectionLevelCanBeSetToReadOnly() {
    // Arrange & Act
    let config = ConnectionConfig(protectionLevel: .readOnly)

    // Assert
    #expect(config.protectionLevel == .readOnly)
    #expect(config.isReadOnly == true)
  }

  @Test("ConnectionConfig protectionLevel can be set to schemaOnly")
  func connectionConfigProtectionLevelCanBeSetToSchemaOnly() {
    // Arrange & Act
    let config = ConnectionConfig(protectionLevel: .schemaOnly)

    // Assert
    #expect(config.protectionLevel == .schemaOnly)
    #expect(config.isReadOnly == false)
    #expect(config.blocksSchemaChanges == true)
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
}
