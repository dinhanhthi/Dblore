// SQLiteSession.swift
// One SQLite file connection. Every sqlite3 call except `sqlite3_interrupt` runs on one serial
// queue. Interrupt is safe from another thread while a statement is inside `sqlite3_step`.
// `load_extension` stays disabled (SQLite's default). Binds use `?` and never enter SQL text.

import Foundation
import SQLite3

/// `sqlite3_errmsg` plus the extended result code. The message does not include binds or secrets.
nonisolated struct SQLiteSessionError: Error, Equatable, Sendable, LocalizedError {
  let extendedCode: Int32
  let message: String

  var errorDescription: String? {
    "\(message) (\(extendedCode))"
  }
}

private nonisolated(unsafe) let sqliteTransientDestructor = unsafeBitCast(
  -1, to: sqlite3_destructor_type.self)

/// Finalizes a read when the row stream is released, including when the caller stops early.
private nonisolated final class ReadLifetime: @unchecked Sendable {
  let id: UUID
  private let cancel: @Sendable () -> Void

  init(id: UUID, cancel: @escaping @Sendable () -> Void) {
    self.id = id
    self.cancel = cancel
  }

  deinit { cancel() }
}

nonisolated final class SQLiteSession: DatabaseSession, @unchecked Sendable {
  let capabilities: DatabaseCapabilities
  let closeEvents: AsyncStream<SessionCloseReason>

  private let config: ConnectionConfig
  private let executor: DispatchSerialQueue
  private let closeContinuation: AsyncStream<SessionCloseReason>.Continuation
  private let stateLock = NSLock()
  private var db: OpaquePointer?
  private var didEmitClose = false
  private var statementTimeoutSeconds: Int
  /// Deadline checked by the progress handler. Nil when no statement is inside `sqlite3_step`.
  private var publishedDeadline: ContinuousClock.Instant?
  private var timedOut = false
  private var reads: [UUID: ReadState] = [:]

  /// Virtual-machine instructions between progress-handler checks. Small enough that a one-second
  /// statement timeout fires while a recursive query is still inside one `sqlite3_step`.
  private static let progressInstructionCount: Int32 = 1000
  private static let busyTimeoutMilliseconds = 5000
  private static let cursorError = SQLiteSessionError(
    extendedCode: SQLITE_ERROR, message: "SQLite does not support server cursors")

  init(config: ConnectionConfig) {
    self.config = config
    capabilities = config.databaseType.capabilities
    statementTimeoutSeconds = config.statementTimeoutSeconds
    executor = DispatchSerialQueue(label: "dblore.sqlite.session.\(UUID().uuidString)")
    (closeEvents, closeContinuation) = AsyncStream.makeStream(
      of: SessionCloseReason.self, bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    let handle = withState { () -> OpaquePointer? in
      let handle = db
      db = nil
      return handle
    }
    if let handle {
      sqlite3_progress_handler(handle, 0, nil, nil)
      sqlite3_interrupt(handle)
      for read in reads.values {
        if let statement = read.statement {
          sqlite3_finalize(statement)
        }
      }
      sqlite3_close_v2(handle)
    }
    stateLock.lock()
    let finished = didEmitClose
    stateLock.unlock()
    if !finished { closeContinuation.finish() }
  }

  func open() async throws {
    try await run { try self.openOnQueue() }
  }

  func close() async {
    emit(.closedByApp)
    if let handle = withState({ db }) {
      sqlite3_interrupt(handle)
    }
    await run { self.closeOnQueue() }
  }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let prepared = try await run { try self.prepareRead(sql, binds: binds) }
    // The stream keeps this alive. Dropping the stream (a capped read stops early) resets the
    // statement without closing the connection.
    let lifetime = ReadLifetime(id: prepared.id) {
      self.executor.async {
        self.finishRead(prepared.id)
      }
    }
    let rows = AsyncThrowingStream<[CellValue], Error> { [lifetime] in
      try await self.nextRow(lifetime.id)
    }
    return SessionRowSource(columns: prepared.columns, rows: rows)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await run {
      let statement = try self.prepare(sql)
      defer {
        self.clearDeadline()
        sqlite3_reset(statement)
        sqlite3_finalize(statement)
      }
      try self.bind(statement, binds)
      self.beginStatementTiming()
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { continue }
        if code == SQLITE_DONE { break }
        throw self.currentError(code: code)
      }
      let changes = self.withState { self.db }.map { Int(exactly: sqlite3_changes64($0)) ?? 0 } ?? 0
      return CommandResult(affectedRows: changes, tag: Self.commandTag(sql))
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

  /// SQLite has no server-side lock or idle brake. The statement timeout is the progress handler,
  /// which reads `statementTimeoutSeconds` (updated here when the actor applies settings).
  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    _ = lockTimeoutSeconds
    _ = idleTimeoutSeconds
    await run {
      self.statementTimeoutSeconds = statementTimeoutSeconds
    }
  }

  /// Stops the statement currently inside `sqlite3_step`. Does not hop to the serial queue:
  /// that queue is blocked in the step this call is meant to abort.
  func interrupt() async {
    if let handle = withState({ db }) {
      sqlite3_interrupt(handle)
    }
  }

  func formatError(_ error: Error) -> String {
    if let error = error as? SQLiteSessionError {
      return error.errorDescription ?? error.message
    }
    return error.localizedDescription
  }

  // MARK: - Open / close

  private func openOnQueue() throws {
    if withState({ db }) != nil {
      throw SQLiteSessionError(extendedCode: SQLITE_MISUSE, message: "database is already open")
    }
    let filePath = config.database
    if filePath.isEmpty {
      throw SQLiteSessionError(extendedCode: SQLITE_CANTOPEN, message: "database path is empty")
    }
    let readOnly = config.readOnlyFile
    let path = try Self.databasePath(filePath: filePath, readOnly: readOnly)
    let flags = Self.openFlags(readOnly: readOnly)
    var handle: OpaquePointer?
    let code = path.withCString { pointer in
      sqlite3_open_v2(pointer, &handle, flags, nil)
    }
    guard code == SQLITE_OK, let opened = handle else {
      let error = errorFrom(handle, fallback: code, fallbackMessage: "unable to open database")
      sqlite3_close_v2(handle)
      throw error
    }
    withState { db = opened }
    sqlite3_extended_result_codes(opened, 1)
    sqlite3_progress_handler(
      opened, Self.progressInstructionCount,
      { context in
        guard let context else { return 0 }
        return Unmanaged<SQLiteSession>.fromOpaque(context).takeUnretainedValue().progressTick()
      }, Unmanaged.passUnretained(self).toOpaque())
    do {
      try exec("PRAGMA busy_timeout = \(Self.busyTimeoutMilliseconds)")
      try exec("PRAGMA foreign_keys = ON")
    } catch {
      closeOnQueue()
      throw error
    }
  }

  private func closeOnQueue() {
    guard let handle = withState({ db }) else { return }
    sqlite3_progress_handler(handle, 0, nil, nil)
    for id in Array(reads.keys) {
      finishRead(id)
    }
    sqlite3_close_v2(handle)
    clearDeadline()
    withState { db = nil }
  }

  private static func openFlags(readOnly: Bool) -> Int32 {
    if readOnly {
      return SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
    }
    // CREATE so a new file can be opened. READONLY is not combined with CREATE.
    return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
  }

  /// Read-only files use a `file:` URI with `immutable=1`, which refuses writes.
  private static func databasePath(filePath: String, readOnly: Bool) throws -> String {
    if !readOnly { return filePath }
    var components = URLComponents()
    components.scheme = "file"
    components.path = filePath
    components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    guard let uri = components.string else {
      throw SQLiteSessionError(
        extendedCode: SQLITE_CANTOPEN, message: "unable to open a read-only database")
    }
    return uri
  }

  // MARK: - Statements

  private func prepareRead(_ sql: String, binds: [SQLBindValue]) throws -> PreparedRead {
    let statement = try prepare(sql)
    do {
      try bind(statement, binds)
      let described = columnInfos(statement)
      let id = UUID()
      reads[id] = ReadState(statement: statement, declaredTypes: described.declared)
      return PreparedRead(id: id, columns: described.columns)
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }

  private func nextRow(_ id: UUID) async throws -> [CellValue]? {
    try await run {
      guard var read = self.reads[id], let statement = read.statement else { return nil }
      let deadline: ContinuousClock.Instant
      if let existing = read.deadline {
        deadline = existing
      } else {
        deadline = ContinuousClock.now.advanced(by: .seconds(self.statementTimeoutSeconds))
        read.deadline = deadline
        self.stateLock.lock()
        self.timedOut = false
        self.stateLock.unlock()
      }
      self.reads[id] = read
      self.publish(deadline)
      let code = sqlite3_step(statement)
      switch code {
      case SQLITE_ROW:
        return self.makeRow(statement, declared: read.declaredTypes)
      case SQLITE_DONE:
        self.finishRead(id)
        return nil
      default:
        let error = self.currentError(code: code)
        self.finishRead(id)
        throw error
      }
    }
  }

  /// `sqlite3_reset` ends the read and leaves the connection open, so a temp table survives.
  private func finishRead(_ id: UUID) {
    guard let read = reads.removeValue(forKey: id) else { return }
    if let statement = read.statement {
      sqlite3_reset(statement)
      sqlite3_finalize(statement)
    }
    if reads.isEmpty { clearDeadline() }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let db = withState({ db }) else {
      throw SQLiteSessionError(extendedCode: SQLITE_MISUSE, message: "database is closed")
    }
    var statement: OpaquePointer?
    let code = sql.withCString { pointer in
      sqlite3_prepare_v2(db, pointer, -1, &statement, nil)
    }
    guard code == SQLITE_OK, let prepared = statement else {
      let error = errorFrom(db, fallback: code, fallbackMessage: "unable to prepare statement")
      sqlite3_finalize(statement)
      throw error
    }
    return prepared
  }

  private func bind(_ statement: OpaquePointer, _ binds: [SQLBindValue]) throws {
    for (offset, value) in binds.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .null:
        try check(sqlite3_bind_null(statement, index))
      case .text(let text):
        let code = text.withCString { pointer in
          sqlite3_bind_text(statement, index, pointer, -1, sqliteTransientDestructor)
        }
        try check(code)
      }
    }
  }

  private func exec(_ sql: String) throws {
    guard let db = withState({ db }) else {
      throw SQLiteSessionError(extendedCode: SQLITE_MISUSE, message: "database is closed")
    }
    let code = sql.withCString { pointer in
      sqlite3_exec(db, pointer, nil, nil, nil)
    }
    try check(code)
  }

  private func makeRow(_ statement: OpaquePointer, declared: [String?]) -> [CellValue] {
    let count = Int(sqlite3_column_count(statement))
    var row: [CellValue] = []
    row.reserveCapacity(count)
    for index in 0..<count {
      let column = Int32(index)
      let declaredType = index < declared.count ? declared[index] : nil
      row.append(
        SQLiteValueMapping.cell(
          storage: storage(statement, column), declaredType: declaredType))
    }
    return row
  }

  /// Reads only the accessor for the storage class. A mismatched accessor would convert the value.
  private func storage(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValueMapping.Storage {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_INTEGER:
      return .integer(sqlite3_column_int64(statement, column))
    case SQLITE_FLOAT:
      return .real(sqlite3_column_double(statement, column))
    case SQLITE_TEXT:
      guard let pointer = sqlite3_column_text(statement, column) else { return .text("") }
      return .text(String(cString: pointer))
    case SQLITE_BLOB:
      return .blob(columnBlob(statement, column))
    default:
      return .null
    }
  }

  /// A NULL blob pointer with `SQLITE_BLOB` is a zero-length blob, not SQL NULL.
  private func columnBlob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard let pointer = sqlite3_column_blob(statement, column), count > 0 else { return Data() }
    return Data(bytes: pointer, count: count)
  }

  private func columnInfos(
    _ statement: OpaquePointer
  ) -> (
    columns: [ColumnInfo], declared: [String?]
  ) {
    let count = Int(sqlite3_column_count(statement))
    let metadata = sqlite3_compileoption_used("ENABLE_COLUMN_METADATA") != 0
    var copied: [CopiedColumn] = []
    copied.reserveCapacity(count)
    for index in 0..<count {
      let column = Int32(index)
      let schema = metadata ? copy(sqlite3_column_database_name(statement, column)) : nil
      let table = metadata ? copy(sqlite3_column_table_name(statement, column)) : nil
      let origin = metadata ? copy(sqlite3_column_origin_name(statement, column)) : nil
      copied.append(
        CopiedColumn(
          name: copy(sqlite3_column_name(statement, column)) ?? "",
          declared: copy(sqlite3_column_decltype(statement, column)),
          schema: schema,
          table: table,
          origin: origin
        ))
    }
    var ordinals: [String: [String: Int]] = [:]
    var columns: [ColumnInfo] = []
    var declared: [String?] = []
    for column in copied {
      declared.append(column.declared)
      columns.append(
        ColumnInfo(
          name: column.name,
          type: column.declared ?? "",
          origin: columnOrigin(column, ordinals: &ordinals)))
    }
    return (columns, declared)
  }

  /// `cid` from `pragma_table_info` (0-based). Nil when the column is an expression or the
  /// library has no column metadata.
  private func columnOrigin(
    _ column: CopiedColumn, ordinals: inout [String: [String: Int]]
  ) -> ColumnOrigin? {
    guard let schema = column.schema, let table = column.table, let name = column.origin,
      !schema.isEmpty, !table.isEmpty, !name.isEmpty
    else { return nil }
    let key = schema + "\u{0}" + table
    if ordinals[key] == nil {
      ordinals[key] = loadOrdinals(schema: schema, table: table)
    }
    guard let ordinal = ordinals[key]?[name] else { return nil }
    return ColumnOrigin(tableID: .sqlite(schema: schema, table: table), columnOrdinal: ordinal)
  }

  private func loadOrdinals(schema: String, table: String) -> [String: Int] {
    // A paused statement may have left a deadline in the past. This lookup is not that statement.
    let savedDeadline = withState { publishedDeadline }
    clearDeadline()
    defer {
      if let savedDeadline { publish(savedDeadline) }
    }
    guard let db = withState({ db }) else { return [:] }
    var statement: OpaquePointer?
    let sql = "SELECT cid, name FROM pragma_table_info(?, ?)"
    let code = sql.withCString { pointer in
      sqlite3_prepare_v2(db, pointer, -1, &statement, nil)
    }
    guard code == SQLITE_OK, let prepared = statement else {
      sqlite3_finalize(statement)
      return [:]
    }
    defer { sqlite3_finalize(prepared) }
    guard bindTransient(prepared, 1, table), bindTransient(prepared, 2, schema) else { return [:] }
    var ordinals: [String: Int] = [:]
    while sqlite3_step(prepared) == SQLITE_ROW {
      guard let name = sqlite3_column_text(prepared, 1) else { continue }
      ordinals[String(cString: name)] = Int(sqlite3_column_int64(prepared, 0))
    }
    return ordinals
  }

  private func bindTransient(_ statement: OpaquePointer, _ index: Int32, _ text: String) -> Bool {
    let code = text.withCString { pointer in
      sqlite3_bind_text(statement, index, pointer, -1, sqliteTransientDestructor)
    }
    return code == SQLITE_OK
  }

  private func copy(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
  }

  private static func commandTag(_ sql: String) -> String {
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = trimmed.prefix { !$0.isWhitespace && $0 != ";" }
    return String(word).uppercased()
  }

  // MARK: - Timeout

  private func beginStatementTiming() {
    let deadline = ContinuousClock.now.advanced(by: .seconds(statementTimeoutSeconds))
    stateLock.lock()
    publishedDeadline = deadline
    timedOut = false
    stateLock.unlock()
  }

  private func publish(_ deadline: ContinuousClock.Instant) {
    stateLock.lock()
    publishedDeadline = deadline
    stateLock.unlock()
  }

  private func clearDeadline() {
    stateLock.lock()
    publishedDeadline = nil
    stateLock.unlock()
  }

  /// Called on the thread inside `sqlite3_step`. Returning non-zero aborts that step.
  fileprivate func progressTick() -> Int32 {
    stateLock.lock()
    let deadline = publishedDeadline
    stateLock.unlock()
    guard let deadline, ContinuousClock.now >= deadline else { return 0 }
    stateLock.lock()
    timedOut = true
    stateLock.unlock()
    return 1
  }

  // MARK: - Errors

  private func check(_ code: Int32) throws {
    if code == SQLITE_OK { return }
    throw currentError(code: code)
  }

  private func currentError(code: Int32) -> SQLiteSessionError {
    let handle = withState { db }
    return errorFrom(handle, fallback: code, fallbackMessage: "SQLite error \(code)")
  }

  private func errorFrom(
    _ handle: OpaquePointer?, fallback: Int32, fallbackMessage: String
  ) -> SQLiteSessionError {
    let extended = handle.map { sqlite3_extended_errcode($0) } ?? fallback
    let text = handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
    let base = text.isEmpty ? fallbackMessage : text
    stateLock.lock()
    let didTimeOut = timedOut
    timedOut = false
    stateLock.unlock()
    if didTimeOut {
      return SQLiteSessionError(
        extendedCode: extended, message: "statement timed out: \(base)")
    }
    return SQLiteSessionError(extendedCode: extended, message: base)
  }

  private func emit(_ reason: SessionCloseReason) {
    stateLock.lock()
    if didEmitClose {
      stateLock.unlock()
      return
    }
    didEmitClose = true
    stateLock.unlock()
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
      executor.async {
        continuation.resume(with: Result { try body() })
      }
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

nonisolated extension SQLiteSession {
  fileprivate nonisolated struct PreparedRead: Sendable {
    let id: UUID
    let columns: [ColumnInfo]
  }

  fileprivate nonisolated struct ReadState {
    var statement: OpaquePointer?
    var declaredTypes: [String?]
    var deadline: ContinuousClock.Instant?
  }

  fileprivate nonisolated struct CopiedColumn {
    var name: String
    var declared: String?
    var schema: String?
    var table: String?
    var origin: String?
  }
}
