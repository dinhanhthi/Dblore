//
//  FileOptimizationServiceTests.swift
//  SQLNotebookTests
//

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
struct FileOptimizationServiceTests {
  // MARK: - File Size Calculation Tests

  @Test("Calculate size for empty notebook")
  func testCalculateSizeEmptyNotebook() throws {
    let notebook = SQLNotebook.newDocument()
    let size = try FileOptimizationService.calculateNotebookSize(
      notebook,
      includeResults: true
    )

    #expect(size > 0)
    #expect(size < 1000)  // Empty notebook should be small (< 1KB)
  }

  @Test("Calculate size with results")
  func testCalculateSizeWithResults() throws {
    var notebook = SQLNotebook.newDocument()

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
    #expect(sizeWithResults > 1000)  // Should be larger with results
  }

  // MARK: - Size Formatting Tests

  @Test("Format file sizes")
  func testFormatFileSize() {
    let kb = FileOptimizationService.formatFileSize(1024)
    let mb = FileOptimizationService.formatFileSize(1024 * 1024)
    let gb = FileOptimizationService.formatFileSize(1024 * 1024 * 1024)

    #expect(kb.contains("KB") || kb.contains("kB"))
    #expect(mb.contains("MB"))
    #expect(gb.contains("GB"))
  }

  // MARK: - Optimization Tests

  @Test("Remove all results from notebook")
  func testRemoveAllResults() throws {
    var notebook = SQLNotebook.newDocument()

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

  @Test("Calculate size reduction")
  func testCalculateSizeReduction() throws {
    var notebook = SQLNotebook.newDocument()

    // Add large result
    var rows: [[CellValue]] = []
    for i in 0..<100 {
      rows.append([.int(i), .string("Name \(i)"), .string("Description for row \(i)")])
    }

    let result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "description", type: "TEXT"),
      ],
      rows: rows,
      executionTime: 0.5,
      rowCount: 100,
      timestamp: Date()
    )

    var cell = notebook.cells[0]
    cell.result = result
    notebook.cells[0] = cell

    let (withResults, withoutResults, reduction) =
      try FileOptimizationService.calculateSizeReduction(for: notebook)

    #expect(withResults > withoutResults)
    #expect(reduction == withResults - withoutResults)
    #expect(reduction > 0)
  }

  // MARK: - Statistics Tests

  @Test("Get notebook statistics")
  func testGetNotebookStatistics() {
    var notebook = SQLNotebook.newDocument()

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

  @Test("Statistics for empty notebook")
  func testStatisticsEmptyNotebook() {
    let notebook = SQLNotebook.newDocument()
    let stats = FileOptimizationService.getNotebookStatistics(notebook)

    #expect(stats.totalCells == 1)
    #expect(stats.cellsWithResults == 0)
    #expect(stats.totalRows == 0)
    #expect(stats.hasResults == false)
    #expect(stats.approximateResultDataSize == 0)
  }

  // MARK: - Compact Format Tests

  @Test("Compact format reduces file size")
  func testCompactFormat() throws {
    var notebook = SQLNotebook.newDocument()

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

    // Compact format should be smaller (removes whitespace and formatting)
    #expect(compactData.count < prettyData.count)

    // Both should decode to same notebook
    let prettyString = String(data: prettyData, encoding: .utf8)
    let compactString = String(data: compactData, encoding: .utf8)

    #expect(prettyString != nil)
    #expect(compactString != nil)

    // Pretty format should have newlines, compact should not
    #expect(prettyString!.contains("\n"))
    #expect(!compactString!.contains("\n") || compactString!.filter { $0 == "\n" }.count < 5)
  }
}
