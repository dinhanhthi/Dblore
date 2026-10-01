// PerformanceBenchmarkTests.swift
// Baseline benchmarks (Debug). Each test records a median through PerfReport.
// Scaling checks compare two measurements from the same run, so a slow CI runner
// does not fail the suite. Absolute ceilings stay only where the slack is huge
// (ReDoS under 1 s, a 100 KB autocomplete under 5 ms).

import AppKit
import Foundation
import Testing

@testable import Dblore

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
    let lines = sql.split(separator: "\n", omittingEmptySubsequences: false)
    let short = lines.prefix(400).joined(separator: "\n")
    withSyntaxHighlightingEnabled {
      var shortLength = 0
      var fullLength = 0
      let shortMs = PerfBench.median(of: 5) {
        shortLength = SQLSyntaxHighlighter.highlight(short).length
      }
      let fullMs = PerfBench.median(of: 5) {
        fullLength = SQLSyntaxHighlighter.highlight(sql).length
      }
      #expect(shortLength == short.utf16.count)
      #expect(fullLength == sql.utf16.count)
      PerfReport.record("fullHighlight400Lines", ms: shortMs)
      PerfReport.record("fullHighlight2kLines", ms: fullMs)
      // 5× the lines. Linear stays near 5×. A quadratic highlighter is about 25×.
      // 15× leaves room for a fixed per-call cost on the shorter sample.
      #expect(
        fullMs < shortMs * 15,
        "full highlight \(fullMs) ms is more than 15× the 400-line highlight \(shortMs) ms")
    }
  }

  @Test("no regex is compiled per highlight call")
  func noRegexCompiledPerCall() {
    let before = SQLSyntaxHighlighter.scanRegexes
    withSyntaxHighlightingEnabled {
      _ = SQLSyntaxHighlighter.highlight("SELECT count(*) FROM t WHERE a = 'x' -- c")
      _ = SQLSyntaxHighlighter.highlight("SELECT 1")
    }
    let after = SQLSyntaxHighlighter.scanRegexes
    #expect(before.count == after.count)
    for (b, a) in zip(before, after) { #expect(b === a) }
  }

  // MARK: - Adversarial inputs (ReDoS)

  private func seconds(_ body: () -> Void) -> Double {
    let d = ContinuousClock().measure(body)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  private func expectNoColor(_ attributed: NSAttributedString, _ color: NSColor) {
    var found = false
    attributed.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: attributed.length), options: []
    ) { value, _, stop in
      if let c = value as? NSColor, c == color {
        found = true
        stop.pointee = true
      }
    }
    #expect(!found)
  }

  @Test("unterminated block comments scan in linear time", .timeLimit(.minutes(1)))
  func unterminatedBlockComments() {
    let text = String(repeating: "/* ", count: 200_000)
    withSyntaxHighlightingEnabled {
      var spans: [NSRange] = []
      var result = NSAttributedString()
      let t = seconds {
        spans = SQLSyntaxHighlighter.blockSpans(in: text as NSString)
        result = SQLSyntaxHighlighter.highlight(text)
      }
      #expect(t < 1, "took \(t) s")
      #expect(spans.isEmpty)
      expectNoColor(result, SQLSyntaxHighlighter.Palette().comment)
    }
  }

  @Test("a long digit run ending in a letter is not a number", .timeLimit(.minutes(1)))
  func longDigitRunThenLetter() {
    let text = String(repeating: "1", count: 100_000) + "a"
    withSyntaxHighlightingEnabled {
      var result = NSAttributedString()
      let t = seconds { result = SQLSyntaxHighlighter.highlight(text) }
      #expect(t < 1, "took \(t) s")
      expectNoColor(result, SQLSyntaxHighlighter.Palette().number)
    }
  }

  @Test("repeated quotes and dollar quotes without closer are linear", .timeLimit(.minutes(1)))
  func repeatedQuotesAndDollars() {
    let escapedQuotes = String(repeating: "\\'", count: 100_000)
    let quotes = String(repeating: "'", count: 100_000)
    let dollars = String(repeating: "$$ ", count: 100_000) + "$"
    withSyntaxHighlightingEnabled {
      for text in [quotes, dollars, "'" + escapedQuotes] {
        let t = seconds {
          _ = SQLSyntaxHighlighter.blockSpans(in: text as NSString)
          _ = SQLSyntaxHighlighter.highlight(text)
        }
        #expect(t < 1, "took \(t) s")
      }
    }
  }

  @Test("highlight(in:range:palette:) only touches attributes inside the range")
  func subRangeHighlightLeavesOutsideUntouched() {
    let text = "SELECT 1 FROM t\nSELECT 2 FROM u\nSELECT 3 FROM v"
    let ns = text as NSString
    let palette = SQLSyntaxHighlighter.Palette()
    let storage = NSMutableAttributedString(string: text)
    storage.addAttributes(palette.defaultAttributes, range: NSRange(location: 0, length: ns.length))
    let middle = ns.paragraphRange(for: NSRange(location: ns.range(of: "u").location, length: 0))
    SQLSyntaxHighlighter.highlight(in: storage, range: middle, palette: palette)
    for i in 0..<ns.length {
      let color = storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
      if NSLocationInRange(i, middle) { continue }
      #expect(color === palette.foreground, "offset \(i) outside range was modified")
    }
    let kw =
      storage.attribute(
        .foregroundColor, at: middle.location, effectiveRange: nil) as? NSColor
    #expect(kw === palette.keyword)
  }

  @Test("keystrokeHighlight2kLines")
  func keystrokeHighlight2kLines() {
    withSyntaxHighlightingEnabled {
      let sql = PerfFixtures.sql2kLines()
      var fullLength = 0
      let fullMs = PerfBench.median(of: 5) {
        fullLength = SQLSyntaxHighlighter.highlight(sql).length
      }
      #expect(fullLength == sql.utf16.count)

      let host = OffscreenEditorHost(text: sql)
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
      let median = samples[samples.count / 2]
      PerfReport.record("keystrokeHighlight2kLines", ms: median)
      // On CI the keystroke median stayed about 1/8 of a full highlight, on a fast
      // runner and on a slow one. Half still fails when a keystroke re-highlights
      // the whole document.
      #expect(
        median * 2 < fullMs,
        "keystroke \(median) ms is not under half of full highlight \(fullMs) ms")
    }
  }

  // Typical case: 100 KB document, cursor in a short last statement (tiny statement window).
  @Test("autocompleteSuggestions100KB")
  func autocompleteSuggestions100KB() {
    let provider = autocompleteProvider()
    let text = PerfFixtures.sql2kLines() + "\nSELECT * FROM us"
    let (count, ms) = suggestionMedian(provider, text: text)
    #expect(count > 0)
    PerfReport.record("autocompleteSuggestions100KB", ms: ms)
    #expect(ms < 5, "autocomplete median \(ms) ms")
  }

  // Worst case: one statement without any ";", aliases present, cursor at the end.
  // The 100 KB / 200 JOIN shape is the old quadratic case (~74 ms in Debug).
  @Test("autocompleteSuggestionsHugeStatement")
  func autocompleteSuggestionsHugeStatement() {
    let provider = autocompleteProvider()
    let smallText = hugeStatement(minUTF8Bytes: 10_000, joins: 20)
    let largeText = hugeStatement(minUTF8Bytes: 100_000, joins: 200)
    #expect(smallText.utf8.count >= 10_000 && !smallText.contains(";"))
    #expect(largeText.utf8.count >= 100_000 && !largeText.contains(";"))

    let (smallCount, smallMs) = suggestionMedian(provider, text: smallText)
    let (largeCount, largeMs) = suggestionMedian(provider, text: largeText)
    #expect(smallCount > 0)
    #expect(largeCount > 0)
    PerfReport.record("autocompleteSuggestions10KB", ms: smallMs)
    PerfReport.record("autocompleteSuggestionsHugeStatement", ms: largeMs)
    // Fixed cost dominates: locally 10 KB / 20 JOINs was 6.1 ms and 100 KB /
    // 200 JOINs was 8.0 ms (~1.3×). getSuggestions only scans the cursor window,
    // so the old full-text ~74 ms is not 10× this small shape. A quadratic scan
    // still inside the window is ~40 ms vs ~7 ms. 4× fails that and passes ~1.3×.
    #expect(
      largeMs < smallMs * 4,
      "100 KB autocomplete \(largeMs) ms is more than 4× the 10 KB run \(smallMs) ms")
  }

  private func autocompleteProvider() -> SQLAutocompleteProvider {
    let provider = SQLAutocompleteProvider()
    provider.update(
      tables: ["users", "orders", "order_items", "products", "sessions"].map {
        DatabaseTable(
          schema: "public", name: $0,
          columns: [DatabaseColumn(name: "id", type: "integer")])
      })
    return provider
  }

  /// One statement with no ";". The SELECT list grows to `minUTF8Bytes`, then `joins` JOINs.
  private func hugeStatement(minUTF8Bytes: Int, joins: Int) -> String {
    var text = "SELECT "
    var i = 0
    while text.utf8.count < minUTF8Bytes {
      text += "u\(i).id, o\(i).total, p\(i).name, "
      i += 1
    }
    text += "x FROM users u0 JOIN orders o0 ON o0.id = u0.id"
    for j in 0..<joins { text += " JOIN products p\(j) ON p\(j).id = u0.id" }
    text += " WHERE us"
    return text
  }

  private func suggestionMedian(
    _ provider: SQLAutocompleteProvider, text: String
  ) -> (count: Int, ms: Double) {
    let cursor = (text as NSString).length  // UTF-16 offset, as NSTextView reports it
    var count = 0
    let ms = PerfBench.median(of: 20) {
      count = provider.getSuggestions(for: text, at: cursor).count
    }
    return (count, ms)
  }

  @Test("gridDisplayText1000x30")
  func gridDisplayText1000x30() {
    let result = PerfFixtures.cellResult()
    #expect(result.rows.count == 1000 && result.columns.count == 30)
    func pass(_ model: ResultGridModel) -> Int {
      var total = 0
      for row in 0..<model.rowCount {
        for column in 0..<model.columns.count {
          total += model.displayText(row: row, column: column).utf16.count
        }
      }
      return total
    }

    // First pass: a fresh (cold cache) model per run
    var total = 0
    let first = PerfBench.median(of: 7, warmup: 1) {
      let fresh = ResultGridModel(result: result, sortColumn: nil, ascending: true)
      total = pass(fresh)
    }
    #expect(total > 0)
    PerfReport.record("gridDisplayText1000x30.firstPass", ms: first)

    let model = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    _ = pass(model)
    let second = PerfBench.median(of: 20, warmup: 0) { _ = pass(model) }
    PerfReport.record("gridDisplayText1000x30.secondPass", ms: second)
    #expect(second * 5 <= first, "warm pass \(second) ms not 5x faster than cold \(first) ms")

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
