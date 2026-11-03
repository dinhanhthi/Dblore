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

  @Test("An interrupt with no running statement does not stop the next statement")
  func idleInterruptDoesNotStopNextStatement() async throws {
    try await withWritableDatabase(statementTimeoutSeconds: 30) { session in
      await session.interrupt()
      // Long enough to reach the progress handler, which checks the interrupt flag
      let counted = """
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 100000)
        SELECT max(x) FROM c
        """
      // A read first: a command resets the flag when it starts, a read relies on the guard
      let read = try await collect(session, counted)
      #expect(read.rows == [[.int(100000)]])
      let command = try await session.command("CREATE TABLE n AS " + counted, binds: [])
      #expect(command.tag == "CREATE")
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

  @Test("A statement timeout of 0 disables the interrupt timer (the SQL dump setting)")
  func zeroStatementTimeoutDisablesTimer() async throws {
    try await withWritableDatabase(statementTimeoutSeconds: 1) { session in
      try await session.applySessionSettings(
        statementTimeoutSeconds: 0, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
      let count = 40_000_000
      let start = ContinuousClock.now
      let result = try await collect(
        session,
        """
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT \(count))
        SELECT max(x) FROM c
        """)
      #expect(result.rows == [[.int(count)]])
      // The statement outlived the 1 s brake it was opened with
      #expect(start.duration(to: .now) > .seconds(1))
      let command = try await session.command(
        "CREATE TABLE t AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c"
          + " LIMIT \(count)) SELECT max(x) AS m FROM c", binds: [])
      #expect(command.tag == "CREATE")
    }
  }

  @Test(
    "A read-only open (tab or snapshot) sees rows still in another connection's WAL",
    arguments: [false, true])
  func readOnlyOpenReadsWAL(snapshotReadOnly: Bool) async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let writing = SQLiteSession(config: makeConfig(path: url.path))
    try await writing.open()
    _ = try await collect(writing, "PRAGMA journal_mode = WAL")
    _ = try await collect(writing, "PRAGMA wal_autocheckpoint = 0")
    _ = try await writing.command("CREATE TABLE notes (body TEXT)", binds: [])
    _ = try await writing.command("INSERT INTO notes (body) VALUES ('in the wal')", binds: [])

    let reading = SQLiteSession(
      config: makeConfig(path: url.path, readOnlyFile: true), snapshotReadOnly: snapshotReadOnly)
    try await reading.open()
    let visible = try await collect(reading, "SELECT body FROM notes")
    #expect(visible.rows == [[.string("in the wal")]])
    await #expect(throws: SQLiteSessionError.self) {
      try await reading.command("INSERT INTO notes (body) VALUES ('x')", binds: [])
    }
    await reading.close()
    let unchanged = try await collect(writing, "SELECT body FROM notes")
    #expect(unchanged.rows == [[.string("in the wal")]])
    await writing.close()
  }

  @Test("A read-only WAL file whose -shm cannot be created still opens (immutable fallback)")
  func readOnlyOpenFallsBackWhenSidecarsDenied() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-ro-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("locked.db")
    let writing = SQLiteSession(config: makeConfig(path: url.path))
    try await writing.open()
    _ = try await collect(writing, "PRAGMA journal_mode = WAL")
    _ = try await writing.command("CREATE TABLE notes (body TEXT)", binds: [])
    _ = try await writing.command("INSERT INTO notes (body) VALUES ('checkpointed')", binds: [])
    _ = try await collect(writing, "PRAGMA wal_checkpoint(TRUNCATE)")
    await writing.close()
    // The system SQLite keeps empty sidecars after the last close. Without them, and in a folder
    // the process cannot write, a normal read-only open cannot create the -shm.
    let fileManager = FileManager.default
    try? fileManager.removeItem(atPath: url.path + "-wal")
    try? fileManager.removeItem(atPath: url.path + "-shm")
    try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }
    let reading = SQLiteSession(config: makeConfig(path: url.path, readOnlyFile: true))
    try await reading.open()
    let visible = try await collect(reading, "SELECT body FROM notes")
    #expect(visible.rows == [[.string("checkpointed")]])
    // A normal read-only open would have created the -shm: none means immutable=1 ran
    #expect(!fileManager.fileExists(atPath: url.path + "-shm"))
    await #expect(throws: SQLiteSessionError.self) {
      try await reading.command("INSERT INTO notes (body) VALUES ('x')", binds: [])
    }
    await reading.close()
  }

  @Test("A read-only open of a file another connection holds EXCLUSIVE reads the committed rows")
  func readOnlyOpenFallsBackWhenExclusivelyLocked() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let writing = SQLiteSession(config: makeConfig(path: url.path))
    try await writing.open()
    _ = try await writing.command("CREATE TABLE notes (body TEXT)", binds: [])
    _ = try await writing.command("INSERT INTO notes (body) VALUES ('committed')", binds: [])
    _ = try await writing.command("BEGIN EXCLUSIVE", binds: [])
    _ = try await writing.command("INSERT INTO notes (body) VALUES ('pending')", binds: [])

    // Waits out the busy timeout, then opens with immutable=1 as before the mode=ro probe
    let reading = SQLiteSession(config: makeConfig(path: url.path, readOnlyFile: true))
    try await reading.open()
    let visible = try await collect(reading, "SELECT body FROM notes")
    #expect(visible.rows == [[.string("committed")]])
    await reading.close()
    _ = try await writing.command("ROLLBACK", binds: [])
    await writing.close()
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

  @Test("A keyless UPDATE by rowid and typed IS values changes exactly the one row it read")
  func keylessUpdateChangesOneRow() async throws {
    try await withWritableDatabase { session in
      _ = try await session.command("CREATE TABLE t(a, b REAL, c)", binds: [])
      // Two identical rows (rowid tells them apart), an integer stored into the REAL column
      _ = try await session.command(
        "INSERT INTO t VALUES (1, 2.5, 'x'), (1, 2.5, 'x'), (2, 3, 'y')", binds: [])
      let table = try #require(
        try await SQLiteSchemaIntrospector().editTable(named: "t", in: session))
      let kind = try #require(table.rowLocator)
      let target = EditTarget(
        qualifiedName: table.qualifiedName, tableID: .sqlite(schema: "main", table: "t"),
        primaryKeyColumns: [], rowLocator: kind)
      let read = try await collect(session, "SELECT rowid, a, b, c FROM t ORDER BY rowid")
      let columns = Array(read.columns.dropFirst())
      let locators = read.rows.map { row in
        RowLocatorValues(
          texts: [CellUpdateStatement.inputText(row[0], dialect: .sqlite) ?? ""],
          row: Dictionary(uniqueKeysWithValues: zip(columns.map(\.name), row.dropFirst())))
      }

      // Staged path: the second of the two identical rows
      var set = RowChangeSet(target: target)
      try set.stageEdit(
        row: RowChangeSet.RowKey(locator: locators[1]), column: "c", value: .string("staged"),
        original: .string("x"))
      let staged = try #require(
        try RowChangeSQLBuilder.statements(
          for: set, target: target, columns: columns, dialect: .sqlite
        ).first)
      #expect(staged.sql == #"UPDATE "main"."t" SET "c" = ?1 WHERE rowid = ?2 AND "b" IS ?3"#)
      #expect(try await session.command(staged.sql, binds: staged.binds).affectedRows == 1)

      // Single-cell path: the row whose integer was stored as REAL
      let cell = try CellUpdateStatement.make(
        qualifiedName: table.qualifiedName, assignments: [(column: "c", value: "cell")],
        primaryKeyColumns: [], rowData: locators[2].row, dialect: .sqlite, rowLocator: kind,
        locator: locators[2])
      #expect(try await session.command(cell.sql, binds: cell.binds).affectedRows == 1)

      let after = try await collect(session, "SELECT c FROM t ORDER BY rowid")
      #expect(after.rows == [[.string("x")], [.string("staged")], [.string("cell")]])

      // STRICT keyless table: a number in an ANY column is not compared, rowid names the row
      _ = try await session.command("CREATE TABLE s(a ANY, b TEXT) STRICT", binds: [])
      _ = try await session.command("INSERT INTO s VALUES (5, 'x'), (5, 'x')", binds: [])
      let strict = try #require(
        try await SQLiteSchemaIntrospector().editTable(named: "s", in: session))
      let strictKind = try #require(strict.rowLocator)
      let strictRead = try await collect(session, "SELECT rowid, a, b FROM s ORDER BY rowid")
      let strictColumns = Array(strictRead.columns.dropFirst())
      let first = strictRead.rows[0]
      let firstRow = Dictionary(
        uniqueKeysWithValues: zip(strictColumns.map(\.name), first.dropFirst()))
      let strictCell = try CellUpdateStatement.make(
        qualifiedName: strict.qualifiedName, assignments: [(column: "b", value: "y")],
        primaryKeyColumns: [], rowData: firstRow, dialect: .sqlite, rowLocator: strictKind,
        locator: RowLocatorValues(
          texts: [CellUpdateStatement.inputText(first[0], dialect: .sqlite) ?? ""], row: firstRow))
      #expect(strictCell.sql == #"UPDATE "main"."s" SET "b" = ?1 WHERE rowid = ?2 AND "b" IS ?3"#)
      #expect(try await session.command(strictCell.sql, binds: strictCell.binds).affectedRows == 1)
      let strictAfter = try await collect(session, "SELECT b FROM s ORDER BY rowid")
      #expect(strictAfter.rows == [[.string("y")], [.string("x")]])
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
