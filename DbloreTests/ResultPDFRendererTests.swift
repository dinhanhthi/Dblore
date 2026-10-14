// ResultPDFRendererTests.swift
// Paginated PDF of an already-loaded query result: pages, repeated headers, truncation.

import Foundation
import PDFKit
import Testing

@testable import Dblore

@Suite("Result PDF renderer")
struct ResultPDFRendererTests {
  @Test("Zero rows still produce a PDF with at least one page")
  func emptyRows() {
    let data = ResultPDFRenderer.render(
      result: result(columns: [ColumnInfo(name: "h_alpha", type: "text")], rows: []),
      title: "Empty",
      query: nil)
    let document = PDFDocument(data: data)
    #expect(document != nil)
    #expect((document?.pageCount ?? 0) >= 1)
  }

  @Test("Two hundred fifty short rows span a second page that repeats every column header")
  func manyRowsRepeatHeaders() {
    let names = ["h_alpha", "h_beta", "h_gamma"]
    let columns = names.map { ColumnInfo(name: $0, type: "text") }
    let rows = (0..<250).map { index in
      names.map { _ in CellValue.string("r\(index)") }
    }
    let document = PDFDocument(
      data: ResultPDFRenderer.render(
        result: result(columns: columns, rows: rows), title: "Many", query: nil))
    #expect((document?.pageCount ?? 0) > 1)
    let page = text(document?.page(at: 1))
    for name in names {
      #expect(page.contains(name))
    }
  }

  @Test("Wrapping keeps a long word and a later word instead of an ellipsis")
  func wrappedTextKeepsTail() {
    let tail = "TAILMARKER_XYZ"
    let packed = String(repeating: "a", count: 400) + tail
    let packedLines = ResultPDFRenderer.wrappedLines(packed, width: 40)
    #expect(packedLines.count > 1)
    #expect(packedLines.joined() == packed)

    let prose = String(repeating: "word ", count: 200) + tail
    let pageSize = CGSize(width: 420, height: 140)
    let document = PDFDocument(
      data: ResultPDFRenderer.render(
        result: result(
          columns: [ColumnInfo(name: "h_alpha", type: "text")],
          rows: [[.string(prose)]]),
        title: "Wrap",
        query: nil,
        wrapText: true,
        pageSize: pageSize))
    #expect((document?.pageCount ?? 0) > 1)
    let combined = (0..<(document?.pageCount ?? 0)).map { text(document?.page(at: $0)) }.joined(
      separator: "\n")
    #expect(combined.contains(tail))
    #expect(!combined.contains("…"))
  }

  private func result(columns: [ColumnInfo], rows: [[CellValue]]) -> QueryResult {
    QueryResult(columns: columns, rows: rows, rowCount: rows.count, executionTime: 0)
  }

  private func text(_ page: PDFPage?) -> String {
    if let string = page?.string, !string.isEmpty {
      return string
    }
    return page?.attributedString?.string ?? ""
  }
}
