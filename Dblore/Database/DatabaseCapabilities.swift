// DatabaseCapabilities.swift
// Feature flags for one database engine. The connection form and safety badge read these.

import Foundation

/// What a database engine supports. PostgreSQL matches today's behaviour.
/// SQLite is a beta file database (`isAvailable == true`).
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
  let supportsUpdateOnly: Bool
  /// False means the engine is not a working database in the app.
  let isAvailable: Bool
}
