// ExplainPlanAnalyzer.swift
// Exclusive time or cost for each node in an EXPLAIN tree.

import Foundation

/// Planner row estimate compared with measured rows.
nonisolated enum MisestimateDirection: Equatable, Sendable {
  /// The estimate is higher than the measured row count.
  case over
  /// The estimate is lower than the measured row count.
  case under
}

/// Shared-buffer counts left on a node after subtracting included children.
nonisolated struct ExplainBuffers: Equatable, Sendable {
  var sharedHit: Int
  var sharedRead: Int
  var sharedDirtied: Int
  var sharedWritten: Int
}

/// Conditions worth showing on a plan node.
nonisolated struct ExplainWarning: OptionSet, Sendable {
  var rawValue: Int

  static let diskSort = ExplainWarning(rawValue: 1 << 0)
  static let misestimate = ExplainWarning(rawValue: 1 << 1)
  static let seqScanFilter = ExplainWarning(rawValue: 1 << 2)
  static let nestedLoop = ExplainWarning(rawValue: 1 << 3)
}

/// One EXPLAIN node scored by exclusive time or cost.
nonisolated struct AnalyzedNode: Equatable, Sendable {
  var node: ExplainNode
  var inclusive: Double
  var exclusive: Double
  /// Exclusive metric divided by the root inclusive metric, clamped to 0...1.
  var share: Double
  var estimatedRows: Double?
  /// `actualRows * actualLoops` when both values are present.
  var actualRowsTimesLoops: Double?
  var misestimateFactor: Double?
  var misestimateDirection: MisestimateDirection?
  var buffersExclusive: ExplainBuffers?
  /// True when inclusive time was divided by workers launched plus one.
  var parallelCaveat: Bool
  var warnings: ExplainWarning
}

/// Preorder nodes and the hottest exclusive values.
nonisolated struct AnalyzedPlan: Equatable, Sendable {
  var nodes: [AnalyzedNode]
  /// Up to five nodes with the largest exclusive metric. Ties keep preorder.
  var hotNodes: [AnalyzedNode]
}

/// Ranks an EXPLAIN tree by exclusive time, or by exclusive cost when the root
/// has no actual time.
///
/// The whole tree uses one metric. If the root has `actualTotalTime`, every node
/// is scored in time and a child missing actual time counts as 0. Otherwise every
/// node is scored with `totalCost`. Cost is not multiplied by loops.
///
/// Exclusive value is inclusive minus the inclusive values of children, floored at 0.
/// Children whose parent relationship is `InitPlan` or `SubPlan`, and children whose
/// node type is `CTE Scan`, are not subtracted. Their time or cost is already counted
/// on the node that reads the result. Those same children are left out of exclusive buffers.
nonisolated enum ExplainPlanAnalyzer {
  static func analyze(_ plan: ExplainPlan) -> AnalyzedPlan {
    let useTime = plan.root.actualTotalTime != nil
    let rootInclusive = inclusiveMetric(plan.root, useTime: useTime)
    var nodes: [AnalyzedNode] = []
    visit(plan.root, useTime: useTime, rootInclusive: rootInclusive, into: &nodes)
    return AnalyzedPlan(nodes: nodes, hotNodes: hottest(nodes))
  }

  private static func visit(
    _ node: ExplainNode,
    useTime: Bool,
    rootInclusive: Double,
    into nodes: inout [AnalyzedNode]
  ) -> Double {
    let inclusive = inclusiveMetric(node, useTime: useTime)
    let rows = rowStats(node)
    let index = nodes.count
    nodes.append(
      AnalyzedNode(
        node: node,
        inclusive: inclusive,
        exclusive: 0,
        share: 0,
        estimatedRows: rows.estimated,
        actualRowsTimesLoops: rows.actualTimesLoops,
        misestimateFactor: rows.factor,
        misestimateDirection: rows.direction,
        buffersExclusive: exclusiveBuffers(node),
        parallelCaveat: useTime && node.workersLaunched != nil,
        warnings: warnings(for: node, factor: rows.factor)
      )
    )

    var subtracted = 0.0
    for child in node.children {
      let childInclusive = visit(
        child, useTime: useTime, rootInclusive: rootInclusive, into: &nodes)
      if countsInParentExclusive(child) {
        subtracted += childInclusive
      }
    }

    let exclusive = max(0, inclusive - subtracted)
    nodes[index].exclusive = exclusive
    nodes[index].share = share(exclusive: exclusive, rootInclusive: rootInclusive)
    return inclusive
  }

  private static func inclusiveMetric(_ node: ExplainNode, useTime: Bool) -> Double {
    guard useTime else { return node.totalCost ?? 0 }
    let time = node.actualTotalTime ?? 0
    let loops = loopFactor(node.actualLoops)
    guard let workers = node.workersLaunched else { return time * loops }
    return time * loops / Double(workers + 1)
  }

  /// Nil and zero loops count as one execution.
  private static func loopFactor(_ loops: Double?) -> Double {
    guard let loops, loops != 0 else { return 1 }
    return loops
  }

  /// InitPlan, SubPlan, and CTE Scan children are already counted on the reader.
  private static func countsInParentExclusive(_ child: ExplainNode) -> Bool {
    switch child.parentRelationship {
    case "InitPlan", "SubPlan":
      return false
    default:
      return child.nodeType != "CTE Scan"
    }
  }

  private static func share(exclusive: Double, rootInclusive: Double) -> Double {
    guard rootInclusive > 0 else { return 0 }
    return min(exclusive / rootInclusive, 1)
  }

  private static func rowStats(
    _ node: ExplainNode
  ) -> (
    estimated: Double?,
    actualTimesLoops: Double?,
    factor: Double?,
    direction: MisestimateDirection?
  ) {
    let estimated = node.planRows
    let actualTimesLoops: Double?
    if let actual = node.actualRows, let loops = node.actualLoops {
      actualTimesLoops = actual * loops
    } else {
      actualTimesLoops = nil
    }
    guard let estimated, let actual = actualTimesLoops, estimated > 0, actual > 0 else {
      return (estimated, actualTimesLoops, nil, nil)
    }
    let factor = max(estimated, actual) / min(estimated, actual)
    let direction: MisestimateDirection?
    if estimated > actual {
      direction = .over
    } else if actual > estimated {
      direction = .under
    } else {
      direction = nil
    }
    return (estimated, actualTimesLoops, factor, direction)
  }

  private static func exclusiveBuffers(_ node: ExplainNode) -> ExplainBuffers? {
    guard hasSharedBuffers(node) else { return nil }
    var hit = node.sharedHitBlocks ?? 0
    var read = node.sharedReadBlocks ?? 0
    var dirtied = node.sharedDirtiedBlocks ?? 0
    var written = node.sharedWrittenBlocks ?? 0
    for child in node.children where countsInParentExclusive(child) {
      hit -= child.sharedHitBlocks ?? 0
      read -= child.sharedReadBlocks ?? 0
      dirtied -= child.sharedDirtiedBlocks ?? 0
      written -= child.sharedWrittenBlocks ?? 0
    }
    return ExplainBuffers(
      sharedHit: max(0, hit),
      sharedRead: max(0, read),
      sharedDirtied: max(0, dirtied),
      sharedWritten: max(0, written)
    )
  }

  private static func hasSharedBuffers(_ node: ExplainNode) -> Bool {
    node.sharedHitBlocks != nil || node.sharedReadBlocks != nil
      || node.sharedDirtiedBlocks != nil || node.sharedWrittenBlocks != nil
  }

  private static func warnings(for node: ExplainNode, factor: Double?) -> ExplainWarning {
    var warnings = ExplainWarning()
    if node.sortSpaceType?.lowercased() == "disk" {
      warnings.insert(.diskSort)
    }
    if let factor, factor >= 10 {
      warnings.insert(.misestimate)
    }
    if removesMostRows(node) {
      warnings.insert(.seqScanFilter)
    }
    if repeatsUnderNestedLoop(node) {
      warnings.insert(.nestedLoop)
    }
    return warnings
  }

  private static func removesMostRows(_ node: ExplainNode) -> Bool {
    guard node.nodeType == "Seq Scan",
      let removed = node.rowsRemovedByFilter,
      removed >= 10_000,
      let actualRows = node.actualRows
    else { return false }
    let denominator = Double(removed) + actualRows * loopFactor(node.actualLoops)
    guard denominator > 0 else { return false }
    return Double(removed) / denominator > 0.90
  }

  private static func repeatsUnderNestedLoop(_ node: ExplainNode) -> Bool {
    guard node.nodeType?.contains("Nested Loop") == true else { return false }
    if let loops = node.actualLoops, loops >= 1_000 { return true }
    return node.children.contains { ($0.actualLoops ?? 0) >= 1_000 }
  }

  private static func hottest(_ nodes: [AnalyzedNode]) -> [AnalyzedNode] {
    nodes.enumerated()
      .sorted { lhs, rhs in
        if lhs.element.exclusive != rhs.element.exclusive {
          return lhs.element.exclusive > rhs.element.exclusive
        }
        return lhs.offset < rhs.offset
      }
      .prefix(5)
      .map(\.element)
  }
}
