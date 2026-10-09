//
//  ExplainPlanCompareView.swift
//  Dblore
//
//  Pinned vs current EXPLAIN plan: root deltas and the per-node changes, in plan order.
//

import SwiftUI

/// Rows and number text of the plan compare view
enum ExplainPlanCompareRows {
  enum Kind: Equatable {
    case paired(ExplainPlanDiff.NodeDelta)
    case typeChange(baseline: String?, current: String?)
    case added(ExplainPlanDiff.UnpairedNode)
    case removed(ExplainPlanDiff.UnpairedNode)
  }

  struct Entry: Equatable, Identifiable {
    let path: [Int]
    let kind: Kind

    var id: String { path.map(String.init).joined(separator: ".") }
  }

  /// One entry per path in pre-order. A node type change replaces the removed and added
  /// entries at its path.
  static func entries(_ diff: ExplainPlanDiff) -> [Entry] {
    let changedPaths = Set(diff.nodeTypeChanges.map(\.path))
    var entries = diff.paired.map { Entry(path: $0.path, kind: .paired($0)) }
    entries += diff.nodeTypeChanges.map {
      Entry(
        path: $0.path, kind: .typeChange(baseline: $0.baselineNodeType, current: $0.currentNodeType)
      )
    }
    entries += diff.added.filter { !changedPaths.contains($0.path) }.map {
      Entry(path: $0.path, kind: .added($0))
    }
    entries += diff.removed.filter { !changedPaths.contains($0.path) }.map {
      Entry(path: $0.path, kind: .removed($0))
    }
    return entries.sorted { $0.path.lexicographicallyPrecedes($1.path) }
  }

  /// "+12", "−3.5" or "0"
  static func signed(_ value: Double) -> String {
    if value > 0 { return "+" + ExplainMetricText.number(value) }
    if value < 0 { return "\u{2212}" + ExplainMetricText.number(-value) }
    return "0"
  }
}

struct ExplainPlanCompareView: View {
  let diff: ExplainPlanDiff

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      header
      if diff.hasChanges {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(ExplainPlanCompareRows.entries(diff)) { entry in
              row(entry)
            }
          }
          .padding(.vertical, Spacing.xxs)
        }
      } else {
        Text("No changes")
          .font(.small)
          .foregroundStyle(Color.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private var header: some View {
    HStack(spacing: Spacing.md) {
      if let cost = diff.rootTotalCostDelta {
        delta("Total cost", cost)
      }
      if let time = diff.rootActualTotalTimeDelta {
        delta("Total time", time, unit: " ms")
      }
      Text(
        "\(diff.added.count) added, \(diff.removed.count) removed, "
          + "\(diff.nodeTypeChanges.count) type changed"
      )
      .foregroundStyle(Color.foregroundSubtle)
    }
    .font(.small)
  }

  /// Higher cost or time reads as worse
  private func delta(_ label: String, _ value: Double, unit: String = "") -> some View {
    HStack(spacing: Spacing.xs) {
      Text(label)
        .foregroundStyle(Color.foregroundMuted)
      Text(ExplainPlanCompareRows.signed(value) + unit)
        .font(.monoSmall)
        .foregroundStyle(deltaColor(value))
    }
  }

  private func deltaColor(_ value: Double) -> Color {
    value > 0 ? .destructive : value < 0 ? .success : .foregroundMuted
  }

  private func row(_ entry: ExplainPlanCompareRows.Entry) -> some View {
    HStack(spacing: Spacing.sm) {
      marker(entry.kind)
        .font(.monoSmall)
        .frame(width: 14)
      title(entry.kind)
        .font(.small)
        .lineLimit(1)
      metrics(entry.kind)
        .font(.monoSmall)
      Spacer(minLength: 0)
      Text(entry.path.isEmpty ? "root" : entry.id)
        .font(.smallest)
        .foregroundStyle(Color.foregroundSubtle)
    }
    .padding(.vertical, Spacing.xxs)
    .padding(.horizontal, Spacing.xs)
    .padding(.leading, CGFloat(entry.path.count) * Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm).fill(background(entry.kind))
    )
  }

  @ViewBuilder
  private func marker(_ kind: ExplainPlanCompareRows.Kind) -> some View {
    switch kind {
    case .paired(let node):
      Text(node.hasChanges ? "~" : " ")
        .foregroundStyle(Color.warning)
    case .typeChange:
      Text("~").foregroundStyle(Color.warning)
    case .added:
      Text("+").foregroundStyle(Color.success)
    case .removed:
      Text("\u{2212}").foregroundStyle(Color.destructive)
    }
  }

  @ViewBuilder
  private func title(_ kind: ExplainPlanCompareRows.Kind) -> some View {
    switch kind {
    case .paired(let node):
      Text(name(node.nodeType, node.relationName))
        .foregroundStyle(node.hasChanges ? Color.foreground : Color.foregroundMuted)
    case .typeChange(let baseline, let current):
      Text("\(baseline ?? "Node") \u{2192} \(current ?? "Node")")
        .foregroundStyle(Color.foreground)
    case .added(let node):
      Text(name(node.nodeType, node.relationName))
        .foregroundStyle(Color.success)
    case .removed(let node):
      Text(name(node.nodeType, node.relationName))
        .foregroundStyle(Color.destructive)
        .strikethrough()
    }
  }

  @ViewBuilder
  private func metrics(_ kind: ExplainPlanCompareRows.Kind) -> some View {
    if case .paired(let node) = kind, node.hasChanges {
      HStack(spacing: Spacing.sm) {
        if let cost = node.totalCostDelta, cost != 0 {
          Text("cost \(ExplainPlanCompareRows.signed(cost))")
            .foregroundStyle(deltaColor(cost))
        }
        if let time = node.actualTotalTimeDelta, time != 0 {
          Text("time \(ExplainPlanCompareRows.signed(time)) ms")
            .foregroundStyle(deltaColor(time))
        }
        if let rows = node.actualRowsDelta, rows != 0 {
          Text("rows \(ExplainPlanCompareRows.signed(rows))")
            .foregroundStyle(Color.foregroundMuted)
        }
      }
    }
  }

  private func background(_ kind: ExplainPlanCompareRows.Kind) -> Color {
    switch kind {
    case .paired: .clear
    case .typeChange: .warning.opacity(0.12)
    case .added: .success.opacity(0.12)
    case .removed: .destructive.opacity(0.12)
    }
  }

  private func name(_ nodeType: String?, _ relation: String?) -> String {
    let type = nodeType ?? "Node"
    return relation.map { "\(type) on \($0)" } ?? type
  }
}
