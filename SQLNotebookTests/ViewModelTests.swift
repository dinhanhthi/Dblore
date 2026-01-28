// ViewModelTests.swift
// Unit tests for NotebookViewModel cell management business logic
// Converted to Swift Testing framework

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Cell Management Tests")
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
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.isSchemaChangeQuery("CREATE TABLE users (id INT)") == true)
    #expect(viewModel.isSchemaChangeQuery("create table users (id int)") == true)
    #expect(viewModel.isSchemaChangeQuery("  CREATE INDEX idx ON users(id)") == true)
    #expect(viewModel.isSchemaChangeQuery("CREATE VIEW v AS SELECT 1") == true)
  }

  @Test("isSchemaChangeQuery detects DROP statements")
  func isSchemaChangeQueryDetectsDROP() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.isSchemaChangeQuery("DROP TABLE users") == true)
    #expect(viewModel.isSchemaChangeQuery("drop table users cascade") == true)
    #expect(viewModel.isSchemaChangeQuery("  DROP INDEX idx") == true)
    #expect(viewModel.isSchemaChangeQuery("DROP VIEW v") == true)
  }

  @Test("isSchemaChangeQuery detects ALTER statements")
  func isSchemaChangeQueryDetectsALTER() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.isSchemaChangeQuery("ALTER TABLE users ADD COLUMN name VARCHAR") == true)
    #expect(viewModel.isSchemaChangeQuery("alter table users drop column name") == true)
    #expect(viewModel.isSchemaChangeQuery("  ALTER INDEX idx RENAME TO idx2") == true)
  }

  @Test("isSchemaChangeQuery detects TRUNCATE statements")
  func isSchemaChangeQueryDetectsTRUNCATE() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.isSchemaChangeQuery("TRUNCATE TABLE users") == true)
    #expect(viewModel.isSchemaChangeQuery("truncate users") == true)
    #expect(viewModel.isSchemaChangeQuery("  TRUNCATE users CASCADE") == true)
  }

  @Test("isSchemaChangeQuery allows SELECT and data modification queries")
  func isSchemaChangeQueryAllowsDataQueries() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // SELECT is allowed
    #expect(viewModel.isSchemaChangeQuery("SELECT * FROM users") == false)
    #expect(viewModel.isSchemaChangeQuery("select 1") == false)

    // Data modification is allowed (not schema change)
    #expect(viewModel.isSchemaChangeQuery("INSERT INTO users VALUES (1)") == false)
    #expect(viewModel.isSchemaChangeQuery("UPDATE users SET name = 'test'") == false)
    #expect(viewModel.isSchemaChangeQuery("DELETE FROM users WHERE id = 1") == false)
  }

  // MARK: - blockSchemaChanges Property Tests

  @Test("ConnectionConfig blockSchemaChanges defaults to false")
  func connectionConfigBlockSchemaChangesDefault() {
    let config = ConnectionConfig()
    #expect(config.blockSchemaChanges == false)
  }

  @Test("ConnectionConfig blockSchemaChanges can be set to true")
  func connectionConfigBlockSchemaChangesCanBeSet() {
    let config = ConnectionConfig(blockSchemaChanges: true)
    #expect(config.blockSchemaChanges == true)
  }

  @Test("ConnectionConfig with blockSchemaChanges is Codable")
  func connectionConfigBlockSchemaChangesCodable() throws {
    let config = ConnectionConfig(
      host: "localhost",
      port: 5432,
      database: "test",
      username: "user",
      password: "pass",
      blockSchemaChanges: true
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ConnectionConfig.self, from: data)

    #expect(decoded.blockSchemaChanges == true)
  }

  @Test("ConnectionConfig without blockSchemaChanges decodes to false (migration)")
  func connectionConfigBlockSchemaChangesMigration() throws {
    // Simulate old config without blockSchemaChanges field
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

    // Should default to false for old configs
    #expect(config.blockSchemaChanges == false)
  }
}
