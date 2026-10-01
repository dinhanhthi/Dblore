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

  @Test("One short row and no query fit on a single page")
  func singleRow() {
    let data = ResultPDFRenderer.render(
      result: result(
        columns: [ColumnInfo(name: "h_alpha", type: "text")],
        rows: [[.string("ok")]]),
      title: "One",
      query: nil)
    #expect(PDFDocument(data: data)?.pageCount == 1)
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

  @Test("A cell of hundreds of characters does not keep its untruncated tail")
  func longCellTruncated() {
    let tail = "TAILMARKER_XYZ"
    let value = String(repeating: "a", count: 400) + tail
    let document = PDFDocument(
      data: ResultPDFRenderer.render(
        result: result(
          columns: [ColumnInfo(name: "h_alpha", type: "text")],
          rows: [[.string(value)]]),
        title: "Long",
        query: nil))
    let page = text(document?.page(at: 0))
    #expect(page.contains("…") || !page.contains(tail))
  }

  @Test("Forty columns stay inside the requested media box")
  func fortyColumnsFitMediaBox() {
    let columns = (0..<40).map { ColumnInfo(name: "c\($0)", type: "text") }
    let row = (0..<40).map { CellValue.string("v\($0)") }
    let pageSize = ResultPDFRenderer.a4Landscape
    let data = ResultPDFRenderer.render(
      result: result(columns: columns, rows: [row]),
      title: "Wide",
      query: nil,
      pageSize: pageSize)
    #expect(!data.isEmpty)
    let document = PDFDocument(data: data)
    let count = document?.pageCount ?? 0
    #expect(count >= 1)
    for index in 0..<count {
      let box = document?.page(at: index)?.bounds(for: .mediaBox) ?? .zero
      #expect(abs(box.width - pageSize.width) <= 1)
      #expect(abs(box.height - pageSize.height) <= 1)
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

  @Test("A non-empty query is on the first page and stops after twelve lines")
  func queryBlockIsCapped() {
    let lines = (0..<20).map { "QLINE\($0)" }
    let document = PDFDocument(
      data: ResultPDFRenderer.render(
        result: result(
          columns: [ColumnInfo(name: "h_alpha", type: "text")],
          rows: [[.string("x")]]),
        title: "Query",
        query: lines.joined(separator: "\n")))
    let page = text(document?.page(at: 0))
    #expect(page.contains("QLINE0"))
    #expect(page.contains("QLINE11"))
    #expect(!page.contains("QLINE12"))
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
