//
//  FileOptimizationService.swift
//  SQLNotebook
//

import Foundation

/// Service for detecting and optimizing large notebook files
enum FileOptimizationService {
  // MARK: - Constants

  /// Large file threshold
  /// Production: 10MB (10 * 1024 * 1024)
  /// Testing: 23KB for easier testing
  nonisolated static let largeSizeThreshold: Int64 = 50 * 1024 * 1024

  /// Warning threshold
  /// Production: 5MB (5 * 1024 * 1024)
  /// Testing: 20KB for easier testing
  nonisolated static let warningSizeThreshold: Int64 = 40 * 1024 * 1024

  // MARK: - File Size Calculation

  /// Calculate the size of a notebook if it were saved to disk
  nonisolated static func calculateNotebookSize(
    _ notebook: SQLNotebook,
    includeResults: Bool
  ) throws -> Int64 {
    let data = try DocumentCoder.encode(notebook, includeResultsOnSave: includeResults)
    return Int64(data.count)
  }

  /// Format file size in human-readable format
  nonisolated static func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
  }

  // MARK: - Optimization Operations

  /// Remove results from all cells to reduce file size
  nonisolated static func removeAllResults(from notebook: SQLNotebook) -> SQLNotebook {
    var optimizedNotebook = notebook
    optimizedNotebook.cells = notebook.cells.map { cell in
      var newCell = cell
      newCell.result = nil
      return newCell
    }
    return optimizedNotebook
  }

  /// Remove results older than a specified date
  nonisolated static func removeOldResults(
    from notebook: SQLNotebook,
    olderThan date: Date
  ) -> (notebook: SQLNotebook, removedCount: Int) {
    var optimizedNotebook = notebook
    var removedCount = 0

    optimizedNotebook.cells = notebook.cells.map { cell in
      var newCell = cell
      if let result = cell.result, result.timestamp < date {
        newCell.result = nil
        removedCount += 1
      }
      return newCell
    }

    return (optimizedNotebook, removedCount)
  }

  /// Calculate potential size reduction if results were removed
  nonisolated static func calculateSizeReduction(
    for notebook: SQLNotebook
  ) throws -> (withResults: Int64, withoutResults: Int64, reduction: Int64) {
    let withResults = try calculateNotebookSize(notebook, includeResults: true)
    let withoutResults = try calculateNotebookSize(notebook, includeResults: false)
    let reduction = withResults - withoutResults

    return (withResults, withoutResults, reduction)
  }

  /// Get statistics about the notebook
  nonisolated static func getNotebookStatistics(
    _ notebook: SQLNotebook
  ) -> NotebookStatistics {
    let totalCells = notebook.cells.count
    let cellsWithResults = notebook.cells.filter { $0.result != nil }.count
    let totalRows = notebook.cells.compactMap { $0.result?.rowCount }.reduce(0, +)

    // Calculate approximate data sizes
    var resultDataSize: Int64 = 0
    for cell in notebook.cells {
      if let result = cell.result {
        // Approximate size: each row * columns * average bytes per value
        let avgBytesPerValue = 50  // Conservative estimate
        let rowSize = result.columns.count * avgBytesPerValue
        resultDataSize += Int64(result.rows.count * rowSize)
      }
    }

    return NotebookStatistics(
      totalCells: totalCells,
      cellsWithResults: cellsWithResults,
      totalRows: totalRows,
      approximateResultDataSize: resultDataSize
    )
  }
}

/// Statistics about a notebook
struct NotebookStatistics: Sendable {
  let totalCells: Int
  let cellsWithResults: Int
  let totalRows: Int
  let approximateResultDataSize: Int64

  var hasResults: Bool {
    cellsWithResults > 0
  }
}

/// The document coder the app saves with (the nested `DocumentCoder` below shadows the name)
private typealias MainDocumentCoder = DocumentCoder

/// Expose DocumentCoder for file size calculation. Delegates to the main coder so the size
/// estimate uses exactly the saved format (same keys, same legacy-compatibility rules).
extension FileOptimizationService {
  enum DocumentCoder {
    nonisolated static func encode(
      _ notebook: SQLNotebook,
      includeResultsOnSave: Bool,
      useCompactFormat: Bool = false
    ) throws -> Data {
      try MainDocumentCoder.encode(
        notebook, includeResultsOnSave: includeResultsOnSave, useCompactFormat: useCompactFormat)
    }
  }
}
