// SQLiteHandleTests.swift
// SQLiteHandle opens a file or memory database, binds every CellValue, and rolls a transaction back.

import Foundation
import Testing

@testable import Dblore

/// Column indexes are 0-based (`sqlite3_column_*`). Bind indexes are 1-based (`sqlite3_bind_*`).
/// Non-finite doubles are stored as NULL.
@Suite("SQLite handle")
struct SQLiteHandleTests {
  private struct SampleFailure: Error, Equatable {}

  @Test("Temp file insert and select round-trips, and the file is in WAL")
  func tempFileRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-\(UUID().uuidString).db")
    defer { removeDatabase(at: url) }
    do {
      let db = try SQLiteHandle(url: url)

      let mode = try db.prepare("PRAGMA journal_mode")
      #expect(try mode.step())
      #expect(mode.columnText(0) == "wal")

      let timeout = try db.prepare("PRAGMA busy_timeout")
      #expect(try timeout.step())
      #expect(timeout.columnInt(0) == 2000)

      let foreignKeys = try db.prepare("PRAGMA foreign_keys")
      #expect(try foreignKeys.step())
      #expect(foreignKeys.columnInt(0) == 1)

      try db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
      let insert = try db.prepare("INSERT INTO notes (body) VALUES (?)")
      try insert.bind(text: "hello", index: 1)
      #expect(try insert.step() == false)
      try insert.reset()
      try insert.bind(text: "world", index: 1)
      #expect(try insert.step() == false)

      #expect(db.lastInsertRowID == 2)
      #expect(db.changes == 1)

      let select = try db.prepare("SELECT body FROM notes ORDER BY id")
      #expect(try select.step())
      #expect(select.columnText(0) == "hello")
      #expect(try select.step())
      #expect(select.columnText(0) == "world")
      #expect(try select.step() == false)

      db.userVersion = 4
      #expect(db.userVersion == 4)
    }
  }

  @Test("Every CellValue case binds and reads back")
  func bindEveryCellValue() throws {
    let db = try openMemory()
    try db.execute(
      """
      CREATE TABLE cells (
        n, i, d, bt, bf, s, j, dt, blob, nan, pinf, ninf
      )
      """
    )
    let insert = try db.prepare(
      """
      INSERT INTO cells (n, i, d, bt, bf, s, j, dt, blob, nan, pinf, ninf)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    )
    let date = Date(timeIntervalSince1970: 1_577_934_245)
    let blob = Data([0x00, 0x0A, 0xFF])
    try insert.bind(1, .null)
    try insert.bind(2, .int(42))
    try insert.bind(3, .double(1.5))
    try insert.bind(4, .bool(true))
    try insert.bind(5, .bool(false))
    try insert.bind(6, .string("o'brien"))
    try insert.bind(7, .json(#"{"a":1}"#))
    try insert.bind(8, .date(date))
    try insert.bind(9, .data(blob))
    try insert.bind(10, .double(.nan))
    try insert.bind(11, .double(.infinity))
    try insert.bind(12, .double(-.infinity))
    #expect(try insert.step() == false)

    let row = try db.prepare(
      "SELECT n, i, d, bt, bf, s, j, dt, blob, nan, pinf, ninf FROM cells"
    )
    #expect(try row.step())
    #expect(row.columnNull(0))
    #expect(row.columnInt(1) == 42)
    #expect(row.columnDouble(2) == 1.5)
    #expect(row.columnInt(3) == 1)
    #expect(row.columnInt(4) == 0)
    #expect(row.columnText(5) == "o'brien")
    #expect(row.columnText(6) == #"{"a":1}"#)
    #expect(row.columnText(7) == "2020-01-02T03:04:05Z")
    #expect(row.columnBlob(8) == blob)
    #expect(row.columnNull(9))
    #expect(row.columnNull(10))
    #expect(row.columnNull(11))
    #expect(try row.step() == false)
  }

  @Test("A thrown transaction body rolls back and the row is not visible")
  func transactionRollback() throws {
    let db = try openMemory()
    try db.execute("CREATE TABLE t (id INTEGER)")
    #expect(throws: SampleFailure.self) {
      try db.transaction {
        try db.execute("INSERT INTO t (id) VALUES (1)")
        throw SampleFailure()
      }
    }
    let count = try db.prepare("SELECT COUNT(*) FROM t")
    #expect(try count.step())
    #expect(count.columnInt(0) == 0)
  }

  @Test("Bad SQL throws SQLiteError with a non-empty message")
  func badSQLThrows() throws {
    let db = try openMemory()
    do {
      try db.execute("THIS IS NOT SQL")
      Issue.record("expected SQLiteError")
    } catch let error as SQLiteError {
      #expect(!error.message.isEmpty)
      #expect(error.code != 0)
    } catch {
      Issue.record("expected SQLiteError, got \(error)")
    }
  }

  @Test("Compile options include ENABLE_FTS5")
  func compileOptionsIncludeFTS5() {
    #expect(SQLiteHandle.compileOptions().contains("ENABLE_FTS5"))
  }

  @Test("A :memory: URL opens an in-memory database")
  func memoryOpen() throws {
    var components = URLComponents()
    components.path = ":memory:"
    let byPath = try #require(components.url)
    #expect(byPath.path == ":memory:")
    try expectInMemory(SQLiteHandle(url: byPath))

    let byString = try #require(URL(string: ":memory:"))
    #expect(byString.absoluteString == ":memory:")
    try expectInMemory(SQLiteHandle(url: byString))

    try expectInMemory(SQLiteHandle.inMemory())
  }

  private func openMemory() throws -> SQLiteHandle {
    var components = URLComponents()
    components.path = ":memory:"
    let url = try #require(components.url)
    return try SQLiteHandle(url: url)
  }

  private func expectInMemory(_ db: SQLiteHandle) throws {
    try db.execute("CREATE TABLE t (id INTEGER)")
    try db.execute("INSERT INTO t (id) VALUES (7)")
    let row = try db.prepare("SELECT id FROM t")
    #expect(try row.step())
    #expect(row.columnInt(0) == 7)
    let mode = try db.prepare("PRAGMA journal_mode")
    #expect(try mode.step())
    #expect(mode.columnText(0) == "memory")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
}
