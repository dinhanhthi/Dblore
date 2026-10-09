//
//  ExplainPlanComparison.swift
//  Dblore
//
//  EXPLAIN plan diff: nodes pair by tree path and node type
//

import Foundation

/// Difference between a baseline and a current EXPLAIN plan.
/// A path is the child index path from the root (`[]` is the root).
/// Deltas are current minus baseline, nil when either side lacks the value.
nonisolated struct ExplainPlanDiff: Sendable, Equatable {
  /// Nodes at the same path with the same node type
  struct NodeDelta: Sendable, Equatable {
    let path: [Int]
    let nodeType: String?
    let relationName: String?
    let totalCostDelta: Double?
    let actualTotalTimeDelta: Double?
    let actualRowsDelta: Double?

    var hasChanges: Bool {
      [totalCostDelta, actualTotalTimeDelta, actualRowsDelta].contains { ($0 ?? 0) != 0 }
    }
  }

  /// A node only on one side, or a side of a node type change
  struct UnpairedNode: Sendable, Equatable {
    let path: [Int]
    let nodeType: String?
    let relationName: String?
  }

  struct NodeTypeChange: Sendable, Equatable {
    let path: [Int]
    let baselineNodeType: String?
    let currentNodeType: String?
  }

  /// In pre-order
  let paired: [NodeDelta]
  /// Current-only nodes, in pre-order
  let added: [UnpairedNode]
  /// Baseline-only nodes, in pre-order
  let removed: [UnpairedNode]
  let nodeTypeChanges: [NodeTypeChange]
  let rootTotalCostDelta: Double?
  let rootActualTotalTimeDelta: Double?

  var hasChanges: Bool {
    !added.isEmpty || !removed.isEmpty || !nodeTypeChanges.isEmpty
      || paired.contains(where: \.hasChanges)
  }
}

nonisolated enum ExplainPlanComparison {
  /// Nodes of different types at one path are listed as removed and added and flagged as a
  /// type change; their children still pair by path.
  static func compare(baseline: ExplainNode, current: ExplainNode) -> ExplainPlanDiff {
    var walk = Walk()
    walk.visit(baseline, current, path: [])
    return ExplainPlanDiff(
      paired: walk.paired,
      added: walk.added,
      removed: walk.removed,
      nodeTypeChanges: walk.typeChanges,
      rootTotalCostDelta: delta(baseline.totalCost, current.totalCost),
      rootActualTotalTimeDelta: delta(baseline.actualTotalTime, current.actualTotalTime)
    )
  }

  private static func delta(_ baseline: Double?, _ current: Double?) -> Double? {
    guard let baseline, let current else { return nil }
    return current - baseline
  }

  private struct Walk {
    var paired: [ExplainPlanDiff.NodeDelta] = []
    var added: [ExplainPlanDiff.UnpairedNode] = []
    var removed: [ExplainPlanDiff.UnpairedNode] = []
    var typeChanges: [ExplainPlanDiff.NodeTypeChange] = []

    mutating func visit(_ baseline: ExplainNode, _ current: ExplainNode, path: [Int]) {
      if baseline.nodeType == current.nodeType {
        paired.append(
          ExplainPlanDiff.NodeDelta(
            path: path,
            nodeType: current.nodeType,
            relationName: current.relationName,
            totalCostDelta: delta(baseline.totalCost, current.totalCost),
            actualTotalTimeDelta: delta(baseline.actualTotalTime, current.actualTotalTime),
            actualRowsDelta: delta(baseline.actualRows, current.actualRows)
          ))
      } else {
        typeChanges.append(
          ExplainPlanDiff.NodeTypeChange(
            path: path, baselineNodeType: baseline.nodeType, currentNodeType: current.nodeType))
        removed.append(Self.unpaired(baseline, path))
        added.append(Self.unpaired(current, path))
      }

      let baselineChildren = baseline.children
      let currentChildren = current.children
      for index in 0..<max(baselineChildren.count, currentChildren.count) {
        let childPath = path + [index]
        let old = index < baselineChildren.count ? baselineChildren[index] : nil
        let new = index < currentChildren.count ? currentChildren[index] : nil
        switch (old, new) {
        case (let old?, let new?): visit(old, new, path: childPath)
        case (let old?, nil): Self.collect(old, path: childPath, into: &removed)
        case (nil, let new?): Self.collect(new, path: childPath, into: &added)
        case (nil, nil): break
        }
      }
    }

    private static func unpaired(_ node: ExplainNode, _ path: [Int]) -> ExplainPlanDiff.UnpairedNode
    {
      ExplainPlanDiff.UnpairedNode(
        path: path, nodeType: node.nodeType, relationName: node.relationName)
    }

    private static func collect(
      _ node: ExplainNode, path: [Int], into list: inout [ExplainPlanDiff.UnpairedNode]
    ) {
      list.append(unpaired(node, path))
      for (index, child) in node.children.enumerated() {
        collect(child, path: path + [index], into: &list)
      }
    }
  }
}
