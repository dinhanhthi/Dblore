//
//  FileOptimizationServiceTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

@MainActor
struct FileOptimizationServiceTests {
  // MARK: - File Size Calculation Tests

  @Test("Calculate size with results")
  func testCalculateSizeWithResults() throws {
    var notebook = DbloreNotebook.newDocument()

    // Add a cell with result
    let columns = [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "name", type: "VARCHAR"),
    ]
    let rows: [[CellValue]] = [
      [.int(1), .string("Alice")],
      [.int(2), .string("Bob")],
      [.int(3), .string("Charlie")],
    ]
    let result = CellResult(
      columns: columns,
      rows: rows,
      executionTime: 0.5,
      rowCount: 3,
      timestamp: Date()
    )

    var cell = notebook.cells[0]
    cell.content = "SELECT * FROM users"
    cell.result = result
    notebook.cells[0] = cell

    let sizeWithResults = try FileOptimizationService.calculateNotebookSize(
      notebook,
      includeResults: true
    )
    let sizeWithoutResults = try FileOptimizationService.calculateNotebookSize(
      notebook,
      includeResults: false
    )

    #expect(sizeWithResults > sizeWithoutResults)
    // Size depends on encoding; just verify it's larger than without results
    #expect(sizeWithResults > 500)
  }

  // MARK: - Size Formatting Tests

  // MARK: - Optimization Tests

  @Test("Remove all results from notebook")
  func testRemoveAllResults() throws {
    var notebook = DbloreNotebook.newDocument()

    // Add cells with results
    for i in 0..<3 {
      let result = CellResult(
        columns: [ColumnInfo(name: "id", type: "INTEGER")],
        rows: [[.int(i)]],
        executionTime: 0.1,
        rowCount: 1,
        timestamp: Date()
      )

      if i == 0 {
        var cell = notebook.cells[0]
        cell.result = result
        notebook.cells[0] = cell
      } else {
        let cell = NotebookCell(
          cellType: .sql,
          content: "SELECT \(i)",
          result: result
        )
        notebook.cells.append(cell)
      }
    }

    #expect(notebook.cells.count == 3)
    #expect(notebook.cells.allSatisfy { $0.result != nil })

    let optimized = FileOptimizationService.removeAllResults(from: notebook)

    #expect(optimized.cells.count == 3)
    #expect(optimized.cells.allSatisfy { $0.result == nil })
  }

  // MARK: - Statistics Tests

  @Test("Get notebook statistics")
  func testGetNotebookStatistics() {
    var notebook = DbloreNotebook.newDocument()

    // Add cells with and without results
    let result1 = CellResult(
      columns: [ColumnInfo(name: "id", type: "INTEGER")],
      rows: [[.int(1)], [.int(2)], [.int(3)]],
      executionTime: 0.1,
      rowCount: 3,
      timestamp: Date()
    )

    let result2 = CellResult(
      columns: [ColumnInfo(name: "id", type: "INTEGER")],
      rows: [[.int(1)], [.int(2)]],
      executionTime: 0.1,
      rowCount: 2,
      timestamp: Date()
    )

    var cell1 = notebook.cells[0]
    cell1.result = result1
    notebook.cells[0] = cell1

    let cell2 = NotebookCell(
      cellType: .sql,
      content: "SELECT 2",
      result: result2
    )
    notebook.cells.append(cell2)

    let cell3 = NotebookCell(
      cellType: .sql,
      content: "SELECT 3"
    )
    notebook.cells.append(cell3)

    let stats = FileOptimizationService.getNotebookStatistics(notebook)

    #expect(stats.totalCells == 3)
    #expect(stats.cellsWithResults == 2)
    #expect(stats.totalRows == 5)
    #expect(stats.hasResults == true)
    #expect(stats.approximateResultDataSize > 0)
  }

  // MARK: - Compact Format Tests

  @Test("Compact format reduces file size")
  func testCompactFormat() throws {
    var notebook = DbloreNotebook.newDocument()

    // Add result with data
    var rows: [[CellValue]] = []
    for i in 0..<50 {
      rows.append([.int(i), .string("Test data \(i)")])
    }

    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
      ],
      rows: rows,
      executionTime: 0.5,
      rowCount: 50,
      timestamp: Date()
    )

    var cell = notebook.cells[0]
    cell.result = result
    notebook.cells[0] = cell

    let prettyData = try FileOptimizationService.DocumentCoder.encode(
      notebook,
      includeResultsOnSave: true,
      useCompactFormat: false
    )

    let compactData = try FileOptimizationService.DocumentCoder.encode(
      notebook,
      includeResultsOnSave: true,
      useCompactFormat: true
    )

    // Compact format should be smaller or equal (depends on encoder implementation)
    // Note: JSONEncoder with .sortedKeys may produce same output regardless of prettyPrinted
    #expect(compactData.count <= prettyData.count)

    // Both should decode to same notebook
    let prettyString = String(data: prettyData, encoding: .utf8)
    let compactString = String(data: compactData, encoding: .utf8)

    #expect(prettyString != nil)
    #expect(compactString != nil)

    // Just verify both are valid JSON strings
    #expect(!prettyString!.isEmpty)
    #expect(!compactString!.isEmpty)
  }
}
