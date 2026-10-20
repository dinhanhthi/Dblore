// SQLDumpDDL.swift
// Schema statements of a SQL dump, rendered from catalog reads the caller has already made. The
// dump writer emits `comment`, then `preData`, then one INSERT batch series per `tables` entry
// (in order, skipping entries without data), then `postData`. Every statement ends with `;`.
//
// PostgreSQL: pre-data is CREATE SCHEMA for every non-public schema, enums, domains, the
// sequences that column defaults use, then CREATE TABLE with columns, PK, UNIQUE and CHECK
// (partitioned parents before their partitions). Post-data is indexes, exclusion constraints,
// NOT VALID domain and table checks, foreign keys, `ALTER SEQUENCE ... OWNED BY`, `setval`, then
// views. NOT VALID checks come after the data so rows that break them still restore. Identity
// sequences are created by their column (`SEQUENCE NAME` keeps their name); they still get a
// `setval`.
// MySQL: `SHOW CREATE TABLE` text as printed, views from `SHOW CREATE VIEW` without DEFINER. The
// writer adds `SET FOREIGN_KEY_CHECKS`.
// SQLite: `PRAGMA defer_foreign_keys = ON;` first, then `sqlite_master.sql` of tables (internal
// `sqlite_` tables and virtual-table shadow tables skipped; a virtual table keeps its CREATE
// only); AUTOINCREMENT counters, indexes, views and triggers after data. That text is file data,
// so each one must be exactly one CREATE statement of its row's type (`sqliteDefinition`).
// DuckDB: pre-data is CREATE SCHEMA for every schema but `main`, the ENUM types, the sequences
// (built from their values, starting at the next one), then `duckdb_tables().sql` in creation
// order (a foreign key's table first); post-data is `duckdb_indexes().sql`, then
// `duckdb_views().sql` after the views each one names (DuckDB resolves a view's names when it is
// created, and a reopened file numbers views by name). The catalog text must be exactly one CREATE statement
// of its kind (`duckdbDefinition`). The table text writes ENUM columns as `ENUM('a', ...)`, so
// restored columns have the labels but not the type name.
//
// Views are ordered by their dependencies, ties and unknown dependencies by schema then name.
// Identifiers go through `SQLDialect.quoteIdentifier`; expressions, types and definitions are
// server text, written as the catalog printed them.

import Foundation
import SQLite3

nonisolated enum SQLDumpDDLError: Error, Equatable, LocalizedError {
  /// A table listed in `sqlite_master` has no structure in the input
  case missingStructure(String)
  /// An index has an expression key whose text the catalog did not report
  case unrenderableIndex(String)
  /// A SQLite `sqlite_master.sql` text is not exactly one CREATE statement of its row's type
  case unsafeDefinition(String)

  var errorDescription: String? {
    switch self {
    case .missingStructure(let name): "The structure of table \"\(name)\" was not read."
    case .unrenderableIndex(let name): "Index \"\(name)\" has an expression that was not read."
    case .unsafeDefinition(let name):
      "The definition of \"\(name)\" is not a single CREATE statement of its kind."
    }
  }
}

nonisolated enum SQLDumpDDL {
  struct ObjectName: Sendable, Hashable {
    var schema: String
    var name: String
  }

  struct ColumnRef: Sendable, Equatable {
    var table: ObjectName
    var column: String
  }

  struct Script: Sendable, Equatable {
    /// `-- ` lines for the top of the dump
    var comment: [String]
    var preData: [String]
    /// Tables in creation order
    var tables: [TableInsert]
    var postData: [String]
  }

  /// What the data writer needs to read one table and write its INSERTs
  struct TableInsert: Sendable, Equatable {
    var schema: String
    var name: String
    /// Quoted name for `INSERT INTO` and the data read: PostgreSQL `"schema"."table"`, MySQL and
    /// SQLite the table alone (a restore targets the connected database)
    var target: String
    /// Columns to read and insert, in table order. Generated columns are left out.
    var columns: [TableStructure.Column]
    /// A column is PostgreSQL `GENERATED ALWAYS AS IDENTITY`: the INSERT needs
    /// `OVERRIDING SYSTEM VALUE`
    var overridingSystemValue: Bool
    /// False for a PostgreSQL partitioned parent: its rows live in its partitions
    var hasData: Bool
  }

  struct View: Sendable, Equatable {
    var schema: String
    var name: String
    /// PostgreSQL `pg_get_viewdef` text; MySQL `SHOW CREATE VIEW` text; SQLite `sqlite_master.sql`
    var sql: String
    /// Objects the view reads (PostgreSQL `pg_depend`/`pg_rewrite`, MySQL
    /// `information_schema.VIEW_TABLE_USAGE`). Only other views affect the order; empty when
    /// unknown.
    var dependsOn: [ObjectName]
  }

  // MARK: - PostgreSQL input

  struct PostgresInput: Sendable, Equatable {
    var tables: [PostgresTable]
    /// Sequences that dumped column defaults use (`nextval`), plus identity sequences
    var sequences: [PostgresSequence]
    /// Enum types that dumped columns or domains use
    var enums: [PostgresEnum]
    /// Domains that dumped columns use, in creation order
    var domains: [PostgresDomain]
    var views: [View]
  }

  struct PostgresTable: Sendable, Equatable {
    var structure: TableStructure
    /// `pg_get_partkeydef` text (`RANGE (logdate)`) of a partitioned table
    var partitionKey: String? = nil
    /// Set for a partition
    var partitionOf: Partition? = nil
    /// Constraints a partition gets from its parent (`coninhcount > 0` and not local)
    var inheritedConstraintNames: Set<String> = []
    /// Indexes attached to a parent index (`pg_inherits` on the index)
    var inheritedIndexNames: Set<String> = []
    /// `pg_get_indexdef(indexrelid)` by index name. Used as is when present (it keeps operator
    /// classes, ordering and INCLUDE columns), otherwise the index is rebuilt from `structure`.
    var indexDefinitions: [String: String] = [:]
    /// `pg_get_constraintdef(oid)` of foreign keys by name. Used as is when present (it keeps
    /// MATCH FULL, DEFERRABLE and NOT VALID), otherwise the key is rebuilt from `structure`.
    var foreignKeyDefinitions: [String: String] = [:]
    /// `pg_get_constraintdef(oid)` of exclusion constraints (`contype = 'x'`) by name. Their
    /// backing index has the constraint's name and is not emitted as an index.
    var exclusionConstraints: [String: String] = [:]
    /// `pg_get_constraintdef(oid)` of CHECK constraints that are not validated (`contype = 'c'`,
    /// `NOT convalidated`) by name. They are left out of the table's creation and added after
    /// the data (the text ends in `NOT VALID`), so rows that break them still restore.
    var notValidCheckDefinitions: [String: String] = [:]
  }

  struct Partition: Sendable, Equatable {
    var parent: ObjectName
    /// `pg_get_expr(relpartbound, oid)` text (`FOR VALUES FROM (...) TO (...)`, `DEFAULT`)
    var bound: String
  }

  struct PostgresSequence: Sendable, Equatable {
    var schema: String
    var name: String
    /// `smallint`, `integer` or `bigint`
    var dataType: String
    var start: Int64
    var increment: Int64
    var minValue: Int64
    var maxValue: Int64
    var cycle: Bool
    /// Column the sequence belongs to (serial, bigserial, identity, `OWNED BY`)
    var ownedBy: ColumnRef?
    /// `pg_sequences.last_value`: nil when the sequence was never used
    var lastValue: Int64?
    /// Created by its identity column, never by `CREATE SEQUENCE`
    var isIdentity: Bool
  }

  struct PostgresEnum: Sendable, Equatable {
    var schema: String
    var name: String
    /// In sort order
    var labels: [String]
  }

  struct PostgresDomain: Sendable, Equatable {
    var schema: String
    var name: String
    /// `format_type` text of the base type
    var baseType: String
    var defaultExpression: String?
    var notNull: Bool
    var constraints: [DomainConstraint]
  }

  struct DomainConstraint: Sendable, Equatable {
    var name: String
    /// `pg_get_constraintdef` text (`CHECK ((VALUE > 0))`)
    var definition: String
    /// Not validated (`NOT convalidated`; the text ends in `NOT VALID`): added after the data
    /// with `ALTER DOMAIN`, since `CREATE DOMAIN` cannot hold it
    var notValid: Bool = false
  }

  // MARK: - MySQL and SQLite input

  struct MySQLInput: Sendable, Equatable {
    var tables: [MySQLTable]
    var views: [View]
  }

  struct MySQLTable: Sendable, Equatable {
    var structure: TableStructure
    /// `SHOW CREATE TABLE` text
    var createStatement: String
  }

  struct SQLiteInput: Sendable, Equatable {
    /// `sqlite_master` rows in rowid order
    var masterRows: [SQLiteMasterRow]
    /// One per name in `sqliteDumpedTableNames(masterRows, shadowTableNames:)`
    var structures: [TableStructure]
    /// `PRAGMA table_list` names of type `shadow`. Nil when that pragma is not available: then
    /// a table whose name starts with a virtual table's name and `_` is a shadow table.
    var shadowTableNames: Set<String>? = nil
    /// `sqlite_sequence` rows (AUTOINCREMENT counters)
    var sequences: [SQLiteSequence] = []
  }

  struct SQLiteSequence: Sendable, Equatable {
    var name: String
    var seq: Int64
  }

  struct SQLiteMasterRow: Sendable, Equatable {
    var type: String
    var name: String
    var tableName: String
    /// Nil for automatic indexes
    var sql: String?
  }

  // MARK: - DuckDB input

  struct DuckDBInput: Sendable, Equatable {
    /// Schemas other than `main`
    var schemas: [String]
    var enums: [DuckDBEnum]
    var sequences: [DuckDBSequence]
    /// In creation order: a table a foreign key references comes first
    var tables: [DuckDBTable]
    /// In creation order
    var indexes: [DuckDBIndex]
    /// `duckdb_views().sql`; `dependsOn` is filled from the names each one mentions
    var views: [View]
  }

  struct DuckDBEnum: Sendable, Equatable {
    var schema: String
    var name: String
    /// In sort order
    var labels: [String]
  }

  struct DuckDBSequence: Sendable, Equatable {
    var schema: String
    var name: String
    var start: Int64
    var increment: Int64
    var minValue: Int64
    var maxValue: Int64
    var cycle: Bool
    /// `duckdb_sequences().last_value`: nil when the sequence was never used
    var lastValue: Int64?
  }

  struct DuckDBTable: Sendable, Equatable {
    var structure: TableStructure
    /// `duckdb_tables().sql`
    var sql: String
  }

  struct DuckDBIndex: Sendable, Equatable {
    var schema: String
    var table: String
    var name: String
    /// `duckdb_indexes().sql`
    var sql: String
  }

  // MARK: - PostgreSQL

  private static let postgresComment = [
    "-- Not included: functions, procedures, triggers, extensions, roles, ownership, grants,",
    "-- row security policies, materialized views, comments, and types other than enums and domains.",
  ]

  static func postgres(_ input: PostgresInput) throws -> Script {
    let dialect = SQLDialect.postgresql
    let tables = parentsFirst(input.tables)
    var pre = try dumpedSchemas(input).map {
      "CREATE SCHEMA IF NOT EXISTS \(try dialect.quoteIdentifier($0));"
    }
    for type in input.enums {
      let labels = type.labels.map { dialect.literal(.string($0)) }.joined(separator: ", ")
      pre.append(
        "CREATE TYPE \(try qualified(type.schema, type.name)) AS ENUM (\(labels));")
    }
    pre += try input.domains.map(domainStatement)
    for sequence in input.sequences where !sequence.isIdentity {
      pre.append(
        "CREATE SEQUENCE \(try qualified(sequence.schema, sequence.name)) AS \(sequence.dataType) "
          + sequenceOptions(sequence) + ";")
    }
    var indexes: [String] = []
    var checks = try input.domains.flatMap { domain in
      try domain.constraints.filter(\.notValid).map {
        "ALTER DOMAIN \(try qualified(domain.schema, domain.name)) ADD CONSTRAINT"
          + " \(try dialect.quoteIdentifier($0.name)) \($0.definition);"
      }
    }
    var foreignKeys: [String] = []
    var inserts: [TableInsert] = []
    for table in tables {
      let structure = table.structure
      let name = try StructureDDLBuilder.tableName(structure, dialect: dialect)
      let ownConstraints = structure.constraints.filter {
        !table.inheritedConstraintNames.contains($0.name ?? "")
          && table.notValidCheckDefinitions[$0.name ?? ""] == nil
      }
      if let partition = table.partitionOf {
        pre.append(
          "CREATE TABLE \(name) PARTITION OF "
            + "\(try qualified(partition.parent.schema, partition.parent.name)) \(partition.bound)"
            + (table.partitionKey.map { " PARTITION BY \($0)" } ?? "") + ";")
        for constraint in ownConstraints where !constraint.isForeignKey {
          pre.append("ALTER TABLE \(name) ADD \(try definition(constraint));")
        }
      } else {
        pre.append(try createTable(table, constraints: ownConstraints, sequences: input.sequences))
      }
      indexes += try indexStatements(table, tableName: name)
      for (constraint, text) in table.exclusionConstraints.sorted(by: { $0.key < $1.key }) {
        indexes.append(
          "ALTER TABLE \(name) ADD CONSTRAINT \(try dialect.quoteIdentifier(constraint)) \(text);")
      }
      // A parent's check reaches its partitions through this ALTER
      for (constraint, text) in table.notValidCheckDefinitions.sorted(by: { $0.key < $1.key })
      where !table.inheritedConstraintNames.contains(constraint) {
        checks.append(
          "ALTER TABLE \(name) ADD CONSTRAINT \(try dialect.quoteIdentifier(constraint)) \(text);")
      }
      for constraint in ownConstraints where constraint.isForeignKey {
        if let constraintName = constraint.name,
          let text = table.foreignKeyDefinitions[constraintName]
        {
          foreignKeys.append(
            "ALTER TABLE \(name) ADD CONSTRAINT \(try dialect.quoteIdentifier(constraintName))"
              + " \(text);")
          continue
        }
        foreignKeys.append("ALTER TABLE \(name) ADD \(try definition(constraint));")
      }
      let columns = structure.columns.filter { $0.generated == nil }
      inserts.append(
        TableInsert(
          schema: structure.schema, name: structure.name, target: name, columns: columns,
          overridingSystemValue: columns.contains { $0.identity == .always },
          hasData: table.partitionKey == nil))
    }
    var ownership: [String] = []
    var setvals: [String] = []
    for sequence in input.sequences {
      let name = try qualified(sequence.schema, sequence.name)
      if let owner = sequence.ownedBy, !sequence.isIdentity {
        ownership.append(
          "ALTER SEQUENCE \(name) OWNED BY \(try qualified(owner.table.schema, owner.table.name))."
            + "\(try dialect.quoteIdentifier(owner.column));")
      }
      if let last = sequence.lastValue {
        setvals.append(
          "SELECT pg_catalog.setval(\(dialect.literal(.string(name))), \(last), true);")
      }
    }
    let views = try orderedViews(input.views).map {
      "CREATE VIEW \(try qualified($0.schema, $0.name)) AS\n"
        + terminated($0.sql.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return Script(
      comment: postgresComment, preData: pre, tables: inserts,
      postData: indexes + checks + foreignKeys + ownership + setvals + views)
  }

  /// Non-public schemas of every dumped object, sorted
  private static func dumpedSchemas(_ input: PostgresInput) -> [String] {
    var schemas = Set(input.tables.map(\.structure.schema))
    schemas.formUnion(input.sequences.filter { !$0.isIdentity }.map(\.schema))
    schemas.formUnion(input.enums.map(\.schema))
    schemas.formUnion(input.domains.map(\.schema))
    schemas.formUnion(input.views.map(\.schema))
    schemas.remove(SQLDialect.postgresql.defaultSchema)
    return schemas.sorted()
  }

  private static func domainStatement(_ domain: PostgresDomain) throws -> String {
    var text = "CREATE DOMAIN \(try qualified(domain.schema, domain.name)) AS \(domain.baseType)"
    if let expression = domain.defaultExpression { text += " DEFAULT \(expression)" }
    if domain.notNull { text += " NOT NULL" }
    for constraint in domain.constraints where !constraint.notValid {
      text +=
        " CONSTRAINT \(try SQLDialect.postgresql.quoteIdentifier(constraint.name))"
        + " \(constraint.definition)"
    }
    return text + ";"
  }

  /// `START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 NO CYCLE`
  private static func sequenceOptions(_ sequence: PostgresSequence) -> String {
    "START WITH \(sequence.start) INCREMENT BY \(sequence.increment)"
      + " MINVALUE \(sequence.minValue) MAXVALUE \(sequence.maxValue)"
      + (sequence.cycle ? " CYCLE" : " NO CYCLE")
  }

  private static func createTable(
    _ table: PostgresTable, constraints: [TableStructure.Constraint],
    sequences: [PostgresSequence]
  ) throws -> String {
    let structure = table.structure
    let dialect = SQLDialect.postgresql
    var lines: [String] = []
    for column in structure.columns {
      var line = "\(try dialect.quoteIdentifier(column.name)) \(column.dataType)"
      if let generated = column.generated, let expression = generated.expression {
        line += " GENERATED ALWAYS AS (\(expression)) \(generated.isStored ? "STORED" : "VIRTUAL")"
      }
      if column.identity == .always || column.identity == .byDefault {
        line += column.identity == .always ? " GENERATED ALWAYS" : " GENERATED BY DEFAULT"
        line += " AS IDENTITY"
        let owner = ColumnRef(
          table: ObjectName(schema: structure.schema, name: structure.name), column: column.name)
        if let sequence = sequences.first(where: { $0.isIdentity && $0.ownedBy == owner }) {
          line +=
            " (SEQUENCE NAME \(try qualified(sequence.schema, sequence.name)) "
            + sequenceOptions(sequence) + ")"
        }
      }
      if column.generated == nil, let expression = column.defaultExpression {
        line += " DEFAULT \(expression)"
      }
      if !column.isNullable { line += " NOT NULL" }
      lines.append(line)
    }
    for constraint in constraints where !constraint.isForeignKey {
      lines.append(try definition(constraint))
    }
    let body =
      lines.isEmpty ? "()" : "(\n" + lines.map { "  " + $0 }.joined(separator: ",\n") + "\n)"
    return "CREATE TABLE \(try StructureDDLBuilder.tableName(structure, dialect: dialect)) \(body)"
      + (table.partitionKey.map { " PARTITION BY \($0)" } ?? "") + ";"
  }

  /// Indexes other than the ones backing a primary key, unique or exclusion constraint and the
  /// ones a partition inherits
  private static func indexStatements(_ table: PostgresTable, tableName: String) throws -> [String]
  {
    let dialect = SQLDialect.postgresql
    let constraintNames = Set(table.structure.constraints.compactMap(\.name))
    var statements: [String] = []
    for index in table.structure.indexes
    where !index.isPrimary && !constraintNames.contains(index.name)
      && !table.inheritedIndexNames.contains(index.name)
      && table.exclusionConstraints[index.name] == nil
    {
      if let definition = table.indexDefinitions[index.name] {
        statements.append(terminated(removingOnOnly(definition)))
        continue
      }
      let keys = try index.keys.map { key -> String in
        switch key {
        case .column(let name): return try dialect.quoteIdentifier(name)
        case .expression(let text?): return "(\(text))"
        case .expression(nil): throw SQLDumpDDLError.unrenderableIndex(index.name)
        }
      }
      statements.append(
        "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(try dialect.quoteIdentifier(index.name))"
          + " ON \(tableName)" + (index.method.map { " USING \($0)" } ?? "")
          + " (\(keys.joined(separator: ", ")))"
          + (index.predicate.map { " WHERE \($0)" } ?? "") + ";")
    }
    return statements
  }

  /// `pg_get_indexdef` prints `ON ONLY` for an index on a partitioned table. Without ONLY the
  /// index also builds (or attaches) the partitions' indexes, which the dump does not emit.
  static func removingOnOnly(_ definition: String) -> String {
    var rest = Substring(definition)
    for prefix in ["CREATE UNIQUE INDEX ", "CREATE INDEX "] where rest.hasPrefix(prefix) {
      rest = rest.dropFirst(prefix.count)
      break
    }
    // The index name: a quoted identifier or a bare word
    if rest.first == "\"" {
      rest = rest.dropFirst()
      while let quote = rest.firstIndex(of: "\"") {
        rest = rest[rest.index(after: quote)...]
        guard rest.first == "\"" else { break }
        rest = rest.dropFirst()
      }
    } else {
      rest = rest.drop { $0 != " " }
    }
    guard rest.hasPrefix(" ON ONLY ") else { return definition }
    return String(definition[..<rest.startIndex]) + " ON " + rest.dropFirst(" ON ONLY ".count)
  }

  /// Puts each partition after the parent it names; other tables keep their order
  private static func parentsFirst(_ tables: [PostgresTable]) -> [PostgresTable] {
    let byName = Dictionary(
      tables.map { (ObjectName(schema: $0.structure.schema, name: $0.structure.name), $0) },
      uniquingKeysWith: { first, _ in first })
    var placed = Set<ObjectName>()
    var ordered: [PostgresTable] = []
    func place(_ table: PostgresTable) {
      let name = ObjectName(schema: table.structure.schema, name: table.structure.name)
      guard placed.insert(name).inserted else { return }
      if let parent = table.partitionOf?.parent, let parentTable = byName[parent] {
        place(parentTable)
      }
      ordered.append(table)
    }
    tables.forEach(place)
    return ordered
  }

  private static func qualified(_ schema: String, _ name: String) throws -> String {
    let dialect = SQLDialect.postgresql
    return try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(name)
  }

  private static func definition(_ constraint: TableStructure.Constraint) throws -> String {
    try StructureDDLBuilder.constraintDefinition(constraint, dialect: .postgresql, renamed: [:])
  }

  // MARK: - MySQL

  private static let mysqlComment = [
    "-- Not included: stored procedures, functions, triggers, events, users and grants."
  ]

  static func mysql(_ input: MySQLInput) throws -> Script {
    var inserts: [TableInsert] = []
    for table in input.tables {
      let structure = table.structure
      inserts.append(
        TableInsert(
          schema: structure.schema, name: structure.name,
          target: try SQLDialect.mysql.quoteIdentifier(structure.name),
          columns: structure.columns.filter { $0.generated == nil }, overridingSystemValue: false,
          hasData: true))
    }
    return Script(
      comment: mysqlComment, preData: input.tables.map { terminated($0.createStatement) },
      tables: inserts,
      postData: orderedViews(input.views).map { terminated(removingDefiner($0.sql)) })
  }

  /// `SHOW CREATE VIEW` text without its `DEFINER=user@host` clause, so a user without the
  /// SET_USER_ID (or SUPER) privilege can restore it. `SQL SECURITY` stays. Only the clauses
  /// before the `VIEW` keyword are searched, skipping quoted text.
  static func removingDefiner(_ statement: String) -> String {
    let chars = Array(statement)
    var index = 0
    while index < chars.count {
      let char = chars[index]
      if char == "`" || char == "'" || char == "\"" {
        index = endOfQuoted(chars, from: index)
        continue
      }
      guard isWordCharacter(char), index == 0 || !isWordCharacter(chars[index - 1]) else {
        index += 1
        continue
      }
      var end = index
      while end < chars.count, isWordCharacter(chars[end]) { end += 1 }
      let word = String(chars[index..<end]).uppercased()
      if word == "VIEW" { return statement }
      if word == "DEFINER", let equals = skippingSpaces(chars, from: end),
        chars[equals] == "="
      {
        var cursor = endOfUser(chars, from: skippingSpaces(chars, from: equals + 1) ?? chars.count)
        if cursor < chars.count, chars[cursor] == "@" {
          cursor = endOfUser(chars, from: cursor + 1)
        }
        cursor = skippingSpaces(chars, from: cursor) ?? chars.count
        return String(chars[..<index]) + String(chars[cursor...])
      }
      index = end
    }
    return statement
  }

  private static func isWordCharacter(_ char: Character) -> Bool {
    char == "_" || char.isLetter || char.isNumber
  }

  /// First non-space index at or after `start`, nil at the end
  private static func skippingSpaces(_ chars: [Character], from start: Int) -> Int? {
    var index = start
    while index < chars.count, chars[index].isWhitespace { index += 1 }
    return index < chars.count ? index : nil
  }

  /// Index after the quoted text that opens at `start` (doubled quotes and `\` escapes inside)
  private static func endOfQuoted(_ chars: [Character], from start: Int) -> Int {
    let quote = chars[start]
    var index = start + 1
    while index < chars.count {
      if chars[index] == "\\" && quote != "`" {
        index += 2
        continue
      }
      if chars[index] == quote {
        if index + 1 < chars.count, chars[index + 1] == quote {
          index += 2
          continue
        }
        return index + 1
      }
      index += 1
    }
    return chars.count
  }

  /// Index after one user or host part: quoted, or bare up to a space or `@`
  private static func endOfUser(_ chars: [Character], from start: Int) -> Int {
    guard start < chars.count else { return chars.count }
    if chars[start] == "`" || chars[start] == "'" || chars[start] == "\"" {
      return endOfQuoted(chars, from: start)
    }
    var index = start
    while index < chars.count, !chars[index].isWhitespace, chars[index] != "@" { index += 1 }
    return index
  }

  // MARK: - SQLite

  /// Tables the dump creates and fills (virtual and shadow tables left out), in
  /// `sqlite_master` order: the ones that need a structure
  static func sqliteDumpedTableNames(
    _ rows: [SQLiteMasterRow], shadowTableNames: Set<String>? = nil
  ) -> [String] {
    sqliteTables(rows, shadowTableNames: shadowTableNames).filter { !isVirtual($0) }.map(\.name)
  }

  static func sqlite(_ input: SQLiteInput) throws -> Script {
    let tables = sqliteTables(input.masterRows, shadowTableNames: input.shadowTableNames)
    var inserts: [TableInsert] = []
    for table in tables {
      if isVirtual(table) {
        inserts.append(
          TableInsert(
            schema: SQLDialect.sqlite.defaultSchema, name: table.name,
            target: try SQLDialect.sqlite.quoteIdentifier(table.name), columns: [],
            overridingSystemValue: false, hasData: false))
        continue
      }
      guard let structure = input.structures.first(where: { $0.name == table.name }) else {
        throw SQLDumpDDLError.missingStructure(table.name)
      }
      inserts.append(
        TableInsert(
          schema: structure.schema, name: structure.name,
          target: try SQLDialect.sqlite.quoteIdentifier(structure.name),
          columns: structure.columns.filter { $0.generated == nil }, overridingSystemValue: false,
          hasData: true))
    }
    let tableNames = Set(tables.map(\.name))
    let virtualNames = try tables.filter(isVirtual).map {
      try SQLDialect.sqlite.quoteIdentifier($0.name)
    }
    let comment =
      virtualNames.isEmpty
      ? []
      : [
        "-- Virtual tables are created empty (their contents are not included): "
          + virtualNames.joined(separator: ", ") + "."
      ]
    var post: [String] = []
    for sequence in input.sequences where tableNames.contains(sequence.name) {
      let name = SQLDialect.sqlite.literal(.string(sequence.name))
      post.append("DELETE FROM sqlite_sequence WHERE name = \(name);")
      post.append("INSERT INTO sqlite_sequence (name, seq) VALUES (\(name), \(sequence.seq));")
    }
    let objects = ["index", "view", "trigger"].flatMap { dumped(input.masterRows, type: $0) }
    let shadows = shadowNames(input.masterRows, shadowTableNames: input.shadowTableNames)
    post += try objects.filter { !shadows.contains($0.tableName) }.map(sqliteDefinition)
    return Script(
      comment: comment,
      preData: ["PRAGMA defer_foreign_keys = ON;"] + (try tables.map(sqliteDefinition)),
      tables: inserts, postData: post)
  }

  /// First words of the statement each `sqlite_master` type may hold
  private static let sqliteStatementHeads: [String: [[String]]] = [
    "table": [["CREATE", "TABLE"], ["CREATE", "VIRTUAL", "TABLE"]],
    "index": [["CREATE", "INDEX"], ["CREATE", "UNIQUE", "INDEX"]],
    "view": [["CREATE", "VIEW"]],
    "trigger": [["CREATE", "TRIGGER"]],
  ]

  /// `row.sql` terminated, once it is exactly one CREATE statement of the row's type. The text
  /// is file data: a file edited with `writable_schema` can store several statements, or open
  /// a comment or string that a later statement of the dump closes.
  /// - Throws: `SQLDumpDDLError.unsafeDefinition` otherwise.
  private static func sqliteDefinition(_ row: SQLiteMasterRow) throws -> String {
    let text = terminated(row.sql ?? "")
    let words = SQLTokenizer(dialect: .sqlite).tokens(text).prefix(3).map {
      $0.kind == .word ? $0.text : ""
    }
    let heads = sqliteStatementHeads[row.type.lowercased()] ?? []
    guard heads.contains(where: { words.starts(with: $0) }), isOneSQLiteStatement(text) else {
      throw SQLDumpDDLError.unsafeDefinition(row.name)
    }
    return text
  }

  /// SQLite's own reading (`sqlite3_complete`, which knows that a trigger body holds `;`
  /// between BEGIN and END): `text` is complete at its final `;` and at no `;` before it
  private static func isOneSQLiteStatement(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.last == UInt8(ascii: ";"), !bytes.contains(0) else { return false }
    func isComplete(through end: Int) -> Bool {
      sqlite3_complete(String(decoding: bytes[...end], as: UTF8.self)) != 0
    }
    for end in bytes.indices.dropLast() where bytes[end] == UInt8(ascii: ";") {
      if isComplete(through: end) { return false }
    }
    return isComplete(through: bytes.count - 1)
  }

  /// Rows of `type` with SQL text, without SQLite's internal objects
  private static func dumped(_ rows: [SQLiteMasterRow], type: String) -> [SQLiteMasterRow] {
    rows.filter {
      $0.type.lowercased() == type && $0.sql != nil && !$0.name.lowercased().hasPrefix("sqlite_")
    }
  }

  /// Dumped tables, virtual ones included, without shadow tables
  private static func sqliteTables(
    _ rows: [SQLiteMasterRow], shadowTableNames: Set<String>?
  ) -> [SQLiteMasterRow] {
    let shadows = shadowNames(rows, shadowTableNames: shadowTableNames)
    return dumped(rows, type: "table").filter { !shadows.contains($0.name) }
  }

  /// `shadowTableNames`, or without it every table named `<virtual table>_...` (the shadow
  /// table naming rule of SQLite's virtual table documentation)
  private static func shadowNames(
    _ rows: [SQLiteMasterRow], shadowTableNames: Set<String>?
  ) -> Set<String> {
    if let shadowTableNames { return shadowTableNames }
    let tables = dumped(rows, type: "table")
    let prefixes = tables.filter(isVirtual).map { $0.name.lowercased() + "_" }
    return Set(
      tables.filter { table in
        !isVirtual(table) && prefixes.contains { table.name.lowercased().hasPrefix($0) }
      }.map(\.name))
  }

  /// `CREATE VIRTUAL TABLE` text
  private static func isVirtual(_ row: SQLiteMasterRow) -> Bool {
    let words = (row.sql ?? "").split(whereSeparator: \.isWhitespace).prefix(2)
    return words.map { $0.uppercased() } == ["CREATE", "VIRTUAL"]
  }

  // MARK: - DuckDB

  private static let duckdbComment = [
    "-- Not included: macros, secrets, comments, temporary objects, attached databases and user"
      + " types other than ENUM."
  ]

  static func duckdb(_ input: DuckDBInput) throws -> Script {
    let dialect = SQLDialect.duckdb
    var pre = try input.schemas.map {
      "CREATE SCHEMA IF NOT EXISTS \(try dialect.quoteIdentifier($0));"
    }
    for type in input.enums {
      let labels = type.labels.map { dialect.literal(.string($0)) }.joined(separator: ", ")
      pre.append(
        "CREATE TYPE \(try duckdbQualified(type.schema, type.name)) AS ENUM (\(labels));")
    }
    for sequence in input.sequences {
      pre.append(
        "CREATE SEQUENCE \(try duckdbQualified(sequence.schema, sequence.name))"
          + " START WITH \(duckdbNextValue(sequence)) INCREMENT BY \(sequence.increment)"
          + " MINVALUE \(sequence.minValue) MAXVALUE \(sequence.maxValue)"
          + (sequence.cycle ? " CYCLE;" : " NO CYCLE;"))
    }
    var inserts: [TableInsert] = []
    for table in input.tables {
      let structure = table.structure
      pre.append(try duckdbDefinition(table.sql, heads: [["CREATE", "TABLE"]], name: structure.name))
      let generated = duckdbGeneratedColumns(table.sql, columns: structure.columns.map(\.name))
      inserts.append(
        TableInsert(
          schema: structure.schema, name: structure.name,
          target: try duckdbQualified(structure.schema, structure.name),
          columns: structure.columns.filter { !generated.contains($0.name) },
          overridingSystemValue: false, hasData: true))
    }
    let indexes = try input.indexes.map {
      try duckdbDefinition(
        $0.sql, heads: [["CREATE", "INDEX"], ["CREATE", "UNIQUE", "INDEX"]], name: $0.name)
    }
    let views = try orderedViews(duckdbViewDependencies(input.views)).map {
      try duckdbDefinition($0.sql, heads: [["CREATE", "VIEW"]], name: $0.name)
    }
    return Script(comment: duckdbComment, preData: pre, tables: inserts, postData: indexes + views)
  }

  /// The value the restored sequence hands out first: the one after `lastValue` (its start
  /// when never used). A used-up sequence starts at its first value again with CYCLE, and stays
  /// at its last value without (START cannot pass the bound, so that value comes once more).
  static func duckdbNextValue(_ sequence: DuckDBSequence) -> Int64 {
    guard let last = sequence.lastValue else { return sequence.start }
    let (next, overflow) = last.addingReportingOverflow(sequence.increment)
    if !overflow, (sequence.minValue...sequence.maxValue).contains(next) { return next }
    guard sequence.cycle else { return last }
    return sequence.increment > 0 ? sequence.minValue : sequence.maxValue
  }

  /// `views` with `dependsOn` set to the other views whose name (ASCII case-insensitive, in any
  /// schema) appears as a word or quoted identifier in their text. A column that shares a
  /// view's name only adds an order constraint; a cycle falls back to name order.
  static func duckdbViewDependencies(_ views: [View]) -> [View] {
    views.map { view in
      let mentioned = Set(
        SQLTokenizer(dialect: .duckdb).tokens(view.sql).compactMap { token -> String? in
          guard token.kind == .word || token.kind == .quotedIdentifier else { return nil }
          return SQLTokenizer.asciiUppercased(token.text)
        })
      var dependent = view
      dependent.dependsOn = views.filter {
        $0 != view && mentioned.contains(SQLTokenizer.asciiUppercased($0.name))
      }.map { ObjectName(schema: $0.schema, name: $0.name) }
      return dependent
    }
  }

  /// The names in `columns` that the table text defines as generated (`<name> <type> GENERATED
  /// ALWAYS AS(...)`, the one form `duckdb_tables().sql` prints): `duckdb_columns()` shows a
  /// generated column as a plain default. Names compare ASCII case-insensitively, as DuckDB
  /// compares identifiers.
  static func duckdbGeneratedColumns(_ sql: String, columns: [String]) -> Set<String> {
    let tokens = SQLTokenizer(dialect: .duckdb).tokens(sql)
    guard let open = tokens.firstIndex(where: { $0.isSymbol("(") }) else { return [] }
    let depth = tokens[open].depth + 1
    var generated = Set<String>()
    var segment: [SQLToken] = []
    for token in tokens[(open + 1)...] {
      let ends = token.depth == depth - 1 || (token.depth == depth && token.isSymbol(","))
      if !ends {
        if token.depth == depth { segment.append(token) }
        continue
      }
      let words = segment.map { $0.keyword ?? "" }
      if let name = segment.first, name.kind == .word || name.kind == .quotedIdentifier,
        words.indices.contains(where: { words[$0...].starts(with: ["GENERATED", "ALWAYS", "AS"]) })
      {
        let key = SQLTokenizer.asciiUppercased(name.text)
        generated.formUnion(columns.filter { SQLTokenizer.asciiUppercased($0) == key })
      }
      segment = []
      if token.depth == depth - 1 { break }
    }
    return generated
  }

  /// `sql` terminated, once it is exactly one CREATE statement starting with one of `heads`:
  /// catalog text of a database file, which can hold anything. The final `;` must be a symbol
  /// (not inside a comment or string a later statement of the dump would close), the only one,
  /// and no NUL may cut it short.
  /// - Throws: `SQLDumpDDLError.unsafeDefinition` otherwise.
  private static func duckdbDefinition(
    _ sql: String, heads: [[String]], name: String
  ) throws -> String {
    let text = terminated(sql)
    let tokenizer = SQLTokenizer(dialect: .duckdb)
    let words = tokenizer.tokens(text).prefix(3).map { $0.kind == .word ? $0.text : "" }
    guard !text.unicodeScalars.contains("\0"), heads.contains(where: { words.starts(with: $0) }),
      endsAtItsOnlySemicolon(text, tokenizer)
    else { throw SQLDumpDDLError.unsafeDefinition(name) }
    return text
  }

  /// The last lexeme of `text` other than whitespace is a `;` symbol, and no other `;` is one
  private static func endsAtItsOnlySemicolon(_ text: String, _ tokenizer: SQLTokenizer) -> Bool {
    let scalars = Array(text.unicodeScalars)
    var semicolons = 0
    var endsWithSemicolon = false
    var i = 0
    while i < scalars.count {
      let lexeme = tokenizer.lexeme(in: scalars, at: i)
      switch lexeme.kind {
      case .whitespace: break
      case .symbol where scalars[i] == ";":
        semicolons += 1
        endsWithSemicolon = true
      default: endsWithSemicolon = false
      }
      i = lexeme.range.upperBound
    }
    return semicolons == 1 && endsWithSemicolon
  }

  private static func duckdbQualified(_ schema: String, _ name: String) throws -> String {
    let dialect = SQLDialect.duckdb
    return try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(name)
  }

  // MARK: - Shared

  /// Views whose view dependencies come first; among the ready ones, schema then name order.
  /// A dependency cycle (never valid in a database) falls back to name order.
  private static func orderedViews(_ views: [View]) -> [View] {
    var remaining = views.sorted { ($0.schema, $0.name) < ($1.schema, $1.name) }
    let names = Set(views.map { ObjectName(schema: $0.schema, name: $0.name) })
    var created = Set<ObjectName>()
    var ordered: [View] = []
    while !remaining.isEmpty {
      let ready =
        remaining.firstIndex { view in
          let own = ObjectName(schema: view.schema, name: view.name)
          return view.dependsOn.allSatisfy {
            !names.contains($0) || created.contains($0) || $0 == own
          }
        } ?? 0
      let view = remaining.remove(at: ready)
      created.insert(ObjectName(schema: view.schema, name: view.name))
      ordered.append(view)
    }
    return ordered
  }

  /// Trimmed, ending with `;`
  private static func terminated(_ sql: String) -> String {
    let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.hasSuffix(";") ? text : text + ";"
  }
}

nonisolated extension TableStructure.Constraint {
  fileprivate var isForeignKey: Bool {
    if case .foreignKey = kind { return true }
    return false
  }
}
