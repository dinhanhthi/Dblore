// SQLiteSessionTests.swift
// SQLiteSession against a temporary file: rows, types, cap, cancel, timeout, read-only, transactions.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite session")
struct SQLiteSessionTests {
  private static let secretPassword = "dblore-session-password"
  private static let secretBind = "dblore-session-bind-secret"
  private static let longAggregate = """
    WITH RECURSIVE c(x) AS (
      SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 1000000000
    )
    SELECT max(x) FROM c
    """

  @Test("Temp file create, insert, and select keep binds out of SQL")
  func createInsertSelect() async throws {
    try await withWritableDatabase { session in
      let timeout = try await collect(session, "PRAGMA busy_timeout")
      #expect(timeout.rows == [[.int(5000)]])
      let foreignKeys = try await collect(session, "PRAGMA foreign_keys")
      #expect(foreignKeys.rows == [[.int(1)]])
      let journal = try await collect(session, "PRAGMA journal_mode")
      #expect(journal.rows == [[.string("delete")]])

      _ = try await session.command(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)", binds: [])
      let inserted = try await session.command(
        "INSERT INTO notes (body) VALUES (?)", binds: [.text("o'brien")])
      #expect(inserted.affectedRows == 1)

      let selected = try await collect(
        session, "SELECT body, id, body || '!' AS shouted FROM notes")
      #expect(selected.rows == [[.string("o'brien"), .int(1), .string("o'brien!")]])
      #expect(selected.columns.map(\.name) == ["body", "id", "shouted"])
      #expect(
        selected.columns[0].origin?.tableID == TableRef.sqlite(schema: "main", table: "notes"))
      #expect(selected.columns[0].origin?.columnOrdinal == 1)
      #expect(
        selected.columns[1].origin?.tableID == TableRef.sqlite(schema: "main", table: "notes"))
      #expect(selected.columns[1].origin?.columnOrdinal == 0)
      #expect(selected.columns[2].origin == nil)
    }
  }

  @Test("Storage classes map to cell values, and JSON follows the declared type")
  func storageClasses() async throws {
    try await withWritableDatabase { session in
      _ = try await session.command(
        """
        CREATE TABLE cells (
          i INTEGER,
          r REAL,
          s TEXT,
          j JSON,
          bad JSON,
          plain TEXT,
          b BLOB,
          empty BLOB,
          n TEXT
        )
        """, binds: [])
      _ = try await session.command(
        """
        INSERT INTO cells (i, r, s, j, bad, plain, b, empty, n)
        VALUES (7, 1.5, 'hi', '{"a":1}', 'nope', '{"a":1}', X'000AFF', X'', NULL)
        """, binds: [])
      let selected = try await collect(
        session, "SELECT i, r, s, j, bad, plain, b, empty, n FROM cells")
      #expect(
        selected.rows == [
          [
            .int(7),
            .double(1.5),
            .string("hi"),
            .json(#"{"a":1}"#),
            .string("nope"),
            .string(#"{"a":1}"#),
            .data(Data([0x00, 0x0A, 0xFF])),
            .data(Data()),
            .null,
          ]
        ])
    }
  }

  @Test("Stopping a read early leaves the temp table on the same connection")
  func cappedReadKeepsTempTable() async throws {
    try await withWritableDatabase { session in
      _ = try await session.command("CREATE TEMP TABLE kept (id INTEGER)", binds: [])
      _ = try await session.command("INSERT INTO kept (id) VALUES (1)", binds: [])
      let source = try await session.query(
        """
        WITH RECURSIVE c(x) AS (
          SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 50000000
        )
        SELECT x FROM c
        """, binds: [])
      let start = ContinuousClock.now
      var seen = 0
      for try await _ in source.rows {
        seen += 1
        if seen == 3 { break }
      }
      #expect(seen == 3)
      #expect(start.duration(to: .now) < .seconds(3))
      let kept = try await collect(session, "SELECT id FROM kept")
      #expect(kept.rows == [[.int(1)]])
    }
  }

  @Test("interrupt cancels a recursive aggregate without closing the session")
  func interruptCancelsRecursiveCTE() async throws {
    try await withWritableDatabase(statementTimeoutSeconds: 30) { session in
      let gate = FinishGate()
      let running = Task {
        defer { gate.finish() }
        let source = try await session.query(Self.longAggregate, binds: [])
        for try await _ in source.rows {}
      }
      let start = ContinuousClock.now
      while !gate.isFinished, start.duration(to: .now) < .seconds(3) {
        await session.interrupt()
        try await Task.sleep(for: .milliseconds(25))
      }
      let error = try #require(
        await #expect(throws: SQLiteSessionError.self) {
          try await running.value
        })
      let message = session.formatError(error)
      #expect(message.contains("interrupted"))
      #expect(!message.contains("timed out"))
      #expect(!message.contains(Self.secretPassword))
      #expect(start.duration(to: .now) < .seconds(8))
      let stillOpen = try await collect(session, "SELECT 1")
      #expect(stillOpen.rows == [[.int(1)]])
    }
  }

  @Test("The progress handler stops a statement at the connection timeout")
  func progressHandlerTimeout() async throws {
    try await withWritableDatabase(statementTimeoutSeconds: 1) { session in
      let start = ContinuousClock.now
      let error = try #require(
        await #expect(throws: SQLiteSessionError.self) {
          let source = try await session.query(Self.longAggregate, binds: [])
          for try await _ in source.rows {}
        })
      let message = session.formatError(error)
      #expect(message.contains("timed out"))
      #expect(!message.contains(Self.secretPassword))
      let elapsed = start.duration(to: .now)
      #expect(elapsed < .seconds(5))
      let stillOpen = try await collect(session, "SELECT 1")
      #expect(stillOpen.rows == [[.int(1)]])
    }
  }

  @Test("A read-only open rejects a write and keeps the bound value out of the error")
  func readOnlyOpenRejectsWrite() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let writing = SQLiteSession(config: makeConfig(path: url.path))
    try await writing.open()
    _ = try await writing.command("CREATE TABLE notes (body TEXT)", binds: [])
    _ = try await writing.command(
      "INSERT INTO notes (body) VALUES (?)", binds: [.text("kept")])
    await writing.close()

    let reading = SQLiteSession(config: makeConfig(path: url.path, readOnlyFile: true))
    try await reading.open()
    let visible = try await collect(reading, "SELECT body FROM notes")
    #expect(visible.rows == [[.string("kept")]])
    let error = try #require(
      await #expect(throws: SQLiteSessionError.self) {
        try await reading.command(
          "INSERT INTO notes (body) VALUES (?)", binds: [.text(Self.secretBind)])
      })
    let message = reading.formatError(error)
    #expect(message.localizedCaseInsensitiveContains("readonly"))
    #expect(!message.contains(Self.secretBind))
    #expect(!message.contains(Self.secretPassword))
    let unchanged = try await collect(reading, "SELECT body FROM notes")
    #expect(unchanged.rows == [[.string("kept")]])
    await reading.close()
  }

  @Test("BEGIN, ROLLBACK, and a savepoint rollback leave the committed row")
  func transactionAndSavepointRollback() async throws {
    try await withWritableDatabase { session in
      _ = try await session.command("CREATE TABLE t (id INTEGER)", binds: [])
      let begin = try await session.command("BEGIN", binds: [])
      #expect(begin.tag == "BEGIN")
      let inserted = try await session.command(
        "INSERT INTO t (id) VALUES (?)", binds: [.text("1")])
      #expect(inserted.affectedRows == 1)
      let rolledBack = try await session.command("ROLLBACK", binds: [])
      #expect(rolledBack.tag == "ROLLBACK")
      let empty = try await collect(session, "SELECT COUNT(*) FROM t")
      #expect(empty.rows == [[.int(0)]])

      _ = try await session.command("BEGIN", binds: [])
      _ = try await session.command("INSERT INTO t (id) VALUES (?)", binds: [.text("2")])
      _ = try await session.command("SAVEPOINT mark", binds: [])
      _ = try await session.command("INSERT INTO t (id) VALUES (?)", binds: [.text("3")])
      _ = try await session.command("ROLLBACK TO mark", binds: [])
      let committed = try await session.command("COMMIT", binds: [])
      #expect(committed.tag == "COMMIT")
      let left = try await collect(session, "SELECT id FROM t")
      #expect(left.rows == [[.int(2)]])
    }
  }

  @Test("openCursor throws because SQLite has no server cursor")
  func openCursorUnsupported() async throws {
    try await withWritableDatabase { session in
      let error = try #require(
        await #expect(throws: SQLiteSessionError.self) {
          try await session.openCursor("SELECT 1", binds: [])
        })
      let message = session.formatError(error)
      #expect(message.localizedCaseInsensitiveContains("cursor"))
      #expect(!message.contains(Self.secretPassword))
    }
  }

  private func withWritableDatabase(
    statementTimeoutSeconds: Int = 60,
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let session = SQLiteSession(
      config: makeConfig(path: url.path, statementTimeoutSeconds: statementTimeoutSeconds))
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func collect(
    _ session: SQLiteSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> (columns: [ColumnInfo], rows: [[CellValue]]) {
    let source = try await session.query(sql, binds: binds)
    var rows: [[CellValue]] = []
    for try await row in source.rows {
      rows.append(row)
    }
    return (source.columns, rows)
  }

  private func makeConfig(
    path: String, readOnlyFile: Bool = false, statementTimeoutSeconds: Int = 60
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      database: path,
      username: "unused",
      password: Self.secretPassword,
      sslMode: .disable,
      statementTimeoutSeconds: statementTimeoutSeconds,
      readOnlyFile: readOnlyFile
    )
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-session-\(UUID().uuidString).db")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-journal"))
  }
}

/// Set when a query task has left `query`. The interrupt loop stops once the statement returns.
private final class FinishGate: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func finish() {
    lock.lock()
    finished = true
    lock.unlock()
  }
}
