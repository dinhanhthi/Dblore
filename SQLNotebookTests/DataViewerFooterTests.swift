// DataViewerFooterTests.swift
// The data viewer footer shows where the loaded page sits in the relation: page count and row
// range once COUNT(*) returned, just the page number while it is unknown.

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
@Suite("Data Viewer Footer Tests")
struct DataViewerFooterTests {
  private func state(
    page: Int = 1, pageSize: Int = 100, totalRows: Int? = nil
  )
    -> DataViewerState
  {
    DataViewerState(
      schema: "public", name: "users", orderColumns: [], page: page, pageSize: pageSize,
      totalRows: totalRows)
  }

  @Test("Known total shows page count and row range")
  func knownTotal() {
    let label = DataViewerView.pageLabel(
      state: state(page: 2, totalRows: 250), loadedRows: 100)
    #expect(label == "Page 2 of 3 · 101–200 of 250")
  }

  @Test("Unknown total shows only the page")
  func unknownTotal() {
    #expect(DataViewerView.pageLabel(state: state(page: 4), loadedRows: 100) == "Page 4")
  }

  @Test("Empty relation shows page 1 of 1 without a row range")
  func emptyRelation() {
    #expect(
      DataViewerView.pageLabel(state: state(totalRows: 0), loadedRows: 0) == "Page 1 of 1 · 0 rows")
  }
}
