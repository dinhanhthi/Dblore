// CopyObjectsPlanner.swift
// Copy Objects: the DDL that copies the selected source tables into the target's default schema
// (PostgreSQL current_schema(), the MySQL / MariaDB database, SQLite main). No append mode: a
// selected table whose name the target schema already has refuses the plan (exact on PostgreSQL,
// ASCII case-insensitive on MySQL and SQLite).
//
// Run order: the prelude creates every table (columns with mapped types, primary key, NOT NULL,
// literal defaults, unique constraints, and CHECKs between the same engine only), the rows
// follow, then the post-row DDL: plain indexes first, then the foreign keys between selected
// tables, then (run-only, never shown) the identity restart. Creating without foreign keys makes
// cycles need no ordering. PostgreSQL and MySQL add the foreign keys as ALTER TABLE ADD
// CONSTRAINT with checks on, so the copied rows are validated; a SQLite target declares them
// inline and runs under PRAGMA defer_foreign_keys = ON, which checks them at COMMIT. Foreign keys
// to tables that are not selected are left out with a warning; triggers are listed, never copied.
//
// Plain indexes are the indexes that back neither the primary key nor a unique constraint, written
// as CREATE [UNIQUE] INDEX on every target. Partial indexes, expression keys without text,
// FULLTEXT and SPATIAL are skipped; across engines only column keys with the btree (or no) method
// are copied, with no method written; on a MySQL target a key on a TEXT / BLOB column of a MySQL
// source is skipped. Each skip is a warning. A key keeps DESC, and on a PostgreSQL target a NULLS
// FIRST / LAST that is not the default for the direction; NULLS on another target, and DESC on a
// MySQL before 8.0 or MariaDB before 10.8 target (which build the key ascending), are dropped
// with a warning. PostgreSQL and SQLite index names share one namespace
// per schema / database: an index or unique-constraint name that is already used (by the plan or
// by the target) or starts with sqlite_ becomes <table>_<name>, cut to 63 bytes with a short hash.
// On a SQLite target a constraint name starting with sqlite_ is dropped instead. MySQL and
// MariaDB foreign-key and CHECK names are unique per database: a name already used (by the plan
// or by the target's known names) gets the same <table>_<name> rename; ON DELETE / ON UPDATE SET
// DEFAULT, which InnoDB rejects, becomes the default action with a warning.
//
// Every identifier goes through `dialect.quoteIdentifier`: catalog names are data, never SQL text.
// Type, default, CHECK and index expression text is catalog text, checked with
// `StructureDDLBuilder.checkedText` like the structure editor's. The target evaluates a CHECK or
// an index expression on every copied row, as the target role, so one that calls anything but a
// few side-effect-free built-ins or has a subquery (`CopyObjectsDDLCheck.expressionRefusal`) is
// skipped with a warning.

import CryptoKit
import Foundation

nonisolated enum CopyObjectsPlanError: Error, Equatable, LocalizedError {
  case noTables
  case unsupportedTarget(String)
  case noTargetSchema
  /// No append mode: the target schema already has this name
  case targetTableExists(String)
  /// Two selected tables (from different source schemas) have the same target name
  case duplicateTable(String)

  var errorDescription: String? {
    switch self {
    case .noTables: "Select at least one table to copy."
    case .unsupportedTarget(let engine): "\(engine) cannot be a Copy Objects target."
    case .noTargetSchema: "The target connection has no current schema or database."
    case .targetTableExists(let name):
      "The target already has a table named \"\(name)\". Copy Objects only creates new tables."
    case .duplicateTable(let name):
      "Two selected tables would both be copied as \"\(name)\"."
    }
  }
}

nonisolated struct CopyObjectsPlan: Sendable, Equatable {
  typealias Engine = StructureDDLBuilder.Engine

  struct Column: Sendable, Equatable {
    /// The same name on the source and the target
    var name: String
    var mapping: CopyObjectsTypeMapping.Mapping
  }

  struct Table: Sendable, Equatable {
    /// The source table as loaded: its schema, name and primary key are what the rows are read by
    var source: TableStructure
    /// The target name (the source name), in `targetSchema`
    var name: String
    /// Every source column, in table order
    var columns: [Column]
    var draft: CreateTableDraft
    var createStatement: String
  }

  /// A PostgreSQL identity column whose sequence restarts after the rows
  struct IdentityColumn: Sendable, Equatable {
    var table: String
    var column: String
  }

  static let sqliteDeferForeignKeys = "PRAGMA defer_foreign_keys = ON"

  var source: Engine
  var target: Engine
  var targetSchema: String
  var tables: [Table]
  /// CREATE [UNIQUE] INDEX, after the rows
  var indexStatements: [String]
  /// ALTER TABLE ... ADD CONSTRAINT, after the indexes (PostgreSQL and MySQL only)
  var foreignKeyStatements: [String]
  var identityColumns: [IdentityColumn]
  var warnings: [String]

  /// Before the rows: SQLite's PRAGMA, then one CREATE TABLE per table
  var preludeStatements: [String] {
    let pragma: [String] = if case .sqlite = target { [Self.sqliteDeferForeignKeys] } else { [] }
    return pragma + tables.map(\.createStatement)
  }

  /// After the rows: indexes, then foreign keys
  var postRowStatements: [String] { indexStatements + foreignKeyStatements }

  /// The DDL the preview shows and the user may edit (checked by `CopyObjectsDDLCheck`)
  var editableDDL: String {
    (preludeStatements + postRowStatements).map { $0 + ";" }.joined(separator: "\n\n")
  }

  /// PostgreSQL: each identity sequence continues after the largest copied value. Run-only,
  /// after the rows; built from the planned names. Empty on other targets. Every function,
  /// operator and cast type names pg_catalog, so nothing on the target's search_path runs.
  func identityRestartStatements() throws -> [String] {
    guard case .postgresql = target else { return [] }
    let dialect = SQLDialect.postgresql
    return try identityColumns.map { identity in
      let table =
        try dialect.quoteIdentifier(targetSchema) + "."
        + dialect.quoteIdentifier(identity.table)
      let column = try dialect.quoteIdentifier(identity.column)
      return "SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence("
        + "\(dialect.literal(.string(table)))::pg_catalog.text, "
        + "\(dialect.literal(.string(identity.column)))::pg_catalog.text), "
        + "GREATEST(COALESCE(pg_catalog.max(\(column)), 0), 0)::pg_catalog.int8 "
        + "OPERATOR(pg_catalog.+) 1, false) FROM \(table)"
    }
  }
}

nonisolated enum CopyObjectsPlanner {
  typealias Engine = StructureDDLBuilder.Engine
  private typealias Constraint = TableStructure.Constraint

  struct SourceTable: Sendable, Equatable {
    var structure: TableStructure
    /// Listed in a warning, never copied
    var triggerNames: [String] = []
  }

  /// `existingNames`: the names already used in the target schema (tables and views; on
  /// PostgreSQL and SQLite also indexes and sequences, which share the namespace).
  /// `existingConstraintNames`: MySQL / MariaDB foreign-key and CHECK names already used in the
  /// target database.
  static func plan(
    _ tables: [SourceTable], source: Engine, target: Engine, targetSchema: String,
    existingNames: [String], existingConstraintNames: [String] = []
  ) throws -> CopyObjectsPlan {
    if case .duckdb = target { throw CopyObjectsPlanError.unsupportedTarget("DuckDB") }
    guard !tables.isEmpty else { throw CopyObjectsPlanError.noTables }
    guard !targetSchema.isEmpty else { throw CopyObjectsPlanError.noTargetSchema }
    var builder = Builder(
      source: source, target: target, schema: targetSchema, tables: tables.map(\.structure))
    let existing = Set(existingNames.map(builder.key))
    var planned = Set<String>()
    for table in tables.map(\.structure) {
      let key = builder.key(table.name)
      if existing.contains(key) { throw CopyObjectsPlanError.targetTableExists(table.name) }
      guard planned.insert(key).inserted else {
        throw CopyObjectsPlanError.duplicateTable(table.name)
      }
    }
    builder.usedNames = existing.union(planned)
    builder.usedConstraintNames = Set(existingConstraintNames.map(builder.key))
    var plannedTables: [CopyObjectsPlan.Table] = []
    for table in tables {
      plannedTables.append(try builder.table(table))
    }
    return CopyObjectsPlan(
      source: source, target: target, targetSchema: targetSchema, tables: plannedTables,
      indexStatements: builder.indexStatements, foreignKeyStatements: builder.foreignKeys,
      identityColumns: builder.identityColumns, warnings: builder.warnings)
  }

  /// The plan under construction: names already used, statements and warnings so far
  private struct Builder {
    let source: Engine
    let target: Engine
    let schema: String
    let dialect: SQLDialect
    let sameEngine: Bool
    /// Source (schema, name) of every selected table
    let selected: Set<[String]>
    /// Index (and unique constraint) names taken in the target schema, as `key` folds them
    var usedNames = Set<String>()
    /// MySQL / MariaDB foreign-key and CHECK names taken in the target database
    var usedConstraintNames = Set<String>()
    var indexStatements: [String] = []
    var foreignKeys: [String] = []
    var identityColumns: [CopyObjectsPlan.IdentityColumn] = []
    var warnings: [String] = []

    init(source: Engine, target: Engine, schema: String, tables: [TableStructure]) {
      self.source = source
      self.target = target
      self.schema = schema
      dialect = target.dialect
      sameEngine = source.dialect == target.dialect
      selected = Set(tables.map { [$0.schema, $0.name] })
    }

    /// PostgreSQL names are case-sensitive; MySQL and SQLite names are compared without case
    func key(_ name: String) -> String { Self.key(name, dialect: dialect) }

    static func key(_ name: String, dialect: SQLDialect) -> String {
      dialect == .postgresql ? name : SQLTokenizer.asciiLowercased(name)
    }

    mutating func table(_ selection: SourceTable) throws -> CopyObjectsPlan.Table {
      let table = selection.structure
      let name = table.name
      let primaryKey = CopyObjectsTypeMapping.primaryKey(of: table)
      var columns: [CopyObjectsPlan.Column] = []
      var draft = CreateTableDraft(schema: schema, name: name, columns: [])
      for column in table.columns {
        let mapping = try CopyObjectsTypeMapping.map(
          column, context: .init(column: column.name, in: table), from: source, to: target)
        for warning in mapping.warnings { warn(name, column.name, warning) }
        if column.generated != nil {
          warn(name, column.name, "A generated column: its values are copied as plain data.")
        }
        if mapping.identity == .generatedByDefault {
          identityColumns.append(.init(table: name, column: column.name))
        }
        columns.append(.init(name: column.name, mapping: mapping))
        draft.columns.append(
          .init(
            name: column.name, type: mapping.type, isNullable: column.isNullable,
            defaultExpression: mapping.defaultExpression,
            isPrimaryKey: primaryKey.contains(column.name)))
      }
      if primaryKey != table.columns.map(\.name).filter(primaryKey.contains) {
        warn(
          name,
          "The primary key is created in column order (\(primaryKey.joined(separator: ", ")) "
            + "in the source).")
      }

      let uniqueNames = Set(table.constraints.compactMap { $0.kind == .unique ? $0.name : nil })
      for constraint in table.constraints {
        switch constraint.kind {
        case .primaryKey:
          break
        case .unique:
          if hasMySQLLongKey(constraint.columns, in: table) {
            warn(
              name, "The unique key \(label(constraint.name)) on a TEXT or BLOB column is skipped.")
            continue
          }
          var unique = constraint
          unique.name = constraintName(constraint.name, table: name, isUnique: true)
          draft.constraints.append(unique)
        case .foreignKey(var reference):
          guard selected.contains([reference.schema, reference.table]) else {
            warn(
              name,
              "The foreign key \(label(constraint.name)) to \"\(reference.table)\" is left out: "
                + "that table is not copied.")
            continue
          }
          reference.schema = schema
          if case .mysql = target {
            for (clause, action) in [
              ("ON DELETE", reference.onDelete), ("ON UPDATE", reference.onUpdate),
            ]
            where action == .setDefault {
              warn(
                name,
                "The foreign key \(label(constraint.name)) loses \(clause) SET DEFAULT, which "
                  + "InnoDB rejects.")
            }
            if reference.onDelete == .setDefault { reference.onDelete = .noAction }
            if reference.onUpdate == .setDefault { reference.onUpdate = .noAction }
          }
          var foreignKey = constraint
          foreignKey.kind = .foreignKey(reference)
          foreignKey.name = constraintName(constraint.name, table: name, isUnique: false)
          if case .sqlite = target {
            draft.constraints.append(foreignKey)
          } else {
            foreignKeys.append(
              "ALTER TABLE \(try qualified(name)) ADD "
                + (try StructureDDLBuilder.constraintDefinition(
                  foreignKey, dialect: dialect, renamed: [:])))
          }
        case .check(let expression):
          guard sameEngine else {
            warn(
              name,
              "The check \(label(constraint.name)) is skipped: checks are copied only between "
                + "the same engine.")
            continue
          }
          guard (try? StructureDDLBuilder.checkedText(expression, "check", dialect: dialect)) != nil
          else {
            warn(name, "The check \(label(constraint.name)) cannot be restated safely: skipped.")
            continue
          }
          if let reason = CopyObjectsDDLCheck.expressionRefusal(expression, dialect: dialect) {
            warn(name, "The check \(label(constraint.name)) is skipped: it has \(reason).")
            continue
          }
          var check = constraint
          check.name = constraintName(constraint.name, table: name, isUnique: false)
          draft.constraints.append(check)
        }
      }
      if table.comment != nil || table.columns.contains(where: { $0.comment != nil }) {
        warn(name, "Comments are not copied.")
      }
      if !selection.triggerNames.isEmpty {
        warn(
          name,
          "Triggers are not copied: "
            + selection.triggerNames.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
      }

      // One statement: the draft has no comment
      let create = try CreateTableDDLBuilder.build(draft, engine: target)[0]
      for index in table.indexes where !index.isPrimary && !uniqueNames.contains(index.name) {
        if let statement = try indexStatement(index, table: table) {
          indexStatements.append(statement)
        }
      }
      return CopyObjectsPlan.Table(
        source: table, name: name, columns: columns, draft: draft,
        createStatement: create)
    }

    // MARK: Indexes

    /// CREATE [UNIQUE] INDEX for a plain index, or nil (with a warning) when it is skipped
    private mutating func indexStatement(
      _ index: TableStructure.Index, table: TableStructure
    ) throws -> String? {
      let what = "The index \"\(index.name)\""
      let method = index.method.map(SQLTokenizer.asciiLowercased)
      if index.isPartial {
        warn(table.name, "\(what) is partial: skipped.")
        return nil
      }
      if let method, ["fulltext", "spatial"].contains(method) {
        warn(table.name, "\(what) is a \(method.uppercased()) index: skipped.")
        return nil
      }
      var keys: [String] = []
      for key in index.keys {
        switch key {
        case .column(let column):
          keys.append(try dialect.quoteIdentifier(column))
        case .expression(let text):
          guard sameEngine, let text,
            (try? StructureDDLBuilder.checkedText(text, "index expression", dialect: dialect))
              != nil
          else {
            warn(table.name, "\(what) has an expression key that cannot be copied: skipped.")
            return nil
          }
          if let reason = CopyObjectsDDLCheck.expressionRefusal(text, dialect: dialect) {
            warn(table.name, "\(what) is skipped: its expression key has \(reason).")
            return nil
          }
          keys.append("(\(text))")
        }
      }
      var writtenMethod: String?
      if sameEngine {
        // SQLite has one kind of index and no USING
        if let method = index.method, dialect != .sqlite {
          guard !method.isEmpty, method.unicodeScalars.allSatisfy(Self.isASCIIWordCharacter)
          else {
            warn(table.name, "\(what) has a method that cannot be restated: skipped.")
            return nil
          }
          writtenMethod = method
        }
      } else if let method, method != "btree" {
        warn(table.name, "\(what) uses the \(method) method: skipped.")
        return nil
      }
      let columns = index.keys.compactMap { if case .column(let name) = $0 { name } else { nil } }
      if hasMySQLLongKey(columns, in: table) {
        warn(table.name, "\(what) on a TEXT or BLOB column is skipped.")
        return nil
      }
      applyOrder(index.sortOrder, to: &keys, warning: what, table: table.name)

      let name = indexName(index.name, table: table.name)
      let unique = index.isUnique ? "UNIQUE " : ""
      let list = keys.joined(separator: ", ")
      switch target {
      case .postgresql:
        return "CREATE \(unique)INDEX \(try dialect.quoteIdentifier(name)) ON "
          + "\(try qualified(table.name))" + (writtenMethod.map { " USING \($0)" } ?? "")
          + " (\(list))"
      case .mysql:
        return "CREATE \(unique)INDEX \(try dialect.quoteIdentifier(name)) ON "
          + "\(try qualified(table.name)) (\(list))" + (writtenMethod.map { " USING \($0)" } ?? "")
      case .sqlite, .duckdb:
        // SQLite qualifies the index; its table is looked up in the index's database
        return "CREATE \(unique)INDEX \(try qualified(name)) ON "
          + "\(try dialect.quoteIdentifier(table.name)) (\(list))"
      }
    }

    /// Each key's DESC and (PostgreSQL target) non-default NULLS; one warning per dropped clause
    private mutating func applyOrder(
      _ order: [TableStructure.Index.KeyOrder], to keys: inout [String], warning what: String,
      table: String
    ) {
      var server: MySQLServerInfo?
      if case .mysql(let info) = target { server = info }
      let keepsDescending = server?.supportsDescendingIndexKeys ?? true
      var droppedDescending = false
      var droppedNulls = false
      for position in keys.indices where position < order.count {
        let key = order[position]
        if key.descending {
          if keepsDescending { keys[position] += " DESC" } else { droppedDescending = true }
        }
        guard key.effectiveNullsFirst != key.descending else { continue }
        if dialect == .postgresql {
          keys[position] += key.effectiveNullsFirst ? " NULLS FIRST" : " NULLS LAST"
        } else {
          droppedNulls = true
        }
      }
      if droppedDescending, let server {
        let name = server.flavor == .mysql ? "MySQL" : "MariaDB"
        warn(
          table,
          "\(what) is copied without DESC: \(name) \(server.major).\(server.minor) builds every "
            + "key ascending.")
      }
      if droppedNulls {
        warn(table, "\(what) is copied without NULLS FIRST / LAST, which only PostgreSQL has.")
      }
    }

    /// MySQL to MySQL: a key on a TEXT / BLOB column needs a prefix length the catalog does not
    /// keep
    private func hasMySQLLongKey(_ columns: [String], in table: TableStructure) -> Bool {
      guard case .mysql = source, case .mysql = target else { return false }
      let long: Set<String> = [
        "tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob",
      ]
      return table.columns.contains { column in
        columns.contains(column.name)
          && long.contains(SQLTokenizer.asciiLowercased(column.dataType))
      }
    }

    // MARK: Names

    /// A constraint name for the target: SQLite drops names starting with sqlite_; a unique
    /// constraint's name follows the index rule on PostgreSQL and SQLite; a MySQL foreign-key or
    /// CHECK name is unique per database
    private mutating func constraintName(
      _ name: String?, table: String, isUnique: Bool
    ) -> String? {
      guard let name else { return nil }
      if case .sqlite = target, Self.isSQLiteReserved(name) { return nil }
      if isUnique { return indexName(name, table: table) }
      guard case .mysql = target else { return name }
      let dialect = dialect
      return Self.unused(
        name, table: table, renaming: false, in: &usedConstraintNames, dialect: dialect)
    }

    /// PostgreSQL and SQLite: a name already used or starting with sqlite_ becomes
    /// <table>_<name>, cut to 63 bytes with a short hash
    private mutating func indexName(_ name: String, table: String) -> String {
      switch target {
      case .postgresql, .sqlite: break
      case .mysql, .duckdb: return name
      }
      let dialect = dialect
      return Self.unused(
        name, table: table, renaming: Self.isSQLiteReserved(name), in: &usedNames,
        dialect: dialect)
    }

    /// `name`, or <table>_<name> (cut to 63 bytes, then numbered) when `used` has it or
    /// `renaming`; the result is added to `used`
    private static func unused(
      _ name: String, table: String, renaming: Bool, in used: inout Set<String>,
      dialect: SQLDialect
    ) -> String {
      let key = { (name: String) in Self.key(name, dialect: dialect) }
      var candidate = name
      if renaming || used.contains(key(candidate)) {
        let base = table + "_" + name
        candidate = fitted(base)
        var suffix = 2
        while used.contains(key(candidate)) {
          candidate = fitted(base + "_\(suffix)")
          suffix += 1
        }
      }
      used.insert(key(candidate))
      return candidate
    }

    /// `text` when it fits PostgreSQL's 63-byte names, else its first bytes and a short hash
    static func fitted(_ text: String) -> String {
      let limit = 63
      guard text.utf8.count > limit else { return text }
      let hash = SHA256.hash(data: Data(text.utf8)).prefix(4)
        .map { String(format: "%02x", $0) }.joined()
      var cut = String.UnicodeScalarView()
      var bytes = 0
      for scalar in text.unicodeScalars {
        let size = String(scalar).utf8.count
        guard bytes + size <= limit - hash.count - 1 else { break }
        cut.append(scalar)
        bytes += size
      }
      return String(cut) + "_" + hash
    }

    private static func isSQLiteReserved(_ name: String) -> Bool {
      SQLTokenizer.asciiLowercased(name).hasPrefix("sqlite_")
    }

    private static func isASCIIWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
      scalar.isASCII
        && (scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }

    // MARK: Text

    /// `schema.name` in the target schema
    private func qualified(_ name: String) throws -> String {
      try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(name)
    }

    private func label(_ name: String?) -> String {
      name.map { "\"\($0)\"" } ?? "(unnamed)"
    }

    private mutating func warn(_ table: String, _ message: String) {
      warnings.append("\"\(table)\": \(message)")
    }

    private mutating func warn(_ table: String, _ column: String, _ message: String) {
      warnings.append("\"\(table)\".\"\(column)\": \(message)")
    }
  }
}
