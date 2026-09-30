//
//  ExplainNodeRow.swift
//  Dblore
//
//  One EXPLAIN node: type, relation, exclusive share, and planner warnings.
//

import SwiftUI

enum ExplainNodeTitle {
  static func type(_ node: ExplainNode) -> String {
    node.nodeType ?? "Node"
  }

  /// Relation, alias, index, and join type when the plan recorded them.
  static func relation(_ node: ExplainNode) -> String? {
    var parts: [String] = []
    if let name = node.relationName {
      if let alias = node.alias, alias != name {
        parts.append("\(name) \(alias)")
      } else {
        parts.append(name)
      }
    } else if let alias = node.alias {
      parts.append(alias)
    }
    if let index = node.indexName {
      parts.append(index)
    }
    if let join = node.joinType, !join.isEmpty {
      parts.append(join)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

enum ExplainMetricText {
  static func usesTime(_ plan: ExplainPlan) -> Bool {
    plan.root.actualTotalTime != nil
  }

  static func unit(usesTime: Bool) -> String {
    usesTime ? "ms" : "cost"
  }

  static func number(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value.rounded() == value ? 0 : 3
    formatter.minimumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  /// Exclusive / inclusive, with the unit labeled.
  static func pair(exclusive: Double, inclusive: Double, usesTime: Bool) -> String {
    "\(number(exclusive)) / \(number(inclusive)) \(unit(usesTime: usesTime))"
  }

  static func rows(_ node: AnalyzedNode) -> String? {
    switch (node.estimatedRows, node.actualRowsTimesLoops) {
    case (let estimated?, let actual?):
      return "rows \(number(estimated)) → \(number(actual))"
    case (let estimated?, nil):
      return "rows \(number(estimated))"
    case (nil, let actual?):
      return "rows → \(number(actual))"
    case (nil, nil):
      return nil
    }
  }

  /// Badge when the estimate and the measured rows differ by 10× or more.
  static func misestimateBadge(_ node: AnalyzedNode) -> String? {
    guard let factor = node.misestimateFactor, factor >= 10 else { return nil }
    let rounded = factor >= 100 ? String(format: "%.0f", factor) : String(format: "%.1f", factor)
    switch node.misestimateDirection {
    case .over:
      return "\(rounded)× over"
    case .under:
      return "\(rounded)× under"
    case nil:
      return "\(rounded)×"
    }
  }

  static func loops(_ node: AnalyzedNode) -> String? {
    guard let loops = node.node.actualLoops else { return nil }
    return "loops \(number(loops))"
  }

  static func buffers(_ buffers: ExplainBuffers) -> String {
    var parts: [String] = []
    if buffers.sharedHit != 0 { parts.append("hit \(buffers.sharedHit)") }
    if buffers.sharedRead != 0 { parts.append("read \(buffers.sharedRead)") }
    if buffers.sharedDirtied != 0 { parts.append("dirtied \(buffers.sharedDirtied)") }
    if buffers.sharedWritten != 0 { parts.append("written \(buffers.sharedWritten)") }
    let body = parts.isEmpty ? "0" : parts.joined(separator: " ")
    return "buffers \(body)"
  }
}

struct ExplainWarningMark: Identifiable {
  let id: String
  let systemImage: String
  let help: String
}

enum ExplainWarningMarks {
  static func marks(for warnings: ExplainWarning, factor: Double?) -> [ExplainWarningMark] {
    var marks: [ExplainWarningMark] = []
    if warnings.contains(.diskSort) {
      marks.append(
        ExplainWarningMark(
          id: "disk", systemImage: "externaldrive.fill", help: "Sort spilled to disk"))
    }
    if warnings.contains(.misestimate) {
      let factorText = factor.map { ExplainMetricText.number($0) } ?? "10"
      marks.append(
        ExplainWarningMark(
          id: "misestimate",
          systemImage: "exclamationmark.triangle.fill",
          help: "Row estimate is off by a factor of \(factorText)"
        ))
    }
    if warnings.contains(.seqScanFilter) {
      marks.append(
        ExplainWarningMark(
          id: "seq",
          systemImage: "line.3.horizontal.decrease.circle.fill",
          help: "Sequential scan filter removed most rows"
        ))
    }
    if warnings.contains(.nestedLoop) {
      marks.append(
        ExplainWarningMark(
          id: "loop",
          systemImage: "arrow.triangle.2.circlepath",
          help: "Nested loop repeated many times"
        ))
    }
    return marks
  }
}

/// Share of the root metric. Width tracks `share`; a hairline stays visible above zero.
struct ExplainShareBar: View {
  let share: Double

  private let trackWidth: CGFloat = 64

  var body: some View {
    let clamped = share.isFinite ? min(max(share, 0), 1) : 0
    let filled: CGFloat = clamped <= 0 ? 0 : max(2, trackWidth * clamped)
    ZStack(alignment: .leading) {
      Capsule()
        .fill(Color.foregroundMuted.opacity(0.18))
      Capsule()
        .fill(Color.accent)
        .frame(width: filled)
    }
    .frame(width: trackWidth, height: 6)
    .accessibilityLabel("Exclusive share \(Int((clamped * 100).rounded())) percent")
  }
}

struct ExplainNodeRow: View {
  let analyzed: AnalyzedNode
  let usesTime: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Text(ExplainNodeTitle.type(analyzed.node))
          .font(.labelText)
          .foregroundStyle(Color.foreground)
        if let relation = ExplainNodeTitle.relation(analyzed.node) {
          Text(relation)
            .font(.monoSmall)
            .foregroundStyle(Color.foregroundMuted)
            .lineLimit(1)
        }
        Spacer(minLength: Spacing.sm)
        warningIcons
      }
      HStack(alignment: .center, spacing: Spacing.sm) {
        ExplainShareBar(share: analyzed.share)
        Text(
          ExplainMetricText.pair(
            exclusive: analyzed.exclusive, inclusive: analyzed.inclusive, usesTime: usesTime)
        )
        .font(.monoSmall)
        .foregroundStyle(Color.foreground)
        .help(usesTime ? "Exclusive / inclusive time" : "Exclusive / inclusive cost")
        if analyzed.parallelCaveat {
          Image(systemName: "person.2")
            .font(.system(size: 10))
            .foregroundStyle(Color.foregroundSubtle)
            .help("Inclusive time is divided by workers launched plus one")
        }
        if let rows = ExplainMetricText.rows(analyzed) {
          Text(rows)
            .font(.monoSmall)
            .foregroundStyle(Color.foregroundMuted)
            .lineLimit(1)
        }
        if let badge = ExplainMetricText.misestimateBadge(analyzed) {
          Text(badge)
            .font(.smallest)
            .foregroundStyle(Color.warning)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.warning.opacity(0.18)))
        }
        if let loops = ExplainMetricText.loops(analyzed) {
          Text(loops)
            .font(.monoSmall)
            .foregroundStyle(Color.foregroundMuted)
        }
        if let buffers = analyzed.buffersExclusive {
          Text(ExplainMetricText.buffers(buffers))
            .font(.monoSmall)
            .foregroundStyle(Color.foregroundMuted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var warningIcons: some View {
    let marks = ExplainWarningMarks.marks(
      for: analyzed.warnings, factor: analyzed.misestimateFactor)
    if !marks.isEmpty {
      HStack(spacing: Spacing.xs) {
        ForEach(marks) { mark in
          Image(systemName: mark.systemImage)
            .font(.system(size: 11))
            .foregroundStyle(Color.warning)
            .help(mark.help)
            .accessibilityLabel(mark.help)
        }
      }
    }
  }
}
