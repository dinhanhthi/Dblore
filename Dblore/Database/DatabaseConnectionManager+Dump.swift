// DatabaseConnectionManager+Dump.swift
// The SQL dump's snapshot session. `withDumpSnapshot` lifts the session brakes `connect` applied
// (a per-table read of a large table must not time out), opens one read-only snapshot
// transaction for the whole dump, runs the body with an uncapped reader that accepts only reads,
// and always sends ROLLBACK. For PostgreSQL, MySQL and SQLite only a dump manager
// (`SQLDumpWriter`'s own) calls it: the brake statements are app-owned and sent straight to the
// session, never through `applySessionSettings`, whose engines clamp 0 back to the default
// (`SessionBrakeLimits.clamp`). DuckDB is dumped on the tab's own manager: refused while a
// transaction is open there (its BEGIN would fail and its ROLLBACK end the user's work), run as
// one DuckDB catalog read (so the app's own catalog reads wait instead of ending the dump's open
// result), with the session's statement timeout raised for the dump and set back afterwards.

import Foundation

nonisolated enum SQLDumpError: Error, Equatable, LocalizedError {
  /// The dump reader was given a statement the classifier does not mark as a read
  case notRead
  /// The engine has no SQL dump (MongoDB), or DuckDB without the tab's own session
  case unsupportedEngine(DatabaseType)
  /// MySQL or MariaDB could not be told apart, so the statement timeout variable is unknown
  case unknownMySQLServer
  /// The destination is the connected SQLite file or one of its journal files
  case destinationIsDatabase
  /// The MySQL connection has no default database
  case noDatabaseSelected
  /// A data read returned a value that is not text in the expected form
  case unexpectedValue(table: String, column: String)
  /// DuckDB: the tab's session has a transaction open (the dump runs on that session)
  case transactionOpen

  var errorDescription: String? {
    switch self {
    case .notRead:
      "The SQL dump only runs read statements."
    case .unsupportedEngine(let type):
      "\(type.rawValue) databases cannot be exported as a SQL dump."
    case .unknownMySQLServer:
      "The server version could not be read."
    case .destinationIsDatabase:
      "Choose a different file: this is the open database."
    case .noDatabaseSelected:
      "Choose a database in the connection settings to export a SQL dump."
    case .unexpectedValue(let table, let column):
      "Column \"\(column)\" of table \"\(table)\" returned a value the dump cannot write."
    case .transactionOpen:
      "Commit or roll back the open transaction first, then export the dump."
    }
  }
}

/// The dump's view of the snapshot session: `query` runs exactly one statement the classifier
/// marks as a read, with no row cap, cell limit or history; everything else throws. It is a
/// `DatabaseSession` so the schema introspectors can read the catalog through it.
nonisolated final class DumpSnapshotReader: DatabaseSession {
  private let session: any DatabaseSession
  private let dialect: SQLDialect

  init(session: any DatabaseSession, dialect: SQLDialect) {
    self.session = session
    self.dialect = dialect
  }

  var capabilities: DatabaseCapabilities { session.capabilities }

  /// The manager observes the session's own close events; the reader has none.
  var closeEvents: AsyncStream<SessionCloseReason> { AsyncStream { $0.finish() } }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let statements = SQLStatementClassifier.classify(sql, dialect: dialect)
    guard statements.count == 1, statements[0].kind == .read else { throw SQLDumpError.notRead }
    return try await session.query(sql, binds: binds)
  }

  func open() async throws { throw SQLDumpError.notRead }
  func close() async {}

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    throw SQLDumpError.notRead
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    throw SQLDumpError.notRead
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    throw SQLDumpError.notRead
  }

  func closeCursor(_ cursor: SessionCursor) async throws { throw SQLDumpError.notRead }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    throw SQLDumpError.notRead
  }

  func interrupt() async { await session.interrupt() }

  func formatError(_ error: Error) -> String { session.formatError(error) }
}

extension DatabaseConnectionManager {
  /// One year in seconds: MySQL's largest lock wait timeout
  nonisolated static let dumpLockWaitSeconds = 31_536_000

  /// Statements that turn the session brakes off for the dump. PostgreSQL's are `SET LOCAL`
  /// (sent after BEGIN, reverted by the ROLLBACK); MySQL's are `SET SESSION` (sent before
  /// START TRANSACTION; the dump session is closed afterwards). SQLite has none: the dump calls
  /// `applySessionSettings` with 0 instead. DuckDB has none either: its only brake is the
  /// session's own statement timeout (`withDumpSnapshot`).
  /// - Throws: `SQLDumpError.unknownMySQLServer` for MySQL without `serverInfo`.
  nonisolated static func dumpBrakeLiftStatements(
    databaseType: DatabaseType, serverInfo: MySQLServerInfo?
  ) throws -> [String] {
    switch databaseType {
    case .postgresql:
      return [
        "SET LOCAL statement_timeout = 0", "SET LOCAL lock_timeout = 0",
        "SET LOCAL idle_in_transaction_session_timeout = 0",
      ]
    case .mysql:
      guard let serverInfo else { throw SQLDumpError.unknownMySQLServer }
      return [
        "SET SESSION \(serverInfo.statementTimeoutVariable) = 0",
        "SET SESSION innodb_lock_wait_timeout = \(dumpLockWaitSeconds)",
        "SET SESSION lock_wait_timeout = \(dumpLockWaitSeconds)",
      ]
    case .sqlite, .duckdb:
      return []
    case .mongodb:
      throw SQLDumpError.unsupportedEngine(databaseType)
    }
  }

  /// Everything sent before the body, in order. PostgreSQL also pins the text forms the data
  /// reads depend on: `search_path` empty (every name the catalog prints is schema-qualified),
  /// ISO dates, `postgres` intervals, exact floats and hex `bytea`.
  nonisolated static func dumpSnapshotStatements(
    databaseType: DatabaseType, serverInfo: MySQLServerInfo?
  ) throws -> [String] {
    let lift = try dumpBrakeLiftStatements(databaseType: databaseType, serverInfo: serverInfo)
    switch databaseType {
    case .postgresql:
      return ["BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"] + lift + [
        "SET LOCAL search_path = ''", "SET LOCAL DateStyle = 'ISO'",
        "SET LOCAL IntervalStyle = 'postgres'", "SET LOCAL extra_float_digits = 3",
        "SET LOCAL bytea_output = 'hex'",
      ]
    case .mysql:
      return lift + [
        "SET time_zone = '+00:00'", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY",
      ]
    case .sqlite:
      return lift + ["BEGIN"]
    case .duckdb:
      return lift + ["BEGIN TRANSACTION READ ONLY"]
    case .mongodb:
      throw SQLDumpError.unsupportedEngine(databaseType)
    }
  }

  /// Runs `body` inside one read-only snapshot transaction of the connected session, with the
  /// brakes lifted. ROLLBACK is always sent, also when `body` throws or the task is cancelled
  /// (cancel also interrupts the running statement).
  func withDumpSnapshot<T: Sendable>(
    _ body: @escaping @Sendable (DumpSnapshotReader) async throws -> T
  ) async throws -> T {
    guard let databaseType else { throw DatabaseError.notConnected }
    try refuseIfRelocked(config)
    if databaseType == .duckdb { return try await withDuckDBDumpSnapshot(body) }
    var serverInfo = mysqlServerInfo
    return try await withSession { session in
      if databaseType == .mysql, serverInfo == nil {
        serverInfo = try await Self.readServerInfo(session)
      }
      return try await Self.runDumpSnapshot(
        on: session, databaseType: databaseType, serverInfo: serverInfo, body)
    }
  }

  /// DuckDB, on the tab's session: refused while a transaction is open there (app or user);
  /// one catalog read for the whole dump; the statement timeout (DuckDB's watchdog deadline for
  /// a whole read, including the time the dump takes to write its rows) raised to the largest
  /// allowed for the dump, then set back to the connection's own on every path. A statement
  /// another tab sends meanwhile ends the dump's read (it fails) or runs inside its read-only
  /// transaction (a write fails).
  private func withDuckDBDumpSnapshot<T: Sendable>(
    _ body: @escaping @Sendable (DumpSnapshotReader) async throws -> T
  ) async throws -> T {
    guard txState.isIdle, txOwner == nil, !userTxOpen else { throw SQLDumpError.transactionOpen }
    let restored = SessionBrakeLimits.clampStatementTimeout(
      config?.statementTimeoutSeconds ?? SessionBrakeLimits.defaultStatementTimeout)
    return try await withCatalogReadSession { session in
      // The wait for another catalog read can suspend: a transaction opened meanwhile would end
      // at the dump's ROLLBACK
      guard txState.isIdle, txOwner == nil, !userTxOpen else {
        throw SQLDumpError.transactionOpen
      }
      try await session.applySessionSettings(
        statementTimeoutSeconds: SessionBrakeLimits.statementTimeoutRange.upperBound,
        lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
      let result: Result<T, Error>
      do {
        result = .success(
          try await Self.runDumpSnapshot(
            on: session, databaseType: .duckdb, serverInfo: nil, body))
      } catch {
        result = .failure(error)
      }
      try? await session.applySessionSettings(
        statementTimeoutSeconds: restored, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
      return try result.get()
    }
  }

  /// `withDumpSnapshot` on `session`, without the actor (tests drive it with a fake session).
  nonisolated static func runDumpSnapshot<T: Sendable>(
    on session: any DatabaseSession, databaseType: DatabaseType, serverInfo: MySQLServerInfo?,
    _ body: @escaping @Sendable (DumpSnapshotReader) async throws -> T
  ) async throws -> T {
    let result: Result<T, Error>
    do {
      let statements = try dumpSnapshotStatements(
        databaseType: databaseType, serverInfo: serverInfo)
      if databaseType == .sqlite {
        try await session.applySessionSettings(
          statementTimeoutSeconds: 0, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
      }
      for statement in statements {
        _ = try await session.command(statement, binds: [])
      }
      let reader = DumpSnapshotReader(session: session, dialect: databaseType.dialect)
      result = .success(
        try await withTaskCancellationHandler {
          try await body(reader)
        } onCancel: {
          Task { await session.interrupt() }
        })
    } catch {
      result = .failure(error)
    }
    // A closed session (PostgreSQL cancel) cannot take it; the server rolls back on close.
    _ = try? await session.command("ROLLBACK", binds: [])
    return try result.get()
  }

  /// `SELECT VERSION()` of a session that is not a `MySQLSession`; nil when unreadable.
  private nonisolated static func readServerInfo(
    _ session: any DatabaseSession
  ) async throws -> MySQLServerInfo? {
    let source = try await session.query("SELECT VERSION()", binds: [])
    for try await row in source.rows {
      if case .string(let version) = row.first { return MySQLServerInfo(version: version) }
      return nil
    }
    return nil
  }
}
