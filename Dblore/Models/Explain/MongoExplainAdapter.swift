// MongoExplainAdapter.swift
// Maps the MongoDB explain reply (find or aggregate) onto the plan tree, and reads its summary.
// `executionTimeMillisEstimate` includes the stages below, so the analyzer scores it as time.

import Foundation

nonisolated enum MongoExplainAdapter {
  /// Deepest stage kept. Anything below it is left out of the tree.
  static let maxDepth = 32

  /// Totals of one explain reply, and the indexes its winning plan reads.
  struct Summary: Equatable, Sendable {
    var executionTimeMillis: Int?
    var nReturned: Int?
    var totalDocsExamined: Int?
    var totalKeysExamined: Int?
    /// Unique, in tree order.
    var indexNames: [String]
    var usesCollectionScan: Bool
  }

  /// Keys holding the stages below a stage, in child order.
  private static let childKeys = [
    "queryPlan", "inputStage", "inputStages", "outerStage", "innerStage", "thenStage",
    "elseStage",
  ]

  /// Stage keys mapped to node fields or children, so they stay out of `extras`.
  private static let mappedKeys = Set(
    childKeys + ["stage", "indexName", "nReturned", "executionTimeMillisEstimate"])

  /// True when `document` is a MongoDB explain reply (any verbosity, sharded or not).
  static func isMongoExplain(_ document: [String: JSONValue]) -> Bool {
    ["queryPlanner", "explainVersion", "stages", "shards"].contains { document[$0] != nil }
  }

  /// The stage tree of an explain reply. Nil for a sharded reply (raw view only) and for
  /// anything that is not explain output.
  static func plan(fromJSON text: String) -> ExplainPlan? {
    guard let document = document(text), !isSharded(document) else { return nil }
    let root: ExplainNode?
    if case .array(let stages)? = document["stages"] {
      root = pipeline(stages)
    } else {
      root = cursorTree(document).map { withTotals($0, from: executionStages(document)) }
    }
    return root.map { ExplainPlan(root: $0) }
  }

  /// Totals from `executionStats` (of the cursor stage for an aggregate), and the indexes and
  /// collection scans of the winning plan. Only the winning plan says COLLSCAN: the
  /// slot-based execution tree names other scans (`coscan` is a constant scan). Nil for a
  /// sharded reply, whose per-shard plans are not read.
  static func summary(fromJSON text: String) -> Summary? {
    guard let document = document(text), !isSharded(document) else { return nil }
    var source = document
    if case .array(let stages)? = document["stages"] {
      source = cursor(stages) ?? [:]
    }
    var stats: [String: JSONValue] = [:]
    if case .object(let fields)? = source["executionStats"] {
      stats = fields
    }
    var indexNames: [String] = []
    var usesCollectionScan = false
    func walk(_ node: ExplainNode) {
      if let name = node.indexName, !indexNames.contains(name) {
        indexNames.append(name)
      }
      if node.nodeType == "COLLSCAN" {
        usesCollectionScan = true
      }
      node.children.forEach(walk)
    }
    if let winning = winningPlan(source), let tree = stage(winning, depth: 1) {
      walk(tree)
    }
    return Summary(
      executionTimeMillis: integer(stats["executionTimeMillis"]),
      nReturned: integer(stats["nReturned"]),
      totalDocsExamined: integer(stats["totalDocsExamined"]),
      totalKeysExamined: integer(stats["totalKeysExamined"]),
      indexNames: indexNames,
      usesCollectionScan: usesCollectionScan
    )
  }

  /// The reply as an object, nil unless it is MongoDB explain output.
  private static func document(_ text: String) -> [String: JSONValue]? {
    guard let data = text.data(using: .utf8),
      case .object(let document)? = try? JSONDecoder().decode(JSONValue.self, from: data),
      isMongoExplain(document)
    else { return nil }
    return document
  }

  /// A reply from mongos: per-shard plans under top-level `shards` (aggregate), or under
  /// `queryPlanner.winningPlan.shards` with a `mongosPlannerVersion` (find).
  private static func isSharded(_ document: [String: JSONValue]) -> Bool {
    if document["shards"] != nil { return true }
    guard case .object(let planner)? = document["queryPlanner"] else { return false }
    if planner["mongosPlannerVersion"] != nil { return true }
    guard case .object(let winning)? = planner["winningPlan"] else { return false }
    return winning["shards"] != nil
  }

  /// The executed stages when the reply has them (actual rows and times), else the winning
  /// plan (no times). A slot-based plan (`winningPlan.queryPlan`) always shows the winning
  /// plan: its classic-shaped stages (FETCH, IXSCAN, GROUP) read better than the internal
  /// execution stages (`nlj`, `coscan`, `ixseek`). Callers give its root the enclosing totals.
  private static func cursorTree(_ object: [String: JSONValue]) -> ExplainNode? {
    if !isSlotBased(object), let stages = executionStages(object) {
      return stage(stages, depth: 1)
    }
    return winningPlan(object).flatMap { stage($0, depth: 1) }
  }

  /// `executionStats.executionStages`, the root of the executed stages.
  private static func executionStages(_ object: [String: JSONValue]) -> [String: JSONValue]? {
    guard case .object(let stats)? = object["executionStats"],
      case .object(let stages)? = stats["executionStages"]
    else { return nil }
    return stages
  }

  /// `node` with the rows and time of `totals` where it has none, so the analyzer does not
  /// put the time of a slot-based cursor tree (no metrics) on the stage above it.
  private static func withTotals(
    _ node: ExplainNode, from totals: [String: JSONValue]?
  ) -> ExplainNode {
    var node = node
    node.actualRows = node.actualRows ?? number(totals?["nReturned"])
    node.actualTotalTime = node.actualTotalTime ?? number(totals?["executionTimeMillisEstimate"])
    return node
  }

  /// The winning plan has a `queryPlan` (slot-based engine, explainVersion "2").
  private static func isSlotBased(_ object: [String: JSONValue]) -> Bool {
    guard case .object(let planner)? = object["queryPlanner"],
      case .object(let winning)? = planner["winningPlan"],
      case .object? = winning["queryPlan"]
    else { return false }
    return true
  }

  /// `queryPlanner.winningPlan`. On the slot-based engine (explainVersion "2") the stage tree
  /// sits under its `queryPlan`.
  private static func winningPlan(_ object: [String: JSONValue]) -> [String: JSONValue]? {
    guard case .object(let planner)? = object["queryPlanner"],
      case .object(let winning)? = planner["winningPlan"]
    else { return nil }
    if winning["stage"] == nil, case .object(let tree)? = winning["queryPlan"] {
      return tree
    }
    return winning
  }

  /// The `$cursor` body of the first pipeline stage.
  private static func cursor(_ stages: [JSONValue]) -> [String: JSONValue]? {
    guard case .object(let first)? = stages.first,
      case .object(let cursor)? = first["$cursor"]
    else { return nil }
    return cursor
  }

  /// The cursor stage's plan with each later stage (`$group`, `$sort`, …) on top, in pipeline
  /// order: the last stage is the root.
  private static func pipeline(_ stages: [JSONValue]) -> ExplainNode? {
    guard let cursor = cursor(stages), let tree = cursorTree(cursor),
      case .object(let first)? = stages.first
    else { return nil }
    var node = withTotals(tree, from: first)
    for item in stages.dropFirst() {
      guard case .object(let object) = item else { return nil }
      let names = object.keys.filter { $0.hasPrefix("$") }
      guard names.count == 1, let name = names.first else { return nil }
      var parent = ExplainNode(
        nodeType: name,
        children: [node],
        extras: object.filter { !mappedKeys.contains($0.key) }
      )
      parent.actualRows = number(object["nReturned"])
      parent.actualTotalTime = number(object["executionTimeMillisEstimate"])
      node = parent
    }
    return node
  }

  /// One stage and the stages below it. Nil without a `stage` name or past `maxDepth`.
  private static func stage(_ object: [String: JSONValue], depth: Int) -> ExplainNode? {
    guard depth <= maxDepth, case .string(let type)? = object["stage"] else { return nil }
    var children: [ExplainNode] = []
    for key in childKeys {
      switch object[key] {
      case .object(let child)?:
        children += stage(child, depth: depth + 1).map { [$0] } ?? []
      case .array(let items)?:
        for case .object(let child) in items {
          children += stage(child, depth: depth + 1).map { [$0] } ?? []
        }
      default:
        break
      }
    }
    var node = ExplainNode(
      nodeType: type,
      indexName: string(object["indexName"]),
      children: children,
      extras: object.filter { !mappedKeys.contains($0.key) }
    )
    node.actualRows = number(object["nReturned"])
    node.actualTotalTime = number(object["executionTimeMillisEstimate"])
    return node
  }

  private static func number(_ value: JSONValue?) -> Double? {
    guard case .number(let number)? = value, number.isFinite else { return nil }
    return number
  }

  private static func integer(_ value: JSONValue?) -> Int? {
    number(value).flatMap { Int(exactly: $0) }
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }
}
