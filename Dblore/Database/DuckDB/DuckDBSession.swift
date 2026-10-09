// DuckDBSession.swift
// One DuckDB database (file or in-memory) through the dlopen'd C API. Every DuckDB call except
// `duckdb_interrupt` runs on one serial dispatch queue, including loading the ~117 MB plugin, so
// neither the main thread nor the cooperative pool waits on it. Binds use `$1`… and never enter
// SQL text. Reads stream one data chunk at a time; dropping the row stream stops the read. A new
// statement on the session ends an open read, whose next row then throws.
//
// Hardening, applied before any user SQL (the hard boundary behind the classifier's best-effort
// DuckDB rules):
// - extensions: autoinstall and autoload off, community extensions off; the extension and
//   secret directories live in the app container (owner-only) and are not readable from SQL, so
//   INSTALL and LOAD fail;
// - file access: `enable_external_access=false`, with `allowed_paths` set to `extraAllowedPaths`
//   only (files the user picked, task 16.4) and no directory grant. A folder grant would allow
//   writes too (COPY TO, EXPORT DATABASE, ATTACH + DML), even on a READ_ONLY database, since
//   `access_mode` only protects the catalog. The engine's own database and WAL I/O does not go
//   through this check, so the database file needs no grant. This blocks URLs (https, s3,
//   runtime-built strings), COPY TO, EXPORT, ATTACH and reads of any other file, siblings of the
//   database included. Decision vs 16.4: user-picked Parquet/CSV files stay readable because
//   they go into `allowed_paths` when the session opens. `lock_configuration` freezes that list,
//   so picking a new file needs a new session. The app sandbox stays the outer boundary.
//   Gap, closed at the actor: DuckDB itself allows SQL file I/O on the database file and its `.wal`, so
//   `COPY ... TO '<db>.wal'` (or `'<db>'` with `USE_TMP_FILE false`) passes even read-only. The
//   actor is the stop: COPY is a utility statement, refused on a Read-only connection, and a
//   `readOnlyFile` DuckDB connection gates as Read-only (`ProtectionPolicy.init(config:)`);
// - writes: `access_mode=READ_ONLY` when the file is opened read-only (`readOnlyFile`, the
//   SQLite rule) or the connection is Read-only protected. In-memory databases cannot open
//   read-only; the actor's gate still applies to them;
// - `lock_configuration=true` last, so later SQL cannot undo any of this.

import Foundation

/// A DuckDB error message (`duckdb_result_error`, `duckdb_prepare_error`, …). Never contains binds.
nonisolated struct DuckDBSessionError: Error, Equatable, Sendable, LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// Releases a read when the row stream is released, including when the caller stops early.
private nonisolated final class DuckDBReadLifetime: @unchecked Sendable {
  let id: UUID
  private let cancel: @Sendable () -> Void

  init(id: UUID, cancel: @escaping @Sendable () -> Void) {
    self.id = id
    self.cancel = cancel
  }

  deinit { cancel() }
}

nonisolated final class DuckDBSession: DatabaseSession, @unchecked Sendable {
  /// `config.database` value that opens an in-memory database.
  static let inMemoryPath = ":memory:"

  let capabilities: DatabaseCapabilities
  let closeEvents: AsyncStream<SessionCloseReason>

  private let config: ConnectionConfig
  private let extraAllowedPaths: [String]
  private let loadLibrary: @Sendable () throws -> DuckDBLibrary
  private let executor: DispatchSerialQueue
  private let watchdog = DispatchQueue(label: "dblore.duckdb.watchdog")
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation
  /// Guards `handles`, `didEmitClose`, the watchdog state, and `timedOut`.
  private let stateLock = NSLock()
  private var handles: Handles?
  private var didEmitClose = false
  private var watchToken: UInt64 = 0
  private var activeWatch: (token: UInt64, item: DispatchWorkItem)?
  private var timedOut = false
  /// Queue-only state.
  private var statementTimeoutSeconds: Int
  private var reads: [UUID: ReadState] = [:]
  /// Reads a later statement released before it ran; their next row throws `interruptedError`.
  private var interrupted: Set<UUID> = []
  private var tempDirectory: URL?

  private static let cursorError = DuckDBSessionError(
    message: "DuckDB does not support server cursors")
  private static let closedError = DuckDBSessionError(message: "database is closed")
  private static let interruptedError = DuckDBSessionError(
    message: "result was interrupted by another query on this DuckDB connection; re-run it")
  /// How often the watchdog repeats `duckdb_interrupt` after the deadline, in case the first one
  /// landed before DuckDB started the statement.
  private static let reinterruptInterval: TimeInterval = 0.1

  /// `loadLibrary` runs on the session queue during `open()` (it hashes and verifies the plugin).
  /// `extraAllowedPaths` are the only absolute file paths SQL may read (user-picked files).
  init(
    config: ConnectionConfig, extraAllowedPaths: [String] = [],
    loadLibrary: @escaping @Sendable () throws -> DuckDBLibrary
  ) {
    self.config = config
    self.extraAllowedPaths = extraAllowedPaths
    self.loadLibrary = loadLibrary
    capabilities = config.databaseType.capabilities
    statementTimeoutSeconds =
      config.statementTimeoutSeconds ?? SessionBrakeLimits.defaultStatementTimeout
    executor = DispatchSerialQueue(label: "dblore.duckdb.session.\(UUID().uuidString)")
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    let open = withState { () -> Handles? in
      let open = handles
      handles = nil
      activeWatch?.item.cancel()
      activeWatch = nil
      return open
    }
    if let open {
      open.library.interrupt(open.connection)
      for read in reads.values { read.release(open.library) }
      var connection: OpaquePointer? = open.connection
      var database: OpaquePointer? = open.database
      open.library.disconnect(&connection)
      open.library.close(&database)
    }
    if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
    let finished = withState { didEmitClose }
    if !finished { closeContinuation.finish() }
  }

  func open() async throws {
    try await run { try self.openOnQueue() }
  }

  func close() async {
    emit(.closedByApp)
    interruptNow()
    await run { self.closeOnQueue() }
  }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let prepared = try await run { try self.startRead(sql, binds: binds) }
    // The stream keeps this alive. Dropping it (a capped read stops early) releases the result
    // and leaves the connection open.
    let lifetime = DuckDBReadLifetime(id: prepared.id) {
      self.executor.async { self.finishRead(prepared.id) }
    }
    let rows = AsyncThrowingStream<[CellValue], Error> { [lifetime] in
      try await self.nextRow(lifetime.id)
    }
    return SessionRowSource(columns: prepared.columns, rows: rows)
  }

  /// Materializes the result (`duckdb_execute_prepared`) and reports `duckdb_rows_changed`.
  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await run {
      let open = try self.requireOpen()
      self.interruptReads(open)
      var statement = try self.prepare(sql, open)
      defer { open.library.destroyPrepare(&statement) }
      try self.bind(statement, binds, open)
      var result = DuckDBResult()
      defer { open.library.destroyResult(&result) }
      let deadline = self.deadline()
      let state = self.guarded(until: deadline, open) {
        open.library.executePrepared(statement, &result)
      }
      if state != DuckDBState.success {
        throw self.error(open.library.resultError(&result), fallback: "statement failed")
      }
      let changed = Int(exactly: open.library.rowsChanged(&result)) ?? 0
      return CommandResult(affectedRows: changed, tag: Self.commandTag(sql))
    }
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    _ = sql
    _ = binds
    throw Self.cursorError
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    _ = cursor
    _ = maxRows
    throw Self.cursorError
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    _ = cursor
    throw Self.cursorError
  }

  /// DuckDB has no lock or idle brake. The statement timeout is the watchdog's deadline.
  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    _ = lockTimeoutSeconds
    _ = idleTimeoutSeconds
    await run { self.statementTimeoutSeconds = statementTimeoutSeconds }
  }

  /// `duckdb_interrupt` from the calling thread: the serial queue is blocked in the call this
  /// is meant to stop.
  func interrupt() async {
    interruptNow()
  }

  func formatError(_ error: Error) -> String {
    if let error = error as? DuckDBSessionError { return error.message }
    return error.localizedDescription
  }

  // MARK: - Open / close

  private func openOnQueue() throws {
    if withState({ handles }) != nil {
      throw DuckDBSessionError(message: "database is already open")
    }
    let path = config.database
    if path.isEmpty { throw DuckDBSessionError(message: "database path is empty") }
    let inMemory = path == Self.inMemoryPath
    let library: DuckDBLibrary
    do {
      library = try loadLibrary()
    } catch {
      throw DuckDBSessionError(message: "DuckDB plugin could not be loaded: \(error)")
    }
    let directories = try Self.containerDirectories()
    tempDirectory = directories.temp
    var database: OpaquePointer?
    var connection: OpaquePointer?
    do {
      try openDatabase(
        library, path: inMemory ? nil : path, readOnly: !inMemory && isReadOnly,
        directories: directories, into: &database)
      guard library.connect(database, &connection) == DuckDBState.success else {
        library.close(&database)
        throw DuckDBSessionError(message: "unable to connect to the database")
      }
    } catch {
      try? FileManager.default.removeItem(at: directories.temp)
      tempDirectory = nil
      throw error
    }
    let open = Handles(library: library, database: database, connection: connection)
    withState { handles = open }
    do {
      for statement in hardeningStatements() {
        try exec(statement, open)
      }
    } catch {
      closeOnQueue()
      throw error
    }
  }

  /// `readOnlyFile` (the file is opened without writing) or a Read-only protected connection.
  private var isReadOnly: Bool {
    config.readOnlyFile || config.protectionLevel == .readOnly
  }

  private func openDatabase(
    _ library: DuckDBLibrary, path: String?, readOnly: Bool, directories: Directories,
    into database: inout OpaquePointer?
  ) throws {
    var options = [
      ("autoinstall_known_extensions", "false"),
      ("autoload_known_extensions", "false"),
      ("allow_community_extensions", "false"),
      ("allow_unsigned_extensions", "false"),
      ("allow_persistent_secrets", "false"),
      ("temp_directory", directories.temp.path),
      ("extension_directory", directories.extensions.path),
      ("secret_directory", directories.secrets.path),
    ]
    if readOnly { options.append(("access_mode", "READ_ONLY")) }
    var config: OpaquePointer?
    guard library.createConfig(&config) == DuckDBState.success else {
      throw DuckDBSessionError(message: "unable to create the DuckDB configuration")
    }
    defer { library.destroyConfig(&config) }
    for (name, value) in options {
      guard library.setConfig(config, name, value) == DuckDBState.success else {
        throw DuckDBSessionError(message: "unable to set DuckDB option \(name)")
      }
    }
    var message: UnsafeMutablePointer<CChar>?
    guard library.openExt(path, &database, config, &message) == DuckDBState.success else {
      let text = message.map { String(cString: $0) } ?? "unable to open database"
      library.free(message)
      throw DuckDBSessionError(message: text)
    }
  }

  /// Run on the connection before any user SQL. `allowed_paths` must be set while external
  /// access is still on; `lock_configuration` comes last.
  private func hardeningStatements() -> [String] {
    var statements: [String] = []
    if !extraAllowedPaths.isEmpty {
      statements.append("SET allowed_paths = \(Self.listLiteral(extraAllowedPaths))")
    }
    statements.append("SET enable_external_access = false")
    statements.append("SET lock_configuration = true")
    return statements
  }

  private static func listLiteral(_ values: [String]) -> String {
    "["
      + values.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
      .joined(separator: ", ") + "]"
  }

  /// Temp (per session, removed on close), extension and secret directories in the container,
  /// owner-only (0700), including ones an earlier version created with wider permissions.
  private static func containerDirectories() throws -> Directories {
    let manager = FileManager.default
    guard
      let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
      let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { throw DuckDBSessionError(message: "app container directories are unavailable") }
    let root = support.appendingPathComponent("Dblore/DuckDB", isDirectory: true)
    let directories = Directories(
      temp: caches.appendingPathComponent(
        "Dblore/DuckDB/tmp/\(UUID().uuidString)", isDirectory: true),
      extensions: root.appendingPathComponent("extensions", isDirectory: true),
      secrets: root.appendingPathComponent("secrets", isDirectory: true))
    do {
      for url in [directories.temp, directories.extensions, directories.secrets] {
        try manager.createDirectory(
          at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      }
    } catch {
      try? manager.removeItem(at: directories.temp)
      throw DuckDBSessionError(
        message: "unable to create DuckDB directories: \(error.localizedDescription)")
    }
    return directories
  }

  private func closeOnQueue() {
    for id in Array(reads.keys) { finishRead(id) }
    interrupted.removeAll()
    let open = withState { () -> Handles? in
      let open = handles
      handles = nil
      return open
    }
    if let open {
      var connection: OpaquePointer? = open.connection
      var database: OpaquePointer? = open.database
      open.library.disconnect(&connection)
      open.library.close(&database)
    }
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
      self.tempDirectory = nil
    }
  }

  // MARK: - Statements

  private func startRead(_ sql: String, binds: [SQLBindValue]) throws -> PreparedRead {
    let open = try requireOpen()
    interruptReads(open)
    let library = open.library
    let read = ReadState()
    do {
      read.statement = try prepare(sql, open)
      try bind(read.statement, binds, open)
      if library.pendingPreparedStreaming(read.statement, &read.pending) != DuckDBState.success {
        throw error(library.pendingError(read.pending), fallback: "statement failed")
      }
      read.deadline = deadline()
      // duckdb_destroy_result is required even when execution fails.
      read.hasResult = true
      let state = guarded(until: read.deadline, open) {
        library.executePending(read.pending, read.result)
      }
      if state != DuckDBState.success {
        throw error(library.resultError(read.result), fallback: "statement failed")
      }
    } catch {
      read.release(library)
      throw error
    }
    let mapping = DuckDBValueMapping(library: library)
    let count = library.columnCount(read.result)
    var columns: [ColumnInfo] = []
    for index in 0..<count {
      let type = mapping.node(consuming: library.columnLogicalType(read.result, index))
      read.types.append(type)
      let name = library.columnName(read.result, index).map { String(cString: $0) } ?? ""
      columns.append(ColumnInfo(name: name, type: type.name))
    }
    let id = UUID()
    reads[id] = read
    return PreparedRead(id: id, columns: columns)
  }

  private func nextRow(_ id: UUID) async throws -> [CellValue]? {
    try await run {
      if self.interrupted.remove(id) != nil { throw Self.interruptedError }
      guard let read = self.reads[id] else { return nil }
      while read.buffered.isEmpty {
        guard let open = self.withState({ self.handles }) else {
          self.finishRead(id)
          throw Self.closedError
        }
        guard ContinuousClock.now < read.deadline else {
          self.finishRead(id)
          throw DuckDBSessionError(message: "statement timed out")
        }
        var copy = read.result.pointee
        var chunk = self.guarded(until: read.deadline, open) {
          open.library.fetchChunk(&copy)
        }
        guard chunk != nil else {
          let failure = open.library.resultError(read.result).map {
            self.error($0, fallback: "")
          }
          self.finishRead(id)
          if let failure { throw failure }
          return nil
        }
        let rows = DuckDBValueMapping(library: open.library).rows(chunk: chunk, types: read.types)
        open.library.destroyDataChunk(&chunk)
        read.buffered = rows.reversed()
      }
      return read.buffered.removeLast()
    }
  }

  /// A DuckDB connection holds one open result: preparing another statement closes it, and a
  /// later fetch on it fails. Release open reads first, so no fetch touches a closed result.
  private func interruptReads(_ open: Handles) {
    for (id, read) in reads {
      read.release(open.library)
      interrupted.insert(id)
    }
    reads.removeAll()
  }

  private func finishRead(_ id: UUID) {
    interrupted.remove(id)
    guard let read = reads.removeValue(forKey: id) else { return }
    if let open = withState({ handles }) { read.release(open.library) }
  }

  private func prepare(_ sql: String, _ open: Handles) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    if open.library.prepare(open.connection, sql, &statement) != DuckDBState.success {
      let failure = error(open.library.prepareError(statement), fallback: "unable to prepare")
      open.library.destroyPrepare(&statement)
      throw failure
    }
    return statement
  }

  private func bind(_ statement: OpaquePointer?, _ binds: [SQLBindValue], _ open: Handles) throws {
    for (offset, value) in binds.enumerated() {
      let index = UInt64(offset + 1)
      let state =
        switch value {
        case .null: open.library.bindNull(statement, index)
        case .text(let text): open.library.bindVarchar(statement, index, text)
        }
      if state != DuckDBState.success {
        throw DuckDBSessionError(message: "unable to bind parameter $\(index)")
      }
    }
  }

  /// One internal statement (hardening). Never user SQL.
  private func exec(_ sql: String, _ open: Handles) throws {
    var result = DuckDBResult()
    defer { open.library.destroyResult(&result) }
    if open.library.query(open.connection, sql, &result) != DuckDBState.success {
      throw error(open.library.resultError(&result), fallback: "unable to configure DuckDB")
    }
  }

  /// Also clears a timeout flag a previous statement left set, so a new error is not labelled
  /// as timed out.
  private func requireOpen() throws -> Handles {
    let open = withState { () -> Handles? in
      timedOut = false
      return handles
    }
    guard let open else { throw Self.closedError }
    return open
  }

  private static func commandTag(_ sql: String) -> String {
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = trimmed.prefix { !$0.isWhitespace && $0 != ";" }
    return String(word).uppercased()
  }

  // MARK: - Timeout and interrupt

  private func deadline() -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: .seconds(statementTimeoutSeconds))
  }

  /// Runs `body` (a blocking DuckDB call) with the watchdog armed: at `deadline` it marks the
  /// statement timed out and calls `duckdb_interrupt`, repeating until `body` returns.
  private func guarded<T>(
    until deadline: ContinuousClock.Instant, _ open: Handles, _ body: () -> T
  ) -> T {
    let token = withState { () -> UInt64 in
      watchToken &+= 1
      timedOut = false
      return watchToken
    }
    let item = DispatchWorkItem { [weak self] in self?.fireWatch(token) }
    withState { activeWatch = (token, item) }
    let remaining = ContinuousClock.now.duration(to: deadline)
    let seconds =
      Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
    watchdog.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    defer {
      withState {
        if activeWatch?.token == token {
          activeWatch?.item.cancel()
          activeWatch = nil
        }
      }
    }
    return body()
  }

  private func fireWatch(_ token: UInt64) {
    let fired = withState { () -> Bool in
      guard activeWatch?.token == token, let open = handles else { return false }
      timedOut = true
      open.library.interrupt(open.connection)
      return true
    }
    guard fired else { return }
    watchdog.asyncAfter(deadline: .now() + Self.reinterruptInterval) { [weak self] in
      self?.fireWatch(token)
    }
  }

  /// Under the lock, so `close` cannot free the connection during the call.
  private func interruptNow() {
    withState {
      if let open = handles { open.library.interrupt(open.connection) }
    }
  }

  // MARK: - Errors

  /// The DuckDB message, prefixed when the watchdog stopped the statement.
  private func error(_ message: UnsafePointer<CChar>?, fallback: String) -> DuckDBSessionError {
    let text = message.map { String(cString: $0) } ?? ""
    let base = text.isEmpty ? fallback : text
    let didTimeOut = withState { () -> Bool in
      let value = timedOut
      timedOut = false
      return value
    }
    return DuckDBSessionError(message: didTimeOut ? "statement timed out: \(base)" : base)
  }

  private func emit(_ reason: SessionCloseReason) {
    let first = withState { () -> Bool in
      if didEmitClose { return false }
      didEmitClose = true
      return true
    }
    guard first else { return }
    closeContinuation.yield(reason)
    closeContinuation.finish()
  }

  private func withState<T>(_ body: () throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body()
  }

  private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      executor.async { continuation.resume(with: Result { try body() }) }
    }
  }

  private func run(_ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      executor.async {
        body()
        continuation.resume()
      }
    }
  }
}

nonisolated extension DuckDBSession {
  fileprivate struct Handles {
    let library: DuckDBLibrary
    let database: OpaquePointer?
    let connection: OpaquePointer?
  }

  fileprivate struct Directories {
    let temp: URL
    let extensions: URL
    let secrets: URL
  }

  fileprivate struct PreparedRead: Sendable {
    let id: UUID
    let columns: [ColumnInfo]
  }

  /// One streaming read. The result struct lives on the heap so its address stays stable.
  fileprivate final class ReadState {
    var statement: OpaquePointer?
    var pending: OpaquePointer?
    let result: UnsafeMutablePointer<DuckDBResult>
    var hasResult = false
    var types: [DuckDBTypeNode] = []
    /// Decoded rows of the current chunk, last row first.
    var buffered: [[CellValue]] = []
    var deadline = ContinuousClock.now

    init() {
      result = .allocate(capacity: 1)
      result.initialize(to: DuckDBResult())
    }

    deinit {
      result.deinitialize(count: 1)
      result.deallocate()
    }

    /// Result, then pending, then prepared statement. Safe on a result a later statement closed.
    func release(_ library: DuckDBLibrary) {
      if hasResult {
        library.destroyResult(result)
        hasResult = false
      }
      library.destroyPending(&pending)
      library.destroyPrepare(&statement)
    }
  }
}
