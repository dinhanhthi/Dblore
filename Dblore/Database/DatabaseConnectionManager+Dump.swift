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
// The all-rows result export (`ResultExportRunner`) runs one read in the same snapshot with the
// `.resultExport` purpose: the tab session's search_path, database, time zone, DateStyle and
// MySQL sql_mode and GROUP_CONCAT / division settings instead of the dump's pins
// (`resultExportSessionState` reads them on the tab's manager, and refuses state a separate
// session cannot carry: temporary tables, PostgreSQL SET ROLE, a MySQL sql_mode that changes how
// the app reads the query).

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

/// The tab session's state an all-rows result export carries to its own session
nonisolated struct ResultExportSessionState: Sendable, Equatable {
  /// PostgreSQL: `current_setting('search_path')` of the tab's session
  var searchPath: String? = nil
  /// MySQL / MariaDB: `DATABASE()` of the tab's session, nil when none is selected
  var database: String? = nil
  /// PostgreSQL: `current_setting('TimeZone')`; MySQL / MariaDB: `@@session.time_zone`, of the
  /// tab's session
  var timeZone: String? = nil
  /// PostgreSQL: `current_setting('DateStyle')` of the tab's session (how date literals parse)
  var dateStyle: String? = nil
  /// MySQL / MariaDB: `@@session.sql_mode`, `@@session.group_concat_max_len` and
  /// `@@session.div_precision_increment` of the tab's session
  var sqlMode: String? = nil
  var groupConcatMaxLength: UInt64? = nil
  var divPrecisionIncrement: UInt64? = nil
}

/// What a snapshot session is for
nonisolated enum DumpSnapshotPurpose: Sendable, Equatable {
  /// The SQL dump: the session pinned for a portable file (PostgreSQL `search_path = ''` and
  /// text forms, MySQL UTC)
  case dump
  /// An all-rows result export: the tab session's state, the server's own text forms, so the
  /// read resolves its names and shows its values as the tab's result did
  case resultExport(ResultExportSessionState)
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
  var brakeFlavor: DatabaseFlavor? { session.brakeFlavor }

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
  /// session's own statement timeout (`withDumpSnapshot`). A brake `flavor` does not support
  /// was never set, so it is not lifted either.
  /// - Throws: `SQLDumpError.unknownMySQLServer` for MySQL without `serverInfo`.
  nonisolated static func dumpBrakeLiftStatements(
    databaseType: DatabaseType, serverInfo: MySQLServerInfo?, flavor: DatabaseFlavor? = nil
  ) throws -> [String] {
    switch databaseType {
    case .postgresql:
      var lift = ["SET LOCAL statement_timeout = 0"]
      if flavor?.supportsLockTimeout != false { lift.append("SET LOCAL lock_timeout = 0") }
      if flavor?.supportsIdleInTransactionTimeout != false {
        lift.append("SET LOCAL idle_in_transaction_session_timeout = 0")
      }
      return lift
    case .mysql:
      guard let serverInfo else { throw SQLDumpError.unknownMySQLServer }
      return [
        "SET SESSION \(serverInfo.statementTimeoutVariable) = 0",
        "SET SESSION innodb_lock_wait_timeout = \(dumpLockWaitSeconds)",
        "SET SESSION lock_wait_timeout = \(dumpLockWaitSeconds)",
      ]
    case .sqlite, .duckdb:
      return []
    case .mongodb, .clickhouse, .sqlserver:
      throw SQLDumpError.unsupportedEngine(databaseType)
    }
  }

  /// Everything sent before the body, in order, with its binds. For the dump PostgreSQL also
  /// pins the text forms the data reads depend on: `search_path` empty (every name the catalog
  /// prints is schema-qualified), ISO dates, `postgres` intervals, exact floats and hex `bytea`,
  /// and MySQL reads in UTC. For a result export PostgreSQL takes the tab's search_path
  /// time zone and DateStyle (`set_config(..., true)`, reverted by the ROLLBACK) and keeps the
  /// server's text forms, and MySQL takes the tab's database (`USE`), time zone, sql_mode,
  /// group_concat_max_len and div_precision_increment. SQLite and DuckDB are the same for both:
  /// they read their file.
  /// - Throws: `SQLDumpError.unknownMySQLServer`; `ResultExportError.sessionStateUnreadable`
  ///   for a result export without the tab's search_path, time zone or DateStyle (MySQL: a
  ///   plain time zone and sql_mode, and both integer settings).
  nonisolated static func dumpSnapshotStatements(
    databaseType: DatabaseType, serverInfo: MySQLServerInfo?,
    purpose: DumpSnapshotPurpose = .dump, flavor: DatabaseFlavor? = nil
  ) throws -> [(sql: String, binds: [SQLBindValue])] {
    func plain(_ statements: [String]) -> [(sql: String, binds: [SQLBindValue])] {
      statements.map { ($0, []) }
    }
    let lift = try dumpBrakeLiftStatements(
      databaseType: databaseType, serverInfo: serverInfo, flavor: flavor)
    switch (databaseType, purpose) {
    case (.postgresql, .dump):
      return plain(
        ["BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"] + lift + [
          "SET LOCAL search_path = ''", "SET LOCAL DateStyle = 'ISO'",
          "SET LOCAL IntervalStyle = 'postgres'", "SET LOCAL extra_float_digits = 3",
          "SET LOCAL bytea_output = 'hex'",
        ])
    case (.postgresql, .resultExport(let state)):
      guard let searchPath = state.searchPath, let zone = state.timeZone,
        let dateStyle = state.dateStyle
      else { throw ResultExportError.sessionStateUnreadable }
      return plain(["BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"] + lift) + [
        (SearchPathPin.putBackSQL, [.text(searchPath)]),
        (resultExportTimeZoneSQL, [.text(zone)]),
        (resultExportDateStyleSQL, [.text(dateStyle)]),
      ]
    case (.mysql, .dump):
      return plain(
        lift + [
          "SET time_zone = '+00:00'", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY",
        ])
    case (.mysql, .resultExport(let state)):
      guard let zone = state.timeZone, isPlainTimeZone(zone), let mode = state.sqlMode,
        isPlainSQLMode(mode), let groupConcat = state.groupConcatMaxLength,
        let division = state.divPrecisionIncrement
      else { throw ResultExportError.sessionStateUnreadable }
      let use = try state.database.map { ["USE " + (try SQLDialect.mysql.quoteIdentifier($0))] }
      return plain(
        lift + (use ?? []) + [
          "SET time_zone = '\(zone)'", "SET SESSION sql_mode = '\(mode)'",
          "SET SESSION group_concat_max_len = \(groupConcat)",
          "SET SESSION div_precision_increment = \(division)",
          "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY",
        ])
    case (.sqlite, _):
      return plain(lift + ["BEGIN"])
    case (.duckdb, _):
      return plain(lift + ["BEGIN TRANSACTION READ ONLY"])
    case (.mongodb, _), (.clickhouse, _), (.sqlserver, _):
      throw SQLDumpError.unsupportedEngine(databaseType)
    }
  }

  /// A MySQL time zone value (`SYSTEM`, `+05:30`, `Europe/Paris`, `Etc/GMT+5`): letters, digits
  /// and `_ / + - : .` only, so it is quoted as is in any `sql_mode` (no quote, no backslash)
  private nonisolated static func isPlainTimeZone(_ zone: String) -> Bool {
    !zone.isEmpty
      && zone.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0))
          || "_/+-:.".unicodeScalars.contains($0)
      }
  }

  /// A MySQL sql_mode value as the server reports it (`STRICT_TRANS_TABLES,ONLY_FULL_GROUP_BY`,
  /// MariaDB's `MYSQL40`, or empty): ASCII uppercase letters, digits, `_` and `,` only, so it is
  /// quoted as is in any `sql_mode` (no quote, no backslash)
  private nonisolated static func isPlainSQLMode(_ mode: String) -> Bool {
    mode.unicodeScalars.allSatisfy {
      ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == ","
    }
  }

  /// Runs `body` inside one read-only snapshot transaction of the connected session, with the
  /// brakes lifted. ROLLBACK is always sent, also when `body` throws or the task is cancelled
  /// (cancel also interrupts the running statement).
  func withDumpSnapshot<T: Sendable>(
    purpose: DumpSnapshotPurpose = .dump,
    _ body: @escaping @Sendable (DumpSnapshotReader) async throws -> T
  ) async throws -> T {
    guard let databaseType else { throw DatabaseError.notConnected }
    try refuseIfRelocked(config)
    // DuckDB reads on the tab's own session: the same statements for both purposes
    if databaseType == .duckdb { return try await withDuckDBDumpSnapshot(body) }
    var serverInfo = mysqlServerInfo
    return try await withSession { session in
      if databaseType == .mysql, serverInfo == nil {
        serverInfo = try await Self.readServerInfo(session)
      }
      return try await Self.runDumpSnapshot(
        on: session, databaseType: databaseType, serverInfo: serverInfo, purpose: purpose, body)
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
  /// The lift follows the session's verified `brakeFlavor`.
  nonisolated static func runDumpSnapshot<T: Sendable>(
    on session: any DatabaseSession, databaseType: DatabaseType, serverInfo: MySQLServerInfo?,
    purpose: DumpSnapshotPurpose = .dump,
    _ body: @escaping @Sendable (DumpSnapshotReader) async throws -> T
  ) async throws -> T {
    let result: Result<T, Error>
    do {
      let statements = try dumpSnapshotStatements(
        databaseType: databaseType, serverInfo: serverInfo, purpose: purpose,
        flavor: session.brakeFlavor)
      if databaseType == .sqlite {
        try await session.applySessionSettings(
          statementTimeoutSeconds: 0, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
      }
      for statement in statements {
        _ = try await session.command(statement.sql, binds: statement.binds)
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

  /// PostgreSQL: whether the session's temporary schema holds a relation now (a temporary
  /// table, view or sequence; the schema stays after they are dropped), its search_path, time
  /// zone and DateStyle, and its current and session user (they differ after SET ROLE)
  nonisolated static let resultExportPostgresStateSQL =
    "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE relnamespace "
    + "OPERATOR(pg_catalog.=) pg_catalog.pg_my_temp_schema()), "
    + "pg_catalog.current_setting('search_path'::pg_catalog.text), "
    + "pg_catalog.current_setting('TimeZone'::pg_catalog.text), "
    + "pg_catalog.current_setting('DateStyle'::pg_catalog.text), "
    + "current_user::pg_catalog.text, session_user::pg_catalog.text"
  /// PostgreSQL: sets the read's time zone to `$1` for the transaction (the ROLLBACK reverts it)
  nonisolated static let resultExportTimeZoneSQL =
    "SELECT pg_catalog.set_config('TimeZone'::pg_catalog.text, $1, true)"
  /// PostgreSQL: sets the read's DateStyle to `$1` for the transaction (the ROLLBACK reverts it)
  nonisolated static let resultExportDateStyleSQL =
    "SELECT pg_catalog.set_config('DateStyle'::pg_catalog.text, $1, true)"
  /// SQLite: the objects (tables, views, indexes, triggers) of the session's `temp` schema
  nonisolated static let resultExportSQLiteTemporarySQL = "SELECT count(*) FROM sqlite_temp_master"
  /// MySQL / MariaDB: the session's default database (NULL without one), time zone, sql_mode,
  /// GROUP_CONCAT length limit and division scale
  nonisolated static let resultExportMySQLStateSQL =
    "SELECT DATABASE(), @@session.time_zone, @@session.sql_mode, "
    + "@@session.group_concat_max_len, @@session.div_precision_increment"

  /// The state of this (the tab's) session an all-rows result export applies to its own
  /// session, read here before the export connects: PostgreSQL its search_path, time zone and
  /// DateStyle, MySQL its database, time zone, sql_mode, group_concat_max_len and
  /// div_precision_increment; nothing for SQLite and DuckDB, which keep their file.
  /// - Throws: `ResultExportError.openChanges` with `hasStagedChanges` or while a transaction is
  ///   open here (app or user: the export's connection would not see its changes);
  ///   `ResultExportError.temporaryTables` when the session has temporary tables (PostgreSQL a
  ///   temporary relation, MySQL tracked temporary tables, SQLite objects in `temp`: one could
  ///   shadow a name the read uses); `ResultExportError.otherRole` when PostgreSQL's current
  ///   user is not the session user; `ResultExportError.sqlMode` when the MySQL sql_mode has a
  ///   flag that changes how the app reads the query; `ResultExportError.sessionStateUnreadable`
  ///   when a value cannot be read, a MySQL time zone or sql_mode is not plain or a MySQL
  ///   integer setting is not one (fails closed);
  ///   `DatabaseError.notConnected`.
  func resultExportSessionState(hasStagedChanges: Bool) async throws -> ResultExportSessionState {
    guard let databaseType else { throw DatabaseError.notConnected }
    guard !hasStagedChanges, txState.isIdle, txOwner == nil, !userTxOpen else {
      throw ResultExportError.openChanges
    }
    switch databaseType {
    case .postgresql:
      let row = try await withCatalogSession { session in
        try await Self.firstRow(session, Self.resultExportPostgresStateSQL)
      }
      guard let row, row.count == 6, let temporary = Self.truth(row[0]) else {
        throw ResultExportError.sessionStateUnreadable
      }
      if temporary { throw ResultExportError.temporaryTables }
      guard case .string(let path) = row[1], case .string(let zone) = row[2],
        case .string(let dateStyle) = row[3], case .string(let currentUser) = row[4],
        case .string(let sessionUser) = row[5]
      else { throw ResultExportError.sessionStateUnreadable }
      guard currentUser == sessionUser else { throw ResultExportError.otherRole }
      return ResultExportSessionState(searchPath: path, timeZone: zone, dateStyle: dateStyle)
    case .mysql:
      guard mysqlTempTables.names.isEmpty else { throw ResultExportError.temporaryTables }
      let row = try await withCatalogSession { session in
        try await Self.firstRow(session, Self.resultExportMySQLStateSQL)
      }
      guard let row, row.count == 5, case .string(let zone) = row[1], Self.isPlainTimeZone(zone),
        case .string(let mode) = row[2]
      else { throw ResultExportError.sessionStateUnreadable }
      // The app's MySQL lexer (read guard, user variable check) reads `"…"` as a string and `\`
      // as an escape: the flags `MySQLSession` strips on connect. The export's session is
      // pinned the same way, so the tab's sql_mode is carried only without them.
      let flags = mode.split(separator: ",").map(String.init)
      guard flags.allSatisfy({ !MySQLSession.unpinnedSQLModes.contains($0) }) else {
        throw ResultExportError.sqlMode
      }
      guard Self.isPlainSQLMode(mode), let groupConcat = Self.unsigned(row[3]),
        let division = Self.unsigned(row[4])
      else { throw ResultExportError.sessionStateUnreadable }
      var state = ResultExportSessionState(
        timeZone: zone, sqlMode: mode, groupConcatMaxLength: groupConcat,
        divPrecisionIncrement: division)
      switch row[0] {
      case .string(let database): state.database = database
      case .null: break
      default: throw ResultExportError.sessionStateUnreadable
      }
      return state
    case .sqlite:
      // The export opens the file on a connection of its own, which has no `temp` schema
      let row = try await withCatalogSession { session in
        try await Self.firstRow(session, Self.resultExportSQLiteTemporarySQL)
      }
      guard let row, row.count == 1, case .int(let count) = row[0] else {
        throw ResultExportError.sessionStateUnreadable
      }
      if count > 0 { throw ResultExportError.temporaryTables }
      return ResultExportSessionState()
    case .duckdb:
      // DuckDB exports on this session
      return ResultExportSessionState()
    case .mongodb, .clickhouse, .sqlserver:
      throw ResultExportError.unsupportedEngine(databaseType)
    }
  }

  /// The first row of `sql` (every row is read), nil without one
  private nonisolated static func firstRow(
    _ session: any DatabaseSession, _ sql: String
  ) async throws -> [CellValue]? {
    var first: [CellValue]?
    for try await row in try await session.query(sql, binds: []).rows where first == nil {
      first = row
    }
    return first
  }

  /// A non-negative integer as MySQL returns an unsigned setting: `int`, or text above
  /// `Int.max`; nil otherwise
  private nonisolated static func unsigned(_ value: CellValue) -> UInt64? {
    switch value {
    case .int(let value): UInt64(exactly: value)
    case .string(let text): UInt64(text)
    default: nil
    }
  }

  /// A boolean as a server returns it (`bool`, `t` / `f` text, 0 / 1), nil otherwise
  private nonisolated static func truth(_ value: CellValue) -> Bool? {
    switch value {
    case .bool(let value): value
    case .int(let value) where value == 0 || value == 1: value == 1
    case .string("t"), .string("true"): true
    case .string("f"), .string("false"): false
    default: nil
    }
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
