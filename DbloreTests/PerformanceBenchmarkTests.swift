// PerformanceBenchmarkTests.swift
// Adversarial-input checks (Debug): the SQL highlighter scans unterminated comments, quotes
// and long digit runs in linear time. The absolute ceiling (under 1 s) leaves huge slack, so
// a slow CI runner does not fail the suite. Timings are asserted, not recorded in PerfReport.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Performance benchmarks", .serialized)
@MainActor
struct PerformanceBenchmarkTests {

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
}
