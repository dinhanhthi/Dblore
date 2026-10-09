//
//  DatabaseConnectionManager+Schema.swift
//  Dblore
//
//  Schema introspection methods for DatabaseConnectionManager
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Schema Introspection

  /// Fetch all tables from the database (row count is the planner estimate, nil if never analyzed)
  func fetchTables() async throws -> [DatabaseTable] {
    try await fetchCatalog("tables") { session in
      try await self.introspector.tables(in: session)
    }
  }

  /// Fetch the columns of every table and view in one query, keyed by "schema.relation"
  func fetchAllColumns() async throws -> [String: [DatabaseColumn]] {
    try await fetchCatalog("columns") { session in
      try await self.introspector.allColumns(in: session)
    }
  }

  /// Fetch row count for a specific table
  func fetchRowCount(tableSchema: String, tableName: String) async throws -> Int {
    _ = try catalogConnection()
    do {
      return try await withSession { session in
        try await self.introspector.rowCount(schema: tableSchema, table: tableName, in: session)
      }
    } catch {
      // If fetching row count fails, return 0 instead of throwing
      await AppLogger.shared.warning(
        "Failed to fetch row count for \(tableSchema).\(tableName): \(error)", category: "Schema")
      return 0
    }
  }

  /// Fetch primary key column names for a table, in key order (empty if no PK).
  /// `tableName` (`table` or `schema.table`, SQL identifier syntax) is resolved with
  /// `to_regclass` like an unqualified name in a query (search_path) and bound as a parameter.
  func fetchPrimaryKeyColumns(tableName: String) async throws -> [String] {
    _ = try catalogConnection()
    do {
      return try await withSession { session in
        try await self.introspector.primaryKeyColumns(of: tableName, in: session)
      }
    } catch {
      // If query fails (invalid name, permissions, etc.), return empty array
      return []
    }
  }

  // MARK: - Views

  /// Fetch all views from the database
  func fetchViews() async throws -> [DatabaseView] {
    try await fetchCatalog("views") { session in
      try await self.introspector.views(in: session)
    }
  }

  // MARK: - Functions

  /// Fetch all functions from the database
  func fetchFunctions() async throws -> [DatabaseFunction] {
    try await fetchCatalog("functions") { session in
      try await self.introspector.functions(in: session)
    }
  }

  // MARK: - Triggers

  /// Fetch all triggers (names only; the source is read with `fetchDefinition(of:)`)
  func fetchTriggers() async throws -> [DatabaseTrigger] {
    try await fetchCatalog("triggers") { session in
      try await self.introspector.triggers(in: session)
    }
  }

  /// Fetch the source of one function, procedure, or trigger (nil when the engine has none)
  func fetchDefinition(of object: SchemaObjectRef) async throws -> String? {
    try await fetchCatalog("definition") { session in
      try await self.introspector.definition(of: object, in: session)
    }
  }

  // MARK: - Procedures

  /// Fetch all procedures from the database
  func fetchProcedures() async throws -> [DatabaseProcedure] {
    try await fetchCatalog("procedures") { session in
      try await self.introspector.procedures(in: session)
    }
  }

  // MARK: - Users

  /// Fetch all users from the database
  func fetchUsers() async throws -> [DatabaseUser] {
    try await fetchCatalog("users") { session in
      try await self.introspector.users(in: session)
    }
  }

  // MARK: - Roles

  /// Fetch all roles from the database
  func fetchRoles() async throws -> [DatabaseRole] {
    try await fetchCatalog("roles") { session in
      try await self.introspector.roles(in: session)
    }
  }
}
