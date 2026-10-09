// DatabaseSession.swift
// One database session. The connection actor talks to an engine through this
// protocol. Driver modules stay in the session implementation.

import Foundation

// Namespace only (no cases), so it cannot be passed to `applySessionSettings`. The actor
// passes the clamped statement, lock, and idle timeouts as integers.
extension SessionBrakeLimits: @unchecked Sendable {}

/// Rows changed by `DatabaseSession.command`, plus the server command tag
/// (`UPDATE 3`, `INSERT 0 1`, `MERGE 2`).
nonisolated struct CommandResult: Sendable, Equatable {
  /// Count carried by `tag` when the tag has one; `0` when it does not.
  var affectedRows: Int
  /// Server command tag, unchanged. The actor parses tags that `affectedRows` cannot
  /// (`MERGE n` stays in the tag text).
  var tag: String
}

/// Why `DatabaseSession.closeEvents` fired. The connection actor maps this onto session loss.
///
/// `.connectionLost` is the server or the network. The actor forgets the session and
/// publishes it as a loss (`SessionLostEvent`, `DatabaseError.connectionLost`), the same
/// path as `markSessionLost`. `.closedByApp` is `close()` from disconnect, cancel, or a
/// reconnect. The actor has already forgotten that session and does not publish a loss.
nonisolated enum SessionCloseReason: Sendable, Equatable {
  /// The server or the network ended the session.
  case connectionLost
  /// The app closed the session. Not a loss.
  case closedByApp
}

/// Handle for a server-side cursor. Callers use the cursor methods only when
/// `DatabaseCapabilities.supportsServerCursor` is true.
nonisolated struct SessionCursor: Sendable, Hashable {
  /// Name the session used in DECLARE, FETCH, and CLOSE.
  let name: String
}

/// An open connection to one database. A session is a class or an actor so the
/// connection actor can hold it and call `interrupt` on the same instance.
/// `query` and `command` take neutral binds; the session encodes them.
nonisolated protocol DatabaseSession: AnyObject, Sendable {
  var capabilities: DatabaseCapabilities { get }

  /// Connect. Throws when the server cannot be reached or session setup fails.
  func open() async throws

  /// Close the session. Yields `.closedByApp` on `closeEvents` when it was still open.
  func close() async

  /// One reason when the session ends, then the stream finishes. At most one reason.
  var closeEvents: AsyncStream<SessionCloseReason> { get }

  /// Run a statement and stream its rows. `binds` are `$1`, `$2`, … in order.
  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource

  /// Run a statement and discard its rows. The outcome is the command tag.
  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult

  /// Open a server-side cursor for `sql` (DECLARE). The session chooses the name.
  /// Only when `capabilities.supportsServerCursor` is true.
  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor

  /// FETCH up to `maxRows` rows. The caller passes the count; this does not add one
  /// for truncation detection.
  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource

  /// CLOSE the cursor.
  func closeCursor(_ cursor: SessionCursor) async throws

  /// Apply the per-connection safety timeouts. The actor clamps `statementTimeoutSeconds`,
  /// `lockTimeoutSeconds`, and `idleTimeoutSeconds` with `SessionBrakeLimits` first.
  /// Throws when a timeout cannot be set; the actor then does not publish the session.
  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws

  /// Stop the running statement in this process. Callers use this when
  /// `capabilities.cancelStrategy` is `.interrupt`. A reconnect cancel closes the
  /// session instead.
  func interrupt() async

  /// User-facing text for a driver error.
  func formatError(_ error: Error) -> String
}

/// Builds a session that is not open yet. `open()` connects. Throws when the engine cannot
/// run in this build (`DatabaseError.engineUnavailable`). Async so a factory can read state
/// on the main actor (the DuckDB plugin's install state).
nonisolated protocol DatabaseSessionFactory: Sendable {
  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession
  /// `extraAllowedPaths`: the only files a DuckDB session's SQL may read (user-picked files).
  /// Other engines ignore them.
  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession
}

extension DatabaseSessionFactory {
  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    try await makeSession(config: config)
  }
}
