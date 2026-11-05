// TableHealthReport.swift
// Table Health: a read-only list of findings per table, plus notes on how far the server's
// statistics can be trusted. "No primary key" and "foreign key without a covering index" come from
// each `TableStructure`; unused, redundant and bloated indexes or tables come from the engine's
// statistics (`TableHealthQueries`).
//
// An index covers a foreign key when the key's columns are the index's leading key columns, in any
// order inside that prefix: (a, b) is covered by (b, a, c), not by (c, a, b) or (a). A partial
// index (`isPartial`) never counts, nor does one with an expression key (`Key.expression`) inside
// that prefix. The primary key's columns count as an index too: a SQLite INTEGER PRIMARY KEY is
// the rowid and lists no index.

import Foundation

nonisolated struct TableHealthFinding: Sendable, Equatable {
  enum Kind: Sendable, Hashable {
    case noPrimaryKey
    case foreignKeyWithoutIndex
    case unusedIndex
    case deadTuples
    case redundantIndex
  }

  /// Ordered: `warning` sorts above `info`
  enum Severity: Sendable, Comparable {
    case info
    case warning
  }

  var schema: String
  var table: String
  var kind: Kind
  /// The foreign key or index the finding is about. Nil for a table-wide finding, and for a
  /// foreign key the engine does not name (SQLite).
  var objectName: String?
  /// One line of user-facing text
  var reason: String

  var severity: Severity {
    switch kind {
    case .noPrimaryKey, .foreignKeyWithoutIndex, .deadTuples: .warning
    case .unusedIndex, .redundantIndex: .info
    }
  }
}

nonisolated struct TableHealthReport: Sendable, Equatable {
  var findings: [TableHealthFinding] = []
  /// What limits the statistics findings (collection off, statistics reset lately, a missing
  /// sys schema). At most one per cause.
  var notes: [String] = []

  /// The structure checks of one table: no primary key, then each uncovered foreign key
  static func structureFindings(_ structure: TableStructure) -> [TableHealthFinding] {
    var findings: [TableHealthFinding] = []
    let primaryKey = structure.constraints.first { $0.kind == .primaryKey }?.columns
    if primaryKey == nil, !structure.indexes.contains(where: \.isPrimary) {
      findings.append(
        .init(
          schema: structure.schema, table: structure.name, kind: .noPrimaryKey,
          reason: "No primary key, so rows can only be identified by their physical position, "
            + "which is unstable for edits and replication."))
    }
    let primaryKeys = primaryKey.map { $0.map(TableStructure.Index.Key.column) }
    for constraint in structure.constraints {
      guard case .foreignKey(let reference) = constraint.kind, !constraint.columns.isEmpty,
        !structure.indexes.contains(where: { covers($0, constraint.columns) }),
        !(primaryKeys.map { covers($0, constraint.columns) } ?? false)
      else { continue }
      let parent =
        reference.schema.isEmpty ? reference.table : "\(reference.schema).\(reference.table)"
      findings.append(
        .init(
          schema: structure.schema, table: structure.name, kind: .foreignKeyWithoutIndex,
          objectName: constraint.name,
          reason: "Foreign key (\(constraint.columns.joined(separator: ", "))) has no index that "
            + "starts with its columns, so each delete or key update in \(parent) scans this table."
        ))
    }
    return findings
  }

  /// One run's report: each table's structure findings, then the statistics findings of the
  /// tables in `structures` (a table the run did not read can't be checked or shown), warnings
  /// first. An unused index is kept only when it can be dropped: not unique or primary, and not
  /// covering a foreign key of its table (`covers`, so a partial index never counts), which the
  /// key's deletes and updates need even while no query uses it.
  static func combined(
    structures: [TableStructure], statistics: TableHealthReport
  ) -> TableHealthReport {
    var byTable: [String: TableStructure] = [:]
    for structure in structures {
      byTable[tableKey(structure.schema, structure.name)] = structure
    }
    let kept = statistics.findings.filter { finding in
      guard let structure = byTable[tableKey(finding.schema, finding.table)] else { return false }
      guard finding.kind == .unusedIndex,
        let index = structure.indexes.first(where: { $0.name == finding.objectName })
      else { return true }
      if index.isUnique || index.isPrimary { return false }
      return !structure.constraints.contains { constraint in
        guard case .foreignKey = constraint.kind, !constraint.columns.isEmpty else { return false }
        return covers(index, constraint.columns)
      }
    }
    let findings = (structures.flatMap(structureFindings) + kept).enumerated()
      .sorted { lhs, rhs in
        lhs.element.severity != rhs.element.severity
          ? lhs.element.severity > rhs.element.severity : lhs.offset < rhs.offset
      }
      .map(\.element)
    return TableHealthReport(findings: findings, notes: statistics.notes)
  }

  private static func tableKey(_ schema: String, _ table: String) -> String {
    "\(schema)\u{0}\(table)"
  }

  /// Whether `index` serves lookups on `columns`: not partial, and its keys cover them
  private static func covers(_ index: TableStructure.Index, _ columns: [String]) -> Bool {
    !index.isPartial && covers(index.keys, columns)
  }

  /// Whether the first `columns.count` keys are plain columns that are exactly `columns`
  private static func covers(_ keys: [TableStructure.Index.Key], _ columns: [String]) -> Bool {
    guard keys.count >= columns.count else { return false }
    var leading: Set<String> = []
    for key in keys.prefix(columns.count) {
      guard case .column(let name) = key else { return false }
      leading.insert(name)
    }
    return leading == Set(columns)
  }
}
