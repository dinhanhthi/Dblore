// JoinQueryBuilder.swift
// The SELECT that joins the picked tables (Build Join Query). Each picked table after the first
// joins the tables before it on the fewest foreign-key hops (breadth-first over the loaded
// foreign keys, in either direction, in their given order); a table on that path that was not
// picked (a junction such as `order_items`) is joined too and listed, and picking it later
// reuses that join instead of adding a copy. A composite key compares column by column. Every
// table gets its own alias (its name, then `_2`, `_3`), so a self-reference or a second foreign
// key to the same table joins a fresh copy; a foreign key is used once from each joined table.
// Selected columns are qualified by alias, and a name selected more than once is aliased
// `<alias>_<column>`. Each table's filter is qualified by its alias; several are parenthesized
// and joined with AND. A table no foreign-key path reaches is refused, never cross joined. Every
// identifier is quoted, and a statement is returned only once it passed `ReadOnlyQueryGuard`.

import Foundation

nonisolated enum JoinQueryBuilder {
  enum JoinKind: String, CaseIterable, Identifiable, Sendable {
    case inner
    case left

    var id: String { rawValue }

    var title: String {
      switch self {
      case .inner: "Inner"
      case .left: "Left"
      }
    }

    fileprivate var keyword: String {
      switch self {
      case .inner: "INNER JOIN"
      case .left: "LEFT JOIN"
      }
    }
  }

  struct TableName: Hashable, Sendable {
    var schema: String
    var name: String
  }

  /// One picked table
  struct Pick: Sendable {
    var table: TableName
    /// How it joins the tables before it, and every junction on the way. Ignored on the first
    /// pick, and on a table already joined as a junction: that join keeps the kind of the pick
    /// that added it.
    var kind: JoinKind = .inner
    /// Selected columns in order. No column selected in any pick selects `*`.
    var columns: [String] = []
    var filter: TableFilter? = nil
  }

  /// A table of the FROM clause, in join order
  struct JoinedTable: Sendable, Equatable {
    var alias: String
    var table: TableName
    /// False for a junction added on the path to a pick and never picked itself
    var isPicked: Bool
    /// Constraint it joins on, nil for the first table
    var foreignKeyName: String?
  }

  struct Query: Sendable, Equatable {
    var sql: String
    var tables: [JoinedTable]
    /// Alias of each pick, in pick order
    var pickAliases: [String]
  }

  /// Why no query was built
  enum Refusal: Error, Equatable, LocalizedError {
    case noTables
    case noPath(TableName)

    var errorDescription: String? {
      switch self {
      case .noTables: "Pick at least one table."
      case .noPath(let table):
        "No foreign key path links \"\(table.name)\" to the tables before it (each foreign key "
          + "joins once from a table), so it cannot be joined."
      }
    }
  }

  /// One hop: `forward` goes from the key's source table to its target table
  private struct Step {
    var foreignKey: Int
    var forward: Bool
  }

  /// Hops from the joined table at `anchor`
  private struct Path {
    var anchor: Int
    var steps: [Step]
  }

  /// A foreign key already joined from the table aliased `anchor`
  private struct Use: Hashable {
    var foreignKey: Int
    var anchor: String
  }

  /// The SELECT over `picks` in order. Throws a `Refusal`, a `SQLDialectError` when a name
  /// cannot be quoted (a NUL, or MongoDB) or the refusal of `ReadOnlyQueryGuard`.
  static func query(
    picks: [Pick], foreignKeys: [ForeignKey], dialect: SQLDialect
  ) throws -> Query {
    guard let first = picks.first else { throw Refusal.noTables }
    var tables = [
      JoinedTable(alias: first.table.name, table: first.table, isPicked: true, foreignKeyName: nil)
    ]
    var pickAliases = [first.table.name]
    var joins: [String] = []
    var used: Set<Use> = []
    for pick in picks.dropFirst() {
      if let junction = tables.firstIndex(where: { !$0.isPicked && $0.table == pick.table }) {
        tables[junction].isPicked = true
        pickAliases.append(tables[junction].alias)
        continue
      }
      guard
        let path = shortestPath(
          to: pick.table, from: tables, foreignKeys: foreignKeys, used: used)
      else { throw Refusal.noPath(pick.table) }
      var anchor = tables[path.anchor].alias
      for (index, step) in path.steps.enumerated() {
        let key = foreignKeys[step.foreignKey]
        let table = endTable(of: step, foreignKeys)
        let alias = uniqueName(table.name, taken: tables.map(\.alias))
        let (anchorColumns, newColumns) =
          step.forward
          ? (key.sourceColumns, key.targetColumns) : (key.targetColumns, key.sourceColumns)
        let conditions = try zip(newColumns, anchorColumns).map {
          try column($0, of: alias, dialect: dialect) + " = "
            + column($1, of: anchor, dialect: dialect)
        }
        joins.append(
          try "\(pick.kind.keyword) \(dialect.qualified(schema: table.schema, name: table.name))"
            + " AS \(dialect.quoteIdentifier(alias)) ON \(conditions.joined(separator: " AND "))")
        let isPicked = index == path.steps.count - 1
        tables.append(
          JoinedTable(
            alias: alias, table: table, isPicked: isPicked, foreignKeyName: key.constraintName))
        used.insert(Use(foreignKey: step.foreignKey, anchor: anchor))
        anchor = alias
      }
      pickAliases.append(anchor)
    }

    let selected = try selectList(picks: picks, aliases: pickAliases, dialect: dialect)
    var lines = [
      "SELECT \(selected)",
      try "FROM \(dialect.qualified(schema: first.table.schema, name: first.table.name))"
        + " AS \(dialect.quoteIdentifier(first.table.name))",
    ]
    lines += joins
    let clauses = zip(picks, pickAliases).compactMap { pick, alias in
      pick.filter?.whereClause(dialect: dialect, qualifier: alias)
    }
    if clauses.count == 1 {
      lines.append("WHERE \(clauses[0])")
    } else if !clauses.isEmpty {
      lines.append("WHERE " + clauses.map { "(\($0))" }.joined(separator: " AND "))
    }
    let sql = lines.joined(separator: "\n")
    _ = try ReadOnlyQueryGuard.check(sql, dialect: dialect)
    return Query(sql: sql, tables: tables, pickAliases: pickAliases)
  }

  /// Fewest hops from any joined table to `target`, at least one. Ties go to the earlier joined
  /// table, then the earlier foreign key, forward before backward.
  private static func shortestPath(
    to target: TableName, from joined: [JoinedTable], foreignKeys: [ForeignKey], used: Set<Use>
  ) -> Path? {
    var frontier = joined.indices.map { Path(anchor: $0, steps: []) }
    var reached = Set(joined.map(\.table))
    while !frontier.isEmpty {
      var next: [Path] = []
      for path in frontier {
        let end = path.steps.last.map { endTable(of: $0, foreignKeys) } ?? joined[path.anchor].table
        for (index, key) in foreignKeys.enumerated() {
          if path.steps.isEmpty,
            used.contains(Use(foreignKey: index, anchor: joined[path.anchor].alias))
          {
            continue
          }
          let source = TableName(schema: key.sourceSchema, name: key.sourceTable)
          let destination = TableName(schema: key.targetSchema, name: key.targetTable)
          for forward in [true, false] where (forward ? source : destination) == end {
            let step = Step(foreignKey: index, forward: forward)
            let extended = Path(anchor: path.anchor, steps: path.steps + [step])
            let reachedTable = forward ? destination : source
            if reachedTable == target { return extended }
            if reached.insert(reachedTable).inserted { next.append(extended) }
          }
        }
      }
      frontier = next
    }
    return nil
  }

  /// The table a step reaches
  private static func endTable(of step: Step, _ foreignKeys: [ForeignKey]) -> TableName {
    let key = foreignKeys[step.foreignKey]
    return step.forward
      ? TableName(schema: key.targetSchema, name: key.targetTable)
      : TableName(schema: key.sourceSchema, name: key.sourceTable)
  }

  /// Qualified selected columns; a name selected more than once gets `AS <alias>_<column>`
  private static func selectList(
    picks: [Pick], aliases: [String], dialect: SQLDialect
  ) throws -> String {
    let selected = zip(picks, aliases).flatMap { pick, alias in
      pick.columns.map { (alias: alias, name: $0) }
    }
    guard !selected.isEmpty else { return "*" }
    var counts: [String: Int] = [:]
    for column in selected { counts[column.name.lowercased(), default: 0] += 1 }
    var taken = selected.map(\.name).filter { counts[$0.lowercased()] == 1 }
    return try selected.map { column in
      let qualified = try self.column(column.name, of: column.alias, dialect: dialect)
      guard counts[column.name.lowercased()]! > 1 else { return qualified }
      let name = uniqueName("\(column.alias)_\(column.name)", taken: taken)
      taken.append(name)
      return try "\(qualified) AS \(dialect.quoteIdentifier(name))"
    }.joined(separator: ", ")
  }

  private static func column(
    _ name: String, of alias: String, dialect: SQLDialect
  ) throws
    -> String
  {
    try dialect.quoteIdentifier(alias) + "." + dialect.quoteIdentifier(name)
  }

  /// `base`, or `base_2`, `base_3`, … when taken (case-insensitive, as SQLite and MySQL compare
  /// names)
  private static func uniqueName(_ base: String, taken: [String]) -> String {
    let lowered = Set(taken.map { $0.lowercased() })
    var name = base
    var suffix = 2
    while lowered.contains(name.lowercased()) {
      name = "\(base)_\(suffix)"
      suffix += 1
    }
    return name
  }
}
