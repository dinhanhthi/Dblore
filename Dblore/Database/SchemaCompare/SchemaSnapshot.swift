// SchemaSnapshot.swift
// The tables of ONE schema (PostgreSQL schema, MySQL database, SQLite attached name) of one
// connection, as `SchemaSnapshotLoader` read them through the read-only catalog path. Schema
// Compare diffs two of them (`SchemaDiff`) and scripts the result for the target
// (`SchemaMigrationScriptBuilder`). Views, routines and types are not part of a snapshot.

import Foundation

nonisolated struct SchemaSnapshot: Sendable, Equatable {
  /// PostgreSQL, MySQL (with the server's flavor and version) or SQLite. Never DuckDB.
  var engine: StructureDDLBuilder.Engine
  var schema: String
  /// Sorted by name
  var tables: [TableStructure]
  /// The connection's epoch when the load started: a script is sent only while it is unchanged
  var connectionEpoch: UInt64 = 0
  /// MySQL `lower_case_table_names` 1 or 2: table names match ignoring case. False (names are
  /// case-sensitive) unless the caller knows otherwise; SQLite names always ignore ASCII case.
  var tableNamesIgnoreCase = false

  /// MySQL or MariaDB; nil on the other engines
  var mysqlFlavor: MySQLServerInfo.Flavor? {
    if case .mysql(let server) = engine { server.flavor } else { nil }
  }

  /// True when both are PostgreSQL, both MySQL (any flavor or version) or both SQLite
  func hasSameEngine(as other: SchemaSnapshot) -> Bool {
    switch (engine, other.engine) {
    case (.postgresql, .postgresql), (.mysql, .mysql), (.sqlite, .sqlite): true
    default: false
    }
  }
}

nonisolated enum SchemaCompareError: Error, Equatable, LocalizedError {
  /// DuckDB and MongoDB have no Schema Compare
  case unsupportedEngine(String)
  /// The schema has more than `SchemaSnapshotLoader.maxTables` tables
  case tooManyTables(Int)
  /// Source and target are different engines
  case engineMismatch
  /// A transaction is open on the connection: its catalog is not read meanwhile
  case transactionOpen
  /// The connection lists no table in the schema: it does not exist, is empty or is not visible
  /// to this connection (MySQL lists only the connected database's tables, PostgreSQL only the
  /// schemas it may read). Never compared as an empty snapshot.
  case schemaNotFound(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedEngine(let name): "Schema Compare does not support \(name)."
    case .tooManyTables(let count):
      "This schema has \(count.formatted()) tables. Schema Compare covers at most "
        + "\(SchemaSnapshotLoader.maxTables.formatted()) tables."
    case .engineMismatch: "Schema Compare compares two databases of the same engine."
    case .transactionOpen:
      "A transaction is open on this connection. Commit or roll it back, then compare again."
    case .schemaNotFound(let schema): "No tables found in \(schema) on this connection."
    }
  }
}
