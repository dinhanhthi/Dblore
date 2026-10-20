// DuckDBExplainAdapter.swift
// Maps DuckDB `EXPLAIN (FORMAT JSON)` (an array of `{name, children, extra_info}` root nodes,
// estimates only) and `EXPLAIN (ANALYZE, FORMAT JSON)` (one profile object whose nodes carry
// `operator_name`, `operator_timing` in seconds and `operator_cardinality`) onto the plan tree.

import Foundation

nonisolated enum DuckDBExplainAdapter {
  /// Column names of a DuckDB `EXPLAIN` result, in order. The plan is in `explain_value`.
  static let columnNames = ["explain_key", "explain_value"]

  /// Deepest node kept. Anything below it is left out of the tree.
  static let maxDepth = 64

  /// Longest JSON text decoded (UTF-8 bytes) and most operators kept; past either, no plan.
  static let maxJSONBytes = 4 * 1024 * 1024
  static let maxNodes = 5_000

  /// `extra_info` keys mapped to node fields, so they stay out of `extras`.
  private static let mappedInfoKeys: Set<String> = [
    "Table", "Join Type", "Filters", "Projections", "Estimated Cardinality",
  ]

  /// Nil unless `text` is one of the two JSON shapes, at most `maxJSONBytes` long, with at most
  /// `maxNodes` operators. Several roots go under a "Query plan" node.
  static func plan(fromJSON text: String) -> ExplainPlan? {
    guard text.utf8.count <= maxJSONBytes,
      let start = text.first(where: { !$0.isWhitespace }), start == "[" || start == "{",
      let data = text.data(using: .utf8),
      let document = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    switch document {
    case .array(let items):
      return roots(items).map { ExplainPlan(root: $0) }
    case .object(let profile):
      guard case .array(var items)? = profile["children"] else { return nil }
      if items.count == 1, case .object(let wrapper) = items[0],
        wrapper["operator_name"] == .string("EXPLAIN_ANALYZE")
          || wrapper["operator_type"] == .string("EXPLAIN_ANALYZE"),
        case .array(let inner)? = wrapper["children"]
      {
        items = inner
      }
      guard let root = roots(items) else { return nil }
      return ExplainPlan(root: root, executionTime: number(profile["latency"]).map { $0 * 1000 })
    default:
      return nil
    }
  }

  /// The one root, or a "Query plan" node over several. Nil when any item is not a node or
  /// there are more than `maxNodes` operators.
  private static func roots(_ items: [JSONValue]) -> ExplainNode? {
    var nodes: [ExplainNode] = []
    var count = 0
    for item in items {
      guard case .object(let object) = item, let built = node(object, depth: 1, count: &count)
      else { return nil }
      nodes.append(built)
    }
    guard count <= maxNodes else { return nil }
    guard let first = nodes.first else { return nil }
    if nodes.count == 1 { return first }
    var root = ExplainNode(nodeType: "Query plan", children: nodes)
    if nodes.contains(where: { $0.actualTotalTime != nil }) {
      root.actualTotalTime = nodes.reduce(0) { $0 + ($1.actualTotalTime ?? 0) }
    }
    return root
  }

  /// One operator. The filter goes to `filter` and join conditions stay in `extras`, never in
  /// the fields the AI plan context reads (`extra_info` text carries query literals).
  /// `operator_timing` is the operator's own time, so the node's time adds its children's to
  /// match the inclusive time the analyzer expects. `count` is the operators seen so far; once
  /// it passes `maxNodes` nothing more is built and the caller drops the plan.
  private static func node(
    _ object: [String: JSONValue], depth: Int, count: inout Int
  ) -> ExplainNode? {
    guard count <= maxNodes else { return nil }
    count += 1
    guard count <= maxNodes, depth <= maxDepth,
      let name =
        (string(object["name"]) ?? string(object["operator_name"])
        ?? string(object["operator_type"]))?.trimmingCharacters(in: .whitespaces),
      !name.isEmpty
    else { return nil }
    var children: [ExplainNode] = []
    if case .array(let items)? = object["children"] {
      for case .object(let child) in items {
        children += node(child, depth: depth + 1, count: &count).map { [$0] } ?? []
      }
    }
    var info: [String: JSONValue] = [:]
    if case .object(let fields)? = object["extra_info"] {
      info = fields
    }
    var node = ExplainNode(
      nodeType: name,
      relationName: string(info["Table"]),
      planRows: number(info["Estimated Cardinality"]),
      filter: lines(info["Filters"])?.joined(separator: "\n"),
      children: children,
      extras: info.filter { !mappedInfoKeys.contains($0.key) }
    )
    node.joinType = string(info["Join Type"])
    node.output = lines(info["Projections"])
    node.actualRows = number(object["operator_cardinality"])
    if let seconds = number(object["operator_timing"]) {
      node.actualTotalTime = seconds * 1000 + children.reduce(0) { $0 + ($1.actualTotalTime ?? 0) }
    }
    return node
  }

  /// Numbers are JSON numbers in the profile and strings in `extra_info`; both are accepted.
  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number)?:
      return number.isFinite ? number : nil
    case .string(let text)?:
      return Double(text).flatMap { $0.isFinite ? $0 : nil }
    default:
      return nil
    }
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }

  /// An `extra_info` value as lines: one string, or each string of an array.
  private static func lines(_ value: JSONValue?) -> [String]? {
    switch value {
    case .string(let text)?:
      return [text]
    case .array(let items)?:
      return items.compactMap(string)
    default:
      return nil
    }
  }
}
