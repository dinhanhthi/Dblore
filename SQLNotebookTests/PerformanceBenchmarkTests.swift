// PerformanceBenchmarkTests.swift
// Baseline benchmarks (Debug): each reports the median of N runs through PerfReport. No
// budget asserts yet, only sanity checks.

import AppKit
import Foundation
import Testing

@testable import SQLNotebook

@Suite("Performance benchmarks", .serialized)
@MainActor
struct PerformanceBenchmarkTests {

  @Test("Fixture is about 2k lines and 100 KB")
  func fixtureShape() {
    let sql = PerfFixtures.sql2kLines()
    #expect((90_000...130_000).contains(sql.utf16.count))
    #expect(
      (1900...2100).contains(sql.split(separator: "\n", omittingEmptySubsequences: false).count))
    #expect(sql == PerfFixtures.sql2kLines())
  }

  @Test("fullHighlight2kLines")
  func fullHighlight2kLines() {
    let sql = PerfFixtures.sql2kLines()
    withSyntaxHighlightingEnabled {
      var length = 0
      let ms = PerfBench.median(of: 5) { length = SQLSyntaxHighlighter.highlight(sql).length }
      #expect(length == sql.utf16.count)
      PerfReport.record("fullHighlight2kLines", ms: ms)
    }
  }

  @Test("keystrokeHighlight2kLines")
  func keystrokeHighlight2kLines() {
    withSyntaxHighlightingEnabled {
      let host = OffscreenEditorHost(text: PerfFixtures.sql2kLines())
      defer { host.close() }
      let before = host.textView.string
      var samples: [Double] = []
      // one warmup keystroke, then 20 measured ones
      for i in 0..<21 {
        host.insertCharacterMidDocument(i % 2 == 0 ? "x" : "y")
        let d = ContinuousClock().measure { host.fireTextDidChange() }
        if i > 0 {
          samples.append(
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
      }
      #expect(host.textView.string.utf16.count == before.utf16.count + 21)
      #expect(host.boundValue == host.textView.string)
      // the coordinator really re-highlighted: the storage carries colors
      let storage = host.textView.textStorage!
      #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
      samples.sort()
      PerfReport.record("keystrokeHighlight2kLines", ms: samples[samples.count / 2])
    }
  }

  @Test("autocompleteSuggestions100KB")
  func autocompleteSuggestions100KB() {
    let provider = SQLAutocompleteProvider()
    provider.tables = ["users", "orders", "order_items", "products", "sessions"].map {
      DatabaseTable(schema: "public", name: $0)
    }
    let text = PerfFixtures.sql2kLines() + "\nSELECT * FROM us"
    var count = 0
    let ms = PerfBench.median(of: 20) {
      count = provider.getSuggestions(for: text, at: text.count).count
    }
    #expect(count > 0)
    PerfReport.record("autocompleteSuggestions100KB", ms: ms)
  }

  @Test("gridDisplayText1000x30")
  func gridDisplayText1000x30() {
    let result = PerfFixtures.cellResult()
    #expect(result.rows.count == 1000 && result.columns.count == 30)
    let model = ResultGridModel(result: result, sortColumn: nil, ascending: true)

    func pass() -> Int {
      var total = 0
      for row in 0..<model.rowCount {
        for column in 0..<model.columns.count {
          total += model.displayText(row: row, column: column).utf16.count
        }
      }
      return total
    }

    var total = 0
    let first = ContinuousClock().measure { total = pass() }
    #expect(total > 0)
    PerfReport.record("gridDisplayText1000x30.firstPass", ms: milliseconds(first))
    let second = PerfBench.median(of: 20, warmup: 0) { _ = pass() }
    PerfReport.record("gridDisplayText1000x30.secondPass", ms: second)

    var width: CGFloat = 0
    let fit = PerfBench.median(of: 5) {
      for column in 0..<model.columns.count {
        width += ResultGridCoordinator.fitWidth(
          column: column, model: model, headerWidth: 0, minWidth: 40)
      }
    }
    #expect(width > 0)
    PerfReport.record("gridDisplayText1000x30.columnFit30Columns", ms: fit)
  }

  private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
  }
}
