// AIQueryContext.swift
// Catalog-only context of one SQL statement: the structure of the tables it names and the
// structure of the shown EXPLAIN plan with planner cost and width, never rows, conditions or
// literals

import Foundation

/// Builds the context an AI review of one statement reads. The tables the statement names are
/// resolved against the loaded catalog, their structure is fetched and rendered by
/// `AISchemaContext.render(structures:)` (structure only, never row counts or values), and the
/// EXPLAIN plan shown to the user is appended, capped, from its parsed `ExplainPlan`: structure
/// only (node types, relations, aliases, indexes, join types, strategies), with planner cost and
/// width kept. No rows, conditions or literals, because only whitelisted model fields are
/// rendered, never the raw plan text. MongoDB has no context (empty).
nonisolated enum AIQueryContext {
  static let tableLimit = 12
  static let explainLimit = 4_000
  static let fieldLimit = 128
  static let truncationMarker = "\n-- … plan truncated"

  struct TableName: Hashable, Sendable {
    let schema: String
    let name: String
  }

  /// One name part of a table reference: `text` is ASCII-uppercased when unquoted
  private struct Part {
    let text: String
    let quoted: Bool
  }

  /// Fetches the structure of every table `statement` names (at most `tableLimit`; a failed
  /// fetch skips that table) and renders it with `plan`. Empty for MongoDB. Throws
  /// `CancellationError` once cancelled, so a cut context is never returned.
  static func build(
    statement: String, dialect: SQLDialect, tables: [DatabaseTable], plan: ExplainPlan?,
    fetchStructure: @Sendable (String, String) async throws -> TableStructure
  ) async throws -> String {
    guard dialect != .mongodb else { return "" }
    let names = referencedTables(in: statement, dialect: dialect, tables: tables)
    return try await PerfSignpost.interval("ai.queryContext") {
      var structures: [TableStructure] = []
      for name in names {
        try Task.checkCancellation()
        if let structure = try? await fetchStructure(name.schema, name.name) {
          structures.append(structure)
        }
      }
      try Task.checkCancellation()
      return render(structures: structures, plan: plan)
    }
  }

  // MARK: - Table extraction

  /// Tables named after FROM, JOIN, UPDATE, INTO and USING (comma lists included), resolved
  /// against `tables` in statement order, deduplicated and capped at `tableLimit`.
  /// `a.b.c` keeps the last two parts. A qualified name must match schema and table; an
  /// unqualified one takes the first catalog table of that name. Names that resolve to no
  /// catalog table (CTEs, functions, other schemas) are skipped.
  static func referencedTables(
    in statement: String, dialect: SQLDialect, tables: [DatabaseTable]
  ) -> [TableName] {
    guard dialect != .mongodb else { return [] }
    let tokens = SQLTokenizer.tokens(statement, dialect: dialect)
    var found: [TableName] = []
    for (index, token) in tokens.enumerated()
    where ["FROM", "JOIN", "UPDATE", "INTO", "USING"].contains(token.keyword ?? "") {
      var position = index + 1
      while let (parts, next) = chain(in: tokens, at: position) {
        if let table = resolve(parts, dialect: dialect, tables: tables), !found.contains(table) {
          found.append(table)
        }
        position = next
        // An optional alias, then a comma continues the list
        if position < tokens.count, tokens[position].isWord("AS") { position += 1 }
        if position < tokens.count, isIdentifier(tokens[position]) { position += 1 }
        guard position < tokens.count, tokens[position].isSymbol(",") else { break }
        position += 1
      }
    }
    return Array(found.prefix(tableLimit))
  }

  private static func isIdentifier(_ token: SQLToken) -> Bool {
    token.kind == .word || token.kind == .quotedIdentifier
  }

  /// The dotted name starting at `start` and the index after it
  private static func chain(in tokens: [SQLToken], at start: Int) -> ([Part], Int)? {
    guard start < tokens.count, isIdentifier(tokens[start]) else { return nil }
    var parts = [part(tokens[start])]
    var position = start + 1
    while position + 1 < tokens.count, tokens[position].isSymbol("."),
      isIdentifier(tokens[position + 1])
    {
      parts.append(part(tokens[position + 1]))
      position += 2
    }
    return (parts, position)
  }

  private static func part(_ token: SQLToken) -> Part {
    Part(text: token.text, quoted: token.kind == .quotedIdentifier)
  }

  private static func resolve(
    _ parts: [Part], dialect: SQLDialect, tables: [DatabaseTable]
  ) -> TableName? {
    let name = parts.suffix(2)
    let match: DatabaseTable?
    if name.count == 2 {
      let schema = name[name.startIndex]
      let table = name[name.startIndex + 1]
      match = tables.first {
        matches(schema, $0.schema, dialect: dialect) && matches(table, $0.name, dialect: dialect)
      }
    } else {
      match = tables.first { matches(parts[0], $0.name, dialect: dialect) }
    }
    return match.map { TableName(schema: $0.schema, name: $0.name) }
  }

  /// PostgreSQL folds an unquoted name to lower case and keeps a quoted one exact. MySQL,
  /// SQLite and DuckDB compare table names without case (MySQL: macOS default).
  private static func matches(_ part: Part, _ catalogName: String, dialect: SQLDialect) -> Bool {
    if dialect == .postgresql {
      return part.quoted
        ? part.text == catalogName : SQLTokenizer.asciiLowercased(part.text) == catalogName
    }
    return SQLTokenizer.asciiLowercased(part.text) == SQLTokenizer.asciiLowercased(catalogName)
  }

  // MARK: - Rendering

  /// The rendered structures, then `plan` (when given) as one line per node, its body capped at
  /// `explainLimit` characters
  static func render(structures: [TableStructure], plan: ExplainPlan?) -> String {
    var sections: [String] = []
    if !structures.isEmpty { sections.append(AISchemaContext.render(structures: structures)) }
    if let plan {
      sections.append("EXPLAIN plan (structure, cost and width only):\n" + planText(plan.root))
    }
    return sections.joined(separator: "\n\n")
  }

  /// The tree under `root` depth first, two spaces of indent per level. Whole node lines are cut
  /// at `explainLimit` characters and `truncationMarker` ends the text, so the tree has no holes.
  private static func planText(_ root: ExplainNode) -> String {
    var lines: [String] = []
    var used = 0
    var stack = [(node: root, depth: 0)]
    while let (node, depth) = stack.popLast() {
      let line = String(repeating: "  ", count: depth) + nodeLine(node)
      guard used + line.count <= explainLimit else {
        return lines.joined(separator: "\n") + truncationMarker
      }
      used += line.count + 1
      lines.append(line)
      stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
    }
    return lines.joined(separator: "\n")
  }

  /// Whitelisted fields only, each read by name: node type, index, relation, alias (when it is
  /// not the relation name), join type, strategy, planner cost and width. Rows (planned or
  /// actual), timings, loops, conditions, filters, output lists, buffers, sort and hash memory,
  /// and `extras` are never read, so no row count, value or literal can reach the prompt.
  /// Planner cost and width are kept on purpose: they are estimates the review needs, derived
  /// from table statistics, not rows.
  ///
  /// The string fields are still untrusted: `ExplainResultPlan.parse` accepts any one-cell
  /// result whose column is named `QUERY PLAN` (besides the stricter SQLite and DuckDB plan
  /// shapes), so they can hold row data, and even a genuine plan carries user-written aliases.
  /// Every string is flattened to one line and capped at `fieldLimit`, so no field can add lines
  /// to the prompt. The node type must look like a node type (letters, spaces, hyphens, `$` and
  /// underscores, at most 64 characters) or renders as "Node"; join type and strategy must be
  /// one or two words of letters split by one space (at most 32 characters, which covers
  /// "Right Anti") or are left out.
  /// Relation, alias and index names are identifiers of any shape, so they are only flattened
  /// and capped.
  private static func nodeLine(_ node: ExplainNode) -> String {
    let relationName = sanitized(node.relationName)
    var line = allowed(sanitized(node.nodeType), limit: 64, extra: " -$_") ?? "Node"
    if let index = sanitized(node.indexName) { line += " using \(index)" }
    if let relation = relationName { line += " on \(relation)" }
    if let alias = sanitized(node.alias), alias != relationName { line += " \(alias)" }
    if let join = keyword(node.joinType) { line += " join=\(join)" }
    if let strategy = keyword(node.strategy) { line += " strategy=\(strategy)" }
    var figures: [String] = []
    if let total = node.totalCost {
      figures.append(
        "cost=" + (node.startupCost.map { cost($0) + ".." } ?? "") + cost(total))
    }
    if let width = node.planWidth { figures.append("width=\(width)") }
    if !figures.isEmpty { line += " (" + figures.joined(separator: " ") + ")" }
    return line
  }

  /// `value` on one line: control characters, newlines and tabs become spaces, runs of
  /// whitespace collapse to one space, the ends are trimmed, and the text is capped at
  /// `fieldLimit` characters ending in "…". Nil when nothing is left.
  private static func sanitized(_ value: String?) -> String? {
    guard let value else { return nil }
    let spaced = String(
      value.map { character in
        character.isWhitespace
          || character.unicodeScalars.contains {
            [.control, .format, .lineSeparator, .paragraphSeparator]
              .contains($0.properties.generalCategory)
          }
          ? " " : character
      })
    let flat = spaced.split(separator: " ").joined(separator: " ")
    guard !flat.isEmpty else { return nil }
    return flat.count > fieldLimit ? String(flat.prefix(fieldLimit - 1)) + "…" : flat
  }

  /// `value` when it is at most `limit` characters of ASCII letters and `extra`, else nil
  private static func allowed(_ value: String?, limit: Int, extra: String = "") -> String? {
    guard let value, !value.isEmpty, value.count <= limit,
      value.allSatisfy({ ($0.isASCII && $0.isLetter) || extra.contains($0) })
    else { return nil }
    return value
  }

  /// `value` when it is one or two words of ASCII letters split by a single space, at most 32
  /// characters, else nil
  private static func keyword(_ value: String?) -> String? {
    guard let value = allowed(value, limit: 32, extra: " ") else { return nil }
    let words = value.split(separator: " ", omittingEmptySubsequences: false)
    return words.count <= 2 && words.allSatisfy({ !$0.isEmpty }) ? value : nil
  }

  private static func cost(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
