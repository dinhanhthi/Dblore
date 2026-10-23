// SchemaMigrationScriptBuilder.swift
// The script that makes the target schema match the source for the ticked `SchemaDiffItem`s,
// written for the TARGET engine through the app's DDL builders (nothing here writes ALTER
// syntax of its own). Run order, each group in item order:
// 1. drop foreign keys, 2. drop indexes (both also for a changed key or index),
// 3. create tables (`CreateTableDDLBuilder`), 4. column changes (`StructureDDLBuilder`, one
// build per item, so a MySQL column's edits stay in one MODIFY), 5. add indexes, 6. add foreign
// keys and the new tables' checks, 7. drop tables (`StructureDDLBuilder.dropTable`, no CASCADE).
// Every part of an item is built before any is kept: when a builder refuses one (SQLite needs a
// rebuild, an expression or partial index, an unnamed foreign key, a generated column), the
// whole item becomes a manual item with the reason, and nothing of it is scripted, so a changed
// index is never dropped without its replacement. A new table's parts that cannot be scripted
// (an index or check) are manual items of the create item; the table is still created.
// Identifiers are quoted by the builders. Types, defaults and checks are the source catalog's
// text, written verbatim: defaults are server-deparsed expressions (PostgreSQL `pg_get_expr`,
// MySQL / MariaDB `COLUMN_DEFAULT` as the introspector restates it, SQLite `dflt_value`), and a
// MySQL expression default (EXTRA DEFAULT_GENERATED) is wrapped in parentheses as MySQL requires.
// The builders lex that text like typed text and refuse what could end the statement. A foreign
// key to the source's own schema references the target schema; so does a PostgreSQL type,
// default or new table's check that names the source schema (`dev.mood`,
// `nextval('dev.orders_id_seq'::regclass)` become `"prod".…`, `SchemaDiff.schemaPrefixReplaced`).
// Text that names the source schema where it cannot be rewritten safely makes its item manual.
// PostgreSQL: a new table's or added column's default that reads a sequence of the target schema
// (its name rewritten as above) gets that sequence created before the CREATE TABLE / ADD COLUMN,
// in the same item (sequences are not in the diff, so a compare after the run reads the same
// default). The snapshots have no list of sequences, so the columns that read each one (in both
// snapshots, each side's schema prefix read as the target's) stand in for it:
// - a target column reads it: it exists, nothing is scripted;
// - only this column reads it, named as serial names it (`<table>_<column>_seq`, as parsed, not
//   truncated): plain `CREATE SEQUENCE` (`AS` the column's smallint / integer / bigint), then
//   `ALTER SEQUENCE … OWNED BY` the column. A leftover sequence of that name in the target makes
//   the script fail, before anything is changed, rather than take it over;
// - shared or named otherwise: `CREATE SEQUENCE IF NOT EXISTS` in every item that reads it (each
//   stays whole when another is unticked), never OWNED BY, with a warning.
// A default that reads any other sequence, or a changed default that reads one, is warned instead.
// A column change of type, or from NULL to NOT NULL, stays ticked with a warning: existing values
// may be converted (rounded, truncated, time zone dropped) or rejected. A default change on a
// PostgreSQL identity column (identity against serial) is manual: DROP DEFAULT would leave the
// column without either. Warnings carry their item's id.
// New tables: columns with their type, nullability and default; PostgreSQL identity and MySQL
// AUTO_INCREMENT, character set, collation, ON UPDATE and INVISIBLE (manual on MySQL before
// 8.0.23 and MariaDB before 10.3.3, which have no invisible columns) are kept in the column type
// text; the primary key (in column order), unique constraints and the table comment. Column
// comments and SQLite AUTOINCREMENT are not copied (a warning says so). SQLite foreign keys go
// inside CREATE TABLE (SQLite cannot add one later); elsewhere they are added in step 6. SQLite
// cannot add a CHECK later either: a new table's checks are manual items, with a warning that
// they are lost. Partitioning is not in the loaded structure: a PostgreSQL partitioned table or
// partition is created as a plain table.
// For the runner (phase 16): MySQL and MariaDB commit each DDL statement on its own, so a failed
// statement leaves the earlier ones applied. The runner must stop at the first error and tell the
// user to compare again before running anything else.

import Foundation

nonisolated struct SchemaMigrationScript: Sendable, Equatable {
  struct Statement: Sendable, Equatable {
    var sql: String
    /// The `SchemaDiffItem.id` it comes from
    var itemID: String
  }

  /// A change that is not scripted: the user makes it by hand
  struct ManualItem: Sendable, Equatable {
    var itemID: String
    var description: String
    var reason: String
  }

  /// Something to check before running the script, shown next to its item
  struct Warning: Sendable, Equatable {
    var itemID: String
    var message: String
  }

  /// In run order
  var statements: [Statement] = []
  var manualItems: [ManualItem] = []
  var warnings: [Warning] = []
}

nonisolated enum SchemaMigrationScriptBuilder {
  private typealias Column = TableStructure.Column
  private typealias Constraint = TableStructure.Constraint

  private enum Step: Int, Comparable {
    case dropForeignKeys, dropIndexes, createTables, columns, addIndexes, addForeignKeys
    case dropTables

    static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
  }

  /// One item's statements, built before any is kept
  private struct Plan {
    var parts: [(step: Step, sql: [String])] = []
    var manualItems: [SchemaMigrationScript.ManualItem] = []
    var warnings: [String] = []

    mutating func add(_ step: Step, _ sql: [String]) { parts.append((step, sql)) }
  }

  /// The ticked items of a `SchemaDiff` of `source` against `target`
  static func build(
    _ items: [SchemaDiffItem], source: SchemaSnapshot, target: SchemaSnapshot
  ) -> SchemaMigrationScript {
    let builder = Builder(source: source, target: target, items: items)
    var parts: [(step: Step, order: Int, statement: SchemaMigrationScript.Statement)] = []
    var script = SchemaMigrationScript()
    for item in items where item.isSelected {
      do {
        let plan = try builder.plan(item)
        for part in plan.parts {
          for sql in part.sql {
            parts.append((part.step, parts.count, .init(sql: sql, itemID: item.id)))
          }
        }
        script.manualItems += plan.manualItems
        script.warnings += plan.warnings.map { .init(itemID: item.id, message: $0) }
      } catch {
        script.manualItems.append(
          .init(itemID: item.id, description: item.description, reason: reason(error)))
      }
    }
    script.statements = parts.sorted { ($0.step, $0.order) < ($1.step, $1.order) }
      .map(\.statement)
    return script
  }

  private static func reason(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  private struct Builder {
    let source: SchemaSnapshot
    let target: SchemaSnapshot
    /// Per target table, the indexes ticked to be dropped (SQLite refuses dropping an indexed
    /// column, and the index is gone by step 4)
    let droppedIndexes: [String: Set<String>]

    init(source: SchemaSnapshot, target: SchemaSnapshot, items: [SchemaDiffItem]) {
      self.source = source
      self.target = target
      var dropped: [String: Set<String>] = [:]
      for item in items where item.isSelected {
        switch item.kind {
        case .dropIndex(let index), .changeIndex(_, let index):
          dropped[item.table, default: []].insert(index.name)
        default: break
        }
      }
      droppedIndexes = dropped
    }

    var engine: StructureDDLBuilder.Engine { target.engine }

    func plan(_ item: SchemaDiffItem) throws -> Plan {
      var plan = Plan()
      switch item.kind {
      case .createTable(let table):
        return try createPlan(table, item: item)
      case .dropTable(let table):
        plan.add(.dropTables, try StructureDDLBuilder.dropTable(table, engine: engine))
      case .addColumn(let column):
        let table = try targetTable(item.table)
        let column = try rewritten(column)
        let sequences = try serialSequences([column], table: table)
        plan.add(
          .columns,
          sequences.create + (try build([.addColumn(try newColumn(column))], table))
            + sequences.own)
        plan.warnings += sequences.warnings
      case .dropColumn(let column):
        var table = try targetTable(item.table)
        let dropped = droppedIndexes[item.table] ?? []
        table.indexes.removeAll { dropped.contains($0.name) }
        plan.add(.columns, try build([.dropColumn(column: column.name)], table))
      case .alterColumn(let from, let to):
        let table = try targetTable(item.table)
        let sameDefault = SchemaDiff.sameDefault(from, to, in: (source, target))
        if !sameDefault, from.identity != nil || to.identity != nil {
          throw StructureDDLError.unsupported(
            "\"\(to.name)\" is an identity or auto-increment column on one side: change it by hand."
          )
        }
        let rewrittenFrom = try rewritten(from)
        plan.add(.columns, try build(columnChanges(rewrittenFrom, to, original: from), table))
        if !sameDefault { plan.warnings += sequenceWarning(rewrittenFrom, table: table.name) }
        var lossy: [String] = []
        if !SchemaDiff.sameType(from, to, in: (source, target)) { lossy.append("the type change") }
        if !from.isNullable, to.isNullable { lossy.append("NOT NULL") }
        if !lossy.isEmpty {
          plan.warnings.append(
            "\"\(table.name)\".\"\(to.name)\": \(lossy.joined(separator: " and ")) may convert or "
              + "reject existing values; check the data first.")
        }
      case .addIndex(let index):
        plan.add(
          .addIndexes, try build([.createIndex(try newIndex(index))], targetTable(item.table)))
      case .dropIndex(let index):
        plan.add(.dropIndexes, try build([.dropIndex(name: index.name)], targetTable(item.table)))
      case .changeIndex(let from, let to):
        let table = try targetTable(item.table)
        plan.add(.dropIndexes, try build([.dropIndex(name: to.name)], table))
        plan.add(.addIndexes, try build([.createIndex(try newIndex(from))], table))
      case .addForeignKey(let constraint):
        plan.add(
          .addForeignKeys,
          try build([.addConstraint(remapped(constraint))], targetTable(item.table)))
      case .dropForeignKey(let constraint):
        plan.add(
          .dropForeignKeys, try build([try dropForeignKey(constraint)], targetTable(item.table)))
      case .changeForeignKey(let from, let to):
        let table = try targetTable(item.table)
        plan.add(.dropForeignKeys, try build([try dropForeignKey(to)], table))
        plan.add(.addForeignKeys, try build([.addConstraint(remapped(from))], table))
      }
      return plan
    }

    // MARK: Create table

    private func createPlan(_ sourceTable: TableStructure, item: SchemaDiffItem) throws -> Plan {
      var table = sourceTable
      table.schema = target.schema
      var plan = Plan()
      let primaryKey =
        table.constraints.first { $0.kind == .primaryKey }?.columns ?? []
      table.columns = try table.columns.map(rewritten)
      var draft = CreateTableDraft(
        schema: table.schema, name: table.name,
        columns: try table.columns.map { column in
          let definition = try newColumn(column)
          return CreateTableDraft.Column(
            name: column.name, type: definition.type, isNullable: column.isNullable,
            defaultExpression: definition.defaultExpression,
            isPrimaryKey: primaryKey.contains(column.name))
        },
        comment: table.comment)
      var later: [Constraint] = []
      for constraint in table.constraints {
        switch constraint.kind {
        case .unique:
          // SQLite names a unique constraint after its automatic index: let it pick again
          var unique = constraint
          if case .sqlite = engine { unique.name = nil }
          draft.constraints.append(unique)
        case .foreignKey:
          if case .sqlite = engine {
            draft.constraints.append(remapped(constraint))
          } else {
            later.append(remapped(constraint))
          }
        case .check:
          if case .sqlite = engine {
            plan.warnings.append(
              "\"\(table.name)\": SQLite cannot add a CHECK to an existing table, so "
                + "\(constraint.name.map { "\"\($0)\"" } ?? "a check") is lost unless added by hand."
            )
          }
          later.append(constraint)
        case .primaryKey:
          break
        }
      }
      let sequences = try serialSequences(table.columns, table: table)
      plan.add(
        .createTables,
        sequences.create + (try CreateTableDDLBuilder.build(draft, engine: engine))
          + sequences.own)

      let uniqueNames = Set(
        table.constraints.compactMap { $0.kind == .unique ? $0.name : nil })
      for index in table.indexes where !index.isPrimary && !uniqueNames.contains(index.name) {
        part(&plan, item: item, "Create index \"\(index.name)\" on \"\(table.name)\"") {
          (.addIndexes, try build([.createIndex(try newIndex(index))], table))
        }
      }
      for constraint in later {
        let what =
          constraint.name.map { "Add constraint \"\($0)\" on \"\(table.name)\"" }
          ?? "Add a constraint on \"\(table.name)\""
        part(&plan, item: item, what) {
          var constraint = constraint
          if case .check(let expression) = constraint.kind {
            constraint.kind = .check(try rewritten(expression))
          }
          return (.addForeignKeys, try build([.addConstraint(constraint)], table))
        }
      }
      if primaryKey != table.columns.map(\.name).filter(primaryKey.contains) {
        plan.warnings.append(
          "\"\(table.name)\": the primary key is created in column order (\(primaryKey.joined(separator: ", ")) in the source)."
        )
      }
      if table.columns.contains(where: { $0.comment != nil }) {
        plan.warnings.append("\"\(table.name)\": column comments are not copied.")
      }
      if case .sqlite = engine, table.columns.contains(where: { $0.identity == .autoIncrement }) {
        plan.warnings.append("\"\(table.name)\": AUTOINCREMENT is not copied.")
      }
      plan.warnings += sequences.warnings
      return plan
    }

    /// A part of a new table: its statements, or a manual item of the create item
    private func part(
      _ plan: inout Plan, item: SchemaDiffItem, _ description: String,
      _ make: () throws -> (Step, [String])
    ) {
      do {
        let (step, sql) = try make()
        plan.add(step, sql)
      } catch {
        plan.manualItems.append(
          .init(
            itemID: item.id, description: description,
            reason: SchemaMigrationScriptBuilder.reason(error)))
      }
    }

    // MARK: Changes

    private func build(_ changes: [StructureChange], _ table: TableStructure) throws -> [String] {
      try StructureDDLBuilder.build(changes: changes, structure: table, engine: engine)
    }

    private func targetTable(_ name: String) throws -> TableStructure {
      guard let table = target.tables.first(where: { $0.name == name }) else {
        throw StructureDDLError.unsupported("The target has no table \"\(name)\".")
      }
      return table
    }

    /// The source column's edits to the target column, named as the target names it: `from` as
    /// scripted, compared as `original` read
    private func columnChanges(
      _ from: Column, _ to: Column, original: Column
    ) -> [StructureChange] {
      var changes: [StructureChange] = []
      if !SchemaDiff.sameType(original, to, in: (source, target)) {
        changes.append(.alterColumnType(column: to.name, type: SchemaDiff.typeText(from)))
      }
      if from.isNullable != to.isNullable {
        changes.append(
          from.isNullable ? .dropNotNull(column: to.name) : .setNotNull(column: to.name))
      }
      if !SchemaDiff.sameDefault(original, to, in: (source, target)) {
        changes.append(
          restatedDefault(from).map { .setDefault(column: to.name, expression: $0) }
            ?? .dropDefault(column: to.name))
      }
      return changes
    }

    /// A source column as ADD COLUMN / CREATE TABLE writes it on the target engine
    private func newColumn(_ column: Column) throws -> StructureChange.NewColumn {
      if column.generated != nil {
        throw StructureDDLError.unsupported(
          "\"\(column.name)\" is a generated column: add it by hand.")
      }
      var type = SchemaDiff.typeText(column)
      switch engine {
      case .postgresql:
        switch column.identity {
        case .always: type += " GENERATED ALWAYS AS IDENTITY"
        case .byDefault: type += " GENERATED BY DEFAULT AS IDENTITY"
        case .autoIncrement, nil: break
        }
      case .mysql(let server):
        if let characterSet = column.characterSet { type += " CHARACTER SET \(characterSet)" }
        if let collation = column.collation { type += " COLLATE \(collation)" }
        if column.identity == .autoIncrement { type += " AUTO_INCREMENT" }
        let extra = try StructureDDLBuilder.MySQLExtra(column)
        if let onUpdate = extra.onUpdate { type += " ON UPDATE \(onUpdate)" }
        if extra.invisible {
          let version = (server.major, server.minor, server.patch)
          guard version >= (server.flavor == .mysql ? (8, 0, 23) : (10, 3, 3)) else {
            throw StructureDDLError.unsupported(
              "\"\(column.name)\" is an invisible column, which this server cannot create: "
                + "add it by hand.")
          }
          type += " INVISIBLE"
        }
      case .sqlite, .duckdb:
        break
      }
      return StructureChange.NewColumn(
        name: column.name, type: type, isNullable: column.isNullable,
        defaultExpression: restatedDefault(column))
    }

    /// The source default as the target writes it: MySQL needs an expression default
    /// (EXTRA DEFAULT_GENERATED, read back without them) in parentheses
    private func restatedDefault(_ column: Column) -> String? {
      guard let text = column.defaultExpression else { return nil }
      guard case .mysql(let server) = engine else { return text }
      return StructureDDLBuilder.restatedDefault(text, column: column, server: server)
    }

    /// PostgreSQL across two schemas: the source schema in the column's type and default names
    /// the target schema
    private func rewritten(_ column: Column) throws -> Column {
      var column = column
      column.dataType = try rewritten(column.dataType)
      column.columnType = try column.columnType.map(rewritten)
      column.defaultExpression = try column.defaultExpression.map(rewritten)
      return column
    }

    private func rewritten(_ text: String) throws -> String {
      guard case .postgresql = engine, source.schema != target.schema else { return text }
      let quoted = "\"" + target.schema.replacingOccurrences(of: "\"", with: "\"\"") + "\"."
      guard
        let text = SchemaDiff.schemaPrefixReplaced(in: text, schema: source.schema, with: quoted)
      else {
        throw StructureDDLError.unsupported(
          "\"\(text)\" names the schema \"\(source.schema)\" in a way that cannot be rewritten "
            + "for \"\(target.schema)\": change it by hand.")
      }
      return text
    }

    /// A PostgreSQL default that reads a sequence the script does not create needs that sequence
    /// in the target
    private func sequenceWarning(_ column: Column, table: String) -> [String] {
      guard case .postgresql = engine, column.defaultExpression?.contains("nextval(") == true
      else { return [] }
      return [
        "\"\(table)\".\"\(column.name)\": the default reads a sequence, which must exist in the target."
      ]
    }

    /// PostgreSQL: for new columns (defaults already rewritten) that read a sequence of the
    /// target schema (`nextval('"prod".orders_id_seq'::regclass)`), the statements that create
    /// it before the table or column and, for a serial column's own sequence, tie it to its
    /// column after (dropped with the column). See the file header for the cases. A default that
    /// reads any other sequence gets a warning instead.
    private func serialSequences(
      _ columns: [Column], table: TableStructure
    ) throws -> (create: [String], own: [String], warnings: [String]) {
      guard case .postgresql = engine else { return ([], [], []) }
      let dialect = engine.dialect
      let readers = sequenceReaders()
      var create: [String] = []
      var own: [String] = []
      var warnings: [String] = []
      var seen: Set<[String]> = []
      for column in columns {
        guard let text = column.defaultExpression, text.contains("nextval(") else { continue }
        guard let sequence = Self.nextvalSequence(text), sequence.schema == target.schema else {
          warnings += sequenceWarning(column, table: table.name)
          continue
        }
        let key = [sequence.schema, sequence.name]
        guard seen.insert(key).inserted, !readers.target.contains(key) else { continue }
        let name =
          try dialect.quoteIdentifier(sequence.schema) + "."
          + dialect.quoteIdentifier(sequence.name)
        guard readers.source[key] == 1, sequence.name == "\(table.name)_\(column.name)_seq" else {
          create.append("CREATE SEQUENCE IF NOT EXISTS \(name)")
          warnings.append(
            "\"\(table.name)\".\"\(column.name)\": the sequence \(name) is created if missing and "
              + "its ownership is left unchanged.")
          continue
        }
        let type: String? =
          switch SQLTokenizer.asciiLowercased(SchemaDiff.typeText(column)) {
          case "smallint", "int2": "smallint"
          case "integer", "int4": "integer"
          case "bigint", "int8": "bigint"
          default: nil
          }
        create.append("CREATE SEQUENCE \(name)" + (type.map { " AS \($0)" } ?? ""))
        let owner =
          try StructureDDLBuilder.tableName(table, dialect: dialect) + "."
          + dialect.quoteIdentifier(column.name)
        own.append("ALTER SEQUENCE \(name) OWNED BY \(owner)")
      }
      return (create, own, warnings)
    }

    /// How many source columns read each sequence (`[schema, name]`, the source schema read as
    /// the target's), and the sequences a target column reads
    private func sequenceReaders() -> (source: [[String]: Int], target: Set<[String]>) {
      func key(_ text: String?) -> [String]? {
        guard let text, let sequence = Self.nextvalSequence(text) else { return nil }
        return [sequence.schema, sequence.name]
      }
      var source: [[String]: Int] = [:]
      for column in self.source.tables.flatMap(\.columns) {
        if let key = key(column.defaultExpression.flatMap { try? rewritten($0) }) {
          source[key, default: 0] += 1
        }
      }
      let target = Set(
        self.target.tables.flatMap(\.columns).compactMap { key($0.defaultExpression) })
      return (source, target)
    }

    /// The schema and name of the sequence a whole default `nextval('schema.name'::regclass)`
    /// reads, each part bare (folded to lowercase, as PostgreSQL reads it) or double-quoted. Nil
    /// for any other default or an unqualified name.
    private static func nextvalSequence(_ text: String) -> (schema: String, name: String)? {
      let head = "nextval('"
      let tail = "'::regclass)"
      guard text.hasPrefix(head), text.hasSuffix(tail), text.count >= head.count + tail.count
      else { return nil }
      let literal = String(text.dropFirst(head.count).dropLast(tail.count))
      // A lone quote would end the literal early
      guard !literal.replacingOccurrences(of: "''", with: "").contains("'") else { return nil }
      let chars = Array(literal.replacingOccurrences(of: "''", with: "'"))
      var parts: [String] = []
      var i = 0
      while i < chars.count {
        var part = ""
        if chars[i] == "\"" {
          i += 1
          while true {
            guard i < chars.count else { return nil }
            if chars[i] == "\"" {
              guard i + 1 < chars.count, chars[i + 1] == "\"" else { break }
              i += 1
            }
            part.append(chars[i])
            i += 1
          }
          i += 1
        } else {
          while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_$".contains(chars[i]) {
            part.append(chars[i])
            i += 1
          }
          part = SQLTokenizer.asciiLowercased(part)
        }
        guard !part.isEmpty else { return nil }
        parts.append(part)
        if i < chars.count {
          guard chars[i] == ".", i + 1 < chars.count else { return nil }
          i += 1
        }
      }
      guard parts.count == 2 else { return nil }
      return (parts[0], parts[1])
    }

    private func newIndex(_ index: TableStructure.Index) throws -> StructureChange.NewIndex {
      let columns = index.keys.compactMap { key -> String? in
        if case .column(let name) = key { name } else { nil }
      }
      guard columns.count == index.keys.count, !index.isPartial else {
        throw StructureDDLError.unsupported(
          "\"\(index.name)\" is an expression or partial index: create it by hand.")
      }
      var method = index.method
      if case .mysql = engine, let kind = method,
        ["fulltext", "spatial"].contains(kind.lowercased())
      {
        throw StructureDDLError.unsupported(
          "\"\(index.name)\" is a \(kind.uppercased()) index: create it by hand.")
      }
      if case .sqlite = engine { method = nil }
      return StructureChange.NewIndex(
        name: index.name, columns: columns, isUnique: index.isUnique, method: method)
    }

    private func dropForeignKey(_ constraint: Constraint) throws -> StructureChange {
      guard let name = constraint.name else {
        throw StructureDDLError.unsupported("The foreign key has no name: change it by hand.")
      }
      return .dropConstraint(name: name, kind: .foreignKey)
    }

    /// A reference to the source's own schema points at the target schema
    private func remapped(_ constraint: Constraint) -> Constraint {
      guard case .foreignKey(var reference) = constraint.kind, reference.schema == source.schema
      else { return constraint }
      reference.schema = target.schema
      var remapped = constraint
      remapped.kind = .foreignKey(reference)
      return remapped
    }
  }
}
