// SQLDumpWriter.swift
// Writes a SQL dump of a PostgreSQL, MySQL / MariaDB, SQLite or DuckDB database to a file, off
// the main actor. For PostgreSQL, MySQL and SQLite it connects its own
// `DatabaseConnectionManager` (never the tab's) from the tab's in-memory config with the tab's
// unremembered certificate and SSH secret. DuckDB is read on the tab's own manager and session
// (`init(tabManager:config:)`): a second instance would open an empty new `:memory:` database or
// the same file again. Everything is read inside one snapshot transaction (`withDumpSnapshot`),
// streamed to a temporary file in the container, then the destination is replaced with it.
// Cancel (task cancellation) interrupts the running read, rolls the snapshot back and deletes
// the temporary file. The temporary file is created mode 0600 and moved over the destination in
// one step (`replaceItem`).
//
// Dump format (restore reads it):
//   -- Dblore SQL dump 1 engine=<DatabaseType.rawValue> created=<ISO 8601, UTC>
//                                            (2 instead of 1 when the dump holds a DROP)
//   SET time_zone = '+00:00';               (MySQL)
//   SET NAMES utf8mb4;                       (MySQL)
//   SET SESSION sql_mode = ...;              (MySQL: no NO_BACKSLASH_ESCAPES, adds
//                                             NO_AUTO_VALUE_ON_ZERO)
//   -- comment lines                         (what the dump leaves out; line breaks in them
//                                             become spaces)
//   SET FOREIGN_KEY_CHECKS=0;                (MySQL, before the first CREATE TABLE)
//   pre-data DDL                             (SQLite: `PRAGMA defer_foreign_keys = ON;` first;
//                                             with Drop, the DROPs after the CREATE SCHEMA lines
//                                             or that PRAGMA)
//   INSERT INTO <table> (<columns>) [OVERRIDING SYSTEM VALUE] VALUES
//   (...),
//   (...);                                   (at most 500 rows and 4 MiB of SQL per INSERT)
//   SET FOREIGN_KEY_CHECKS=1;                (MySQL, after the last INSERT)
//   post-data DDL
// Every statement ends with `;` and a newline.

import Foundation

/// How far a dump is. `tableCount` counts the tables that hold rows.
nonisolated struct SQLDumpProgress: Sendable, Equatable {
  var tablesDone: Int
  var tableCount: Int
  var rowsWritten: Int
  /// `SQLDumpDDL.Script.foreignKeyCycle`: the INSERTs keep catalog order, so a restore into a
  /// database that has the tables may fail on foreign keys
  var foreignKeyCycle = false
}

/// What a dump holds. The default dumps every table with its structure and rows, without DROP.
nonisolated struct SQLDumpOptions: Sendable, Equatable {
  /// What the dump writes for one table
  struct TableOptions: Sendable, Equatable {
    /// CREATE TABLE with the table's indexes, constraints, triggers and sequence ownership.
    /// Off: the table adds no DDL (its INSERTs, `setval` and `sqlite_sequence` rows stay), so
    /// its rows restore into the database it came from.
    var structure = true
    /// INSERT statements
    var data = true
    /// DROP TABLE IF EXISTS before the table is created (with `structure` only)
    var drop = false
  }

  /// Tables to dump, by the catalog's schema (SQLite `main`, MySQL the database) and name; nil
  /// dumps every table. `SQLDumpSelection` adds what a chosen table cannot restore without.
  var tables: Set<SQLDumpDDL.ObjectName>? = nil
  /// Flags by table; a table without an entry has `otherTables`
  var perTable: [SQLDumpDDL.ObjectName: TableOptions] = [:]
  var otherTables = TableOptions()

  init(
    tables: Set<SQLDumpDDL.ObjectName>? = nil,
    perTable: [SQLDumpDDL.ObjectName: TableOptions] = [:],
    otherTables: TableOptions = TableOptions()
  ) {
    self.tables = tables
    self.perTable = perTable
    self.otherTables = otherTables
  }

  /// Every table with its structure, `includeData` as its Data flag, without DROP
  init(tables: Set<SQLDumpDDL.ObjectName>? = nil, includeData: Bool) {
    self.init(tables: tables, otherTables: TableOptions(data: includeData))
  }

  func table(_ name: SQLDumpDDL.ObjectName) -> TableOptions {
    perTable[name] ?? otherTables
  }

  func table(_ insert: SQLDumpDDL.TableInsert) -> TableOptions {
    table(SQLDumpDDL.ObjectName(schema: insert.schema, name: insert.name))
  }
}

/// Narrows a catalog read to the chosen tables, so the dump restores on its own: a partition
/// comes with its parent and a parent with its partitions; indexes, triggers, identity
/// sequences and views of tables left out go (a view goes when it reads a table or view that
/// went); a sequence owned by a table left out stays without its OWNED BY. Foreign keys are
/// kept as the catalog has them: a chosen table that references a table left out does not
/// restore (PostgreSQL post-data, SQLite at the first INSERT).
nonisolated enum SQLDumpSelection {
  typealias Name = SQLDumpDDL.ObjectName

  static func postgres(
    _ input: SQLDumpDDL.PostgresInput, keeping chosen: Set<Name>
  ) -> SQLDumpDDL.PostgresInput {
    func name(_ table: SQLDumpDDL.PostgresTable) -> Name {
      Name(schema: table.structure.schema, name: table.structure.name)
    }
    var kept = chosen
    var grew = true
    while grew {
      grew = false
      for table in input.tables {
        guard let parent = table.partitionOf?.parent else { continue }
        let child = name(table)
        if kept.contains(parent), kept.insert(child).inserted { grew = true }
        if kept.contains(child), kept.insert(parent).inserted { grew = true }
      }
    }
    let tables = input.tables.filter { kept.contains(name($0)) }
    let dropped = Set(input.tables.map(name)).subtracting(kept)
    var output = input
    output.tables = tables
    output.sequences = input.sequences.compactMap { sequence in
      guard let owner = sequence.ownedBy, dropped.contains(owner.table) else { return sequence }
      if sequence.isIdentity { return nil }
      var unowned = sequence
      unowned.ownedBy = nil
      return unowned
    }
    output.views = views(input.views, dropped: dropped)
    return output
  }

  static func mysql(
    _ input: SQLDumpDDL.MySQLInput, keeping chosen: Set<Name>
  ) -> SQLDumpDDL.MySQLInput {
    let names = input.tables.map { Name(schema: $0.structure.schema, name: $0.structure.name) }
    var output = input
    output.tables = zip(input.tables, names).filter { chosen.contains($0.1) }.map(\.0)
    output.views = views(input.views, dropped: Set(names).subtracting(chosen))
    return output
  }

  /// Compared by schema and name. Indexes of tables left out go. Views stay only when every
  /// table stays: the catalog keeps no view dependencies, and DuckDB resolves a view's names when
  /// it is created, so a view on a table left out would fail the whole restore. Schemas, ENUM
  /// types and sequences stay.
  static func duckdb(
    _ input: SQLDumpDDL.DuckDBInput, keeping chosen: Set<Name>
  ) -> SQLDumpDDL.DuckDBInput {
    var output = input
    output.tables = input.tables.filter {
      chosen.contains(Name(schema: $0.structure.schema, name: $0.structure.name))
    }
    output.indexes = input.indexes.filter {
      chosen.contains(Name(schema: $0.schema, name: $0.table))
    }
    if output.tables.count < input.tables.count { output.views = [] }
    return output
  }

  /// Compared by name (one `main` schema). Internal and shadow tables and views stay; a
  /// virtual table left out takes its shadow tables (`<name>_...`) along.
  static func sqlite(
    _ input: SQLDumpDDL.SQLiteInput, keeping chosen: Set<Name>
  ) -> SQLDumpDDL.SQLiteInput {
    let keptNames = Set(chosen.map(\.name))
    let dumped = Set(
      SQLDumpDDL.sqliteDumpedTableNames(input.masterRows, shadowTableNames: input.shadowTableNames))
    let virtual = Set(
      input.masterRows.filter { $0.type == "table" && isVirtual($0.sql) }.map(\.name))
    let dropped = dumped.union(virtual).subtracting(keptNames)
    let droppedVirtual = virtual.subtracting(keptNames)
    var output = input
    output.masterRows = input.masterRows.filter { row in
      switch row.type {
      case "table":
        if dumped.contains(row.name) || virtual.contains(row.name) {
          return keptNames.contains(row.name)
        }
        return input.shadowTableNames != nil
          || !droppedVirtual.contains { row.name.hasPrefix($0 + "_") }
      case "view": return true
      default: return !dropped.contains(row.tableName)
      }
    }
    output.structures = input.structures.filter { keptNames.contains($0.name) }
    return output
  }

  /// `CREATE VIRTUAL TABLE`, any case and spacing
  private static func isVirtual(_ sql: String?) -> Bool {
    let words = (sql ?? "").split(whereSeparator: \.isWhitespace).prefix(2).map { $0.uppercased() }
    return words == ["CREATE", "VIRTUAL"]
  }

  /// Views whose dependencies were not dropped, repeated until no more views go
  private static func views(_ views: [SQLDumpDDL.View], dropped: Set<Name>) -> [SQLDumpDDL.View] {
    var gone = dropped
    var kept = views
    while let index = kept.firstIndex(where: { $0.dependsOn.contains(where: gone.contains) }) {
      gone.insert(Name(schema: kept[index].schema, name: kept[index].name))
      kept.remove(at: index)
    }
    return kept
  }
}

/// Builds the text of a dump from the DDL script and the rows' literals. Pure: the writer
/// appends what it returns to the file.
nonisolated struct SQLDumpAssembler {
  let engine: DatabaseType
  var maxRows = SQLDumpWriter.maxBatchRows
  var maxBytes = SQLDumpWriter.maxBatchBytes

  private var table: SQLDumpDDL.TableInsert?
  private var prefix = ""
  private var pending: [String] = []
  /// UTF-8 size of the pending statement: prefix, rows, `,\n` between rows, `;`
  private var pendingBytes = 0

  init(
    engine: DatabaseType, maxRows: Int = SQLDumpWriter.maxBatchRows,
    maxBytes: Int = SQLDumpWriter.maxBatchBytes
  ) {
    self.engine = engine
    self.maxRows = maxRows
    self.maxBytes = maxBytes
  }

  /// `-- Dblore SQL dump 1 engine=PostgreSQL created=2026-10-15T12:00:00Z`; version 2 when the
  /// dump holds a DROP (a reader that knows only 1 refuses it at the header)
  static func header(engine: DatabaseType, created: Date, version: Int = 1) -> String {
    "-- Dblore SQL dump \(version) engine=\(engine.rawValue) created="
      + created.formatted(.iso8601)
  }

  /// MySQL restore session: the dump's literals double `\` and `'`, so `NO_BACKSLASH_ESCAPES`
  /// goes; `NO_AUTO_VALUE_ON_ZERO` keeps a 0 in an AUTO_INCREMENT column. No backslash in it:
  /// it is read under whatever mode the restore session has.
  static let mysqlSessionSettings = [
    "SET time_zone = '+00:00';", "SET NAMES utf8mb4;",
    "SET SESSION sql_mode = TRIM(BOTH ',' FROM CONCAT(REPLACE(CONCAT(',', @@SESSION.sql_mode, ','),"
      + " ',NO_BACKSLASH_ESCAPES,', ','), 'NO_AUTO_VALUE_ON_ZERO'));",
  ]

  /// Header, session settings, comment lines and pre-data
  func opening(_ script: SQLDumpDDL.Script, created: Date) -> String {
    var lines = [
      Self.header(engine: engine, created: created, version: script.containsDrop ? 2 : 1)
    ]
    if engine == .mysql { lines += Self.mysqlSessionSettings }
    lines += script.comment.map(Self.commentLine)
    if engine == .mysql { lines.append("SET FOREIGN_KEY_CHECKS=0;") }
    lines += script.preData
    return lines.map { $0 + "\n" }.joined()
  }

  /// `line` as one `-- ` comment line: every line terminator (CR, LF, VT, FF, NEL, U+2028,
  /// U+2029) becomes a space, so text from the database (an object name) cannot end the
  /// comment and start a statement
  static func commentLine(_ line: String) -> String {
    let scalars = line.unicodeScalars.map {
      CharacterSet.newlines.contains($0) ? " " as Unicode.Scalar : $0
    }
    let text = String(String.UnicodeScalarView(scalars))
    return text.hasPrefix("-- ") ? text : "-- " + text
  }

  /// Foreign key checks back on (MySQL) and post-data
  func closing(_ script: SQLDumpDDL.Script) -> String {
    let lines = (engine == .mysql ? ["SET FOREIGN_KEY_CHECKS=1;"] : []) + script.postData
    return lines.map { $0 + "\n" }.joined()
  }

  /// Starts the INSERTs of `table` (call `finish` before the next table)
  mutating func begin(_ table: SQLDumpDDL.TableInsert) throws {
    self.table = table
    let columns = try table.columns.map { try engine.dialect.quoteIdentifier($0.name) }
    prefix =
      "INSERT INTO \(table.target) (\(columns.joined(separator: ", ")))"
      + (table.overridingSystemValue ? " OVERRIDING SYSTEM VALUE" : "") + " VALUES\n"
    pending = []
    pendingBytes = 0
  }

  /// Adds one row of literals. Returns the INSERT that had to be completed first (500 rows, or
  /// this row would pass 4 MiB), if any. A table without insertable columns gets one
  /// `INSERT ... DEFAULT VALUES` per row.
  mutating func append(_ literals: [String]) -> String? {
    guard let table else { return nil }
    if table.columns.isEmpty { return "INSERT INTO \(table.target) DEFAULT VALUES;\n" }
    let row = "(" + literals.joined(separator: ", ") + ")"
    let rowBytes = row.utf8.count
    var flushed: String?
    if !pending.isEmpty, pending.count >= maxRows || pendingBytes + 2 + rowBytes > maxBytes {
      flushed = finish()
    }
    if pending.isEmpty {
      pendingBytes = prefix.utf8.count + rowBytes + 1
    } else {
      pendingBytes += 2 + rowBytes
    }
    pending.append(row)
    return flushed
  }

  /// The pending INSERT, if any
  mutating func finish() -> String? {
    guard !pending.isEmpty else { return nil }
    let statement = prefix + pending.joined(separator: ",\n") + ";\n"
    pending = []
    pendingBytes = 0
    return statement
  }
}

/// The app's session factory, except that SQLite opens read-only with normal locking
/// (`SQLiteSession` `snapshotReadOnly`): an `immutable=1` open would miss rows still in the WAL.
nonisolated struct SQLDumpSessionFactory: DatabaseSessionFactory {
  let inner: any DatabaseSessionFactory

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    try await makeSession(config: config, extraAllowedPaths: [])
  }

  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    if config.databaseType == .sqlite {
      return SQLiteSession(config: config, snapshotReadOnly: true)
    }
    return try await inner.makeSession(config: config, extraAllowedPaths: extraAllowedPaths)
  }
}

/// The connection and file steps a snapshot export shares (the SQL dump, `ResultExportRunner`):
/// a manager of its own connected from the tab's in-memory config with the tab's unremembered
/// certificate and SSH secret (SQLite opened read-only), or the tab's own manager for DuckDB
/// (never connected or disconnected here), and a private temporary file moved over the
/// destination only once it is whole.
nonisolated struct SnapshotExportConnection: Sendable {
  /// The tab's in-memory config (with its password)
  let config: ConnectionConfig
  let material: ClientCertificateStoreFactory.ConnectionMaterial?
  let sshCredential: SSHCredentialStoreFactory.ConnectionCredential?
  let manager: DatabaseConnectionManager
  /// `manager` is the tab's (DuckDB)
  let usesTabSession: Bool

  /// A manager of the export's own with the app's sessions (`SQLDumpSessionFactory`).
  /// `sshHostKeyPrompt`: the prompt the tab's manager was built with.
  static func ownManager(sshHostKeyPrompt: any SSHHostKeyPrompt) -> DatabaseConnectionManager {
    let factory = SQLDumpSessionFactory(
      inner: AppDatabaseSessionFactory(
        hostKeyValidator: SSHHostKeyPolicy(prompt: sshHostKeyPrompt)))
    return DatabaseConnectionManager(sessionFactory: factory, sshHostKeyPrompt: sshHostKeyPrompt)
  }

  /// A relock (the manager's `lockSource`) stops a long export before its next batch
  func refuseIfRelocked() throws {
    if let refusal = manager.lockSource.refusal(for: config) { throw refusal }
  }

  /// Creates `temporary` (mode 0600), connects, runs `body` with the open file, then closes the
  /// file and disconnects on every path. Afterwards `destination` is replaced with the file,
  /// unless the task was cancelled, the destination became the database or the identity was
  /// relocked meanwhile.
  /// - Throws: what `body` and the connect throw, `SQLDumpError.destinationIsDatabase`,
  ///   `DatabaseError.connectionLocked`, `CancellationError` when the task is cancelled. The
  ///   temporary file is deleted then and `destination` is untouched.
  func write<T: Sendable>(
    to destination: URL, through temporary: URL, _ body: (FileHandle) async throws -> T
  ) async throws -> T {
    let file = FileHandle(
      fileDescriptor: try SQLDumpWriter.createPrivateFile(at: temporary), closeOnDealloc: true)
    // Nil once closed
    var output: FileHandle? = file
    var connectConfig = config
    if config.databaseType == .sqlite { connectConfig.readOnlyFile = true }
    do {
      if !usesTabSession {
        try await manager.reconnectWithActiveCertificate(
          config: connectConfig, material: material, sshCredential: sshCredential)
      }
      let result = try await body(file)
      output = nil
      try file.close()
      if !usesTabSession { await manager.disconnect() }
      try Task.checkCancellation()
      // The path may have become a link to the database while the export ran
      if SQLDumpWriter.isConnectedDatabaseFile(destination, config: config) {
        throw SQLDumpError.destinationIsDatabase
      }
      try refuseIfRelocked()
      try SQLDumpWriter.replaceItem(at: destination, withItemAt: temporary)
      return result
    } catch {
      try? output?.close()
      if !usesTabSession { await manager.disconnect() }
      try? FileManager.default.removeItem(at: temporary)
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}

actor SQLDumpWriter {
  /// Rows per INSERT statement
  static let maxBatchRows = 500
  /// SQL bytes per INSERT statement (MariaDB's default `max_allowed_packet` is 16 MiB)
  static let maxBatchBytes = 4 * 1024 * 1024

  /// Its manager is the tab's for DuckDB: never reconnected or disconnected here
  private let connection: SnapshotExportConnection
  private var config: ConnectionConfig { connection.config }
  private var manager: DatabaseConnectionManager { connection.manager }
  private var usesTabSession: Bool { connection.usesTabSession }
  private let temporaryDirectory: URL
  private var output: FileHandle?

  /// `config`: the tab's in-memory config (with its password). `material` and `sshCredential`:
  /// the tab manager's `activeUnrememberedCertificate` and `activeUnrememberedSSHCredential`.
  /// `sshHostKeyPrompt`: the prompt the tab's manager was built with.
  init(
    config: ConnectionConfig, material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    sshHostKeyPrompt: any SSHHostKeyPrompt
  ) {
    self.init(
      config: config, material: material, sshCredential: sshCredential,
      manager: SnapshotExportConnection.ownManager(sshHostKeyPrompt: sshHostKeyPrompt),
      temporaryDirectory: FileManager.default.temporaryDirectory)
  }

  /// Tests: sessions from `sessionFactory`, the temporary file in `temporaryDirectory`, locks
  /// from `lockSource`
  init(
    config: ConnectionConfig, material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    sessionFactory: any DatabaseSessionFactory, temporaryDirectory: URL,
    lockSource: LockRegistry = .shared
  ) {
    self.init(
      config: config, material: material, sshCredential: sshCredential,
      manager: DatabaseConnectionManager(sessionFactory: sessionFactory, lockSource: lockSource),
      temporaryDirectory: temporaryDirectory)
  }

  /// DuckDB: dumps on `tabManager`'s connected session. `config`: the tab's in-memory config.
  init(
    tabManager: DatabaseConnectionManager, config: ConnectionConfig,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.init(
      config: config, material: nil, sshCredential: nil, manager: tabManager,
      usesTabSession: true, temporaryDirectory: temporaryDirectory)
  }

  private init(
    config: ConnectionConfig, material: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?,
    manager: DatabaseConnectionManager, usesTabSession: Bool = false, temporaryDirectory: URL
  ) {
    connection = SnapshotExportConnection(
      config: config, material: material, sshCredential: sshCredential, manager: manager,
      usesTabSession: usesTabSession)
    self.temporaryDirectory = temporaryDirectory
  }

  /// True when `url` resolves (standardized, symlinks resolved, case-insensitive) to the
  /// connected SQLite file or its `-wal`, `-journal` or `-shm` file, or to the connected DuckDB
  /// file or its `.wal` file
  nonisolated static func isConnectedDatabaseFile(_ url: URL, config: ConnectionConfig) -> Bool {
    let sidecars: [String]
    switch config.databaseType {
    case .sqlite: sidecars = SQLiteFileAccess.sidecarSuffixes
    case .duckdb where config.database != DuckDBSession.inMemoryPath:
      sidecars = SQLiteFileAccess.duckDBSidecarSuffixes
    case .duckdb, .postgresql, .mysql, .mongodb, .clickhouse, .sqlserver: return false
    }
    guard !config.database.isEmpty else { return false }
    let database = resolvedPath(URL(fileURLWithPath: config.database)).lowercased()
    let target = resolvedPath(url).lowercased()
    return ([""] + sidecars).contains { target == database + $0 }
  }

  /// `realpath` of the file, or of its folder plus the name when the file does not exist
  private nonisolated static func resolvedPath(_ url: URL) -> String {
    let standardized = url.standardizedFileURL
    if let real = realPath(standardized.path) { return real }
    let folder = standardized.deletingLastPathComponent().path
    return (realPath(folder) ?? folder) + "/" + standardized.lastPathComponent
  }

  private nonisolated static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Creates a new file at `url` that only its owner can read and write (mode 0600, never an
  /// existing file) and returns its open descriptor
  nonisolated static func createPrivateFile(at url: URL) throws -> Int32 {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSURLErrorKey: url])
    }
    return descriptor
  }

  /// Puts `temporary` at `destination` in one step (`replaceItemAt`): `destination` is the old
  /// file or the new one, never missing or half written. An existing destination keeps its
  /// permissions; a new one gets the temporary file's. Across volumes (`EXDEV`) the file is
  /// first copied next to the destination (`itemReplacementDirectory` on its volume). On
  /// failure the destination is untouched.
  nonisolated static func replaceItem(at destination: URL, withItemAt temporary: URL) throws {
    let files = FileManager.default
    do {
      _ = try files.replaceItemAt(destination, withItemAt: temporary)
      return
    } catch let error where isCrossDevice(error) {}
    let staging = try files.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
      create: true)
    defer { try? files.removeItem(at: staging) }
    let staged = staging.appendingPathComponent(destination.lastPathComponent)
    try files.copyItem(at: temporary, to: staged)
    _ = try files.replaceItemAt(destination, withItemAt: staged)
    try? files.removeItem(at: temporary)
  }

  /// `EXDEV` anywhere in the error's underlying chain
  private nonisolated static func isCrossDevice(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let error = current {
      if error.domain == NSPOSIXErrorDomain, error.code == Int(EXDEV) { return true }
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }

  /// Dumps the database to `destination` (an existing file is replaced) and returns the final
  /// progress. `options` picks tables and their Structure, Data and Drop. `progress` is called on this actor after
  /// each INSERT statement and table.
  /// - Throws: `SQLDumpError` (refused destination or engine), connection and read errors,
  ///   `DatabaseError.connectionLocked` after a relock, `CancellationError` when the task is
  ///   cancelled. Nothing is left at `destination` then, and the temporary file is deleted.
  func write(
    to destination: URL, options: SQLDumpOptions = SQLDumpOptions(),
    progress: @escaping @Sendable (SQLDumpProgress) -> Void = { _ in }
  ) async throws -> SQLDumpProgress {
    let engine = config.databaseType
    switch engine {
    case .postgresql, .mysql, .sqlite:
      guard !usesTabSession else { throw SQLDumpError.unsupportedEngine(engine) }
    case .duckdb:
      // Never through a second instance (see the file header)
      guard usesTabSession else { throw SQLDumpError.unsupportedEngine(engine) }
    case .mongodb, .clickhouse, .sqlserver:
      throw SQLDumpError.unsupportedEngine(engine)
    }
    if Self.isConnectedDatabaseFile(destination, config: config) {
      throw SQLDumpError.destinationIsDatabase
    }
    let temporary = temporaryDirectory.appendingPathComponent(
      "Dblore-dump-\(UUID().uuidString).sql")
    return try await connection.write(to: destination, through: temporary) { handle in
      output = handle
      defer { output = nil }
      return try await manager.withDumpSnapshot { reader in
        try await self.dump(reader, engine: engine, options: options, progress: progress)
      }
    }
  }

  /// A relock (the manager's `lockSource`) stops a long dump before its next table or batch
  private func refuseIfRelocked() throws {
    try connection.refuseIfRelocked()
  }

  private func emit(_ text: String) throws {
    guard let output else { throw CancellationError() }
    try output.write(contentsOf: Data(text.utf8))
  }

  private func dump(
    _ reader: DumpSnapshotReader, engine: DatabaseType, options: SQLDumpOptions,
    progress: @Sendable (SQLDumpProgress) -> Void
  ) async throws -> SQLDumpProgress {
    let script: SQLDumpDDL.Script
    let chosen = options.tables
    switch engine {
    case .postgresql:
      let input = try await SQLDumpCatalog.postgresInput(reader)
      script = try SQLDumpDDL.postgres(
        chosen.map { SQLDumpSelection.postgres(input, keeping: $0) } ?? input, options: options)
    case .mysql:
      let input = try await SQLDumpCatalog.mysqlInput(reader)
      script = try SQLDumpDDL.mysql(
        chosen.map { SQLDumpSelection.mysql(input, keeping: $0) } ?? input, options: options)
    case .sqlite:
      let input = try await SQLDumpCatalog.sqliteInput(reader)
      script = try SQLDumpDDL.sqlite(
        chosen.map { SQLDumpSelection.sqlite(input, keeping: $0) } ?? input, options: options)
    case .duckdb:
      let input = try await SQLDumpCatalog.duckdbInput(reader)
      script = try SQLDumpDDL.duckdb(
        chosen.map { SQLDumpSelection.duckdb(input, keeping: $0) } ?? input, options: options)
    case .mongodb, .clickhouse, .sqlserver:
      throw SQLDumpError.unsupportedEngine(engine)
    }
    var assembler = SQLDumpAssembler(engine: engine)
    let dataTables = script.tables.filter(\.hasData)
    let tables = dataTables.filter { options.table($0).data }
    var state = SQLDumpProgress(
      tablesDone: 0, tableCount: tables.count, rowsWritten: 0,
      foreignKeyCycle: script.foreignKeyCycle)
    try emit(assembler.opening(script, created: Date()))
    for table in tables {
      try Task.checkCancellation()
      try refuseIfRelocked()
      try assembler.begin(table)
      let source = try await reader.query(
        SQLDumpDataRenderer.selectStatement(table, engine: engine), binds: [])
      var pendingRows = 0
      for try await row in source.rows {
        let literals = try zip(row, table.columns).map { value, column in
          try SQLDumpDataRenderer.literal(
            value, column: column, table: table.name, engine: engine)
        }
        if let statement = assembler.append(literals) {
          try Task.checkCancellation()
          try refuseIfRelocked()
          try emit(statement)
          state.rowsWritten += pendingRows
          pendingRows = 0
          progress(state)
        }
        pendingRows += 1
      }
      if let statement = assembler.finish() {
        try refuseIfRelocked()
        try emit(statement)
      }
      state.rowsWritten += pendingRows
      state.tablesDone += 1
      progress(state)
    }
    try emit(assembler.closing(script))
    // Schema only: every table was written without rows (the result reads "n tables, 0 rows")
    if tables.isEmpty {
      state = SQLDumpProgress(
        tablesDone: dataTables.count, tableCount: dataTables.count, rowsWritten: 0,
        foreignKeyCycle: script.foreignKeyCycle)
    }
    return state
  }
}
