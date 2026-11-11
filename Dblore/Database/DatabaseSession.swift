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
  /// Documents changed by a MongoDB update (`nModified`); `affectedRows` is the matched count.
  /// Nil for every other command and engine.
  var modifiedRows: Int? = nil
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

  /// Stop the running statement without closing the session. Callers use this when
  /// `capabilities.cancelStrategy` is `.interrupt`. A reconnect cancel closes the
  /// session instead. PostgreSQL closes its socket here (dump, Parquet export): its Cancel uses
  /// `cancelBackend`.
  func interrupt() async

  /// After an interrupt cancel ended the running statement: whether the transaction opened
  /// with BEGIN is still open. Nil when the session cannot tell: the caller keeps its state.
  /// Not asked when the engine's interrupt always aborts the transaction
  /// (`DatabaseType.interruptAbortsTransaction`): the manager rolls it back.
  func transactionOpenAfterInterrupt() async -> Bool?

  /// PostgreSQL: what `cancelBackend` matches, read at once (Cancel reads it in the actor turn
  /// it decides in, before anything else is queued): this session's backend and the statement
  /// running now, the oldest one in flight. Nil when that cannot be matched (no pid read at
  /// open, nothing running, an empty text). Default nil.
  func prepareCancelBackend() -> CancelBackendTarget?

  /// PostgreSQL: the token of the oldest statement in flight (the one running), for a cancel
  /// that cannot be matched (`prepareCancelBackend` nil). Default nil.
  func runningStatementToken() -> UInt64?

  /// PostgreSQL: whether the statement `token` names (`CancelBackendTarget.token`,
  /// `runningStatementToken`) is still in flight: a failed cancel resets the session only then.
  /// Default false.
  func statementInFlight(_ token: UInt64) -> Bool

  /// PostgreSQL: stop `target`'s statement from a short side connection to the same server
  /// (`pg_cancel_backend`) and keep this session. True only when the server cancelled this
  /// session's backend while it ran that statement; false otherwise, and the caller resets the
  /// session instead while that statement is still in flight. Default false.
  func cancelBackend(_ target: CancelBackendTarget) async -> Bool

  /// User-facing text for a driver error.
  func formatError(_ error: Error) -> String

  /// PostgreSQL: the table origin of each output column of a view body. A requirement so a
  /// session's own answer is used through `any DatabaseSession`; the default is below.
  func columnOrigins(ofViewBody body: String) async throws -> [ColumnOrigin?]

  /// The flavor that gates the session brakes: Redshift only when the server itself reported
  /// it at open, so a crafted flavor never drops a brake. Default nil (every brake sent).
  var brakeFlavor: DatabaseFlavor? { get }
}

nonisolated extension DatabaseSession {
  var brakeFlavor: DatabaseFlavor? { nil }
  func transactionOpenAfterInterrupt() async -> Bool? { nil }
  func prepareCancelBackend() -> CancelBackendTarget? { nil }
  func runningStatementToken() -> UInt64? { nil }
  func statementInFlight(_ token: UInt64) -> Bool { false }
  func cancelBackend(_ target: CancelBackendTarget) async -> Bool { false }

  /// PostgreSQL: the table origin of each output column of a view body (`pg_get_viewdef`), nil
  /// for an expression. The column origins of a query on a view name the view, since they are
  /// set before the rewriter expands it; through a subselect in FROM they name the relations
  /// the body reads. So this reads the row description of `SELECT * FROM (<body>) AS v LIMIT 0`
  /// (one trailing `;` and whitespace removed) inside `BEGIN READ ONLY` with a 5 s
  /// `statement_timeout` and `lock_timeout` (`SET LOCAL`), and always ends with `ROLLBACK`, also
  /// on an error. `LIMIT 0` returns no row and a view body cannot hold a data-modifying CTE, so
  /// no table row is written. The planner may still evaluate IMMUTABLE functions of the body,
  /// and READ ONLY does not stop a function from taking an advisory lock or sending a NOTIFY:
  /// the timeouts bound how long it runs (no `lock_timeout` on a flavor without it). Only for a
  /// single-use side session the app opened for it, never the user's session.
  func columnOrigins(ofViewBody body: String) async throws -> [ColumnOrigin?] {
    var trimmed = Substring(body)
    while trimmed.last?.isWhitespace == true { trimmed = trimmed.dropLast() }
    if trimmed.last == ";" { trimmed = trimmed.dropLast() }
    while trimmed.last?.isWhitespace == true { trimmed = trimmed.dropLast() }
    let result: Result<[ColumnOrigin?], Error>
    do {
      _ = try await command("BEGIN READ ONLY", binds: [])
      _ = try await command("SET LOCAL statement_timeout = '5s'", binds: [])
      if brakeFlavor?.supportsLockTimeout != false {
        _ = try await command("SET LOCAL lock_timeout = '5s'", binds: [])
      }
      let source = try await query("SELECT * FROM (\n\(trimmed)\n) AS v LIMIT 0", binds: [])
      for try await _ in source.rows {}
      result = .success(source.columns.map(\.tableOrigin))
    } catch {
      result = .failure(error)
    }
    _ = try? await command("ROLLBACK", binds: [])
    return try result.get()
  }
}

/// The PostgreSQL session brakes a flavor accepts besides `statement_timeout`: Redshift
/// refuses `lock_timeout` and `idle_in_transaction_session_timeout` as unknown settings, so
/// they are never sent there. The MySQL flavors answer true; their brakes are MySQL's own.
nonisolated extension DatabaseFlavor {
  var supportsLockTimeout: Bool { self != .redshift }
  var supportsIdleInTransactionTimeout: Bool { self != .redshift }
}

/// What PostgreSQL's server cancel matches (`DatabaseSession.prepareCancelBackend`)
nonisolated struct CancelBackendTarget: Sendable, Equatable {
  /// `pg_backend_pid()` and its `backend_start::text`, read at open
  let pid: Int32
  let backendStart: String
  /// The text of the statement running now (`pg_stat_activity.query`)
  let statement: String
  /// That statement's entry among the ones in flight (`DatabaseSession.statementInFlight`)
  var token: UInt64 = 0
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

nonisolated extension DatabaseSessionFactory {
  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    try await makeSession(config: config)
  }
}
