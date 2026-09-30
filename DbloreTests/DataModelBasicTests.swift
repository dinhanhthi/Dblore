// DataModelBasicTests.swift
// Unit tests for DbloreNotebook basic data models (DbloreNotebook, NotebookCell, NotebookMetadata, NotebookSettings)

import Crypto
import Foundation
import NIOCore
import Testing

@testable import Dblore

@Suite("Data Model - Basic Tests")
@MainActor
struct DataModelBasicTests {

  // MARK: - DbloreNotebook Tests

  @Test("Dblore encoding and decoding")
  func dbloreEncodingDecoding() throws {
    // Arrange
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: UUID(),
          cellType: .sql,
          content: "SELECT * FROM users;",
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

    // Act - Encode
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(notebook)

    // Act - Decode
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedNotebook = try decoder.decode(DbloreNotebook.self, from: data)

    // Assert
    #expect(decodedNotebook.id == notebook.id)
    #expect(decodedNotebook.metadata.title == notebook.metadata.title)
    #expect(decodedNotebook.cells.count == notebook.cells.count)
    #expect(decodedNotebook.cells.first?.content == "SELECT * FROM users;")
  }

  @Test("Dblore with empty cells")
  func dbloreWithEmptyCells() throws {
    // Arrange
    let notebook = DbloreNotebook(
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

    // Act
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(notebook)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedNotebook = try decoder.decode(DbloreNotebook.self, from: data)

    // Assert
    #expect(decodedNotebook.cells.count == 0)
  }

  // MARK: - NotebookCell Tests

  @Test("NotebookCell encoding and decoding")
  func notebookCellEncodingDecoding() throws {
    // Arrange
    let cell = NotebookCell(
      id: UUID(),
      cellType: .sql,
      content: "SELECT COUNT(*) FROM products;",
      executionCount: 5,
      result: nil
    )

    // Act
    let encoder = JSONEncoder()
    let data = try encoder.encode(cell)

    let decoder = JSONDecoder()
    let decodedCell = try decoder.decode(NotebookCell.self, from: data)

    // Assert
    #expect(decodedCell.id == cell.id)
    #expect(decodedCell.cellType == .sql)
    #expect(decodedCell.content == cell.content)
    #expect(decodedCell.executionCount == 5)
    #expect(decodedCell.result == nil)
  }

  @Test("NotebookCell with results")
  func notebookCellWithResults() throws {
    // Arrange
    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "integer"),
        ColumnInfo(name: "name", type: "text"),
      ],
      rows: [
        [.int(1), .string("Alice")],
        [.int(2), .string("Bob")],
      ],
      executionTime: 0.042,
      rowCount: 2,
      timestamp: Date()
    )

    let cell = NotebookCell(
      id: UUID(),
      cellType: .sql,
      content: "SELECT id, name FROM users;",
      executionCount: 1,
      result: result
    )

    // Act
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(cell)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedCell = try decoder.decode(NotebookCell.self, from: data)

    // Assert
    #expect(decodedCell.result != nil)
    #expect(decodedCell.result?.columns.count == 2)
    #expect(decodedCell.result?.rows.count == 2)
    #expect(abs(decodedCell.result!.executionTime - 0.042) < 0.001)
  }

  @Test("NotebookCell chartSpec round-trips")
  func notebookCellChartSpecRoundTrip() throws {
    let spec = ChartSpec(
      kind: .area, xColumn: "day", yColumns: ["total", "count"], seriesColumn: "region")
    let cell = NotebookCell(
      id: UUID(),
      cellType: .sql,
      content: "SELECT day, total FROM sales;",
      chartSpec: spec
    )

    let data = try JSONEncoder().encode(cell)
    let decoded = try JSONDecoder().decode(NotebookCell.self, from: data)

    #expect(decoded.chartSpec == spec)
    let raw = try JSONSerialization.jsonObject(with: data)
    let object = try #require(raw as? [String: Any])
    #expect(object["chartSpec"] != nil)
  }

  @Test("NotebookCell without chartSpec still decodes")
  func notebookCellWithoutChartSpecDecodes() throws {
    let id = UUID()
    let legacy = """
      {"id":"\(id.uuidString)","cellType":"sql","content":"SELECT 1"}
      """
    let data = try #require(legacy.data(using: .utf8))
    let decoded = try JSONDecoder().decode(NotebookCell.self, from: data)

    #expect(decoded.id == id)
    #expect(decoded.content == "SELECT 1")
    #expect(decoded.chartSpec == nil)

    let plain = NotebookCell(id: id, cellType: .sql, content: "SELECT 1")
    let encoded = try JSONEncoder().encode(plain)
    let raw = try JSONSerialization.jsonObject(with: encoded)
    let object = try #require(raw as? [String: Any])
    #expect(object["chartSpec"] == nil)
    let roundTrip = try JSONDecoder().decode(NotebookCell.self, from: encoded)
    #expect(roundTrip.chartSpec == nil)
  }

  // MARK: - NotebookMetadata Tests

  @Test("NotebookMetadata encoding and decoding")
  func notebookMetadataEncodingDecoding() throws {
    // Arrange
    let metadata = NotebookMetadata(
      createdAt: Date(),
      modifiedAt: Date(),
      title: "My Notebook"
    )

    // Act
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(metadata)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedMetadata = try decoder.decode(NotebookMetadata.self, from: data)

    // Assert
    #expect(decodedMetadata.title == "My Notebook")
    #expect(decodedMetadata.createdAt.timeIntervalSince1970 > 0)
    #expect(decodedMetadata.modifiedAt.timeIntervalSince1970 > 0)
  }

  // MARK: - NotebookSettings Tests

  @Test("NotebookSettings encoding and decoding")
  func notebookSettingsEncodingDecoding() throws {
    // Arrange
    let settings = NotebookSettings(
      keyboardShortcuts: ["runCell": "cmd+enter", "newCell": "cmd+b"]
    )

    // Act
    let data = try JSONEncoder().encode(settings)
    let decodedSettings = try JSONDecoder().decode(NotebookSettings.self, from: data)

    // Assert
    #expect(decodedSettings.keyboardShortcuts["runCell"] == "cmd+enter")
    #expect(decodedSettings.keyboardShortcuts["newCell"] == "cmd+b")
    #expect(decodedSettings.keyboardShortcuts.count == 2)
  }

  // MARK: - Performance Tests

  @Test("Notebook encoding performance with 100 cells", .timeLimit(.minutes(1)))
  func notebookEncodingPerformance() throws {
    // Create a large notebook with 100 cells
    let cells = (0..<100).map { i in
      NotebookCell(
        id: UUID(),
        cellType: .sql,
        content: "SELECT * FROM table_\(i);",
        executionCount: 0,
        result: nil
      )
    }

    let notebook = DbloreNotebook(
      id: UUID(),
      cells: cells,
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Large Notebook"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )

    _ = try JSONEncoder().encode(notebook)
  }
}
