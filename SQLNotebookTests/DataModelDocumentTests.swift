// DataModelDocumentTests.swift
// Unit tests for document round-trip serialization

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Data Model - Document Tests")
@MainActor
struct DataModelDocumentTests {

  // MARK: - Document Operations Tests (Round-trip Serialization)

  @Test("Document round-trip serialization with empty notebook")
  func documentRoundTripEmpty() throws {
    // Arrange - Create empty notebook
    let original = SQLNotebook(
      id: UUID(),
      cells: [],
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Empty Notebook"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )

    // Act - Encode to JSON
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(original)

    // Act - Decode from JSON
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SQLNotebook.self, from: data)

    // Assert
    #expect(decoded.id == original.id)
    #expect(decoded.cells.count == 0)
    #expect(decoded.metadata.title == "Empty Notebook")
  }

  @Test("Document round-trip serialization with cells and results")
  func documentRoundTripWithResults() throws {
    // Arrange - Create notebook with cells containing results
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "integer"),
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "created_at", type: "timestamp"),
      ],
      rows: [
        [.int(1), .string("Alice"), .date(Date())],
        [.int(2), .string("Bob"), .null],
        [.int(3), .json("{\"foo\":\"bar\"}"), .bool(true)],
      ],
      executionTime: 0.123,
      rowCount: 3,
      timestamp: Date(),
      sourceQuery: "SELECT * FROM users LIMIT 3",
      tableName: "users",
      primaryKeyColumns: ["id"]
    )

    let cells = [
      NotebookCell(
        id: UUID(),
        cellType: .sql,
        content: "SELECT * FROM users LIMIT 3",
        executionCount: 1,
        result: result
      ),
      NotebookCell(
        id: UUID(),
        cellType: .sql,
        content: "SELECT COUNT(*) FROM orders",
        executionCount: 2,
        result: nil
      ),
    ]

    let original = SQLNotebook(
      id: UUID(),
      cells: cells,
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Test Notebook"
      ),
      connectionConfig: ConnectionConfig(
        host: "localhost",
        port: 5432,
        database: "testdb",
        username: "testuser"
      ),
      settings: NotebookSettings()
    )

    // Act - Encode to JSON
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    // Act - Decode from JSON
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SQLNotebook.self, from: data)

    // Assert
    #expect(decoded.cells.count == 2)
    #expect(decoded.cells[0].result != nil)
    #expect(decoded.cells[0].result?.columns.count == 3)
    #expect(decoded.cells[0].result?.rows.count == 3)
    #expect(decoded.cells[0].result?.tableName == "users")
    #expect(decoded.cells[0].result?.primaryKeyColumns == ["id"])
    #expect(decoded.cells[1].result == nil)
    #expect(decoded.connectionConfig?.host == "localhost")
  }

  @Test("Document round-trip with special characters and unicode")
  func documentRoundTripSpecialCharacters() throws {
    // Arrange - Create notebook with special characters
    let cells = [
      NotebookCell(
        content: "SELECT '你好世界' AS greeting, 'Ñoño' AS name, '🎉' AS emoji"
      ),
      NotebookCell(
        content: "-- Comment with 日本語\nSELECT * FROM \"table-name\""
      ),
    ]

    let original = SQLNotebook(
      id: UUID(),
      cells: cells,
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Ñoño's Notebook 日本語 🎉"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )

    // Act - Round-trip
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SQLNotebook.self, from: data)

    // Assert
    #expect(decoded.metadata.title == "Ñoño's Notebook 日本語 🎉")
    #expect(decoded.cells[0].content.contains("你好世界"))
    #expect(decoded.cells[0].content.contains("Ñoño"))
    #expect(decoded.cells[0].content.contains("🎉"))
    #expect(decoded.cells[1].content.contains("日本語"))
  }

  @Test("Document round-trip with large result set")
  func documentRoundTripLargeResults() throws {
    // Arrange - Create notebook with large result set
    let columns = [
      ColumnInfo(name: "id", type: "integer"),
      ColumnInfo(name: "data", type: "text"),
    ]

    let rows = (0..<1000).map { i in
      [CellValue.int(i), CellValue.string("Row \(i) data")]
    }

    let result = CellResult(
      columns: columns,
      rows: rows,
      executionTime: 1.234,
      rowCount: 1000,
      timestamp: Date(),
      wasLimited: true,
      sourceQuery: "SELECT * FROM large_table"
    )

    let cell = NotebookCell(
      content: "SELECT * FROM large_table",
      executionCount: 1,
      result: result
    )

    let original = SQLNotebook(
      id: UUID(),
      cells: [cell],
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Large Results"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )

    // Act - Round-trip
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SQLNotebook.self, from: data)

    // Assert
    #expect(decoded.cells[0].result?.rows.count == 1000)
    #expect(decoded.cells[0].result?.wasLimited == true)
  }
}
