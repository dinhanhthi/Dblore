// ExportSizeTests.swift
// Download size check. Wrapped PDF pages are the case that grows without a byte cap.

import Foundation
import Testing

@testable import Dblore

@Suite("Export size")
@MainActor
struct ExportSizeTests {
  @Test("A short CSV stays under the limit and is in the same range as the real file")
  func smallCSV() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      rows: [[.int(1), .string("ada")]],
      rowCount: 1)
    let estimate = ExportSize.estimate(result: result, options: ExportOptions(format: .csv))
    let actual = DataExporter.toCSV(result: result).utf8.count
    #expect(!estimate.isLarge)
    #expect(estimate.pageCount == nil)
    #expect(estimate.bytes >= actual / 2)
    #expect(estimate.bytes <= actual * 2)
  }

  @Test("Wrapped long cells cross the page limit, and the same PDF without wrap does not")
  func wrappedPDFIsLarge() {
    let long = String(repeating: "a", count: 5_000)
    let row = Array(repeating: CellValue.string(long), count: 6)
    let result = CellResult(
      columns: (0..<6).map { ColumnInfo(name: "c\($0)", type: "text") },
      rows: Array(repeating: row, count: 40),
      rowCount: 40)
    let wrapped = ExportSize.estimate(
      result: result, options: ExportOptions(format: .pdf, wrapText: true))
    let clipped = ExportSize.estimate(
      result: result, options: ExportOptions(format: .pdf, wrapText: false))
    #expect(wrapped.pageCount ?? 0 >= ExportSizeEstimate.largePageCount)
    #expect(wrapped.isLarge)
    #expect(wrapped.warnsAboutWrap)
    #expect((clipped.pageCount ?? 0) < ExportSizeEstimate.largePageCount)
    #expect(!clipped.isLarge)
  }

  @Test("Redacting the long columns brings the wrapped PDF back under the page limit")
  func redactionShrinksWrappedPDF() {
    let long = String(repeating: "a", count: 5_000)
    let row = Array(repeating: CellValue.string(long), count: 6)
    let result = CellResult(
      columns: (0..<6).map { ColumnInfo(name: "c\($0)", type: "text") },
      rows: Array(repeating: row, count: 40),
      rowCount: 40)
    let estimate = ExportSize.estimate(
      result: result,
      options: ExportOptions(format: .pdf, redactedColumns: Set(0..<6), wrapText: true))
    #expect((estimate.pageCount ?? 0) < ExportSizeEstimate.largePageCount)
    #expect(!estimate.isLarge)
  }

  @Test("The byte and page limits are what marks an export as large")
  func limits() {
    let big = ExportSizeEstimate(
      bytes: ExportSizeEstimate.largeByteCount, pageCount: nil, warnsAboutWrap: false)
    let pages = ExportSizeEstimate(
      bytes: 1, pageCount: ExportSizeEstimate.largePageCount, warnsAboutWrap: true)
    let small = ExportSizeEstimate(
      bytes: ExportSizeEstimate.largeByteCount - 1,
      pageCount: ExportSizeEstimate.largePageCount - 1,
      warnsAboutWrap: false)
    #expect(big.isLarge)
    #expect(pages.isLarge)
    #expect(!small.isLarge)
  }
}
