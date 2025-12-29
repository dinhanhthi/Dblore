// DataModelTests.swift
// Unit tests for SQLNotebook data models
// Converted to Swift Testing framework

import Testing
@testable import SQLNotebook
import Foundation

@Suite("Data Model Tests")
struct DataModelTests {

    // MARK: - SQLNotebook Tests

    @Test("SQLNotebook encoding and decoding")
    func sqlNotebookEncodingDecoding() throws {
        // Arrange
        let notebook = SQLNotebook(
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
                    content: "SELECT * FROM users;",
                    result: nil,
                    executionCount: 0
                )
            ],
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
        let decodedNotebook = try decoder.decode(SQLNotebook.self, from: data)

        // Assert
        #expect(decodedNotebook.id == notebook.id)
        #expect(decodedNotebook.metadata.title == notebook.metadata.title)
        #expect(decodedNotebook.cells.count == notebook.cells.count)
        #expect(decodedNotebook.cells.first?.content == "SELECT * FROM users;")
    }

    @Test("SQLNotebook with empty cells")
    func sqlNotebookWithEmptyCells() throws {
        // Arrange
        let notebook = SQLNotebook(
            id: UUID(),
            metadata: NotebookMetadata(
                title: "Empty Notebook",
                createdAt: Date(),
                modifiedAt: Date()
            ),
            cells: [],
            connectionConfig: nil,
            settings: NotebookSettings()
        )

        // Act
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notebook)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedNotebook = try decoder.decode(SQLNotebook.self, from: data)

        // Assert
        #expect(decodedNotebook.cells.count == 0)
    }

    // MARK: - NotebookCell Tests

    @Test("NotebookCell encoding and decoding")
    func notebookCellEncodingDecoding() throws {
        // Arrange
        let cell = NotebookCell(
            id: UUID(),
            type: .code,
            content: "SELECT COUNT(*) FROM products;",
            result: nil,
            executionCount: 5
        )

        // Act
        let encoder = JSONEncoder()
        let data = try encoder.encode(cell)

        let decoder = JSONDecoder()
        let decodedCell = try decoder.decode(NotebookCell.self, from: data)

        // Assert
        #expect(decodedCell.id == cell.id)
        #expect(decodedCell.type == .code)
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
                ColumnInfo(name: "name", type: "text")
            ],
            rows: [
                [.int(1), .string("Alice")],
                [.int(2), .string("Bob")]
            ],
            executionTime: 0.042,
            timestamp: Date(),
            error: nil
        )

        let cell = NotebookCell(
            id: UUID(),
            type: .code,
            content: "SELECT id, name FROM users;",
            result: result,
            executionCount: 1
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

    // MARK: - CellValue Tests

    @Test("CellValue string encoding and decoding")
    func cellValueStringEncodingDecoding() throws {
        // Arrange
        let value = CellValue.string("Hello, World!")

        // Act
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)

        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(CellValue.self, from: data)

        // Assert
        if case .string(let str) = decodedValue {
            #expect(str == "Hello, World!")
        } else {
            Issue.record("Expected .string case")
        }
    }

    @Test("CellValue int encoding and decoding")
    func cellValueIntEncodingDecoding() throws {
        let value = CellValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

        if case .int(let num) = decodedValue {
            #expect(num == 42)
        } else {
            Issue.record("Expected .int case")
        }
    }

    @Test("CellValue double encoding and decoding")
    func cellValueDoubleEncodingDecoding() throws {
        let value = CellValue.double(3.14159)
        let data = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

        if case .double(let num) = decodedValue {
            #expect(abs(num - 3.14159) < 0.00001)
        } else {
            Issue.record("Expected .double case")
        }
    }

    @Test("CellValue bool encoding and decoding")
    func cellValueBoolEncodingDecoding() throws {
        let value = CellValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

        if case .bool(let flag) = decodedValue {
            #expect(flag == true)
        } else {
            Issue.record("Expected .bool case")
        }
    }

    @Test("CellValue null encoding and decoding")
    func cellValueNullEncodingDecoding() throws {
        let value = CellValue.null
        let data = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

        if case .null = decodedValue {
            #expect(Bool(true)) // Success
        } else {
            Issue.record("Expected .null case")
        }
    }

    @Test("CellValue JSON encoding and decoding")
    func cellValueJSONEncodingDecoding() throws {
        let jsonString = "{\"name\":\"Alice\",\"age\":30}"
        let value = CellValue.json(jsonString)
        let data = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(CellValue.self, from: data)

        if case .json(let str) = decodedValue {
            #expect(str == jsonString)
        } else {
            Issue.record("Expected .json case")
        }
    }

    // MARK: - CellValue Display Tests

    @Test("CellValue display strings")
    func cellValueDisplayStrings() {
        #expect(CellValue.string("test").displayString == "test")
        #expect(CellValue.int(42).displayString == "42")
        #expect(CellValue.double(3.14).displayString == "3.14")
        #expect(CellValue.bool(true).displayString == "true")
        #expect(CellValue.null.displayString == "NULL")
    }

    @Test("CellValue isNull property")
    func cellValueIsNull() {
        #expect(CellValue.null.isNull == true)
        #expect(CellValue.string("test").isNull == false)
        #expect(CellValue.int(0).isNull == false)
    }

    @Test("CellValue isJSON property")
    func cellValueIsJSON() {
        #expect(CellValue.json("{}").isJSON == true)
        #expect(CellValue.string("{}").isJSON == false)
        #expect(CellValue.null.isJSON == false)
    }

    // MARK: - ConnectionConfig Tests

    @Test("ConnectionConfig encoding does not include password")
    func connectionConfigEncodingDoesNotIncludePassword() throws {
        // Arrange
        let config = ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "testdb",
            username: "testuser",
            password: "secret123",
            sslMode: .disable
        )

        // Act
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        let jsonString = String(data: data, encoding: .utf8)!

        // Assert
        #expect(!jsonString.contains("secret123"), "Password should not be encoded")
        #expect(jsonString.contains("localhost"))
        #expect(jsonString.contains("testdb"))
        #expect(jsonString.contains("testuser"))
    }

    // MARK: - NotebookMetadata Tests

    @Test("NotebookMetadata encoding and decoding")
    func notebookMetadataEncodingDecoding() throws {
        // Arrange
        let metadata = NotebookMetadata(
            title: "My Notebook",
            createdAt: Date(),
            modifiedAt: Date()
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
        #expect(decodedMetadata.createdAt != nil)
        #expect(decodedMetadata.modifiedAt != nil)
    }

    // MARK: - NotebookSettings Tests

    @Test("NotebookSettings encoding and decoding")
    func notebookSettingsEncodingDecoding() throws {
        // Arrange
        let settings = NotebookSettings(
            maxResultTableHeight: 500.0,
            includeResultsWhenSaving: false
        )

        // Act
        let data = try JSONEncoder().encode(settings)
        let decodedSettings = try JSONDecoder().decode(NotebookSettings.self, from: data)

        // Assert
        #expect(decodedSettings.maxResultTableHeight == 500.0)
        #expect(decodedSettings.includeResultsWhenSaving == false)
    }

    // MARK: - Performance Tests

    @Test("Notebook encoding performance with 100 cells", .timeLimit(.minutes(1)))
    func notebookEncodingPerformance() throws {
        // Create a large notebook with 100 cells
        let cells = (0..<100).map { i in
            NotebookCell(
                id: UUID(),
                type: .code,
                content: "SELECT * FROM table_\(i);",
                result: nil,
                executionCount: 0
            )
        }

        let notebook = SQLNotebook(
            id: UUID(),
            metadata: NotebookMetadata(
                title: "Large Notebook",
                createdAt: Date(),
                modifiedAt: Date()
            ),
            cells: cells,
            connectionConfig: nil,
            settings: NotebookSettings()
        )

        // This should complete within the time limit
        _ = try JSONEncoder().encode(notebook)
    }
}
