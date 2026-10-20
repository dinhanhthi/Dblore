// SQLiteExplainAdapter.swift
// Maps SQLite `EXPLAIN QUERY PLAN` rows (id, parent, notused, detail) onto the plan tree.
// SQLite reports neither cost nor time, so the analyzer shows no share bar.

import Foundation

nonisolated enum SQLiteExplainAdapter {
  /// Column names of an `EXPLAIN QUERY PLAN` result, in order.
  static let columnNames = ["id", "parent", "notused", "detail"]

  /// Deepest node kept. Anything below it is left out of the tree.
  static let maxDepth = 64

  /// Most rows read as a plan. With unique ids every row is at most one node, so this also caps
  /// the node count; a longer result is not a plan.
  static let maxRows = 5_000

  /// Nil unless there are 1 to `maxRows` rows, every row is an integer id and parent, any
  /// `notused`, and a text `detail`, and no two rows share an id. Rows hang under the row whose
  /// id is their parent; rows with no such parent are top level, and several top-level rows go
  /// under a "Query plan" node.
  static func plan(rows: [[CellValue]]) -> ExplainPlan? {
    guard !rows.isEmpty, rows.count <= maxRows else { return nil }
    var entries: [(id: Int, parent: Int, detail: String)] = []
    for row in rows {
      guard row.count == 4, case .int(let id) = row[0], case .int(let parent) = row[1],
        case .string(let detail) = row[3]
      else { return nil }
      entries.append((id, parent, detail))
    }
    let ids = Set(entries.map(\.id))
    guard ids.count == entries.count else { return nil }
    var childrenOf: [Int: [Int]] = [:]
    var tops: [Int] = []
    for (index, entry) in entries.enumerated() {
      if entry.parent != entry.id, ids.contains(entry.parent) {
        childrenOf[entry.parent, default: []].append(index)
      } else {
        tops.append(index)
      }
    }
    // Ids are unique, so each row is in one children list or `tops` and is built at most once;
    // rows on a parent cycle are never reached from a top-level row.
    func build(_ index: Int, depth: Int) -> ExplainNode? {
      guard depth <= maxDepth else { return nil }
      var built = node(detail: entries[index].detail)
      built.children = (childrenOf[entries[index].id] ?? []).compactMap {
        build($0, depth: depth + 1)
      }
      return built
    }
    let roots = tops.compactMap { build($0, depth: 1) }
    guard let first = roots.first else { return nil }
    if roots.count == 1 { return ExplainPlan(root: first) }
    return ExplainPlan(root: ExplainNode(nodeType: "Query plan", children: roots))
  }

  /// One `detail` line. The node type, relation and index come from SQLite's fixed wording; a
  /// trailing condition such as `(a=? AND b>?)` goes to `indexCond` only, and the whole line is
  /// kept in `extras["Detail"]`, so neither reaches the fields the AI plan context reads. A
  /// trailing keyword in parentheses (`MERGE (UNION)`) is part of the node type.
  private static func node(detail: String) -> ExplainNode {
    var node = ExplainNode(nodeType: nil, extras: ["Detail": .string(detail)])
    var text = detail
    if let open = trailingGroupStart(text), open > text.startIndex,
      text[text.index(before: open)] == " "
    {
      let condition = text[open...]
      if !condition.dropFirst().dropLast().allSatisfy({ $0 == " " || ("A"..."Z").contains($0) }) {
        node.indexCond = String(condition)
        text = String(text[..<text.index(before: open)])
      }
    }
    if let rest = text.dropPrefix("SCAN ") {
      access(&node, verb: "Scan", rest)
    } else if let rest = text.dropPrefix("SEARCH ") {
      access(&node, verb: "Search", rest)
    } else if let purpose = text.dropPrefix("USE TEMP B-TREE FOR ") {
      node.nodeType = "Temp B-Tree for \(purpose)"
    } else if let name = text.dropPrefix("MATERIALIZE ") {
      node.nodeType = "Materialize"
      node.relationName = name
    } else if let name = text.dropPrefix("CO-ROUTINE ") {
      node.nodeType = "Co-routine"
      node.relationName = name
    } else if let name = text.dropPrefix("BLOOM FILTER ON ") {
      node.nodeType = "Bloom Filter"
      node.relationName = name
    } else {
      node.nodeType = withoutTrailingNumber(text)
    }
    return node
  }

  /// The `(` matching the final `)`, so a nested group such as `(b=? AND (c,d)>(?,?))` stays
  /// whole. Nil when `text` does not end with `)` or its parentheses do not balance.
  private static func trailingGroupStart(_ text: String) -> String.Index? {
    guard text.hasSuffix(")") else { return nil }
    var depth = 0
    var index = text.endIndex
    while index > text.startIndex {
      index = text.index(before: index)
      if text[index] == ")" {
        depth += 1
      } else if text[index] == "(" {
        depth -= 1
        if depth == 0 { return index }
      }
    }
    return nil
  }

  /// `SCAN` / `SEARCH` `<name> [USING <access>]`, or a virtual table or constant row scan.
  /// The virtual table's index string stays in the detail line only.
  private static func access(_ node: inout ExplainNode, verb: String, _ rest: String) {
    var rest = rest.dropPrefix("TABLE ") ?? rest
    if verb == "Scan", rest == "CONSTANT ROW" {
      node.nodeType = "Constant Row"
      return
    }
    if let virtual = rest.range(of: " VIRTUAL TABLE ") {
      node.nodeType = "Virtual Table Scan"
      node.relationName = String(rest[..<virtual.lowerBound])
      node.indexCond = nil
      return
    }
    var using: String?
    if let range = rest.range(of: " USING ") {
      using = String(rest[range.upperBound...])
      rest = String(rest[..<range.lowerBound])
    }
    node.relationName = rest
    node.nodeType = verb
    guard let using else { return }
    if let index = using.dropPrefix("COVERING INDEX ") {
      node.nodeType = "Covering Index \(verb)"
      node.indexName = index
    } else if let index = using.dropPrefix("INDEX ") {
      node.nodeType = "Index \(verb)"
      node.indexName = index
    } else if using.hasSuffix("PRIMARY KEY") {
      node.nodeType = "Primary Key \(verb)"
    } else if using.hasPrefix("AUTOMATIC ") {
      node.nodeType = "Automatic Index \(verb)"
    }
  }

  /// `LIST SUBQUERY 2` is "LIST SUBQUERY": the number is in the detail line.
  private static func withoutTrailingNumber(_ text: String) -> String {
    guard let space = text.lastIndex(of: " "),
      text[text.index(after: space)...].allSatisfy(\.isNumber),
      space != text.index(before: text.endIndex)
    else { return text }
    return String(text[..<space])
  }
}

extension String {
  /// The rest of the string after `prefix`, nil when it does not start with it.
  nonisolated fileprivate func dropPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
