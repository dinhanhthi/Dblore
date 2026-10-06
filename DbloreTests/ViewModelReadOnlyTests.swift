// ViewModelReadOnlyTests.swift
// Tests for Read-Only Mode functionality

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Read-Only Mode Tests")
@MainActor
struct ViewModelReadOnlyTests {

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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
  }

  @Test("Read-only mode allows SELECT query")
  func readOnlyModeAllowsSelectQuery() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"

    // confirm does not list SELECT. protectedMode stays off so the style is not forced to review.
    var config = ConnectionConfig(protectionLevel: .readOnly, protectedMode: false)
    config.applyCommitStyle(.confirm)
    viewModel.notebook.connectionConfig = config

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should not show error toast or confirmation dialog for SELECT
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    // Note: Toast may not be set to error (it could be nil or info)
    if let toast = WorkspaceWindowManager.shared.toastState.currentToast {
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

    // Unprotected confirm: a review candidate is not used, so the UPDATE still asks.
    var config = ConnectionConfig(protectionLevel: .none, protectedMode: false)
    config.applyCommitStyle(.confirm)
    viewModel.notebook.connectionConfig = config

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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

    // Act - reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Should show toast error, not dialog
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
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

  // MARK: - Gate-based blocking (replaces prefix-based isBlockedInReadOnlyMode)

  func isBlockedInReadOnlyMode(_ query: String) -> Bool {
    let decision = DatabaseConnectionManager.evaluate(
      SQLStatementClassifier.classify(query), policy: ProtectionPolicy(protectionLevel: .readOnly))
    return decision != .allowed
  }

  @Test("Read-only gate blocks modification queries")
  func readOnlyGateBlocksModificationQueries() {
    #expect(isBlockedInReadOnlyMode("UPDATE users SET name = 'x'"))
    #expect(isBlockedInReadOnlyMode("DELETE FROM users"))
    #expect(isBlockedInReadOnlyMode("INSERT INTO users VALUES (1)"))
    #expect(isBlockedInReadOnlyMode("DROP TABLE users"))
    #expect(isBlockedInReadOnlyMode("TRUNCATE TABLE users"))
    #expect(isBlockedInReadOnlyMode("ALTER TABLE users ADD COLUMN age INT"))
  }

  @Test("Read-only gate blocks CREATE query")
  func readOnlyGateBlocksCreateQuery() {
    #expect(isBlockedInReadOnlyMode("CREATE TABLE users (id INT)"))
    #expect(isBlockedInReadOnlyMode("CREATE INDEX idx ON users(name)"))
    #expect(isBlockedInReadOnlyMode("CREATE VIEW user_view AS SELECT * FROM users"))
  }

  @Test("Read-only gate allows SELECT query")
  func readOnlyGateAllowsSelectQuery() {
    #expect(!isBlockedInReadOnlyMode("SELECT * FROM users"))
    #expect(!isBlockedInReadOnlyMode("SELECT id, name FROM users WHERE id = 1"))
  }

  @Test("Read-only gate allows EXPLAIN but blocks EXPLAIN ANALYZE (it executes the statement)")
  func readOnlyGateExplain() {
    #expect(!isBlockedInReadOnlyMode("EXPLAIN SELECT * FROM users"))
    #expect(isBlockedInReadOnlyMode("EXPLAIN ANALYZE SELECT * FROM users"))
    #expect(isBlockedInReadOnlyMode("EXPLAIN ANALYZE DELETE FROM users"))
  }

  @Test("Read-only gate blocks a modification hidden after a SELECT or a comment")
  func readOnlyGateBlocksHiddenStatements() {
    #expect(isBlockedInReadOnlyMode("SELECT 1; DROP TABLE t"))
    #expect(isBlockedInReadOnlyMode("-- harmless\nDELETE FROM users"))
    #expect(isBlockedInReadOnlyMode("/* SELECT */ UPDATE users SET a = 1"))
  }

  @Test("Read-only mode blocks a cell with a hidden DROP (toast, no dialog)")
  func readOnlyModeBlocksHiddenDropInCell() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT 1; DROP TABLE t"
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)

    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("statement 2") == true
    )
  }

  @Test("Schema-only mode blocks DDL in a cell (toast, no dialog)")
  func schemaOnlyModeBlocksDDLInCell() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE t SET a = 1 WHERE id = 1; DROP TABLE t"
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .schemaOnly)

    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
  }
}
