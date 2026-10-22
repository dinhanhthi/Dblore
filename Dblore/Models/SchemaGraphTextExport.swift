// SchemaGraphTextExport.swift
// The schema visualizer's tables and foreign keys as text: a Mermaid `erDiagram` and a Graphviz
// DOT digraph. Mermaid ids keep to letters, digits, `_` and `-` (a sanitized name, `_e` after a
// Mermaid keyword, made unique with `_2`, `_3`, ...) and show the real name as a quoted alias.
// Mermaid quoted text has no escape, so a `"` inside one becomes `'` and line or control
// characters become spaces. DOT node ids are `n1`, `n2`, ... in node order; labels are quoted
// with `\` and `"` escaped.

import Foundation

enum SchemaGraphTextExport {
  // MARK: - Mermaid

  /// https://mermaid.js.org/syntax/entityRelationshipDiagram.html
  static func mermaid(_ graph: SchemaGraph) -> String {
    let ids = mermaidIDs(graph.nodes)
    let foreignKeyColumns = foreignKeyColumnsByNode(graph)
    let showsSchema = Set(graph.nodes.map(\.table.schema)).count > 1
    var lines = ["erDiagram"]
    for node in graph.nodes {
      let id = ids[node.id] ?? "_"
      let label = displayName(node.table, showsSchema: showsSchema)
      let entity = "    " + id + (label == id ? "" : "[\"\(mermaidQuoted(label))\"]")
      guard !node.table.columns.isEmpty else {
        lines.append(entity)
        continue
      }
      lines.append(entity + " {")
      let foreignKeys = foreignKeyColumns[node.id] ?? []
      for column in node.table.columns {
        let name = mermaidAttributeName(column.name)
        var attribute = "        \(mermaidType(column.type)) \(name)"
        let keys = [
          column.isPrimaryKey ? "PK" : nil, foreignKeys.contains(column.name) ? "FK" : nil,
          column.isUnique && !column.isPrimaryKey ? "UK" : nil,
        ].compactMap { $0 }
        if !keys.isEmpty { attribute += " " + keys.joined(separator: ", ") }
        // The real name, when the id had to change it
        if name != column.name {
          attribute += " \"\(mermaidQuoted(column.name))\""
        }
        lines.append(attribute)
      }
      lines.append("    }")
    }
    for edge in graph.edges {
      guard let source = graph.node(withId: edge.sourceNodeId),
        let sourceID = ids[edge.sourceNodeId], let targetID = ids[edge.targetNodeId]
      else { continue }
      let fk = edge.foreignKey
      let columns = fk.sourceColumns.compactMap { name in
        source.table.columns.first { $0.name == name }
      }
      // Target side: exactly one, or zero or one when a key column may be NULL
      let target = columns.contains(where: \.isNullable) ? "|o" : "||"
      // Source side: at most one row when the key is the single unique or primary key column
      let isOneToOne =
        columns.count == 1 && fk.sourceColumns.count == 1
        && (columns[0].isUnique
          || (columns[0].isPrimaryKey && source.table.columns.filter(\.isPrimaryKey).count == 1))
      let label =
        fk.constraintName.isEmpty ? fk.sourceColumns.joined(separator: ", ") : fk.constraintName
      lines.append(
        "    \(targetID) \(target)--\(isOneToOne ? "o|" : "o{") \(sourceID) : "
          + "\"\(mermaidQuoted(label))\"")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Sanitized, unique ids in node order: a later node that sanitizes to a taken id gets `_2`,
  /// `_3`, ... (the first free one)
  private static func mermaidIDs(_ nodes: [SchemaNode]) -> [UUID: String] {
    let showsSchema = Set(nodes.map(\.table.schema)).count > 1
    var taken = Set<String>()
    var ids: [UUID: String] = [:]
    for node in nodes {
      var base = mermaidName(displayName(node.table, showsSchema: showsSchema))
      if mermaidKeywords.contains(base.lowercased()) { base += "_e" }
      var id = base
      var suffix = 2
      while taken.contains(id) {
        id = "\(base)_\(suffix)"
        suffix += 1
      }
      taken.insert(id)
      ids[node.id] = id
    }
    return ids
  }

  /// Each run of characters outside `A-Z a-z 0-9 _ -` (plus `extra`) becomes one `_`; an empty
  /// result or one not starting with a letter or `_` gets a leading `_`
  private static func mermaidName(_ value: String, extra: Set<Character> = []) -> String {
    var result = ""
    var inRun = false
    for character in value {
      let allowed =
        (character.isASCII && (character.isLetter || character.isNumber))
        || character == "_" || character == "-" || extra.contains(character)
      if allowed {
        result.append(character)
        inRun = false
      } else if !inRun {
        result.append("_")
        inRun = true
      }
    }
    guard let first = result.first, first.isASCII, first.isLetter || first == "_" else {
      return "_" + result
    }
    return result
  }

  /// Lowercased words of the `erDiagram` grammar that an entity id must not be
  private static let mermaidKeywords: Set<String> = [
    "erdiagram", "style", "classdef", "class", "direction", "one", "many", "zero", "only", "or",
    "to", "pk", "fk", "uk", "tb", "bt", "lr", "rl", "acctitle", "accdescr", "title",
  ]

  /// A column's id; `_e` after a name that reads as a key marker (`PK`, `FK`, `UK`)
  private static func mermaidAttributeName(_ value: String) -> String {
    let name = mermaidName(value)
    return ["pk", "fk", "uk"].contains(name.lowercased()) ? name + "_e" : name
  }

  /// Types may also hold parentheses and square brackets (`varchar(20)`, `text[]`)
  private static func mermaidType(_ type: String) -> String {
    type.isEmpty
      ? "unknown" : mermaidName(type, extra: ["(", ")", "[", "]"])
  }

  /// `"` as `'`; control characters (`\n`, `\r`, tab, VT, FF, U+0085, ...) and the line and
  /// paragraph separators as spaces
  private static func mermaidQuoted(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .lineSeparator, .paragraphSeparator: result.append(" ")
      default: result.append(scalar == "\"" ? "'" : scalar)
      }
    }
    return String(result)
  }

  // MARK: - DOT

  /// https://graphviz.org/doc/info/lang.html
  static func dot(_ graph: SchemaGraph) -> String {
    let foreignKeyColumns = foreignKeyColumnsByNode(graph)
    let showsSchema = Set(graph.nodes.map(\.table.schema)).count > 1
    var lines = [
      "digraph \"schema\" {", "  graph [rankdir=LR];",
      "  node [shape=box, fontname=\"Helvetica\"];", "  edge [fontname=\"Helvetica\"];",
    ]
    // By position: qualified names may read the same (`a.b` + `c`, `a` + `b.c`)
    var ids: [UUID: String] = [:]
    for (index, node) in graph.nodes.enumerated() { ids[node.id] = "n\(index + 1)" }
    for node in graph.nodes {
      let foreignKeys = foreignKeyColumns[node.id] ?? []
      let columns = node.table.columns.map { column in
        let keys = [
          column.isPrimaryKey ? "PK" : nil, foreignKeys.contains(column.name) ? "FK" : nil,
        ].compactMap { $0 }
        return "\(column.name): \(column.type)"
          + (keys.isEmpty ? "" : " " + keys.joined(separator: " "))
      }
      // Lines joined with the `\n` escape after each one is escaped
      let label = ([displayName(node.table, showsSchema: showsSchema)] + columns)
        .map(dotEscaped).joined(separator: "\\n")
      lines.append("  \(ids[node.id] ?? "") [label=\"\(label)\"];")
    }
    for edge in graph.edges {
      guard let source = ids[edge.sourceNodeId], let target = ids[edge.targetNodeId]
      else { continue }
      lines.append(
        "  \(source) -> \(target) [label=\"\(dotEscaped(edge.foreignKey.constraintName))\"];")
    }
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
  }

  /// Inside a quoted DOT string: `\` and `"` escaped (so no `\N`, `\G`, ... label escape is
  /// formed), line breaks as the `\n` escape
  private static func dotEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r\n", with: "\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\n")
  }

  // MARK: - Shared

  /// The table name, schema-qualified when the diagram spans several schemas
  private static func displayName(_ table: DatabaseTable, showsSchema: Bool) -> String {
    showsSchema ? table.qualifiedName : table.name
  }

  /// Source columns of each node's outgoing foreign keys
  private static func foreignKeyColumnsByNode(_ graph: SchemaGraph) -> [UUID: Set<String>] {
    var result: [UUID: Set<String>] = [:]
    for edge in graph.edges {
      result[edge.sourceNodeId, default: []].formUnion(edge.foreignKey.sourceColumns)
    }
    return result
  }
}
