// MySQLExplainAdapter.swift
// Maps MySQL `EXPLAIN FORMAT=JSON` (`{"query_block": …}`) onto the plan tree.
// MySQL reports estimates only (no actual times), so the analyzer scores the plan by cost.

import Foundation

nonisolated enum MySQLExplainAdapter {
  /// Deepest node kept. Anything below it is left out of the tree.
  static let maxDepth = 32

  /// Wrapper keys of a query block, and the node each becomes.
  private static let operations: [(key: String, nodeType: String)] = [
    ("ordering_operation", "Sort"),
    ("grouping_operation", "Aggregate"),
    ("duplicates_removal", "Unique"),
  ]

  /// MySQL `EXPLAIN` join types that read through an index.
  private static let indexAccess: Set<String> = [
    "system", "const", "eq_ref", "ref", "range", "index", "ref_or_null", "fulltext",
    "index_merge", "unique_subquery", "index_subquery",
  ]

  /// Table keys mapped to node fields or children, so they stay out of `extras`.
  private static let mappedTableKeys: Set<String> = [
    "table_name", "key", "attached_condition", "rows_examined_per_scan",
    "materialized_from_subquery",
  ]

  /// Nil unless `text` is a JSON object with a `query_block` object.
  static func plan(fromJSON text: String) -> ExplainPlan? {
    guard let data = text.data(using: .utf8),
      case .object(let document)? = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let block)? = document["query_block"],
      let root = queryBlock(block, depth: 1)
    else { return nil }
    return ExplainPlan(root: root)
  }

  /// The block's body costed with `query_cost`, or a Result node when the block has no
  /// body (for example "No tables used"). Other block keys land in the node's extras.
  private static func queryBlock(_ block: [String: JSONValue], depth: Int) -> ExplainNode? {
    guard depth <= maxDepth else { return nil }
    let found = body(of: block, depth: depth)
    var node = found?.node ?? ExplainNode(nodeType: "Result")
    if let cost = number(block["cost_info"], "query_cost") {
      node.totalCost = cost
    }
    for (key, value) in block
    where key != found?.key && key != "cost_info" && key != "select_id" && node.extras[key] == nil {
      node.extras[key] = value
    }
    return node
  }

  /// The first operation, nested loop or table in `object`, and the key it came from.
  private static func body(
    of object: [String: JSONValue], depth: Int
  ) -> (node: ExplainNode, key: String)? {
    guard depth <= maxDepth else { return nil }
    for operation in operations {
      if case .object(let inner)? = object[operation.key] {
        return (wrapper(operation.nodeType, inner, depth: depth), operation.key)
      }
    }
    if case .array(let items)? = object["nested_loop"] {
      return (nestedLoop(items, depth: depth), "nested_loop")
    }
    if case .object(let table)? = object["table"] {
      return (tableNode(table, depth: depth), "table")
    }
    return nil
  }

  /// Sort, Aggregate or Unique over the body inside it, costed as that body plus `sort_cost`.
  private static func wrapper(
    _ nodeType: String, _ object: [String: JSONValue], depth: Int
  ) -> ExplainNode {
    let child = body(of: object, depth: depth + 1)
    let sortCost = number(object["cost_info"], "sort_cost")
    var node = ExplainNode(
      nodeType: nodeType,
      children: child.map { [$0.node] } ?? [],
      extras: object.filter { $0.key != child?.key }
    )
    if child?.node.totalCost != nil || sortCost != nil {
      node.totalCost = (child?.node.totalCost ?? 0) + (sortCost ?? 0)
    }
    return node
  }

  /// Tables in join order. `prefix_cost` adds up along the join, so each table is costed
  /// with its own step (its `prefix_cost` minus the one before) and the loop with the last
  /// `prefix_cost`. Costs then add up the way the analyzer expects.
  private static func nestedLoop(_ items: [JSONValue], depth: Int) -> ExplainNode {
    var children: [ExplainNode] = []
    var previous = 0.0
    var last: Double?
    for item in items {
      guard case .object(let object) = item,
        let found = body(of: object, depth: depth + 1)
      else { continue }
      var child = found.node
      if found.key == "table", case .object(let table)? = object["table"],
        let prefix = number(table["cost_info"], "prefix_cost")
      {
        child.totalCost = max(0, prefix - previous)
        previous = prefix
        last = prefix
      }
      children.append(child)
    }
    return ExplainNode(nodeType: "Nested Loop", totalCost: last, children: children)
  }

  /// One table access. A derived table is a Subquery Scan over its subquery's plan.
  private static func tableNode(_ table: [String: JSONValue], depth: Int) -> ExplainNode {
    var nodeType = scanType(table)
    var children: [ExplainNode] = []
    if case .object(let materialized)? = table["materialized_from_subquery"] {
      nodeType = "Subquery Scan"
      if case .object(let block)? = materialized["query_block"],
        let inner = queryBlock(block, depth: depth + 1)
      {
        children = [inner]
      }
    }
    return ExplainNode(
      nodeType: nodeType,
      relationName: string(table["table_name"]),
      indexName: string(table["key"]),
      totalCost: number(table["cost_info"], "prefix_cost"),
      planRows: number(table["rows_examined_per_scan"]),
      filter: string(table["attached_condition"]),
      children: children,
      extras: table.filter { !mappedTableKeys.contains($0.key) }
    )
  }

  /// `ALL` is a Seq Scan; index join types are an Index Scan, or an Index Only Scan when the
  /// index covers the query (`using_index`). A table entry with only a message is a Result.
  private static func scanType(_ table: [String: JSONValue]) -> String {
    guard let access = string(table["access_type"]) else {
      return table["table_name"] == nil ? "Result" : "Table Scan"
    }
    if access == "ALL" { return "Seq Scan" }
    guard indexAccess.contains(access) else { return "Table Scan" }
    return table["using_index"] == .bool(true) ? "Index Only Scan" : "Index Scan"
  }

  /// MySQL writes costs as strings ("0.85") and row counts as numbers; both are accepted.
  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number)?:
      return number
    case .string(let text)?:
      return Double(text).flatMap { $0.isFinite ? $0 : nil }
    default:
      return nil
    }
  }

  private static func number(_ object: JSONValue?, _ key: String) -> Double? {
    guard case .object(let fields)? = object else { return nil }
    return number(fields[key])
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }
}
