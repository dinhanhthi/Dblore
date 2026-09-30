// DataModelDocumentTests.swift
// Unit tests for document round-trip serialization

import Foundation
import Testing

@testable import Dblore

@Suite("Data Model - Document Tests")
@MainActor
struct DataModelDocumentTests {
  // MARK: - Document Operations Tests (Round-trip Serialization)

  @Test("Document round-trip serialization with empty notebook")
  func documentRoundTripEmpty() throws {
    // Arrange - Create empty notebook
    let original = DbloreNotebook(
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
    let decoded = try decoder.decode(DbloreNotebook.self, from: data)

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

    let original = DbloreNotebook(
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
    let decoded = try decoder.decode(DbloreNotebook.self, from: data)

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

    let original = DbloreNotebook(
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
    let decoded = try decoder.decode(DbloreNotebook.self, from: data)

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

    let original = DbloreNotebook(
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
    let decoded = try decoder.decode(DbloreNotebook.self, from: data)

    // Assert
    #expect(decoded.cells[0].result?.rows.count == 1000)
    #expect(decoded.cells[0].result?.wasLimited == true)
  }

  @Test("Malformed statement result entries decode to an empty result")
  func malformedStatementResultDecodesEmpty() throws {
    let json: [String: Any] = [
      "cells": [
        [
          "content": "SELECT 1; SELECT 2",
          "statementResults": [
            ["queryText": "SELECT 1", "statementIndex": 0, "result": "not a dictionary"],
            ["queryText": "SELECT 2", "statementIndex": 1],
          ],
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let notebook = try DocumentCoder.decode(from: data)

    let statements = notebook.cells[0].statementResults
    #expect(statements.map(\.queryText) == ["SELECT 1", "SELECT 2"])
    #expect(statements.allSatisfy { $0.result.rows.isEmpty && $0.result.columns.isEmpty })
  }
}

// MARK: - Saved-file compatibility (pre-Phase-4 <-> current)

/// A `.dblore` written by the pre-Phase-4 `DocumentCoder`: LIMIT-rewrite metadata, ctid row
/// identifiers, edit-target fields and pagination state. Shape reproduced literally.
private let legacyFixture = """
  {"cells":[{"cellType":"sql","content":"SELECT * FROM users","executionCount":3,
  "id":"6F1C2E5A-0000-4000-8000-000000000001","isResultVisible":true,"isRunning":false,
  "paginationInfo":{"baseQuery":"SELECT * FROM users","currentPage":2,"rowsPerPage":2,"totalRows":9},
  "result":{"columns":[{"name":"id","type":"int4"},{"name":"name","type":"text"}],
  "executionTime":0.25,"primaryKeyColumns":["id"],"rowCount":2,
  "rowIdentifiers":[{"type":"string","value":"(0,1)"},{"type":"string","value":"(0,2)"}],
  "rows":[[{"type":"int","value":1},{"type":"string","value":"Alice"}],
  [{"type":"int","value":2},{"type":"null"}]],
  "sourceQuery":"SELECT * FROM users","tableName":"users","timestamp":"2026-01-02T03:04:05Z",
  "userLimitExceeded":true,"userRequestedLimit":500,"wasLimited":true},
  "selectedStatementIndex":0,"statementPaginationInfo":{"6F1C2E5A-0000-4000-8000-000000000002":
  {"baseQuery":"SELECT 1","currentPage":1,"rowsPerPage":1,"totalRows":1}},
  "statementResults":[{"id":"6F1C2E5A-0000-4000-8000-000000000002","queryText":"SELECT 1",
  "result":{"columns":[{"name":"?column?","type":"int4"}],"executionTime":0.01,
  "primaryKeyColumns":["id"],"rowCount":1,"rows":[[{"type":"int","value":1}]],
  "tableName":"users","timestamp":"2026-01-02T03:04:05Z","wasLimited":false},
  "statementIndex":0}]}],
  "documentType":"notebook","id":"6F1C2E5A-0000-4000-8000-0000000000AA",
  "metadata":{"createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-02T00:00:00Z",
  "title":"Legacy"},"settings":{"keyboardShortcuts":{}},"version":"1.0"}
  """

/// Mirror of the pre-Phase-4 `DocumentCoder.decode` result/cell reading (b8be7db and 74e4dc6
/// are identical there): every key is read leniently (`as? T ?? default`); nothing is required
/// beyond a top-level object. Returns what the old build would have used.
private struct LegacyFileView {
  struct Result {
    let columnNames: [String]
    let rowCount: Int
    let rowsDecoded: Int
    let wasLimited: Bool
    let tableName: String?
    let primaryKeyColumns: [String]
    let rowIdentifiers: Int
    let userLimitExceeded: Bool
    let userRequestedLimit: Int?
    /// Old build: inline edit is offered when the result carries a table name
    var isEditableInOldBuild: Bool {
      tableName != nil
    }
  }

  struct Cell {
    let result: Result?
    let statementResults: [Result]
    let hasPaginationInfo: Bool
    let statementPaginationCount: Int
  }

  let cells: [Cell]

  init(data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    let json = try #require(object as? [String: Any])
    let cellsArray = json["cells"] as? [[String: Any]] ?? []
    cells = cellsArray.map { cellDict in
      let statements = (cellDict["statementResults"] as? [[String: Any]] ?? []).compactMap {
        ($0["result"] as? [String: Any]).map(Self.result(from:))
      }
      return Cell(
        result: (cellDict["result"] as? [String: Any]).map(Self.result(from:)),
        statementResults: statements,
        hasPaginationInfo: cellDict["paginationInfo"] as? [String: Any] != nil,
        statementPaginationCount: (cellDict["statementPaginationInfo"] as? [String: [String: Any]])?
          .count ?? 0
      )
    }
  }

  private static func result(from dict: [String: Any]) -> Result {
    let columns = dict["columns"] as? [[String: Any]] ?? []
    let rows = dict["rows"] as? [[[String: Any]]] ?? []
    return Result(
      columnNames: columns.map { $0["name"] as? String ?? "" },
      rowCount: dict["rowCount"] as? Int ?? 0,
      rowsDecoded: rows.count,
      wasLimited: dict["wasLimited"] as? Bool ?? false,
      tableName: dict["tableName"] as? String,
      primaryKeyColumns: dict["primaryKeyColumns"] as? [String] ?? [],
      rowIdentifiers: (dict["rowIdentifiers"] as? [[String: Any]])?.count ?? 0,
      userLimitExceeded: dict["userLimitExceeded"] as? Bool ?? false,
      userRequestedLimit: dict["userRequestedLimit"] as? Int
    )
  }
}

@Suite("Data Model - Saved-file compatibility")
@MainActor
struct DocumentLegacyCompatibilityTests {
  private func legacyData() throws -> Data {
    try #require(legacyFixture.data(using: .utf8))
  }

  private func currentNotebook() -> DbloreNotebook {
    var result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4", tableOID: 16400, attributeNumber: 1)],
      rows: [[.int(1)], [.int(2)]], executionTime: 0.5, rowCount: 2,
      timestamp: Date(timeIntervalSince1970: 1_800_000_000), wasLimited: true,
      sourceQuery: "SELECT id FROM users", tableName: "public.users", primaryKeyColumns: ["id"]
    )
    result.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: .postgresql(oid: 16400), primaryKeyColumns: ["id"])
    let statement = StatementResult(
      queryText: "SELECT id FROM users", result: result, statementIndex: 0
    )
    let cell = NotebookCell(
      content: "SELECT id FROM users", executionCount: 1, result: result,
      statementResults: [statement]
    )
    return DbloreNotebook(
      id: UUID(), cells: [cell],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Current"),
      connectionConfig: nil, settings: NotebookSettings()
    )
  }

  private func assertOldBuildReads(_ data: Data) throws {
    let view = try LegacyFileView(data: data)
    let cell = try #require(view.cells.first)
    let result = try #require(cell.result)
    #expect(result.columnNames == ["id"])
    #expect(result.rowCount == 2)
    #expect(result.rowsDecoded == 2)
    #expect(result.wasLimited)
    #expect(result.isEditableInOldBuild == false)
    #expect(result.primaryKeyColumns.isEmpty)
    #expect(result.rowIdentifiers == 0)
    #expect(result.userLimitExceeded == false)
    #expect(result.userRequestedLimit == nil)
    #expect(cell.hasPaginationInfo == false)
    #expect(cell.statementPaginationCount == 0)
    #expect(cell.statementResults.count == 1)
    #expect(cell.statementResults.first?.isEditableInOldBuild == false)
    // Keys the old build always wrote stay present
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cells = try #require(json["cells"] as? [[String: Any]])
    let dict = try #require(cells.first?["result"] as? [String: Any])
    for key in ["columns", "rows", "executionTime", "rowCount", "timestamp", "wasLimited"] {
      #expect(dict[key] != nil, "missing \(key)")
    }
  }

  @Test("Legacy file decodes: results intact, no edit target")
  func legacyFixtureDecodes() throws {
    let notebook = try DocumentCoder.decode(from: legacyData())
    let cell = try #require(notebook.cells.first)
    let result = try #require(cell.result)
    #expect(cell.content == "SELECT * FROM users")
    #expect(cell.executionCount == 3)
    #expect(result.columns.map(\.name) == ["id", "name"])
    #expect(result.rows == [[.int(1), .string("Alice")], [.int(2), .null]])
    #expect(result.rowCount == 2)
    #expect(result.wasLimited)
    #expect(result.sourceQuery == "SELECT * FROM users")
    #expect(result.editTarget == nil)
    #expect(cell.statementResults.count == 1)
    #expect(cell.statementResults.first?.result.editTarget == nil)
  }

  @Test("Legacy file: stale LIMIT/ctid/edit-target/pagination state is not carried after load")
  func legacyStateDroppedOnLoad() throws {
    let notebook = try DocumentCoder.decode(from: legacyData())
    let result = try #require(notebook.cells.first?.result)
    #expect(result.tableName == nil)
    #expect(result.primaryKeyColumns.isEmpty)
    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: true)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("paginationInfo"))
    #expect(!text.contains("PaginationInfo"))
    #expect(!text.contains("rowIdentifiers"))
    #expect(!text.contains("tableName"))
  }

  @Test("File saved by the current build opens in the pre-Phase-4 build")
  func currentFileReadByOldDecoder() throws {
    try assertOldBuildReads(
      DocumentCoder.encode(currentNotebook(), includeResultsOnSave: true)
    )
  }

  @Test("FileOptimizationService encodes with the same rules as the main coder")
  func fileOptimizationMatchesMainCoder() throws {
    let notebook = currentNotebook()
    let data = try FileOptimizationService.DocumentCoder.encode(
      notebook, includeResultsOnSave: true
    )
    try assertOldBuildReads(data)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("primaryKeyColumns"))
    #expect(!text.contains("tableName"))
    #expect(try data == (DocumentCoder.encode(notebook, includeResultsOnSave: true)))
  }
}
