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

  @Test("A third line ends the second preview line with an ellipsis")
  func thirdLineAddsEllipsis() {
    let sql = """
      -- SELECT * FROM aicreds LIMIT 350;
      SELECT * FROM document LIMIT 350;
      SELECT * FROM other;
      """
    #expect(
      HistorySQLPreview.lines(from: sql) == [
        "-- SELECT * FROM aicreds LIMIT 350;",
        "SELECT * FROM document LIMIT 350;...",
      ])
  }

  @Test("A single line stays one line")
  func singleLine() {
    #expect(HistorySQLPreview.lines(from: "SELECT 1;") == ["SELECT 1;"])
  }

  @Test("Blank lines do not take a preview slot")
  func skipsBlankLines() {
    #expect(
      HistorySQLPreview.lines(from: "\n\nSELECT 1;\n\nSELECT 2;\nSELECT 3;\n") == [
        "SELECT 1;",
        "SELECT 2;...",
      ])
  }
}
