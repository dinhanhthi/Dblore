//
//  ExplainPlanView.swift
//  Dblore
//
//  Plan / Raw toggle and the EXPLAIN tree for a QUERY PLAN result.
//

import SwiftUI

enum ExplainDisplayMode: Hashable {
  case plan
  case raw
}

/// Reads a plan only when the result is one `QUERY PLAN` cell and JSON parses.
enum ExplainResultPlan {
  static func parse(_ result: CellResult) -> ExplainPlan? {
    guard result.columns.count == 1,
      result.columns[0].name.compare("QUERY PLAN", options: [.caseInsensitive]) == .orderedSame,
      let value = result.rows.first?.first
    else { return nil }
    return try? ExplainPlan.parse(value)
  }
}

struct ExplainDisplayPicker: View {
  @Binding var mode: ExplainDisplayMode

  var body: some View {
    Picker("Explain", selection: $mode) {
      Text("Plan").tag(ExplainDisplayMode.plan)
      Text("Raw").tag(ExplainDisplayMode.raw)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .font(.small)
    .frame(width: 160)
    .accessibilityLabel("Plan or raw")
  }
}

/// Fixed plan height in a notebook cell. The editor panel fills its parent instead.
private let notebookPlanHeight: CGFloat = 420

/// Plan view when `ExplainPlan.parse` succeeds; otherwise the raw result, with no toggle.
struct ExplainableResult<Raw: View>: View {
  let result: CellResult
  var fillsAvailableHeight = false
  @ViewBuilder var raw: () -> Raw

  @State private var mode: ExplainDisplayMode = .plan

  private var plan: ExplainPlan? {
    ExplainResultPlan.parse(result)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if plan != nil {
        ExplainDisplayPicker(mode: $mode)
      }
      shown
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: .topLeading
    )
    .onChange(of: result.timestamp) { _, _ in
      mode = .plan
    }
  }

  @ViewBuilder
  private var shown: some View {
    if let plan, mode == .plan {
      ExplainPlanView(plan: plan)
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
        .frame(height: fillsAvailableHeight ? nil : notebookPlanHeight)
    } else {
      raw()
    }
  }
}

struct ExplainTreeItem: Identifiable {
  let id: Int
  let analyzed: AnalyzedNode
  let children: [ExplainTreeItem]
}

enum ExplainTree {
  /// Preorder, matching `ExplainPlanAnalyzer` (parent, then each child).
  static func build(plan: ExplainPlan, analyzed: AnalyzedPlan) -> ExplainTreeItem {
    var index = 0
    func walk(_ node: ExplainNode) -> ExplainTreeItem {
      let id = index
      index += 1
      let children = node.children.map(walk)
      let analyzedNode =
        analyzed.nodes.indices.contains(id)
        ? analyzed.nodes[id]
        : AnalyzedNode(
          node: node,
          inclusive: 0,
          exclusive: 0,
          share: 0,
          estimatedRows: node.planRows,
          actualRowsTimesLoops: nil,
          misestimateFactor: nil,
          misestimateDirection: nil,
          buffersExclusive: nil,
          parallelCaveat: false,
          warnings: []
        )
      return ExplainTreeItem(id: id, analyzed: analyzedNode, children: children)
    }
    return walk(plan.root)
  }

  static func parents(of root: ExplainTreeItem) -> [Int: Int] {
    var map: [Int: Int] = [:]
    func walk(_ item: ExplainTreeItem) {
      for child in item.children {
        map[child.id] = item.id
        walk(child)
      }
    }
    walk(root)
    return map
  }

  /// Indices of `hotNodes`, first unused match when two nodes compare equal.
  static func hotIndices(in analyzed: AnalyzedPlan) -> [Int] {
    var used = Set<Int>()
    var indices: [Int] = []
    for hot in analyzed.hotNodes {
      guard
        let index = analyzed.nodes.enumerated().first(where: { offset, node in
          !used.contains(offset) && node == hot
        })?.offset
      else { continue }
      used.insert(index)
      indices.append(index)
    }
    return indices
  }
}

struct ExplainPlanView: View {
  let plan: ExplainPlan

  @State private var selectedID: Int?
  @State private var collapsed: Set<Int> = []
  @State private var scrollTarget: Int?
  @State private var scrollToken = 0

  private var usesTime: Bool {
    ExplainMetricText.usesTime(plan)
  }

  var body: some View {
    let analyzed = ExplainPlanAnalyzer.analyze(plan)
    let tree = ExplainTree.build(plan: plan, analyzed: analyzed)
    return content(tree: tree, analyzed: analyzed)
  }

  private func content(tree: ExplainTreeItem, analyzed: AnalyzedPlan) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      header(analyzed)
      HStack(alignment: .top, spacing: 0) {
        treeColumn(tree)
        if let selectedID, analyzed.nodes.indices.contains(selectedID) {
          Divider()
          ExplainNodeDetail(node: analyzed.nodes[selectedID].node)
            .frame(width: 300)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(Spacing.sm)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func header(_ analyzed: AnalyzedPlan) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.md) {
        if let planning = plan.planningTime {
          Text("Planning \(ExplainMetricText.number(planning)) ms")
        }
        if let execution = plan.executionTime {
          Text("Execution \(ExplainMetricText.number(execution)) ms")
        }
        if !usesTime {
          Text("Cost")
        }
      }
      .font(.small)
      .foregroundStyle(Color.foregroundMuted)

      if !analyzed.hotNodes.isEmpty {
        HStack(alignment: .center, spacing: Spacing.sm) {
          Text("Hot")
            .font(.smallest)
            .foregroundStyle(Color.foregroundSubtle)
          ScrollView(.horizontal) {
            HStack(spacing: Spacing.xs) {
              ForEach(ExplainTree.hotIndices(in: analyzed), id: \.self) { index in
                hotChip(index: index, analyzed: analyzed)
              }
            }
          }
          .scrollIndicators(.hidden)
        }
      }
    }
  }

  private func hotChip(index: Int, analyzed: AnalyzedPlan) -> some View {
    let node = analyzed.nodes[index]
    let title = chipTitle(node)
    return Button {
      focus(index)
    } label: {
      Text(title)
        .font(.small)
        .foregroundStyle(Color.foreground)
        .lineLimit(1)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
          Capsule().fill(Color.accent.opacity(selectedID == index ? 0.28 : 0.14))
        )
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help(title)
  }

  private func chipTitle(_ node: AnalyzedNode) -> String {
    let type = ExplainNodeTitle.type(node.node)
    let relation = node.node.relationName ?? node.node.indexName
    let name = relation.map { "\(type) \($0)" } ?? type
    let metric = ExplainMetricText.number(node.exclusive)
    return "\(name) \(metric) \(ExplainMetricText.unit(usesTime: usesTime))"
  }

  private func treeColumn(_ tree: ExplainTreeItem) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        ExplainTreeBranch(
          item: tree,
          usesTime: usesTime,
          selectedID: $selectedID,
          collapsed: $collapsed
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xxs)
      }
      .onChange(of: scrollToken) { _, _ in
        guard let target = scrollTarget else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(30))
          proxy.scrollTo(target, anchor: .center)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func focus(_ id: Int) {
    let analyzed = ExplainPlanAnalyzer.analyze(plan)
    let parents = ExplainTree.parents(of: ExplainTree.build(plan: plan, analyzed: analyzed))
    var current = parents[id]
    while let parent = current {
      collapsed.remove(parent)
      current = parents[parent]
    }
    selectedID = id
    scrollTarget = id
    scrollToken += 1
  }
}

struct ExplainTreeBranch: View {
  let item: ExplainTreeItem
  let usesTime: Bool
  @Binding var selectedID: Int?
  @Binding var collapsed: Set<Int>

  private var isExpanded: Bool {
    !collapsed.contains(item.id)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.xs) {
        disclosure
        ExplainNodeRow(analyzed: item.analyzed, usesTime: usesTime)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { selectedID = item.id }
      }
      .padding(.vertical, Spacing.xxs)
      .padding(.horizontal, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(selectedID == item.id ? Color.accent.opacity(0.15) : Color.clear)
      )
      .id(item.id)

      if isExpanded && !item.children.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(item.children) { child in
            ExplainTreeBranch(
              item: child,
              usesTime: usesTime,
              selectedID: $selectedID,
              collapsed: $collapsed
            )
          }
        }
        .padding(.leading, Spacing.md)
      }
    }
  }

  @ViewBuilder
  private var disclosure: some View {
    if item.children.isEmpty {
      Color.clear
        .frame(width: 14, height: 14)
    } else {
      Button {
        if isExpanded {
          collapsed.insert(item.id)
        } else {
          collapsed.remove(item.id)
        }
      } label: {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.foregroundMuted)
          .frame(width: 14, height: 14)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }
  }
}
