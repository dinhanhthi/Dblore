// MCPReadOnlySessionFactory.swift
// Sessions for MCP connections. PostgreSQL and MySQL run every query inside a server-side
// read-only transaction that is always rolled back; SQLite opens the file read-only. DuckDB is
// refused: a second in-process instance is a frozen snapshot, and closing it drops the
// writer's file lock (spike 2.4). MongoDB has no read-only transaction: its session is returned
// as is, since `MongoSession.query` runs only commands the classifier calls reads (and refuses
// binds), MCP never calls `command`, and `MongoSchemaIntrospector` needs the `MongoSession`
// itself. `ReadOnlyQueryGuard` refuses server-side JavaScript first; a read-only database role
// is the server-side backstop.
//
// MCP read path: `DatabaseConnectionManager.execute(userSQL:policy:maxRows:)` with a read-only
// policy and no caller. MCP sends only `.read` statements and never opens a transaction, so a
// read goes through `query` and the capped reader (a truncated PostgreSQL read closes and
// reopens the session, `resetSessionIfCapped`), never through a server cursor. For SQL engines
// `command` and the cursor methods are therefore refused here: nothing MCP sends needs them,
// and the manager's connect setup only calls `applySessionSettings`. MongoDB's session is
// returned unwrapped, so nothing is refused here for it: read-only rests on
// `ReadOnlyQueryGuard`, the manager's read-only policy and `MongoSession.query`, which runs
// reads only.

import Foundation

/// Why MCP refused a connection or a statement. Never carries a secret or a server message.
nonisolated enum MCPConnectionError: Error, Equatable, LocalizedError {
  case unknownConnection
  /// Connecting failed; the server's text (host, user, file) is not passed on
  case connectFailed
  /// The pool was closed (MCP server stopped)
  case stopped
  case duckDBNotSupported
  case certificateNotSaved
  case sshCredentialNotSaved
  case sshHostKeyNotTrusted
  case passwordCommand
  case commandRefused
  case cursorRefused

  var errorDescription: String? {
    switch self {
    case .unknownConnection:
      "This connection is not saved in Dblore."
    case .connectFailed:
      "Could not connect to this connection."
    case .stopped:
      "The MCP server is stopped."
    case .duckDBNotSupported:
      "MCP does not support DuckDB connections."
    case .certificateNotSaved:
      "The connection's client certificate is not saved in the Keychain. Connect once in "
        + "Dblore with Remember on."
    case .sshCredentialNotSaved:
      "The connection's SSH password or key is not saved in the Keychain. Connect once in "
        + "Dblore with Remember on."
    case .sshHostKeyNotTrusted:
      "The SSH server's host key is not trusted yet. Connect once in Dblore and trust it."
    case .passwordCommand:
      "This connection uses a password command; open it in Dblore instead."
    case .commandRefused:
      "MCP connections are read-only: only queries are sent."
    case .cursorRefused:
      "MCP connections do not use server-side cursors."
    }
  }
}

/// Wraps the app's factory for MCP connections (see the file header).
nonisolated struct MCPReadOnlySessionFactory: DatabaseSessionFactory {
  let inner: any DatabaseSessionFactory

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    switch config.databaseType {
    case .postgresql:
      return MCPReadOnlySession(
        inner: try await inner.makeSession(config: config),
        beginSQL: "BEGIN TRANSACTION READ ONLY")
    case .mysql:
      return MCPReadOnlySession(
        inner: try await inner.makeSession(config: config),
        beginSQL: "START TRANSACTION READ ONLY")
    case .sqlite:
      var readOnly = config
      readOnly.readOnlyFile = true
      return try await inner.makeSession(config: readOnly)
    case .duckdb:
      throw MCPConnectionError.duckDBNotSupported
    case .mongodb:
      return try await inner.makeSession(config: config)
    }
  }
}

/// Runs each `query` between `beginSQL` and ROLLBACK. Transactions are chained: the next BEGIN
/// waits until the previous ROLLBACK finished. The ROLLBACK runs when the rows end, when they
/// throw, or when the consumer drops them early (row cap, cancel). A failed ROLLBACK closes the
/// inner session and reports it lost (`closeEvents`), so the manager and the pool replace it.
nonisolated final class MCPReadOnlySession: DatabaseSession, @unchecked Sendable {
  private let inner: any DatabaseSession
  private let beginSQL: String
  private let lock = NSLock()
  /// Finishes once the last transaction started here was rolled back
  private var lastTransaction: Task<Void, Never>?
  /// The inner session's close reasons, plus `.connectionLost` after a failed ROLLBACK
  let closeEvents: AsyncStream<SessionCloseReason>
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation

  init(inner: any DatabaseSession, beginSQL: String) {
    self.inner = inner
    self.beginSQL = beginSQL
    (closeEvents, closeContinuation) = AsyncStream.makeStream()
    let continuation = closeContinuation
    let events = inner.closeEvents
    Task {
      for await reason in events { continuation.yield(reason) }
      continuation.finish()
    }
  }

  var capabilities: DatabaseCapabilities { inner.capabilities }

  func open() async throws {
    try await inner.open()
  }

  /// Does not wait for a pending ROLLBACK: a reconnect cancel closes the session while its read
  /// still runs. Closing ends the transaction on the server.
  func close() async {
    await inner.close()
  }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let (ended, endedContinuation) = AsyncStream<Void>.makeStream()
    let transaction = Task { for await _ in ended {} }
    let previous = lock.withLock {
      defer { lastTransaction = transaction }
      return lastTransaction
    }
    await previous?.value
    do {
      _ = try await inner.command(beginSQL, binds: [])
    } catch {
      endedContinuation.finish()
      throw error
    }
    let inner = inner
    let lost = closeContinuation
    let end = ReadOnlyTransactionEnd(session: inner, ended: endedContinuation) {
      // Before the close, which ends the forwarded events
      lost.yield(.connectionLost)
      await inner.close()
    }
    let source: SessionRowSource
    do {
      source = try await inner.query(sql, binds: binds)
    } catch {
      await end.rollback()
      throw error
    }
    let pull = ReadOnlyRowPull(source.rows.makeAsyncIterator(), end: end)
    return SessionRowSource(
      columns: source.columns, rows: AsyncThrowingStream(unfolding: { try await pull.next() }))
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    throw MCPConnectionError.commandRefused
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw MCPConnectionError.cursorRefused
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw MCPConnectionError.cursorRefused
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    throw MCPConnectionError.cursorRefused
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await inner.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async {
    await inner.interrupt()
  }

  func formatError(_ error: Error) -> String {
    inner.formatError(error)
  }
}

/// Sends the ROLLBACK of one transaction exactly once, then lets the next one begin.
private nonisolated final class ReadOnlyTransactionEnd: @unchecked Sendable {
  private let session: any DatabaseSession
  private let ended: AsyncStream<Void>.Continuation
  private let failed: @Sendable () async -> Void
  private let lock = NSLock()
  private var started = false

  /// `failed` runs when the ROLLBACK throws, before the next transaction may begin.
  init(
    session: any DatabaseSession, ended: AsyncStream<Void>.Continuation,
    failed: @escaping @Sendable () async -> Void
  ) {
    self.session = session
    self.ended = ended
    self.failed = failed
  }

  func rollback() async {
    let first = lock.withLock {
      defer { started = true }
      return !started
    }
    guard first else { return }
    // The session may still be in the read-only transaction. A BEGIN inside it only warns
    // (PostgreSQL) or commits it first (MySQL START TRANSACTION), and every query sends its own
    // READ ONLY BEGIN, so no write could follow; the session is closed anyway (a closed one
    // ends the transaction on the server) and reported lost, so the manager reconnects.
    do {
      _ = try await session.command("ROLLBACK", binds: [])
    } catch {
      await failed()
    }
    ended.finish()
  }
}

/// The inner rows, pulled by one consumer. Dropped before the end: the inner rows are released
/// first (MySQL stops the read), then the ROLLBACK is sent.
private nonisolated final class ReadOnlyRowPull: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<[CellValue], Error>.AsyncIterator?
  private let end: ReadOnlyTransactionEnd

  init(
    _ iterator: AsyncThrowingStream<[CellValue], Error>.AsyncIterator, end: ReadOnlyTransactionEnd
  ) {
    self.iterator = iterator
    self.end = end
  }

  deinit {
    guard iterator != nil else { return }
    iterator = nil
    let end = end
    Task { await end.rollback() }
  }

  func next() async throws -> [CellValue]? {
    guard iterator != nil else { return nil }
    do {
      if let row = try await iterator?.next() { return row }
    } catch {
      iterator = nil
      await end.rollback()
      throw error
    }
    iterator = nil
    await end.rollback()
    return nil
  }
}
