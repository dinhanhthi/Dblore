// DataModelTests.swift
// Unit tests for SQLNotebook data models
// Converted to Swift Testing framework

import Testing
@testable import SQLNotebook
import Foundation
import Crypto  // Force Xcode to include this
import NIOCore // Just in case

@Suite("Data Model Tests")
@MainActor
struct DataModelTests {

    // MARK: - SQLNotebook Tests

    @Test("SQLNotebook encoding and decoding")
    func sqlNotebookEncodingDecoding() throws {
        // Arrange
        let notebook = SQLNotebook(
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
                ColumnInfo(name: "name", type: "text")
            ],
            rows: [
                [.int(1), .string("Alice")],
                [.int(2), .string("Bob")]
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

    @Test("ConnectionConfig encoding and decoding")
    func connectionConfigEncodingDecoding() throws {
        // Arrange
        let config = ConnectionConfig(
            databaseType: .postgresql,
            host: "localhost",
            port: 5432,
            database: "testdb",
            username: "testuser",
            password: "secret123",
            sslMode: .disable,
            timeoutSeconds: 30
        )

        // Act
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        let jsonString = String(data: data, encoding: .utf8)!

        // Assert - Verify basic encoding works
        #expect(jsonString.contains("localhost"))
        #expect(jsonString.contains("testdb"))
        #expect(jsonString.contains("testuser"))
        #expect(jsonString.contains("30")) // Verify timeoutSeconds is encoded

        // Decode
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(ConnectionConfig.self, from: data)
        #expect(decodedConfig.host == "localhost")
        #expect(decodedConfig.database == "testdb")
        #expect(decodedConfig.username == "testuser")
        #expect(decodedConfig.timeoutSeconds == 30) // Verify timeoutSeconds is decoded

        // TODO: Implement Keychain storage for passwords (password should not be in JSON)
    }

    @Test("ConnectionConfig default timeout value")
    func connectionConfigDefaultTimeout() {
        // Arrange & Act - Create config without specifying timeout
        let config = ConnectionConfig(
            host: "localhost",
            database: "test"
        )

        // Assert - Default timeout should be 30 seconds
        #expect(config.timeoutSeconds == 30)
    }

    @Test("ConnectionConfig custom timeout value")
    func connectionConfigCustomTimeout() {
        // Arrange & Act - Create config with custom timeout
        let config = ConnectionConfig(
            host: "localhost",
            database: "test",
            timeoutSeconds: 60
        )

        // Assert - Custom timeout should be preserved
        #expect(config.timeoutSeconds == 60)
    }

    @Test("ConnectionConfig timeout encoding preserves value")
    func connectionConfigTimeoutEncodingPreservesValue() throws {
        // Arrange - Create configs with different timeout values
        let testCases = [10, 30, 60, 120, 300]

        for timeout in testCases {
            let config = ConnectionConfig(
                host: "localhost",
                database: "test",
                timeoutSeconds: timeout
            )

            // Act - Encode and decode
            let encoder = JSONEncoder()
            let data = try encoder.encode(config)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(ConnectionConfig.self, from: data)

            // Assert - Timeout value should be preserved
            #expect(decoded.timeoutSeconds == timeout)
        }
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
        // createdAt and modifiedAt are non-optional, just verify they decoded successfully
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

        let notebook = SQLNotebook(
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

        // This should complete within the time limit
        _ = try JSONEncoder().encode(notebook)
    }

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
                ColumnInfo(name: "created_at", type: "timestamp")
            ],
            rows: [
                [.int(1), .string("Alice"), .date(Date())],
                [.int(2), .string("Bob"), .null],
                [.int(3), .json("{\"foo\":\"bar\"}"), .bool(true)]
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
            )
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
            )
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
            ColumnInfo(name: "data", type: "text")
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

    // MARK: - CellResult Model Tests

    @Test("CellResult with all CellValue types")
    func cellResultWithAllValueTypes() throws {
        // Arrange - Test all CellValue types
        let result = CellResult(
            columns: [
                ColumnInfo(name: "str_col", type: "text"),
                ColumnInfo(name: "int_col", type: "integer"),
                ColumnInfo(name: "double_col", type: "double precision"),
                ColumnInfo(name: "bool_col", type: "boolean"),
                ColumnInfo(name: "null_col", type: "text"),
                ColumnInfo(name: "json_col", type: "jsonb"),
                ColumnInfo(name: "date_col", type: "timestamp"),
                ColumnInfo(name: "data_col", type: "bytea")
            ],
            rows: [
                [
                    .string("test"),
                    .int(42),
                    .double(3.14159),
                    .bool(true),
                    .null,
                    .json("{\"key\":\"value\"}"),
                    .date(Date()),
                    .data(Data([0x01, 0x02, 0x03]))
                ]
            ],
            executionTime: 0.05,
            rowCount: 1,
            timestamp: Date()
        )

        // Act - Encode and decode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CellResult.self, from: data)

        // Assert
        #expect(decoded.columns.count == 8)
        #expect(decoded.rows.count == 1)
        #expect(decoded.rows[0].count == 8)

        // Verify each value type
        if case .string(let str) = decoded.rows[0][0] {
            #expect(str == "test")
        } else {
            Issue.record("Expected string value")
        }

        if case .int(let num) = decoded.rows[0][1] {
            #expect(num == 42)
        } else {
            Issue.record("Expected int value")
        }

        if case .double(let num) = decoded.rows[0][2] {
            #expect(abs(num - 3.14159) < 0.00001)
        } else {
            Issue.record("Expected double value")
        }

        if case .bool(let flag) = decoded.rows[0][3] {
            #expect(flag == true)
        } else {
            Issue.record("Expected bool value")
        }

        if case .null = decoded.rows[0][4] {
            #expect(Bool(true))
        } else {
            Issue.record("Expected null value")
        }

        if case .json(let json) = decoded.rows[0][5] {
            #expect(json == "{\"key\":\"value\"}")
        } else {
            Issue.record("Expected json value")
        }

        if case .date = decoded.rows[0][6] {
            #expect(Bool(true))
        } else {
            Issue.record("Expected date value")
        }

        if case .data(let bytes) = decoded.rows[0][7] {
            #expect(bytes == Data([0x01, 0x02, 0x03]))
        } else {
            Issue.record("Expected data value")
        }
    }

    @Test("CellResult error result factory method")
    func cellResultErrorFactory() {
        // Act
        let errorResult = CellResult.errorResult(
            "Connection timeout",
            executionTime: 30.0,
            sourceQuery: "SELECT * FROM slow_table"
        )

        // Assert
        #expect(errorResult.error == "Connection timeout")
        #expect(errorResult.executionTime == 30.0)
        #expect(errorResult.sourceQuery == "SELECT * FROM slow_table")
        #expect(errorResult.columns.count == 0)
        #expect(errorResult.rows.count == 0)
    }

    @Test("CellResult with modification query metadata")
    func cellResultModificationQuery() throws {
        // Arrange - Test UPDATE/DELETE metadata
        let result = CellResult(
            columns: [],
            rows: [],
            executionTime: 0.05,
            rowCount: 0,
            timestamp: Date(),
            sourceQuery: "UPDATE users SET active = true WHERE id > 100",
            affectedRows: 42
        )

        // Act - Encode and decode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CellResult.self, from: data)

        // Assert
        #expect(decoded.affectedRows == 42)
        #expect(decoded.columns.count == 0)
        #expect(decoded.rows.count == 0)
    }

    @Test("CellResult with row limit metadata")
    func cellResultRowLimitMetadata() throws {
        // Arrange
        let result = CellResult(
            columns: [ColumnInfo(name: "id", type: "integer")],
            rows: [[.int(1)], [.int(2)]],
            executionTime: 0.01,
            rowCount: 2,
            timestamp: Date(),
            wasLimited: true,
            userLimitExceeded: true,
            userRequestedLimit: 10000
        )

        // Act - Round-trip
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CellResult.self, from: data)

        // Assert
        #expect(decoded.wasLimited == true)
        #expect(decoded.userLimitExceeded == true)
        #expect(decoded.userRequestedLimit == 10000)
    }

    @Test("CellResult - User LIMIT exceeds maxRows but database has fewer rows than maxRows")
    func cellResultUserLimitExceedsButFewerActualRows() throws {
        // Scenario: Database has 36 rows, maxRows setting is 100, user query has LIMIT 130
        // Expected: No warning should be shown because actual rows (36) < maxRows (100)

        // Arrange - Simulate 36 rows returned
        let rows = (1...36).map { [CellValue.int($0)] }
        let result = CellResult(
            columns: [ColumnInfo(name: "id", type: "integer")],
            rows: rows,
            executionTime: 0.01,
            rowCount: 36,
            timestamp: Date(),
            wasLimited: false,  // Not limited by auto-LIMIT
            userLimitExceeded: false,  // Should be false because actual rows < maxRows
            userRequestedLimit: nil  // Should be nil because no warning needed
        )

        // Act - Round-trip encoding/decoding
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CellResult.self, from: data)

        // Assert - No warning should be shown
        #expect(decoded.userLimitExceeded == false)
        #expect(decoded.userRequestedLimit == nil)
        #expect(decoded.rowCount == 36)
    }

    @Test("CellResult - User LIMIT exceeds maxRows AND database returns maxRows")
    func cellResultUserLimitExceedsAndMaxRowsReturned() throws {
        // Scenario: Database has 200 rows, maxRows setting is 100, user query has LIMIT 130
        // Expected: Warning should be shown because actual rows returned = maxRows (100)

        // Arrange - Simulate 100 rows returned (capped at maxRows)
        let rows = (1...100).map { [CellValue.int($0)] }
        let result = CellResult(
            columns: [ColumnInfo(name: "id", type: "integer")],
            rows: rows,
            executionTime: 0.01,
            rowCount: 100,
            timestamp: Date(),
            wasLimited: false,
            userLimitExceeded: true,  // Should be true because returned exactly maxRows
            userRequestedLimit: 100  // Should show the actual limit applied
        )

        // Act - Round-trip encoding/decoding
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CellResult.self, from: data)

        // Assert - Warning should be shown
        #expect(decoded.userLimitExceeded == true)
        #expect(decoded.userRequestedLimit == 100)
        #expect(decoded.rowCount == 100)
    }

    // MARK: - DatabaseSchema Model Tests

    @Test("DatabaseTable encoding and properties")
    func databaseTableProperties() {
        // Arrange
        let table = DatabaseTable(
            schema: "public",
            name: "users",
            columns: [
                DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
                DatabaseColumn(name: "email", type: "varchar", isNullable: false),
                DatabaseColumn(name: "created_at", type: "timestamp", isNullable: true)
            ],
            isExpanded: true,
            rowCount: 1234
        )

        // Assert
        #expect(table.schema == "public")
        #expect(table.name == "users")
        #expect(table.qualifiedName == "public.users")
        #expect(table.columns.count == 3)
        #expect(table.isExpanded == true)
        #expect(table.rowCount == 1234)
    }

    @Test("DatabaseColumn type icon mapping")
    func databaseColumnTypeIcons() {
        // Test primary key - must be tested first as it takes precedence
        let pkColumn = DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true)
        #expect(pkColumn.typeIcon == "key")

        // Test numeric types (integers)
        let intColumn = DatabaseColumn(name: "age", type: "integer")
        #expect(intColumn.typeIcon == "textformat.123")

        // Test numeric types (decimals)
        let numericColumn = DatabaseColumn(name: "price", type: "numeric")
        #expect(numericColumn.typeIcon == "number")

        let decimalColumn = DatabaseColumn(name: "amount", type: "decimal")
        #expect(decimalColumn.typeIcon == "number")

        // Test text types
        let varcharColumn = DatabaseColumn(name: "name", type: "varchar")
        #expect(varcharColumn.typeIcon == "textformat")

        let textColumn = DatabaseColumn(name: "bio", type: "text")
        #expect(textColumn.typeIcon == "textformat")

        // Test boolean
        let boolColumn = DatabaseColumn(name: "active", type: "boolean")
        #expect(boolColumn.typeIcon == "checklist")

        // Test date/time
        let timestampColumn = DatabaseColumn(name: "created", type: "timestamp")
        #expect(timestampColumn.typeIcon == "calendar")

        let dateColumn = DatabaseColumn(name: "birthday", type: "date")
        #expect(dateColumn.typeIcon == "calendar")

        // Test JSON
        let jsonColumn = DatabaseColumn(name: "data", type: "jsonb")
        #expect(jsonColumn.typeIcon == "curlybraces")

        // Test UUID
        let uuidColumn = DatabaseColumn(name: "uuid", type: "uuid")
        #expect(uuidColumn.typeIcon == "number.square")

        // Test array
        let arrayColumn = DatabaseColumn(name: "tags", type: "text[]")
        #expect(arrayColumn.typeIcon == "list.bullet")

        // Test unknown type
        let unknownColumn = DatabaseColumn(name: "unknown", type: "custom_type")
        #expect(unknownColumn.typeIcon == "questionmark.circle")
    }

    @Test("DatabaseView properties and qualified name")
    func databaseViewProperties() {
        // Arrange
        let view = DatabaseView(
            schema: "public",
            name: "active_users",
            columns: [
                DatabaseColumn(name: "id", type: "integer"),
                DatabaseColumn(name: "username", type: "varchar")
            ],
            isExpanded: false,
            definition: "SELECT id, username FROM users WHERE active = true"
        )

        // Assert
        #expect(view.schema == "public")
        #expect(view.name == "active_users")
        #expect(view.qualifiedName == "public.active_users")
        #expect(view.columns.count == 2)
        #expect(view.definition != nil)
    }

    @Test("DatabaseFunction signature formatting")
    func databaseFunctionSignature() {
        // Arrange
        let function = DatabaseFunction(
            schema: "public",
            name: "get_user_count",
            returnType: "integer",
            arguments: "start_date timestamp, end_date timestamp",
            definition: "BEGIN RETURN (SELECT COUNT(*) FROM users); END;"
        )

        // Assert
        #expect(function.schema == "public")
        #expect(function.name == "get_user_count")
        #expect(function.qualifiedName == "public.get_user_count")
        #expect(function.signature == "get_user_count(start_date timestamp, end_date timestamp) → integer")
    }

    @Test("DatabaseProcedure signature formatting")
    func databaseProcedureSignature() {
        // Arrange
        let procedure = DatabaseProcedure(
            schema: "public",
            name: "cleanup_old_records",
            arguments: "days_old integer",
            definition: "DELETE FROM logs WHERE created_at < NOW() - days_old * INTERVAL '1 day'"
        )

        // Assert
        #expect(procedure.qualifiedName == "public.cleanup_old_records")
        #expect(procedure.signature == "cleanup_old_records(days_old integer)")
    }

    @Test("DatabaseUser attributes display")
    func databaseUserAttributes() {
        // Test superuser
        let superuser = DatabaseUser(
            name: "postgres",
            canLogin: true,
            isSuperuser: true,
            canCreateDB: true,
            canCreateRole: true
        )
        #expect(superuser.attributes.contains("Superuser"))
        #expect(superuser.attributes.contains("Create DB"))
        #expect(superuser.attributes.contains("Create Role"))

        // Test regular user with no login
        let noLoginUser = DatabaseUser(
            name: "readonly",
            canLogin: false,
            connectionLimit: 5
        )
        #expect(noLoginUser.attributes.contains("No Login"))
        #expect(noLoginUser.attributes.contains("Limit: 5"))
    }

    @Test("DatabaseRole attributes display")
    func databaseRoleAttributes() {
        // Arrange
        let role = DatabaseRole(
            name: "developers",
            canLogin: true,
            canCreateDB: true,
            members: ["alice", "bob", "charlie"]
        )

        // Assert
        #expect(role.attributes.contains("Can Login"))
        #expect(role.attributes.contains("Create DB"))
        #expect(role.members.count == 3)
        #expect(role.members.contains("alice"))
    }
}
