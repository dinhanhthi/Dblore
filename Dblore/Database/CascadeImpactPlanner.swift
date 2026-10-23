// CascadeImpactPlanner.swift
// Read-only COUNT statements that show what deleting rows also changes through foreign keys.
// - ON DELETE CASCADE: the referencing rows are deleted too, so their own referencing rows are
//   counted through nested `IN (SELECT ...)` subqueries, up to `maxDepth` levels. A table
//   already on the path is counted but not followed again (cycles end).
// - SET NULL / SET DEFAULT: counted, not followed.
// - RESTRICT / NO ACTION: counted as blockers. DuckDB has no referential actions: every
//   referencing key is a blocker (the app currently counts nothing on DuckDB: these branches
//   are kept for the planner on its own). A blocker on the deleted table itself (`parent_id
//   REFERENCES same(id)`) does not count the rows deleted with it (`AND NOT (key IN ...)`).
//   A blocker on a table that a cascade of the same delete also deletes rows from (a cascaded
//   self-reference, a diamond, a CASCADE key beside a NO ACTION key) does not count the rows
//   the cascade deletes: `AND NOT COALESCE((<cascade condition>), FALSE)` per cascade the walk
//   recorded on that table (a NULL cascade column keeps the row counted). What is left is a
//   real blocker. Found after the walk: a diamond reaches the cascade only later in it.
//   The commit sends one DELETE per staged row, and NO ACTION on PostgreSQL and SQLite is
//   checked at the end of each of them: the exclusions are exact only for a single staged row
//   and a NO ACTION key. With more staged rows, a row left out may be deleted by a later
//   statement than the one it blocks; RESTRICT is checked at once, while the cascade runs, and
//   MySQL (InnoDB) checks NO ACTION the same way. The rows left out may then still fail the
//   delete, depending on the order the server deletes in, so each such blocker gets a second
//   count of them (`Effect.mayBlock`), shown, never refusing.
//   A cascade stopped by `maxDepth` or a cycle may delete rows the walk does not record: a
//   blocker on that table or on a table it cascades to is counted as `Effect.mayBlock` too.
//   A batch that also edits or inserts rows makes every blocker `Effect.mayBlock`: the commit
//   sends its deletes, then its updates, then its inserts, and a later statement can remove the
//   blocker before a deferred check (re-parent, then delete; delete, then insert the same key).
// Not modeled: DEFERRABLE keys (and SQLite `PRAGMA defer_foreign_keys`), triggers and rules
// that unlink or delete referencing rows, and keys that share columns (a composite NO ACTION
// key beside a SET NULL key). The counts are advisory: the server enforces its foreign keys,
// and the user can commit past a blocker.
// SQLite matches table names in any case and names a key by its columns (`orders(user_id)`):
// `pragma_foreign_key_list` only numbers them. Above `maxSteps` counts nothing is computed.
// Key values are always `:kN` binds (the gate's named parameters), never SQL text. Composite
// keys use row values (`(a, b) IN (...)`; SQLite through `VALUES`, which a row-value IN needs
// on its right), DuckDB an OR of AND groups. SQLite enforces foreign keys only with
// `PRAGMA foreign_keys` on: the plan carries that check to run first.
// Nothing here is sent to a database.

import Foundation

nonisolated enum CascadeImpactPlanner {
  /// Levels of CASCADE followed below the deleted rows
  static let maxDepth = 5
  /// Above this many deleted keys the impact is not computed
  static let maxKeys = 1_000
  /// Above this many counts (diamond cascades repeat a table per path) the impact is not
  /// computed
  static let maxSteps = 50
  /// SQLite: 0 means no foreign key is enforced (`Impact.notEnforced`)
  static let sqliteEnforcementCheck = "PRAGMA foreign_keys"

  /// What the delete does to the rows one step counts.
  enum Effect: Sendable, Equatable {
    case deleted
    case setNull
    case setDefault
    /// RESTRICT / NO ACTION (every DuckDB key): a count above 0 fails the delete
    case blocking
    /// Rows that may fail the delete or not: rows a blocker leaves out because the same batch
    /// deletes them, when the order of the deletes decides (`Count.checkedAtOnce`), every
    /// blocker on a table a cascade the walk stopped may still delete rows from, and every
    /// blocker of a batch that also edits or inserts rows
    case mayBlock
  }

  /// One COUNT of the rows of `schema.table` that `constraintName` ties to the deleted rows.
  struct CountStep: Sendable, Equatable {
    var schema: String
    var table: String
    var constraintName: String
    var effect: Effect
    /// 1 references the deleted rows, 2 references rows deleted by a depth-1 cascade, ...
    var depth: Int
    /// `SELECT COUNT(*) ...` with `:kN` placeholders
    var sql: String
    var parameters: [String: SQLBindValue]
  }

  struct Plan: Sendable, Equatable {
    var steps: [CountStep]
    /// Run before the steps (SQLite `sqliteEnforcementCheck`); nil when keys are always enforced
    var enforcementCheck: String?
  }

  enum Impact: Sendable, Equatable {
    /// Too many keys, or a name or key shape the planner cannot write; the server still enforces
    case notComputed(String)
    /// Set by the caller when `Plan.enforcementCheck` reads 0: nothing to count
    case notEnforced
    case plan(Plan)
  }

  /// Counts for deleting the rows of `schema.table` whose `keyColumns` hold each of `keys`
  /// (values in `keyColumns` order). `foreignKeys` is every key of the database.
  /// `batchAlsoWrites`: the same batch edits or inserts rows, so every blocker is `.mayBlock`.
  static func impact(
    deletingFrom schema: String, table: String, keyColumns: [String], keys: [[CellValue]],
    foreignKeys: [ForeignKey], dialect: SQLDialect, batchAlsoWrites: Bool = false
  ) -> Impact {
    guard keys.count <= maxKeys else {
      return .notComputed("More than \(maxKeys.formatted()) rows are deleted.")
    }
    let check = dialect == .sqlite ? sqliteEnforcementCheck : nil
    guard !keys.isEmpty, !keyColumns.isEmpty else {
      return .plan(Plan(steps: [], enforcementCheck: check))
    }
    var planner = Walk(
      foreignKeys: foreignKeys, dialect: dialect,
      deleted: Deleted(schema: schema, table: table, keyColumns: keyColumns, keys: keys))
    let steps: [CountStep]
    do {
      try planner.visit(
        schema: schema, table: table, rows: .keys(columns: keyColumns, values: keys), depth: 1,
        path: [pathKey(schema, table, dialect: dialect)])
      steps = try rendered(
        planner.counts, uncovered: planner.uncoveredTables, orderDependent: keys.count > 1,
        alsoWrites: batchAlsoWrites, dialect: dialect)
    } catch let failure as Failure {
      return .notComputed(failure.reason)
    } catch {
      return .notComputed("A table or column name can't be written as SQL.")
    }
    return .plan(Plan(steps: steps, enforcementCheck: check))
  }

  /// The steps, each blocker without the rows the same batch deletes from its table (its own
  /// staged rows, the rows a cascade deletes), followed by a `.mayBlock` count of those rows
  /// when the order of the deletes decides (`Count.checkedAtOnce`; its own staged rows when
  /// `orderDependent`, more than one row is staged). A blocker on an `uncovered` table, or any
  /// blocker when the batch `alsoWrites`, is `.mayBlock` itself.
  private static func rendered(
    _ counts: [Count], uncovered: Set<String>, orderDependent: Bool, alsoWrites: Bool,
    dialect: SQLDialect
  ) throws -> [CountStep] {
    var cascaded: [String: [Fragment]] = [:]
    for count in counts where count.effect == .deleted {
      cascaded[pathKey(count.schema, count.table, dialect: dialect), default: []].append(
        count.condition)
    }
    var steps: [CountStep] = []
    for count in counts {
      guard count.effect == .blocking else {
        steps.append(count.step(count.sql, effect: count.effect, dialect: dialect))
        continue
      }
      let table = pathKey(count.schema, count.table, dialect: dialect)
      let conditions = cascaded[table] ?? []
      var blocking = count.sql
      if let own = count.ownRows {
        blocking.text(" AND NOT (")
        blocking.append(own)
        blocking.text(")")
      }
      for condition in conditions {
        blocking.text(" AND NOT COALESCE((")
        blocking.append(condition)
        blocking.text("), FALSE)")
      }
      steps.append(
        count.step(
          blocking, effect: alsoWrites || uncovered.contains(table) ? .mayBlock : .blocking,
          dialect: dialect))
      var leftOutConditions = count.checkedAtOnce ? conditions : []
      var leftOut = count.sql
      if let own = count.ownRows {
        if orderDependent {
          leftOutConditions.insert(own, at: 0)
        } else {
          leftOut.text(" AND NOT (")
          leftOut.append(own)
          leftOut.text(")")
        }
      }
      guard !leftOutConditions.isEmpty else { continue }
      leftOut.text(" AND (")
      for (index, condition) in leftOutConditions.enumerated() {
        leftOut.text(index == 0 ? "(" : " OR (")
        leftOut.append(condition)
        leftOut.text(")")
      }
      leftOut.text(")")
      steps.append(count.step(leftOut, effect: .mayBlock, dialect: dialect))
    }
    guard steps.count <= maxSteps else {
      throw Failure(reason: "More than \(maxSteps) related counts are needed.")
    }
    return steps
  }

  /// SQLite table names match in any case
  fileprivate static func pathKey(
    _ schema: String, _ table: String, dialect: SQLDialect
  )
    -> String
  {
    "\(schema)\u{0}\(dialect == .sqlite ? table.lowercased() : table)"
  }

  /// The rows the user deletes
  fileprivate struct Deleted {
    var schema: String
    var table: String
    var keyColumns: [String]
    var keys: [[CellValue]]
  }

  fileprivate struct Failure: Error {
    var reason: String
  }

  /// One count of the walk, not rendered yet: blockers still get the cascade exclusions
  fileprivate struct Count {
    var schema: String
    var table: String
    var constraintName: String
    var effect: Effect
    var depth: Int
    /// `SELECT COUNT(*) FROM table WHERE condition`
    var sql: Fragment
    /// The counted rows, on the table's own columns
    var condition: Fragment
    /// A blocker on the deleted table: its rows staged for deletion (`key IN (...)`)
    var ownRows: Fragment?
    /// The rows a blocker leaves out may be deleted after the check that they fail: RESTRICT
    /// and NO ACTION on MySQL (InnoDB) are checked as each row is deleted, and with more than
    /// one staged row each staged row is its own DELETE statement
    var checkedAtOnce: Bool

    func step(_ sql: Fragment, effect: Effect, dialect: SQLDialect) -> CountStep {
      let (text, parameters) = sql.rendered(dialect: dialect)
      return CountStep(
        schema: schema, table: table, constraintName: constraintName, effect: effect,
        depth: depth, sql: text, parameters: parameters)
    }
  }

  /// The rows a step's referencing key points at.
  fileprivate enum Rows {
    /// The deleted rows, by key
    case keys(columns: [String], values: [[CellValue]])
    /// Rows of `relation` deleted by a cascade, matched by `condition`
    case selected(relation: String, condition: Fragment)
  }

  /// Depth-first walk of the referencing keys, collecting the steps.
  fileprivate struct Walk {
    let foreignKeys: [ForeignKey]
    let dialect: SQLDialect
    let deleted: Deleted
    var counts: [Count] = []
    /// Tables a CASCADE step deletes from but the walk did not follow (a cycle or `maxDepth`)
    var unfollowed: Set<String> = []

    init(foreignKeys: [ForeignKey], dialect: SQLDialect, deleted: Deleted) {
      self.foreignKeys = foreignKeys
      self.dialect = dialect
      self.deleted = deleted
    }

    mutating func visit(
      schema: String, table: String, rows: Rows, depth: Int, path: Set<String>
    ) throws {
      let parent = try relation(schema, table)
      for key in foreignKeys
      where key.targetSchema == schema && sameTable(key.targetTable, table) {
        guard counts.count < CascadeImpactPlanner.maxSteps else {
          throw Failure(
            reason: "More than \(CascadeImpactPlanner.maxSteps) related counts are needed.")
        }
        let condition = try match(
          key.sourceColumns, to: key.targetColumns, of: rows, parent: parent,
          constraint: key.constraintName)
        let child = try relation(key.sourceSchema, key.sourceTable)
        var count = Fragment()
        count.text("SELECT COUNT(*) FROM \(child) WHERE ")
        count.append(condition)
        let effect = effect(of: key)
        // Rows deleted in the same batch do not block their own delete
        let ownRows =
          effect == .blocking && key.sourceSchema == deleted.schema
            && sameTable(key.sourceTable, deleted.table)
          ? keyList(try deleted.keyColumns.map(dialect.quoteIdentifier), deleted.keys) : nil
        counts.append(
          Count(
            schema: key.sourceSchema, table: key.sourceTable, constraintName: name(of: key),
            effect: effect, depth: depth, sql: count, condition: condition, ownRows: ownRows,
            checkedAtOnce: key.onDelete == .restrict
              || (dialect == .mysql && key.onDelete == .noAction) || deleted.keys.count > 1))
        let childKey = CascadeImpactPlanner.pathKey(
          key.sourceSchema, key.sourceTable, dialect: dialect)
        guard effect == .deleted else { continue }
        guard depth < CascadeImpactPlanner.maxDepth, !path.contains(childKey) else {
          unfollowed.insert(childKey)
          continue
        }
        try visit(
          schema: key.sourceSchema, table: key.sourceTable,
          rows: .selected(relation: child, condition: condition), depth: depth + 1,
          path: path.union([childKey]))
      }
    }

    /// The `unfollowed` tables and every table a CASCADE key deletes from below them: the walk
    /// does not know all the rows the server deletes there
    var uncoveredTables: Set<String> {
      var tables = unfollowed
      var pending = Array(unfollowed)
      while let table = pending.popLast() {
        for key in foreignKeys where effect(of: key) == .deleted {
          let source = CascadeImpactPlanner.pathKey(
            key.sourceSchema, key.sourceTable, dialect: dialect)
          let target = CascadeImpactPlanner.pathKey(
            key.targetSchema, key.targetTable, dialect: dialect)
          if target == table, tables.insert(source).inserted {
            pending.append(source)
          }
        }
      }
      return tables
    }

    /// SQLite table names match in any case
    private func sameTable(_ name: String, _ other: String) -> Bool {
      dialect == .sqlite ? name.caseInsensitiveCompare(other) == .orderedSame : name == other
    }

    /// SQLite keys are only numbered: named by their table and columns
    private func name(of key: ForeignKey) -> String {
      guard dialect == .sqlite else { return key.constraintName }
      return "\(key.sourceTable)(\(key.sourceColumns.joined(separator: ", ")))"
    }

    private func effect(of key: ForeignKey) -> Effect {
      guard dialect != .duckdb else { return .blocking }
      switch key.onDelete {
      case .cascade: return .deleted
      case .setNull: return .setNull
      case .setDefault: return .setDefault
      case .restrict, .noAction: return .blocking
      }
    }

    /// `sources` (child columns) matched against `targets` (parent columns) of `rows`.
    private func match(
      _ sources: [String], to targets: [String], of rows: Rows, parent: String,
      constraint: String
    ) throws -> Fragment {
      guard !sources.isEmpty, sources.count == targets.count else {
        throw Failure(reason: "Foreign key \"\(constraint)\" has no matching column lists.")
      }
      let quotedSources = try sources.map(dialect.quoteIdentifier)
      switch rows {
      case .keys(let columns, let values):
        // The key references the deleted key columns: compare with the key values directly.
        let positions = targets.compactMap { columns.firstIndex(of: $0) }
        if positions.count == targets.count, Set(targets).count == columns.count {
          return keyList(
            quotedSources,
            values.map { row in positions.map { row.indices.contains($0) ? row[$0] : .null } })
        }
        let condition = keyList(try columns.map(dialect.quoteIdentifier), values)
        return try subquery(
          quotedSources, targets, relation: parent, condition: condition,
          constraint: constraint)
      case .selected(let relation, let condition):
        return try subquery(
          quotedSources, targets, relation: relation, condition: condition,
          constraint: constraint)
      }
    }

    /// `(sources) IN (SELECT targets FROM relation WHERE condition)`
    private func subquery(
      _ sources: [String], _ targets: [String], relation: String, condition: Fragment,
      constraint: String
    ) throws -> Fragment {
      guard sources.count == 1 || dialect != .duckdb else {
        throw Failure(
          reason: "Foreign key \"\(constraint)\" references columns that are not the row key.")
      }
      let columns = try targets.map(dialect.quoteIdentifier).joined(separator: ", ")
      var fragment = Fragment()
      fragment.text("\(tuple(sources)) IN (SELECT \(columns) FROM \(relation) WHERE ")
      fragment.append(condition)
      fragment.text(")")
      return fragment
    }

    /// `columns` equal to one of `values` (each in `columns` order).
    private func keyList(_ columns: [String], _ values: [[CellValue]]) -> Fragment {
      var fragment = Fragment()
      if columns.count > 1, dialect == .duckdb {
        fragment.text("(")
        for (row, value) in values.enumerated() {
          fragment.text(row == 0 ? "(" : " OR (")
          for (index, column) in columns.enumerated() {
            fragment.text(index == 0 ? "\(column) = " : " AND \(column) = ")
            fragment.value(index < value.count ? value[index] : .null)
          }
          fragment.text(")")
        }
        fragment.text(")")
        return fragment
      }
      let rowValues = columns.count > 1
      fragment.text("\(tuple(columns)) IN (" + (rowValues && dialect == .sqlite ? "VALUES " : ""))
      for (row, value) in values.enumerated() {
        fragment.text(row == 0 ? (rowValues ? "(" : "") : (rowValues ? ", (" : ", "))
        for index in columns.indices {
          if index > 0 {
            fragment.text(", ")
          }
          fragment.value(index < value.count ? value[index] : .null)
        }
        if rowValues {
          fragment.text(")")
        }
      }
      fragment.text(")")
      return fragment
    }

    private func tuple(_ columns: [String]) -> String {
      columns.count == 1 ? columns[0] : "(\(columns.joined(separator: ", ")))"
    }

    /// `"schema"."table"`, or `"table"` when the schema is empty.
    private func relation(_ schema: String, _ table: String) throws -> String {
      let name = try dialect.quoteIdentifier(table)
      guard !schema.isEmpty else { return name }
      return try dialect.quoteIdentifier(schema) + "." + name
    }
  }
}

/// SQL text and key values, rendered with `:kN` placeholders numbered per statement.
private nonisolated struct Fragment {
  private enum Segment {
    case text(String)
    case value(CellValue)
  }

  private var segments: [Segment] = []

  mutating func text(_ text: String) {
    segments.append(.text(text))
  }

  mutating func value(_ value: CellValue) {
    segments.append(.value(value))
  }

  mutating func append(_ other: Fragment) {
    segments.append(contentsOf: other.segments)
  }

  func rendered(dialect: SQLDialect) -> (sql: String, parameters: [String: SQLBindValue]) {
    var sql = ""
    var parameters: [String: SQLBindValue] = [:]
    for segment in segments {
      switch segment {
      case .text(let text):
        sql += text
      case .value(let value):
        let name = "k\(parameters.count + 1)"
        parameters[name] = SQLBindValue(
          optionalText: CellUpdateStatement.inputText(value, dialect: dialect))
        sql += CellUpdateStatement.bindPlaceholder(":\(name)", value, dialect: dialect)
      }
    }
    return (sql, parameters)
  }
}
