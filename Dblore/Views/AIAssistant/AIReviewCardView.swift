//
//  AIReviewCardView.swift
//  Dblore
//
//  Answer to a Review or Optimize request: summary, severity-tagged steps and the local diff of
//  the rewritten statement with Apply; an answer that is not the review JSON shows as plain text
//

import AppKit
import SwiftUI

struct AIReviewCardView: View {
  let request: AIReviewRequest
  /// The finished answer text, read with `AIReviewResult.parse`
  let text: String
  /// Replaces the reviewed SQL with the rewritten one (never runs); nil disables Apply
  let onApply: ((String) -> NotebookViewModel.AIReviewApplyResult)?

  @State private var refusal: String?
  /// Stays on: the target no longer holds the reviewed SQL, so another Apply would be refused
  @State private var applied = false
  @State private var copied = false
  @State private var parsed = ParsedAnswer()

  var body: some View {
    let (result, hunks) = parsed.read(text, source: request.sourceSQL)
    VStack(alignment: .leading, spacing: 0) {
      header(result, hunks: hunks)
      Rectangle().fill(Color.border).frame(height: 1)
      VStack(alignment: .leading, spacing: Spacing.sm) {
        switch result {
        case .raw(let raw):
          Text(verbatim: raw)
            .font(.labelText)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
        case .review(let summary, let steps, _):
          Text(verbatim: summary)
            .font(.labelText)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
          ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            stepRow(step)
          }
          if let hunks { diff(hunks) }
        }
        if let refusal {
          Text(verbatim: refusal)
            .font(.small)
            .foregroundColor(.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.sm)
      .background(Color.cellBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  /// `hunks` is the diff to the rewritten SQL, nil without one
  private func header(_ result: AIReviewResult, hunks: [SQLLineDiff.Hunk]?) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(request.kind == .review ? "Review" : "Optimize")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer(minLength: 0)
      switch result {
      case .raw(let raw):
        Button(copied ? "Copied" : "Copy") { copy(raw) }
          .buttonStyle(AICodeActionButtonStyle())
      case .review(_, _, let sql):
        // Identical SQL gives no hunks: nothing to apply
        if let sql, hunks?.isEmpty == false {
          Button(applied ? "Applied" : "Apply") { apply(sql) }
            .buttonStyle(AICodeActionButtonStyle())
            .disabled(onApply == nil || applied)
            .help(
              onApply == nil
                ? "No active tab" : "Replace the reviewed query with this one (does not run)")
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
  }

  private func stepRow(_ step: AIReviewResult.Step) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
      severityBadge(step.severity)
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(verbatim: step.title)
          .font(.labelText.weight(.semibold))
          .foregroundColor(.foreground)
        if !step.detail.isEmpty {
          Text(verbatim: step.detail)
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
      }
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func severityBadge(_ severity: AIReviewResult.Severity) -> some View {
    let (label, color): (String, Color) =
      switch severity {
      case .critical: ("Critical", .destructive)
      case .change: ("Change", .warning)
      case .context: ("Context", .foregroundMuted)
      }
    return Text(label)
      .font(.smallest)
      .foregroundColor(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(color.opacity(0.14))
      .clipShape(Capsule())
  }

  @ViewBuilder
  private func diff(_ hunks: [SQLLineDiff.Hunk]) -> some View {
    if hunks.isEmpty {
      Text("No change proposed")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    } else {
      // Rows that fit stretch to the card edge; wider lines scroll sideways
      ViewThatFits(in: .horizontal) {
        diffLines(hunks)
        ScrollView(.horizontal, showsIndicators: false) { diffLines(hunks) }
      }
      .background(Color.cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
      .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
    }
  }

  private func diffLines(_ hunks: [SQLLineDiff.Hunk]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
        diffRow(
          "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@",
          color: .foregroundMuted, fill: .clear)
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
          switch line {
          case .context(let text): diffRow("  " + text, color: .foreground, fill: .clear)
          case .removed(let text):
            diffRow("- " + text, color: .foreground, fill: Color.destructive.opacity(0.12))
          case .added(let text):
            diffRow("+ " + text, color: .foreground, fill: Color.success.opacity(0.12))
          }
        }
      }
    }
    .textSelection(.enabled)
  }

  private func diffRow(_ text: String, color: Color, fill: Color) -> some View {
    Text(verbatim: text)
      .font(.monoSmall)
      .foregroundColor(color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Spacing.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill)
  }

  private func apply(_ sql: String) {
    guard let onApply else { return }
    switch onApply(sql) {
    case .applied:
      refusal = nil
      applied = true
    case .refused(let reason):
      refusal = reason
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

/// The parsed answer and its diff to the reviewed SQL, kept across re-renders (the panel
/// redraws on every streamed token of a later answer) and redone only when the text changes
private final class ParsedAnswer {
  private var key: (text: String, source: String)?
  private var value: (AIReviewResult, [SQLLineDiff.Hunk]?) = (.raw(""), nil)

  /// `hunks` is the diff to the rewritten SQL, nil without one
  func read(_ text: String, source: String) -> (result: AIReviewResult, hunks: [SQLLineDiff.Hunk]?)
  {
    if let key, key.text == text, key.source == source { return value }
    let result = AIReviewResult.parse(text)
    let hunks: [SQLLineDiff.Hunk]? =
      if case .review(_, _, let sql?) = result {
        SQLLineDiff.unified(old: source, new: sql)
      } else {
        nil
      }
    key = (text, source)
    value = (result, hunks)
    return value
  }
}

#Preview("AIReviewCardView") {
  let request = AIReviewRequest(
    kind: .optimize, sourceSQL: "SELECT *\nFROM orders\nWHERE status = 'open'",
    notebookId: UUID(), cellId: nil)
  return VStack(spacing: Spacing.md) {
    AIReviewCardView(
      request: request,
      text: """
        {"summary": "Select only the needed columns and use the status index.",
        "steps": [{"severity": "critical", "title": "SELECT *", "detail": "Reads every column."},
        {"severity": "change", "title": "Name the columns", "detail": "Smaller rows."},
        {"severity": "context", "title": "Index", "detail": "orders_status_idx covers it."}],
        "sql": "SELECT id, total\\nFROM orders\\nWHERE status = 'open'"}
        """,
      onApply: { _ in .refused("The query changed since the review. Run the review again.") })
    AIReviewCardView(request: request, text: "Not JSON at all", onApply: nil)
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}
