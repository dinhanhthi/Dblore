//
//  DatabaseConnectionManager+Schema.swift
//  Dblore
//
//  Schema introspection methods for DatabaseConnectionManager
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Schema Introspection

  /// Fetch all tables from the database (row count is the planner estimate, or the live-tuple
  /// stats counter if never analyzed; nil when unknown). MySQL lists no temporary table: the
  /// ones this session created follow (`mysqlTempTables`, `isTemporary`).
  func fetchTables() async throws -> [DatabaseTable] {
    let tables = try await fetchCatalog("tables") { session in
      try await self.introspector.tables(in: session)
    }
    return tables + mysqlTempTables.tables
  }

  /// Fetch the columns of every table and view in one query, keyed by "schema.relation".
  /// A schema reload: MySQL column origins are read again.
  func fetchAllColumns() async throws -> [String: [DatabaseColumn]] {
    mysqlTableColumns.removeAll()
    return try await fetchCatalog("columns") { session in
      try await self.introspector.allColumns(in: session)
    }
  }

  /// Fetch row count for a specific table
  func fetchRowCount(tableSchema: String, tableName: String) async throws -> Int {
    _ = try catalogConnection()
    do {
      return try await withCatalogReadSession { session in
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
      return try await withCatalogReadSession { session in
        try await self.introspector.primaryKeyColumns(of: tableName, in: session)
      }
    } catch {
      // If query fails (invalid name, permissions, etc.), return empty array
      return []
    }
  }

  /// Fetch the columns, indexes, and constraints of one table for the structure editor
  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
    try await PerfSignpost.interval("schema.tableStructure") {
      try await fetchCatalog("table structure") { session in
        try await self.introspector.tableStructure(schema: schema, table: table, in: session)
      }
    }
  }

  /// Schema Compare on PostgreSQL: the structures of `tables` in `schema`, in order, read in one
  /// read-only transaction with `search_path` empty, so every user type and sequence the catalog
  /// prints names its schema (`public.mood`, `nextval('public.orders_id_seq'::regclass)`),
  /// whatever the session's own path. The reads run one by one on a private connection opened
  /// like this one (`makeSnapshotSideManager`), never on this session, and closed on every path.
  /// Refused while a transaction is open here (the other connection cannot see its uncommitted
  /// work; nothing is opened). Cancelling stops after the read in flight. A cancellation and a
  /// lost connection are thrown as they are; another failed read as `queryFailed`.
  func fetchQualifiedTableStructures(
    schema: String, tables: [String], progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [TableStructure] {
    guard let databaseType else { throw DatabaseError.notConnected }
    guard databaseType == .postgresql else {
      throw SchemaCompareError.unsupportedEngine(databaseType.rawValue)
    }
    guard isOutsideAnyTransaction else { throw SchemaCompareError.transactionOpen }
    _ = try catalogConnection()
    let side = makeSnapshotSideManager()
    do {
      try await connectSideManager(side)
      try Task.checkCancellation()
      let structures = try await side.readQualifiedTableStructures(
        schema: schema, tables: tables, progress: progress)
      await side.disconnect()
      return structures
    } catch {
      await side.disconnect()
      throw error
    }
  }

  /// `fetchQualifiedTableStructures` on this single-use manager's session. ROLLBACK is always
  /// sent; a failed one is left to the caller's disconnect.
  private func readQualifiedTableStructures(
    schema: String, tables: [String], progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [TableStructure] {
    try await withSession { session in
      let result: Result<[TableStructure], Error>
      do {
        _ = try await session.command(
          "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", binds: [])
        _ = try await session.command("SET LOCAL search_path = ''", binds: [])
        let reader = DumpSnapshotReader(session: session, dialect: .postgresql)
        var structures: [TableStructure] = []
        for table in tables {
          try Task.checkCancellation()
          structures.append(
            try await PostgresSchemaIntrospector().tableStructure(
              schema: schema, table: table, in: reader))
          progress?(structures.count, tables.count)
        }
        result = .success(structures)
      } catch let error as CancellationError {
        result = .failure(error)
      } catch let error as DatabaseError {
        if case .connectionLost = error {
          result = .failure(error)
        } else {
          result = .failure(Self.tableStructureReadError(error))
        }
      } catch {
        result = .failure(Self.tableStructureReadError(error))
      }
      _ = try? await session.command("ROLLBACK", binds: [])
      return try result.get()
    }
  }

  private nonisolated static func tableStructureReadError(_ error: Error) -> DatabaseError {
    .queryFailed("Failed to fetch table structure: \(error.localizedDescription)", 0)
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

  // MARK: - Sequences and User Types

  /// Fetch all sequences (empty where the engine has none in the sidebar)
  func fetchSequences() async throws -> [DatabaseSequence] {
    try await fetchCatalog("sequences") { session in
      try await self.introspector.sequences(in: session)
    }
  }

  /// Fetch all enums, domains and standalone composite types
  func fetchUserTypes() async throws -> [DatabaseUserType] {
    try await fetchCatalog("types") { session in
      try await self.introspector.userTypes(in: session)
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
