// AISchemaContext.swift
// Selects relevant tables and renders a compact, value-free schema description for AI prompts

import Foundation

/// Builds schema context for the AI assistant.
/// Privacy: only structure (names, types, constraints) is ever rendered, never row counts or values.
nonisolated enum AISchemaContext {

  private static let fallbackCount = 20

  // Local helpers: model computed properties are main-actor isolated by default.
  private static func qualified(_ table: DatabaseTable) -> String {
    "\(table.schema).\(table.name)"
  }
  private static func source(_ fk: ForeignKey) -> String { "\(fk.sourceSchema).\(fk.sourceTable)" }
  private static func target(_ fk: ForeignKey) -> String { "\(fk.targetSchema).\(fk.targetTable)" }
  private static func isSelfReferencing(_ fk: ForeignKey) -> Bool { source(fk) == target(fk) }

  // MARK: - Selection

  static func relevantTables(
    question: String, tables: [DatabaseTable], foreignKeys: [ForeignKey], limit: Int = 15
  ) -> [DatabaseTable] {
    let tokens = tokenize(question)
    var scores = tables.map { score($0, tokens: tokens) }

    let matched = Set(zip(tables, scores).filter { $0.1 > 0 }.map { qualified($0.0) })
    if matched.isEmpty { return Array(tables.prefix(fallbackCount)) }

    for (index, table) in tables.enumerated() {
      let name = qualified(table)
      for fk in foreignKeys where !isSelfReferencing(fk) {
        if source(fk) == name && matched.contains(target(fk)) {
          scores[index] += 3
        } else if target(fk) == name && matched.contains(source(fk)) {
          scores[index] += 3
        }
      }
    }

    // Stable sort: ties keep original order
    let ranked = tables.indices
      .filter { scores[$0] > 0 }
      .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
    return ranked.prefix(limit).map { tables[$0] }
  }

  static func selectTables(
    explicit: Set<String>, question: String, tables: [DatabaseTable], foreignKeys: [ForeignKey]
  ) -> [DatabaseTable] {
    if !explicit.isEmpty {
      return tables.filter { explicit.contains(qualified($0)) }
    }
    return relevantTables(question: question, tables: tables, foreignKeys: foreignKeys)
  }

  private static func tokenize(_ question: String) -> [String] {
    let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let tokens = words.filter { $0.count >= 3 }.map { word in
      word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }
    return Array(Set(tokens))
  }

  private static func score(_ table: DatabaseTable, tokens: [String]) -> Int {
    let name = table.name.lowercased()
    var total = tokens.contains { name.contains($0) } ? 10 : 0
    for column in table.columns {
      let columnName = column.name.lowercased()
      if tokens.contains(where: { columnName.contains($0) }) { total += 5 }
    }
    return total
  }

  // MARK: - Rendering

  static func render(
    tables: [DatabaseTable], foreignKeys: [ForeignKey], budgetChars: Int = 12_000
  ) -> String {
    var lines: [String] = []
    var used = 0
    var rendered: [DatabaseTable] = []

    for table in tables {
      let line = tableLine(table)
      if used + line.count + 1 > budgetChars { break }
      lines.append(line)
      used += line.count + 1
      rendered.append(table)
    }

    let names = Set(rendered.map { qualified($0) })
    for fk in foreignKeys
    where names.contains(source(fk)) && names.contains(target(fk)) {
      let line =
        "FK \(source(fk))(\(fk.sourceColumns.joined(separator: ", "))) -> "
        + "\(target(fk))(\(fk.targetColumns.joined(separator: ", ")))"
      if used + line.count + 1 > budgetChars { break }
      lines.append(line)
      used += line.count + 1
    }

    let remaining = tables.count - rendered.count
    if remaining > 0 { lines.append("-- … and \(remaining) more tables") }
    return lines.joined(separator: "\n")
  }

  private static func tableLine(_ table: DatabaseTable) -> String {
    let columns = table.columns.map { column -> String in
      var parts = [column.name, column.type]
      if column.isPrimaryKey { parts.append("PK") }
      if !column.isNullable { parts.append("NOT NULL") }
      if column.isUnique { parts.append("UNIQUE") }
      return parts.joined(separator: " ")
    }
    return "\(qualified(table))(\(columns.joined(separator: ", ")))"
  }
}
