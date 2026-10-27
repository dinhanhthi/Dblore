// SchemaSnapshotLoader.swift
// Reads one schema of a connection into a `SchemaSnapshot`: the table list, then each table's
// structure, `concurrency` reads at a time, through the read-only catalog path
// (`fetchTables` / `fetchTableStructure`, which refuse while the app transaction is pending).
// PostgreSQL reads the structures one by one in one read-only transaction with `search_path`
// empty, on a private connection that is closed afterwards, never on the tab's session
// (`fetchQualifiedTableStructures`): `format_type` and `pg_get_expr` then name the schema
// of every user type and sequence (`public.mood`, `nextval('public.orders_id_seq'::regclass)`)
// on both sides, whichever schema the session's own path holds, so `SchemaDiff` can read each
// side's schema prefix as the other's and the script names the target's objects.
// It also refuses up front while any transaction is open (the app's or the user's own), as the
// structure editor does. Unlike the data dictionary export, a table whose read fails fails the
// whole load: a partial snapshot would make the diff propose creating or dropping tables that
// merely failed to read. Cancelling the task stops after the reads in flight. More than
// `maxTables` tables are refused before any structure is read. DuckDB and MongoDB are refused.
// A schema with no table in the connection's list is refused (`schemaNotFound`) rather than
// loaded empty: MySQL lists only the connected database and PostgreSQL only the schemas it may
// read, so an empty list usually means the schema is out of reach, and an empty source would turn
// every target table into a drop. An intentionally empty schema is therefore not comparable.

import Foundation

/// The connection calls the loader makes. `DatabaseConnectionManager` in the app.
nonisolated protocol SchemaSnapshotDatabase: Sendable {
  var databaseType: DatabaseType? { get async }
  func structureEditorState() async -> StructureEditorConnectionState
  func fetchTables() async throws -> [DatabaseTable]
  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure
  /// PostgreSQL: the structures of `tables`, in order, with every name schema-qualified
  /// (`DatabaseConnectionManager.fetchQualifiedTableStructures`)
  func fetchQualifiedTableStructures(
    schema: String, tables: [String], progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [TableStructure]
}

extension DatabaseConnectionManager: SchemaSnapshotDatabase {}

nonisolated enum SchemaSnapshotLoader {
  static let maxTables = 1_000
  /// Structure reads in flight at once
  static let concurrency = 4

  /// `progress` gets (structures read, tables) after each read
  static func load(
    schema: String, from database: any SchemaSnapshotDatabase,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> SchemaSnapshot {
    let state = await database.structureEditorState()
    guard !state.transactionOpen else { throw SchemaCompareError.transactionOpen }
    let engine = try engine(await database.databaseType, server: state.mysqlServerInfo)
    // A session's temporary tables are no part of the schema
    let names = try await database.fetchTables()
      .filter { $0.schema == schema && !$0.isTemporary }.map(\.name)
    guard !names.isEmpty else { throw SchemaCompareError.schemaNotFound(schema) }
    guard names.count <= maxTables else { throw SchemaCompareError.tooManyTables(names.count) }
    let tables: [TableStructure]
    if case .postgresql = engine {
      do {
        tables = try await database.fetchQualifiedTableStructures(
          schema: schema, tables: names.sorted(), progress: progress)
      } catch {
        try Task.checkCancellation()
        throw error
      }
    } else {
      tables = try await structures(
        of: names.sorted(), schema: schema, from: database, progress: progress)
    }
    var snapshot = SchemaSnapshot(
      engine: engine, schema: schema, tables: tables, connectionEpoch: state.connectionEpoch)
    if case .sqlite = engine { snapshot.tableNamesIgnoreCase = true }
    return snapshot
  }

  private static func engine(
    _ type: DatabaseType?, server: MySQLServerInfo?
  ) throws -> StructureDDLBuilder.Engine {
    switch type {
    case .postgresql: return .postgresql
    case .mysql:
      guard let server else { throw DatabaseError.notConnected }
      return .mysql(server)
    case .sqlite: return .sqlite(libraryVersion: SQLiteLibraryVersion.current)
    case .duckdb: throw SchemaCompareError.unsupportedEngine("DuckDB")
    case .mongodb: throw SchemaCompareError.unsupportedEngine("MongoDB")
    case nil: throw DatabaseError.notConnected
    }
  }

  /// The structures in `names` order, at most `concurrency` reads at once. The first failure
  /// (or cancellation) aborts.
  private static func structures(
    of names: [String], schema: String, from database: any SchemaSnapshotDatabase,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [TableStructure] {
    try await withThrowingTaskGroup(of: (Int, TableStructure).self) { group in
      var results = [TableStructure?](repeating: nil, count: names.count)
      var next = 0
      var done = 0
      func addNext() {
        let index = next
        let name = names[index]
        next += 1
        group.addTask {
          do {
            return (index, try await database.fetchTableStructure(schema: schema, table: name))
          } catch {
            // A cancelled read may fail as a wrapped query error: report the cancellation
            try Task.checkCancellation()
            throw error
          }
        }
      }
      while next < min(concurrency, names.count) { addNext() }
      while let (index, structure) = try await group.next() {
        try Task.checkCancellation()
        results[index] = structure
        done += 1
        progress?(done, names.count)
        if next < names.count { addNext() }
      }
      return results.compactMap { $0 }
    }
  }
}
