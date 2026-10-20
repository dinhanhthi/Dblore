// AIReviewResult.swift
// Parses the JSON answer of an AI review or optimize request into a summary, severity-tagged
// steps and an optional rewritten statement; anything else stays raw text

import Foundation

/// The answer to a review or optimize request. The model is asked for
/// `{"summary", "steps": [{"severity", "title", "detail"}], "sql"}`, optionally wrapped in one
/// ```json (or bare ```) fence. Any other answer is kept as `.raw` so it can still be shown.
nonisolated enum AIReviewResult: Equatable, Sendable {
  case review(summary: String, steps: [Step], sql: String?)
  case raw(String)

  /// At most this many steps are kept; the rest are dropped
  static let stepLimit = 50
  /// Answers longer than this (UTF-8 bytes) are not parsed and stay raw, untruncated
  static let inputLimit = 64 * 1024

  enum Severity: String, Equatable, Sendable {
    case critical, change, context
  }

  struct Step: Equatable, Sendable {
    let severity: Severity
    let title: String
    let detail: String
  }

  private struct Payload: Decodable {
    struct Item: Decodable {
      let severity: String?
      let title: String?
      let detail: String?
    }
    let summary: String
    let steps: [Item]?
    let sql: String?
  }

  /// Reads `text` as the review JSON. Invalid JSON, a missing `summary` or input over
  /// `inputLimit` gives `.raw(text)`. Unknown severities become `.context`; a blank `sql` is nil.
  static func parse(_ text: String) -> AIReviewResult {
    guard text.utf8.count <= inputLimit,
      let payload = try? JSONDecoder().decode(Payload.self, from: Data(unfenced(text).utf8))
    else { return .raw(text) }
    let steps = (payload.steps ?? []).prefix(stepLimit).map { item in
      Step(
        severity: Severity(rawValue: item.severity?.lowercased() ?? "") ?? .context,
        title: item.title ?? "", detail: item.detail ?? "")
    }
    let sql = payload.sql?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .review(summary: payload.summary, steps: steps, sql: sql?.isEmpty == false ? sql : nil)
  }

  /// `text` trimmed, without one surrounding ``` fence (its first line holds the language)
  private static func unfenced(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6,
      let lineEnd = trimmed.firstIndex(where: \.isNewline)
    else { return trimmed }
    return String(trimmed[lineEnd..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
  }
}
