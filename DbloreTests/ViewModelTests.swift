// ViewModelTests.swift
// Unit tests for NotebookViewModel cell management business logic
// Converted to Swift Testing framework

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Cell Management Tests")
@MainActor
struct ViewModelTests {

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

  // MARK: - Schema Change Query Detection Tests

  @Test("isSchemaChangeQuery detects CREATE statements")
  func isSchemaChangeQueryDetectsCREATE() {
    #expect(isSchemaChangeQuery("CREATE TABLE users (id INT)") == true)
    #expect(isSchemaChangeQuery("create table users (id int)") == true)
    #expect(isSchemaChangeQuery("  CREATE INDEX idx ON users(id)") == true)
    #expect(isSchemaChangeQuery("CREATE VIEW v AS SELECT 1") == true)
  }

  @Test("isSchemaChangeQuery detects DROP statements")
  func isSchemaChangeQueryDetectsDROP() {
    #expect(isSchemaChangeQuery("DROP TABLE users") == true)
    #expect(isSchemaChangeQuery("drop table users cascade") == true)
    #expect(isSchemaChangeQuery("  DROP INDEX idx") == true)
    #expect(isSchemaChangeQuery("DROP VIEW v") == true)
  }

  @Test("isSchemaChangeQuery detects ALTER statements")
  func isSchemaChangeQueryDetectsALTER() {
    #expect(isSchemaChangeQuery("ALTER TABLE users ADD COLUMN name VARCHAR") == true)
    #expect(isSchemaChangeQuery("alter table users drop column name") == true)
    #expect(isSchemaChangeQuery("  ALTER INDEX idx RENAME TO idx2") == true)
  }

  @Test("isSchemaChangeQuery detects TRUNCATE statements")
  func isSchemaChangeQueryDetectsTRUNCATE() {
    #expect(isSchemaChangeQuery("TRUNCATE TABLE users") == true)
    #expect(isSchemaChangeQuery("truncate users") == true)
    #expect(isSchemaChangeQuery("  TRUNCATE users CASCADE") == true)
  }

  @Test("isSchemaChangeQuery allows SELECT and data modification queries")
  func isSchemaChangeQueryAllowsDataQueries() {
    // SELECT is allowed
    #expect(isSchemaChangeQuery("SELECT * FROM users") == false)
    #expect(isSchemaChangeQuery("select 1") == false)

    // Data modification is allowed (not schema change)
    #expect(isSchemaChangeQuery("INSERT INTO users VALUES (1)") == false)
    #expect(isSchemaChangeQuery("UPDATE users SET name = 'test'") == false)
    #expect(isSchemaChangeQuery("DELETE FROM users WHERE id = 1") == false)
  }

  // MARK: - ConnectionProtectionLevel Property Tests

  @Test("ConnectionConfig protectionLevel defaults to none")
  func connectionConfigProtectionLevelDefault() {
    let config = ConnectionConfig()
    #expect(config.protectionLevel == .none)
    #expect(config.blocksSchemaChanges == false)
  }

  @Test("ConnectionConfig protectionLevel can be set to schemaOnly")
  func connectionConfigProtectionLevelCanBeSetToSchemaOnly() {
    let config = ConnectionConfig(protectionLevel: .schemaOnly)
    #expect(config.protectionLevel == .schemaOnly)
    #expect(config.blocksSchemaChanges == true)
    #expect(config.isReadOnly == false)
  }

  @Test("ConnectionConfig with protectionLevel is Codable")
  func connectionConfigProtectionLevelCodable() throws {
    let config = ConnectionConfig(
      host: "localhost",
      port: 5432,
      database: "test",
      username: "user",
      password: "pass",
      protectionLevel: .schemaOnly
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ConnectionConfig.self, from: data)

    #expect(decoded.protectionLevel == .schemaOnly)
  }

  @Test("ConnectionConfig migrates legacy readOnly to protectionLevel")
  func connectionConfigMigrateLegacyReadOnly() throws {
    // Simulate old config with readOnly=true
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "user",
        "password": "pass",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "readOnly": true,
        "name": "Test"
      }
      """
    let data = json.data(using: .utf8)!

    let decoder = JSONDecoder()
    let config = try decoder.decode(ConnectionConfig.self, from: data)

    // Should migrate to readOnly protection level
    #expect(config.protectionLevel == .readOnly)
    #expect(config.isReadOnly == true)
  }

  @Test("ConnectionConfig migrates legacy blockSchemaChanges to protectionLevel")
  func connectionConfigMigrateLegacyBlockSchemaChanges() throws {
    // Simulate old config with blockSchemaChanges=true
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "user",
        "password": "pass",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "readOnly": false,
        "blockSchemaChanges": true,
        "name": "Test"
      }
      """
    let data = json.data(using: .utf8)!

    let decoder = JSONDecoder()
    let config = try decoder.decode(ConnectionConfig.self, from: data)

    // Should migrate to schemaOnly protection level
    #expect(config.protectionLevel == .schemaOnly)
    #expect(config.blocksSchemaChanges == true)
  }

  @Test("ConnectionConfig defaults to none for old configs without protection")
  func connectionConfigDefaultsToNoneForOldConfigs() throws {
    // Simulate old config without any protection
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "user",
        "password": "pass",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "readOnly": false,
        "name": "Test"
      }
      """
    let data = json.data(using: .utf8)!

    let decoder = JSONDecoder()
    let config = try decoder.decode(ConnectionConfig.self, from: data)

    // Should default to none for old configs
    #expect(config.protectionLevel == .none)
  }
}

/// Classifier-based replacement for the removed prefix-based `NotebookViewModel.isSchemaChangeQuery`
private func isSchemaChangeQuery(_ query: String) -> Bool {
  SQLStatementClassifier.summary(SQLStatementClassifier.classify(query)).hasSchemaChange
}
