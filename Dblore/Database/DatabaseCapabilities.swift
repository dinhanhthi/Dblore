// DatabaseCapabilities.swift
// Feature flags for one database engine. The connection form and safety badge read these.

import Foundation

/// What a database engine supports. PostgreSQL matches today's behaviour.
/// SQLite is a beta file database (`isAvailable == true`). DuckDB is a file database that
/// needs its plugin (`requiresPlugin`).
nonisolated struct DatabaseCapabilities: Sendable, Equatable {
  /// How a running statement is stopped.
  nonisolated enum CancelStrategy: Sendable, Equatable {
    /// Close the session and open another one.
    case reconnect
    /// Stop the statement inside the current process.
    case interrupt
  }

  let usesNetwork: Bool
  let usesPassword: Bool
  let supportsSSL: Bool
  let supportsSchemas: Bool
  let supportsRolesAndUsers: Bool
  let supportsFunctions: Bool
  let supportsServerCursor: Bool
  let supportsSessionBrakes: Bool
  let cancelStrategy: CancelStrategy
  let cappedReadResetsSession: Bool
  let supportsExplainJSON: Bool
  /// Explain Analyze is offered. The plan may be text (DuckDB) rather than JSON.
  let supportsExplainAnalyze: Bool
  let supportsUpdateOnly: Bool
  /// Grid edits can be staged and committed as a batch.
  let supportsRowStaging: Bool
  /// CSV / JSON import into a table.
  let supportsDataImport: Bool
  /// Foreign key values open the referenced row.
  let supportsForeignKeyLookup: Bool
  /// The engine runs only when its plugin is installed. The connection picker asks the
  /// plugin provider; saved connections of the engine stay listed either way.
  let requiresPlugin: Bool
  /// False means the engine is not a working database in the app.
  let isAvailable: Bool

  /// A local file (or in-memory) database: the connection form shows the file picker
  /// instead of host, port, user, password, SSL and SSH.
  var isFileBased: Bool { !usesNetwork }
}
