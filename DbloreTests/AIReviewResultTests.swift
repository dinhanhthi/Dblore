// AIReviewResultTests.swift
// Parsing the review JSON: plain and fenced answers, raw fallback, unknown severities, the step
// and input caps, and a blank statement

import Foundation
import Testing

@testable import Dblore

@Suite("AIReviewResult")
struct AIReviewResultTests {

  private static let json = """
    {"summary": "Add an index", "steps": [
      {"severity": "critical", "title": "Full scan", "detail": "orders is scanned"},
      {"severity": "change", "title": "Index", "detail": "Index user_id"}
    ], "sql": "SELECT id FROM orders WHERE user_id = 1"}
    """

  private static let expected = AIReviewResult.review(
    summary: "Add an index",
    steps: [
      .init(severity: .critical, title: "Full scan", detail: "orders is scanned"),
      .init(severity: .change, title: "Index", detail: "Index user_id"),
    ],
    sql: "SELECT id FROM orders WHERE user_id = 1")

  @Test func parsesPlainJSON() {
    #expect(AIReviewResult.parse(Self.json) == Self.expected)
  }

  @Test func parsesJSONFence() {
    #expect(AIReviewResult.parse("```json\n\(Self.json)\n```\n") == Self.expected)
  }

  @Test func parsesBareFence() {
    #expect(AIReviewResult.parse("  ```\n\(Self.json)\n```") == Self.expected)
  }

  @Test func invalidJSONFallsBackToRaw() {
    let text = "The query looks fine.\n```sql\nSELECT 1\n```"
    #expect(AIReviewResult.parse(text) == .raw(text))
  }

  @Test func missingSummaryFallsBackToRaw() {
    let text = #"{"steps": [], "sql": "SELECT 1"}"#
    #expect(AIReviewResult.parse(text) == .raw(text))
  }

  @Test func unknownSeverityMapsToContext() {
    let text = #"{"summary": "s", "steps": [{"severity": "warning", "title": "t", "detail": "d"}]}"#
    #expect(
      AIReviewResult.parse(text)
        == .review(
          summary: "s", steps: [.init(severity: .context, title: "t", detail: "d")], sql: nil)
    )
  }

  @Test func capsSteps() {
    let step = #"{"severity": "change", "title": "t", "detail": "d"}"#
    let text =
      #"{"summary": "s", "steps": ["# + Array(repeating: step, count: 60).joined(separator: ",")
      + "]}"
    guard case .review(_, let steps, _) = AIReviewResult.parse(text) else {
      Issue.record("expected a review")
      return
    }
    #expect(steps.count == AIReviewResult.stepLimit)
  }

  @Test func inputOverLimitStaysRaw() {
    let padding = String(repeating: " ", count: AIReviewResult.inputLimit)
    let text = #"{"summary": "s"}"# + padding
    #expect(AIReviewResult.parse(text) == .raw(text))
  }

  @Test func blankSQLIsNil() {
    #expect(
      AIReviewResult.parse(#"{"summary": "s", "sql": "  \n"}"#)
        == .review(summary: "s", steps: [], sql: nil))
  }
}
