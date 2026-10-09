// DuckDBSchemaIntrospector.swift
// DuckDB catalog reads for one open session, from the duckdb_* table functions only.
// `duckdb_extensions()` and PRAGMAs are never used: the hardened session refuses the first
// (it lists the extension directory) and does not need the others.
//
// Scope: objects of `current_database()` only. That drops the `system` catalog
// (information_schema, pg_catalog), the session's `temp` catalog (its `main` would collide with
// the database's `main` in the `"schema.relation"` key), and attached databases. The session
// refuses `ATTACH <file>`, so only an in-memory `ATTACH ':memory:'` is hidden.
// Objects are filtered on `NOT internal`; schemas are not (DuckDB marks `main` internal).
//
// DuckDB has no routines the app lists, no triggers, users or roles: those stay empty.

import Foundation

/// `duckdb_tables()`, `duckdb_views()`, `duckdb_columns()`, `duckdb_constraints()` and
/// `duckdb_schemas()` reads through `DatabaseSession.query`.
nonisolated struct DuckDBSchemaIntrospector: SchemaIntrospector {
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    let sql = """
      SELECT schema_name, table_name, estimated_size
      FROM duckdb_tables()
      WHERE database_name = current_database() AND NOT internal
      ORDER BY schema_name, table_name
      """
    var tables: [DatabaseTable] = []
    for row in try await rows(in: session, sql: sql) {
      guard let schema = DuckDBCatalogValue.string(row, 0),
        let name = DuckDBCatalogValue.string(row, 1)
      else { continue }
      tables.append(
        DatabaseTable(schema: schema, name: name, rowCount: DuckDBCatalogValue.int(row, 2)))
    }
    return tables
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    let sql = """
      SELECT schema_name, view_name, sql
      FROM duckdb_views()
      WHERE database_name = current_database() AND NOT internal
      ORDER BY schema_name, view_name
      """
    var views: [DatabaseView] = []
    for row in try await rows(in: session, sql: sql) {
      guard let schema = DuckDBCatalogValue.string(row, 0),
        let name = DuckDBCatalogValue.string(row, 1)
      else { continue }
      views.append(
        DatabaseView(schema: schema, name: name, definition: DuckDBCatalogValue.string(row, 2)))
    }
    return views
  }

  func functions(in _: any DatabaseSession) async throws -> [DatabaseFunction] { [] }

  func procedures(in _: any DatabaseSession) async throws -> [DatabaseProcedure] { [] }

  func users(in _: any DatabaseSession) async throws -> [DatabaseUser] { [] }

  func roles(in _: any DatabaseSession) async throws -> [DatabaseRole] { [] }

  /// DuckDB refuses cross-schema keys and ON UPDATE / ON DELETE actions, so the target schema
  /// is the source schema and both actions are NO ACTION.
  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    DuckDBCatalog.foreignKeys(try await keyParts(in: session))
  }

  /// Table and view columns in one read. Keys come from `duckdb_constraints()`. Generated
  /// columns are not flagged: `duckdb_columns()` shows their expression as the default.
  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    let sql = """
      SELECT schema_name, table_name, column_name, data_type, is_nullable
      FROM duckdb_columns()
      WHERE database_name = current_database() AND NOT internal
      ORDER BY schema_name, table_name, column_index
      """
    var columns: [DuckDBCatalog.ColumnRow] = []
    for row in try await rows(in: session, sql: sql) {
      guard let schema = DuckDBCatalogValue.string(row, 0),
        let relation = DuckDBCatalogValue.string(row, 1),
        let name = DuckDBCatalogValue.string(row, 2),
        let type = DuckDBCatalogValue.string(row, 3)
      else { continue }
      columns.append(
        DuckDBCatalog.ColumnRow(
          schema: schema, relation: relation, name: name, type: type,
          isNullable: DuckDBCatalogValue.bool(row, 4) ?? true))
    }
    return DuckDBCatalog.columnsByRelation(columns, keys: try await keyParts(in: session))
  }

  /// Never editable: DuckDB results carry no column origins, and grid edits are off for the
  /// engine (`supportsRowStaging` is false).
  func editTable(named _: String, in _: any DatabaseSession) async throws -> EditTable? {
    nil
  }

  /// Result types already come from the result. No separate precision catalog is read.
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query _: String, in _: any DatabaseSession
  ) async -> [ColumnInfo] {
    columns
  }

  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int
  {
    let database = try await rows(in: session, sql: "SELECT current_database()")
    guard let name = database.first.flatMap({ DuckDBCatalogValue.string($0, 0) }) else {
      return 0
    }
    let relation = try [name, schema, table].map(SQLDialect.duckdb.quoteIdentifier)
      .joined(separator: ".")
    let counted = try await rows(in: session, sql: "SELECT count(*) FROM \(relation)")
    return counted.first.flatMap { DuckDBCatalogValue.int($0, 0) } ?? 0
  }

  /// `tableName` is `table` (current schema) or `schema.table`. DuckDB names match without case.
  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws -> [String] {
    let listed = try await rows(
      in: session,
      sql: """
        SELECT schema_name, schema_name = current_schema()
        FROM duckdb_schemas()
        WHERE database_name = current_database()
        """)
    let schemas = listed.compactMap { DuckDBCatalogValue.string($0, 0) }
    let current =
      listed.first { DuckDBCatalogValue.bool($0, 1) == true }
      .flatMap { DuckDBCatalogValue.string($0, 0) } ?? SQLDialect.duckdb.defaultSchema
    guard
      let relation = DuckDBCatalog.split(tableName, schemas: schemas, currentSchema: current)
    else { return [] }
    let parts = try await keyParts(
      in: session,
      filter: "AND lower(schema_name) = lower($1) AND lower(table_name) = lower($2)",
      binds: [.text(relation.schema), .text(relation.table)])
    return DuckDBCatalog.primaryKey(parts)
  }

  // MARK: - Reads

  /// One row per key column of every PRIMARY KEY, UNIQUE and FOREIGN KEY constraint, in key
  /// order. The lists are unnested here, not read as nested text. `filter` is a constant SQL
  /// fragment from this file; names always travel in `binds`.
  private func keyParts(
    in session: any DatabaseSession, filter: String = "", binds: [SQLBindValue] = []
  ) async throws -> [DuckDBCatalog.KeyPart] {
    let sql = """
      SELECT schema_name, table_name, constraint_index, constraint_type, constraint_name,
        referenced_table,
        unnest(constraint_column_names) AS key_column,
        generate_subscripts(constraint_column_names, 1) AS key_position,
        referenced_column_names[key_position] AS referenced_column
      FROM duckdb_constraints()
      WHERE database_name = current_database()
        AND constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
        \(filter)
      ORDER BY schema_name, table_name, constraint_index, key_position
      """
    var parts: [DuckDBCatalog.KeyPart] = []
    for row in try await rows(in: session, sql: sql, binds: binds) {
      guard let schema = DuckDBCatalogValue.string(row, 0),
        let table = DuckDBCatalogValue.string(row, 1),
        let index = DuckDBCatalogValue.int(row, 2),
        let type = DuckDBCatalogValue.string(row, 3).flatMap(DuckDBCatalog.KeyKind.init),
        let column = DuckDBCatalogValue.string(row, 6)
      else { continue }
      parts.append(
        DuckDBCatalog.KeyPart(
          schema: schema, table: table, constraintIndex: index, kind: type,
          constraintName: DuckDBCatalogValue.string(row, 4) ?? String(index),
          column: column,
          referencedTable: DuckDBCatalogValue.string(row, 5),
          referencedColumn: DuckDBCatalogValue.string(row, 8)))
    }
    return parts
  }

  private func rows(
    in session: any DatabaseSession, sql: String, binds: [SQLBindValue] = []
  ) async throws -> [[CellValue]] {
    let source = try await session.query(sql, binds: binds)
    var collected: [[CellValue]] = []
    for try await row in source.rows {
      collected.append(row)
    }
    return collected
  }
}

/// Pure mapping of DuckDB catalog rows into the schema tree models.
nonisolated enum DuckDBCatalog {
  /// One `duckdb_columns()` row.
  struct ColumnRow: Sendable, Equatable {
    let schema: String
    let relation: String
    let name: String
    let type: String
    let isNullable: Bool
  }

  enum KeyKind: String, Sendable, Equatable {
    case primaryKey = "PRIMARY KEY"
    case unique = "UNIQUE"
    case foreignKey = "FOREIGN KEY"
  }

  /// One column of one key constraint (`unnest(constraint_column_names)`).
  struct KeyPart: Sendable, Equatable {
    let schema: String
    let table: String
    /// DuckDB's constraint number. Grouped with `schema` and `table` (see `group`), so the
    /// mapping does not rely on it being unique across the database.
    let constraintIndex: Int
    let kind: KeyKind
    let constraintName: String
    let column: String
    let referencedTable: String?
    let referencedColumn: String?

    /// Identifies the constraint this column belongs to.
    var group: KeyGroup { KeyGroup(schema: schema, table: table, constraintIndex: constraintIndex) }
  }

  struct KeyGroup: Hashable, Sendable {
    let schema: String
    let table: String
    let constraintIndex: Int
  }

  /// Columns keyed by `"schema.relation"`, in input order. A column is unique only through a
  /// single-column UNIQUE constraint and never when it is part of the primary key.
  static func columnsByRelation(
    _ rows: [ColumnRow], keys: [KeyPart]
  ) -> [String: [DatabaseColumn]] {
    var primary: Set<ColumnID> = []
    var unique: Set<ColumnID> = []
    let uniqueGroups = Dictionary(
      grouping: keys.filter { $0.kind == .unique }, by: \.group)
    for part in keys where part.kind == .primaryKey {
      primary.insert(columnKey(part.schema, part.table, part.column))
    }
    for parts in uniqueGroups.values where parts.count == 1 {
      unique.insert(columnKey(parts[0].schema, parts[0].table, parts[0].column))
    }
    var result: [String: [DatabaseColumn]] = [:]
    for row in rows {
      let key = columnKey(row.schema, row.relation, row.name)
      let isPrimaryKey = primary.contains(key)
      result["\(row.schema).\(row.relation)", default: []].append(
        DatabaseColumn(
          name: row.name,
          type: row.type,
          isNullable: row.isNullable,
          isPrimaryKey: isPrimaryKey,
          isUnique: unique.contains(key) && !isPrimaryKey))
    }
    return result
  }

  /// Foreign keys in input order, one per constraint. A key whose column lists do not line up
  /// is skipped.
  static func foreignKeys(_ keys: [KeyPart]) -> [ForeignKey] {
    var order: [KeyGroup] = []
    var groups: [KeyGroup: [KeyPart]] = [:]
    for part in keys where part.kind == .foreignKey {
      if groups[part.group] == nil { order.append(part.group) }
      groups[part.group, default: []].append(part)
    }
    return order.compactMap { group in
      guard let parts = groups[group], let first = parts.first,
        let targetTable = first.referencedTable
      else { return nil }
      let targetColumns = parts.compactMap(\.referencedColumn)
      guard targetColumns.count == parts.count else { return nil }
      return ForeignKey(
        constraintName: first.constraintName,
        sourceSchema: first.schema,
        sourceTable: first.table,
        sourceColumns: parts.map(\.column),
        targetSchema: first.schema,
        targetTable: targetTable,
        targetColumns: targetColumns)
    }
  }

  /// Primary key columns in key order (the first primary key in `keys`).
  static func primaryKey(_ keys: [KeyPart]) -> [String] {
    guard let first = keys.first(where: { $0.kind == .primaryKey }) else { return [] }
    return keys.filter { $0.group == first.group }.map(\.column)
  }

  /// `table` is in `currentSchema`. `schema.table` needs a schema from `schemas` (any case);
  /// otherwise the whole text is the table name.
  static func split(
    _ name: String, schemas: [String], currentSchema: String
  ) -> (schema: String, table: String)? {
    guard !name.isEmpty else { return nil }
    if let dot = name.firstIndex(of: ".") {
      let schemaPart = String(name[..<dot])
      let table = String(name[name.index(after: dot)...])
      if !table.isEmpty,
        let schema = schemas.first(where: { $0.caseInsensitiveCompare(schemaPart) == .orderedSame })
      {
        return (schema, table)
      }
    }
    return (currentSchema, name)
  }

  private struct ColumnID: Hashable {
    let schema: String
    let table: String
    let column: String
  }

  private static func columnKey(_ schema: String, _ table: String, _ column: String) -> ColumnID {
    ColumnID(schema: schema, table: table, column: column)
  }
}

private nonisolated enum DuckDBCatalogValue {
  static func string(_ row: [CellValue], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .string(let text), .json(let text):
      return text
    default:
      return nil
    }
  }

  static func int(_ row: [CellValue], _ index: Int) -> Int? {
    guard index < row.count else { return nil }
    if case .int(let number) = row[index] { return number }
    return nil
  }

  static func bool(_ row: [CellValue], _ index: Int) -> Bool? {
    guard index < row.count else { return nil }
    if case .bool(let flag) = row[index] { return flag }
    return nil
  }
}
