// SQLiteHandle.swift
// A nonisolated SQLite connection for app-owned databases. An actor owns the handle later.

import Foundation
import SQLite3

/// Primary result code and the text from `sqlite3_errmsg`.
nonisolated struct SQLiteError: Error, Equatable {
  let code: Int32
  let message: String
}

/// Copies the bound bytes before `sqlite3_bind_*` returns. The module does not export this macro.
private nonisolated(unsafe) let sqliteTransient = unsafeBitCast(
  -1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not `Sendable`: a later actor owns the instance and its statements.
///
/// Bind indexes are 1-based, matching `sqlite3_bind_*`. Column indexes are 0-based, matching
/// `sqlite3_column_*`. `execute` runs only the first statement in `sql`.
///
/// Finite doubles are bound as REAL. Non-finite doubles (NaN, ±infinity) are bound as NULL,
/// the same choice `SQLDialect.sqlite` makes for those literals. Bool is an integer 0 or 1.
/// String, JSON, and dates are text; a date is ISO-8601 internet date-time in UTC with no
/// fractional seconds (`2020-01-02T03:04:05Z`). Data is a blob, including a zero-length blob.
nonisolated final class SQLiteHandle {
  private var db: OpaquePointer?

  /// `url.path` or `url.absoluteString` of `:memory:` opens an in-memory database.
  /// Any other URL opens `url.path` (a temporary file is the caller's choice).
  init(
    url: URL,
    flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
  ) throws {
    let path = Self.databasePath(for: url)
    var handle: OpaquePointer?
    let code = path.withCString { pointer in
      sqlite3_open_v2(pointer, &handle, flags, nil)
    }
    guard code == SQLITE_OK, let opened = handle else {
      let message = Self.errorMessage(handle) ?? "unable to open database"
      sqlite3_close_v2(handle)
      throw SQLiteError(code: code, message: message)
    }
    db = opened
    do {
      try applyPragmas()
    } catch {
      let opened = db
      db = nil
      sqlite3_close_v2(opened)
      throw error
    }
  }

  static func inMemory() throws -> SQLiteHandle {
    var components = URLComponents()
    components.path = ":memory:"
    guard let url = components.url else {
      throw SQLiteError(code: SQLITE_ERROR, message: "unable to build a :memory: URL")
    }
    return try SQLiteHandle(url: url)
  }

  deinit {
    sqlite3_close_v2(db)
  }

  func execute(_ sql: String) throws {
    let statement = try prepare(sql)
    while try statement.step() {}
  }

  func prepare(_ sql: String) throws -> Statement {
    guard let db else {
      throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed")
    }
    var statement: OpaquePointer?
    let code = sql.withCString { pointer in
      sqlite3_prepare_v2(db, pointer, -1, &statement, nil)
    }
    guard code == SQLITE_OK, let prepared = statement else {
      let message = Self.errorMessage(db) ?? "unable to prepare statement"
      sqlite3_finalize(statement)
      throw SQLiteError(code: code, message: message)
    }
    return Statement(statement: prepared, database: db)
  }

  /// `BEGIN`, then `body`, then `COMMIT`. On a throw from `body`, `ROLLBACK` and rethrow.
  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN")
    do {
      try body()
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
    try execute("COMMIT")
  }

  var userVersion: Int32 {
    get { Int32(truncatingIfNeeded: queryInt64("PRAGMA user_version") ?? 0) }
    set { try? execute("PRAGMA user_version = \(newValue)") }
  }

  var lastInsertRowID: Int64 {
    guard let db else { return 0 }
    return sqlite3_last_insert_rowid(db)
  }

  var changes: Int {
    guard let db else { return 0 }
    return Int(sqlite3_changes(db))
  }

  /// `PRAGMA compile_options` rows, such as `ENABLE_FTS5`.
  static func compileOptions() -> [String] {
    guard let db = try? SQLiteHandle.inMemory(),
      let statement = try? db.prepare("PRAGMA compile_options")
    else { return [] }
    var options: [String] = []
    while (try? statement.step()) == true {
      if let name = statement.columnText(0) {
        options.append(name)
      }
    }
    return options
  }

  private func applyPragmas() throws {
    try execute("PRAGMA busy_timeout = 2000")
    try execute("PRAGMA foreign_keys = ON")
    let mode = try queryText("PRAGMA journal_mode = WAL")?.lowercased()
    // In-memory databases report `memory` and cannot switch to WAL.
    if mode != "wal" && mode != "memory" {
      throw SQLiteError(
        code: SQLITE_ERROR,
        message: "journal_mode is \(mode ?? "empty"), expected wal"
      )
    }
  }

  private func queryText(_ sql: String) throws -> String? {
    let statement = try prepare(sql)
    guard try statement.step() else { return nil }
    return statement.columnText(0)
  }

  private func queryInt64(_ sql: String) -> Int64? {
    guard let statement = try? prepare(sql), (try? statement.step()) == true else { return nil }
    return statement.columnInt(0)
  }

  private static func databasePath(for url: URL) -> String {
    if url.path == ":memory:" || url.absoluteString == ":memory:" {
      return ":memory:"
    }
    return url.path
  }

  private static func errorMessage(_ handle: OpaquePointer?) -> String? {
    guard let handle else { return nil }
    let message = String(cString: sqlite3_errmsg(handle))
    return message.isEmpty ? nil : message
  }

  /// A prepared statement. Finalize happens in `deinit`. `reset` does not clear bindings.
  nonisolated final class Statement {
    private var statement: OpaquePointer?
    private let database: OpaquePointer

    fileprivate init(statement: OpaquePointer, database: OpaquePointer) {
      self.statement = statement
      self.database = database
    }

    deinit {
      sqlite3_finalize(statement)
    }

    func bind(_ index: Int32, _ value: CellValue) throws {
      switch value {
      case .null:
        try check(sqlite3_bind_null(statement, index))
      case .int(let number):
        try check(sqlite3_bind_int64(statement, index, sqlite3_int64(number)))
      case .double(let number) where number.isFinite:
        try check(sqlite3_bind_double(statement, index, number))
      case .double:
        try check(sqlite3_bind_null(statement, index))
      case .bool(let flag):
        try check(sqlite3_bind_int(statement, index, flag ? 1 : 0))
      case .string(let text), .json(let text):
        try bind(text: text, index: index)
      case .date(let date):
        try bind(text: Self.iso8601Text(date), index: index)
      case .data(let data):
        try bind(blob: data, index: index)
      }
    }

    func bind(text: String, index: Int32) throws {
      let code = text.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
      }
      try check(code)
    }

    /// `true` while a row is available (`SQLITE_ROW`). `false` on `SQLITE_DONE`.
    func step() throws -> Bool {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        return true
      case SQLITE_DONE:
        return false
      case let code:
        throw error(code)
      }
    }

    func columnInt(_ index: Int32) -> Int64 {
      sqlite3_column_int64(statement, index)
    }

    func columnDouble(_ index: Int32) -> Double {
      sqlite3_column_double(statement, index)
    }

    func columnText(_ index: Int32) -> String? {
      guard sqlite3_column_type(statement, index) != SQLITE_NULL,
        let pointer = sqlite3_column_text(statement, index)
      else { return nil }
      return String(cString: pointer)
    }

    func columnBlob(_ index: Int32) -> Data? {
      guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
      let count = Int(sqlite3_column_bytes(statement, index))
      guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
      return Data(bytes: pointer, count: count)
    }

    func columnNull(_ index: Int32) -> Bool {
      sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func reset() throws {
      try check(sqlite3_reset(statement))
    }

    private func bind(blob data: Data, index: Int32) throws {
      if data.isEmpty {
        // A NULL pointer binds SQL NULL. A length of 0 with a live address is an empty blob.
        var placeholder: UInt8 = 0
        try check(sqlite3_bind_blob(statement, index, &placeholder, 0, sqliteTransient))
        return
      }
      let code = data.withUnsafeBytes { buffer in
        sqlite3_bind_blob(
          statement, index, buffer.baseAddress, Int32(data.count), sqliteTransient)
      }
      try check(code)
    }

    private func check(_ code: Int32) throws {
      guard code == SQLITE_OK else { throw error(code) }
    }

    private func error(_ code: Int32) -> SQLiteError {
      let message = String(cString: sqlite3_errmsg(database))
      if message.isEmpty {
        return SQLiteError(code: code, message: "SQLite error \(code)")
      }
      return SQLiteError(code: code, message: message)
    }

    private static func iso8601Text(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      return formatter.string(from: date)
    }
  }
}
