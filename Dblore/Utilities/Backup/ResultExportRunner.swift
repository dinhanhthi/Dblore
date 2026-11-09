// ResultExportRunner.swift
// Exports every row of a result whose grid holds only part of them (row cap, byte budget, cut
// cells): the result's one read runs again on a separate connection, inside a read-only
// snapshot (`withDumpSnapshot`, purpose `.resultExport`), uncapped, and is written row by row
// (`StreamedResultWriter`) to a private temporary file that replaces the destination once whole.
// The connection is the SQL dump's (`SnapshotExportConnection`): a manager of its own connected
// from the tab's in-memory config, certificate and SSH secret; DuckDB on the tab's own manager.
// The separate session does not carry the tab session's state, so before connecting the runner
// reads it on the tab's manager (`resultExportSessionState`) and applies it (PostgreSQL
// search_path, time zone and DateStyle, MySQL database, time zone, sql_mode,
// group_concat_max_len and div_precision_increment), or refuses (open changes, temporary
// tables, PostgreSQL SET ROLE, MySQL `@name` user variables or a sql_mode that changes how the
// query is read).
// What may not run without a human in the loop is refused before anything connects: not one
// read (`ReadOnlyQueryGuard`) or `:name` parameters. Cancel interrupts the read and deletes the
// temporary file; the destination is untouched.

import Foundation

nonisolated enum ResultExportError: Error, Equatable, LocalizedError {
  /// The tab has an open transaction or pending (Protected mode, staged) changes
  case openChanges
  /// The read answered other column names than the result has
  case columnsChanged
  /// The query has `:name` parameters
  case parameters
  /// The tab's session has temporary tables, which the export's session would not see
  case temporaryTables
  /// PostgreSQL: the tab's session runs as another role (SET ROLE)
  case otherRole
  /// MySQL / MariaDB: the query uses `@name` user variables, which the export's session lacks
  case sessionVariables
  /// MySQL / MariaDB: the tab's sql_mode changes how the app's lexer reads the query (ANSI_QUOTES,
  /// NO_BACKSLASH_ESCAPES or a mode that implies one)
  case sqlMode
  /// The tab's search_path, database, time zone, DateStyle, sql_mode, role or a MySQL setting
  /// could not be read, or is not plain
  case sessionStateUnreadable
  /// MongoDB
  case unsupportedEngine(DatabaseType)

  var errorDescription: String? {
    switch self {
    case .openChanges:
      "Commit or discard the open changes first: a separate connection would not see them."
    case .columnsChanged:
      "The query returns other columns now. Run it again, then export."
    case .parameters:
      "A query with :name parameters cannot export all rows."
    case .temporaryTables:
      "This session has temporary tables, which a separate connection would not see."
    case .otherRole:
      "This session uses another role (SET ROLE), which a separate connection would not use, "
        + "so all rows cannot be exported."
    case .sessionVariables:
      "This query uses session variables (@name), which a separate connection would not have, "
        + "so all rows cannot be exported."
    case .sqlMode:
      "This session's sql_mode (ANSI_QUOTES or NO_BACKSLASH_ESCAPES) changes how the query is "
        + "read, so all rows cannot be exported."
    case .sessionStateUnreadable:
      "The session's settings could not be read, so all rows cannot be exported."
    case .unsupportedEngine(let type):
      "\(type.rawValue) results cannot export all rows."
    }
  }
}

/// The read an all-rows export runs again and the result it must match
nonisolated struct ResultExportRequest: Sendable {
  /// The result's SQL: one read without `:name` parameters (checked again by the runner)
  var sql: String
  /// The result's columns: the read must answer the same names. The file is written with
  /// these (types, `masked` flags), not the read's.
  var columns: [ColumnInfo]
  var format: StreamedResultWriter.Format
  /// The unquoted table of a SQL INSERT export
  var schema: String? = nil
  var name: String? = nil
}

actor ResultExportRunner {
  /// Rows written between two progress reports and cancel checks
  static let batchRows = 1000

  private let tabManager: DatabaseConnectionManager
  private let connection: SnapshotExportConnection
  private let temporaryDirectory: URL

  /// `tabManager`: the tab's (its session state is read there; DuckDB exports on it). `config`:
  /// the tab's in-memory config. `material` and `sshCredential`: the tab manager's
  /// `activeUnrememberedCertificate` and `activeUnrememberedSSHCredential`.
  /// `sshHostKeyPrompt`: the prompt the tab's manager was built with.
  init(
    tabManager: DatabaseConnectionManager, config: ConnectionConfig,
    material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    sshHostKeyPrompt: any SSHHostKeyPrompt
  ) {
    self.init(
      tabManager: tabManager, config: config, material: material, sshCredential: sshCredential,
      ownManager: SnapshotExportConnection.ownManager(sshHostKeyPrompt: sshHostKeyPrompt),
      temporaryDirectory: FileManager.default.temporaryDirectory)
  }

  /// Tests: the export's sessions from `sessionFactory`, the temporary file in
  /// `temporaryDirectory`, locks from `lockSource`
  init(
    tabManager: DatabaseConnectionManager, config: ConnectionConfig,
    material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    sessionFactory: any DatabaseSessionFactory, temporaryDirectory: URL,
    lockSource: LockRegistry = .shared
  ) {
    self.init(
      tabManager: tabManager, config: config, material: material, sshCredential: sshCredential,
      ownManager: DatabaseConnectionManager(sessionFactory: sessionFactory, lockSource: lockSource),
      temporaryDirectory: temporaryDirectory)
  }

  private init(
    tabManager: DatabaseConnectionManager, config: ConnectionConfig,
    material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    ownManager: DatabaseConnectionManager, temporaryDirectory: URL
  ) {
    // DuckDB never through a second instance (an empty new `:memory:` or the file opened twice)
    let usesTabSession = config.databaseType == .duckdb
    self.tabManager = tabManager
    connection = SnapshotExportConnection(
      config: config, material: material, sshCredential: sshCredential,
      manager: usesTabSession ? tabManager : ownManager, usesTabSession: usesTabSession)
    self.temporaryDirectory = temporaryDirectory
  }

  /// Runs `request.sql` again and writes every row, each through `mask` (the connection's
  /// mask rules for the result's columns), to `destination` (an existing file is replaced).
  /// Returns the rows written. `hasStagedChanges`: the tab has staged edits not yet sent.
  /// `progress` gets the rows written so far after each batch and at the end.
  /// - Throws, before connecting: `ReadOnlyQueryGuard.Refusal` (not one read),
  ///   `ResultExportError` (parameters, user variables, open changes, temporary tables, another
  ///   role, sql_mode, unreadable state, MongoDB), `SQLDumpError.destinationIsDatabase`. On the snapshot:
  ///   `ResultExportError.columnsChanged`, `SQLDumpError.notRead`, connection and read errors,
  ///   `DatabaseError.connectionLocked` after a relock, `CancellationError` when the task is
  ///   cancelled. The destination is untouched then and the temporary file deleted.
  func write(
    _ request: ResultExportRequest, to destination: URL, hasStagedChanges: Bool,
    mask: @escaping @Sendable ([CellValue]) -> [CellValue],
    progress: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws -> Int {
    let config = connection.config
    let engine = config.databaseType
    if engine == .mongodb { throw ResultExportError.unsupportedEngine(engine) }
    let statement = try Self.checkedRead(request.sql, dialect: engine.dialect)
    if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
      throw SQLDumpError.destinationIsDatabase
    }
    let state = try await tabManager.resultExportSessionState(hasStagedChanges: hasStagedChanges)
    let temporary = temporaryDirectory.appendingPathComponent(
      "Dblore-export-\(UUID().uuidString).tmp")
    let connection = connection
    return try await connection.write(to: destination, through: temporary) { file in
      try await connection.manager.withDumpSnapshot(purpose: .resultExport(state)) { reader in
        try await Self.copy(
          statement, request: request, from: reader, to: file, dialect: engine.dialect,
          connection: connection, mask: mask, progress: progress)
      }
    }
  }

  /// The one statement of `sql`, refused unless `ReadOnlyQueryGuard` passes it and it has no
  /// `:name` parameter (nothing would bind it) or, on MySQL, `@name` user variable (the
  /// export's session has none of the tab's)
  nonisolated static func checkedRead(_ sql: String, dialect: SQLDialect) throws -> String {
    let statement = try ReadOnlyQueryGuard.check(sql, dialect: dialect)[0]
    guard SQLParameterRewriter.parameterNames(in: statement.text, dialect: dialect).isEmpty else {
      throw ResultExportError.parameters
    }
    if dialect == .mysql, usesUserVariables(statement.text) {
      throw ResultExportError.sessionVariables
    }
    return statement.text
  }

  /// MySQL: an `@` outside strings, comments and quoted identifiers that is not part of `@@`
  /// (a system variable): `@name`, `@'name'`, `` @`name` ``. Fails closed on any other lone `@`
  /// (`'user'@'host'`).
  private nonisolated static func usesUserVariables(_ sql: String) -> Bool {
    let tokens = SQLTokenizer.tokens(sql, dialect: .mysql)
    var index = 0
    while index < tokens.count {
      if tokens[index].isSymbol("@") {
        guard index + 1 < tokens.count, tokens[index + 1].isSymbol("@") else { return true }
        index += 2
      } else {
        index += 1
      }
    }
    return false
  }

  /// Reads `statement` on the snapshot and writes its rows, masked, in batches
  private nonisolated static func copy(
    _ statement: String, request: ResultExportRequest, from reader: DumpSnapshotReader,
    to file: FileHandle, dialect: SQLDialect, connection: SnapshotExportConnection,
    mask: @Sendable ([CellValue]) -> [CellValue], progress: @Sendable (Int) -> Void
  ) async throws -> Int {
    let source = try await reader.query(statement, binds: [])
    guard source.columns.map(\.name) == request.columns.map(\.name) else {
      throw ResultExportError.columnsChanged
    }
    let writer = StreamedResultWriter(
      format: request.format, columns: request.columns, dialect: dialect,
      schema: request.schema, name: request.name, fileHandle: file)
    var batch: [[CellValue]] = []
    batch.reserveCapacity(batchRows)
    var written = 0
    func flush() throws {
      try Task.checkCancellation()
      try connection.refuseIfRelocked()
      try writer.write(rows: batch)
      written += batch.count
      batch.removeAll(keepingCapacity: true)
      progress(written)
    }
    for try await row in source.rows {
      batch.append(mask(row))
      if batch.count == batchRows { try flush() }
    }
    // One report at the end, also for an empty read, never twice for the same count
    if !batch.isEmpty || written == 0 { try flush() }
    try writer.finish()
    return written
  }
}
