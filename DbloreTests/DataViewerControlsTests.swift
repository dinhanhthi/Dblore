// DataViewerFooterTests.swift
// The data viewer header shows where the loaded page sits in the relation: row range and total
// once COUNT(*) returned, just the row range while it is unknown.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Data Viewer Controls Tests")
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

  @Test("Known total shows row range and total")
  func knownTotal() {
    let label = DataViewerControls.pageLabel(
      state: state(page: 2, totalRows: 250), loadedRows: 100)
    #expect(label == "101–200 of 250")
  }

  @Test("Unknown total shows only the row range")
  func unknownTotal() {
    #expect(DataViewerControls.pageLabel(state: state(page: 4), loadedRows: 100) == "301–400")
  }

  @Test("Empty relation shows 0 rows")
  func emptyRelation() {
    #expect(DataViewerControls.pageLabel(state: state(totalRows: 0), loadedRows: 0) == "0 rows")
  }
}
