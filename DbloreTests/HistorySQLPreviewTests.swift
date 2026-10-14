// HistorySQLPreviewTests.swift
// Two-line history sidebar preview. The second line ends with "...".

import Testing

@testable import Dblore

@Suite("History SQL preview")
struct HistorySQLPreviewTests {
  @Test("A comment line keeps the statement on the second line")
  func secondStatementStaysVisible() {
    let sql = """
      -- SELECT * FROM aicreds LIMIT 350;
      SELECT * FROM document LIMIT 350;
      """
    #expect(
      HistorySQLPreview.lines(from: sql) == [
        "-- SELECT * FROM aicreds LIMIT 350;",
        "SELECT * FROM document LIMIT 350;...",
      ])
  }

}
