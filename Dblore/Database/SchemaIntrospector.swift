// SchemaIntrospector.swift
// Catalog reads for one open session. Engine SQL stays in the concrete introspector.

import Foundation

/// Schema catalog for one `DatabaseSession`.
///
/// Each read takes the session it queries. An engine that lacks a catalog inherits the
/// empty default, chosen from `session.capabilities`:
/// `functions` and `procedures` when `supportsFunctions` is false, `users` and `roles`
/// when `supportsRolesAndUsers` is false. Tables, views, foreign keys, and columns stay
/// required when `supportsSchemas` is false; that engine uses its default schema name.
nonisolated protocol SchemaIntrospector: Sendable {
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable]

  func views(in session: any DatabaseSession) async throws -> [DatabaseView]

  func functions(in session: any DatabaseSession) async throws -> [DatabaseFunction]

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure]

  func users(in session: any DatabaseSession) async throws -> [DatabaseUser]

  func roles(in session: any DatabaseSession) async throws -> [DatabaseRole]

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey]

  /// Columns of every table and view, keyed by `"schema.relation"`.
  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]]

  /// Edit target for `name` (`table` or `schema.table`). Nil when the relation is not editable.
  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable?

  /// Precision, scale, and length for a single-table result. Returns `columns` unchanged
  /// when the query is not one table or the catalog cannot be read.
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async -> [ColumnInfo]

  /// Exact row count of one table. The actor turns a failure into 0.
  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int

  /// Primary key column names in key order. Empty when the table has no declared key.
  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws
    -> [String]
}

// Empty catalogs for engines that do not have them. A concrete introspector overrides a
// method when the matching capability is true.
nonisolated extension SchemaIntrospector {
  func functions(in session: any DatabaseSession) async throws -> [DatabaseFunction] {
    guard session.capabilities.supportsFunctions else { return [] }
    return []
  }

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure] {
    guard session.capabilities.supportsFunctions else { return [] }
    return []
  }

  func users(in session: any DatabaseSession) async throws -> [DatabaseUser] {
    guard session.capabilities.supportsRolesAndUsers else { return [] }
    return []
  }

  func roles(in session: any DatabaseSession) async throws -> [DatabaseRole] {
    guard session.capabilities.supportsRolesAndUsers else { return [] }
    return []
  }
}
