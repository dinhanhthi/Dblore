// SQLRestoreStreamTests.swift
// Pass 2 of a file-backed restore (`RestoreStatementSource`): an unchanged file hands out the
// statements the text plan sends; a statement changed, missing or added after pass 1, or a file
// that no longer reads, stops at that statement with "the file changed", never the pass-1 error.
// Through `executeGatedRestore`, a file-backed plan sends what its text plan sends, and a changed
// statement is never sent (PostgreSQL / SQLite roll back, MySQL stops before it and resets).

import Foundation
import Testing

@testable import Dblore

@Suite("SQL restore stream")
struct SQLRestoreStreamTests {

  // MARK: - Helpers

  private typealias Fixtures = SQLRestoreFilePlanTests

  /// Plans `text` from its file (pass 1), then writes `changed` (when given) over it
  private static func plan(
    _ text: String, _ engine: DatabaseType, then changed: String? = nil
  ) throws -> (SQLRestorePlan, URL) {
    let url = try Fixtures.file(text)
    let plan = try SQLRestorePlan(file: url, engine: engine)
    if let changed { try Data(changed.utf8).write(to: url) }
    return (plan, url)
  }

  /// Every statement handed out, then the error that stopped the read (nil at the end)
  private static func drain(
    _ source: inout RestoreStatementSource
  ) -> ([SQLRestorePlanner.Accepted], Error?) {
    var yielded: [SQLRestorePlanner.Accepted] = []
    do {
      while let accepted = try source.next() { yielded.append(accepted) }
      return (yielded, nil)
    } catch {
      return (yielded, error)
    }
  }

  /// The index of the first statement of the text plan whose text holds `fragment`
  private static func index(
    of fragment: String, in text: String, _ engine: DatabaseType
  ) throws
    -> Int
  {
    let memory = try SQLRestorePlan(script: text, engine: engine)
    return try #require(memory.statements.firstIndex { $0.text.contains(fragment) })
  }

  /// Statements before `index` handed out, then `fileChanged(index:)`, again on the next call
  private static func expectChanged(
    _ plan: SQLRestorePlan, at index: Int, _ label: String = "", chunkSize: Int = 1_048_576,
    maxStatementBytes: Int = SQLRestorePlan.maxStatementBytes
  ) throws {
    var source = try RestoreStatementSource(
      plan: plan, chunkSize: chunkSize, maxStatementBytes: maxStatementBytes)
    let (yielded, error) = Self.drain(&source)
    #expect(yielded.map(\.index) == Array(0..<index), "\(label)")
    #expect(
      error as? SQLRestoreError == .fileChanged(index: index, engine: plan.engine), "\(label)")
    #expect(source.yielded == index, "\(label)")
    #expect(throws: SQLRestoreError.fileChanged(index: index, engine: plan.engine)) {
      try source.next()
    }
  }

  // MARK: - Unchanged file

  @Test("An unchanged file hands out the statements the text plan sends, at any chunk size")
  func unchangedFile() throws {
    for (engine, fileText, text) in Fixtures.fixtures {
      let memory = try SQLRestorePlan(script: text, engine: engine)
      let (plan, url) = try Self.plan(fileText, engine)
      defer { try? FileManager.default.removeItem(at: url) }
      for chunkSize in [7, 1_048_576] {
        let label = "\(engine) chunk \(chunkSize)"
        var source = try RestoreStatementSource(plan: plan, chunkSize: chunkSize)
        #expect(source.total == memory.statements.count, "\(label)")
        let (yielded, error) = Self.drain(&source)
        #expect(error == nil, "\(label): \(String(describing: error))")
        #expect(!yielded.isEmpty, "\(label)")
        #expect(yielded.map(\.statement) == memory.statements, "\(label)")
        #expect(yielded.map(\.kind) == memory.kinds, "\(label)")
        #expect(yielded.map(\.index) == Array(memory.statements.indices), "\(label)")
        #expect(source.yielded == memory.statements.count, "\(label)")
        #expect(try source.next() == nil, "\(label)")
      }
    }
  }

  // MARK: - Changed file

  @Test("Same-length bytes changed in place stop at that statement (bound by digest, not range)")
  func changedInPlace() throws {
    let cases: [(DatabaseType, String, String, String)] = [
      (.postgresql, Fixtures.postgresDump, "('2', NULL)", "('3', NULL)"),
      (.sqlite, Fixtures.sqliteDump, "(2, 'ß😀')", "(3, 'ß😀')"),
      (.duckdb, Fixtures.duckdbDump, "('2')", "('3')"),
      (.mysql, MySQLDumpFixtures.mysqlDump, "(10,1,'fruit')", "(19,1,'fruit')"),
      (.mysql, MySQLDumpFixtures.mariaDBDump, "(10,1,'fruit')", "(19,1,'fruit')"),
    ]
    for (engine, text, from, to) in cases {
      #expect(text.contains(from), "\(engine)")
      let changed = text.replacingOccurrences(of: from, with: to)
      #expect(changed.utf8.count == text.utf8.count)
      let index = try Self.index(of: from, in: text, engine)
      let (plan, url) = try Self.plan(text, engine, then: changed)
      defer { try? FileManager.default.removeItem(at: url) }
      try Self.expectChanged(plan, at: index, "\(engine)")
    }
  }

  @Test("A statement added after pass 1 is never handed out")
  func appendedStatement() throws {
    let cases: [(DatabaseType, String, String)] = [
      (.postgresql, Fixtures.postgresDump, "CREATE VIEW \"app\".\"w\" AS SELECT 1;\n"),
      (.postgresql, Fixtures.postgresDump, "DROP TABLE big;\n"),
      (.postgresql, Fixtures.postgresDump, "DROP TABLE IF EXISTS \"app\".\"logs\";\n"),
      (
        .sqlite, Fixtures.sqliteDump,
        "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(3, 'c');\n"
      ),
      (.duckdb, Fixtures.duckdbDump, "CREATE VIEW w AS SELECT 1;\n"),
      (.mysql, MySQLDumpFixtures.mysqlDump, "INSERT INTO `tags` VALUES (12,1,'x');\n"),
    ]
    for (engine, text, appended) in cases {
      let (plan, url) = try Self.plan(text, engine, then: text + appended)
      defer { try? FileManager.default.removeItem(at: url) }
      try Self.expectChanged(plan, at: plan.summary.statementCount, "\(engine) \(appended)")
    }
  }

  @Test("A file cut after pass 1 stops at the first statement it lost or cut")
  func truncatedFile() throws {
    let text = Fixtures.postgresDump
    // Cut before the last statement: missing at the end of the file
    let last = try #require(text.range(of: "CREATE VIEW \"app\".\"v\""))
    let (before, url) = try Self.plan(text, .postgresql, then: String(text[..<last.lowerBound]))
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.expectChanged(before, at: before.summary.statementCount - 1, "missing")
    // Cut inside a statement: its piece differs
    let insert = try #require(text.range(of: "('2', NULL)"))
    let index = try Self.index(of: "('2', NULL)", in: text, .postgresql)
    let (inside, other) = try Self.plan(
      text, .postgresql, then: String(text[..<insert.lowerBound]))
    defer { try? FileManager.default.removeItem(at: other) }
    try Self.expectChanged(inside, at: index, "cut")
  }

  @Test("A file that no longer reads stops with the file changed, not the pass-1 error")
  func pass2ReadErrors() throws {
    // A NUL in a SQLite statement (pass 1 would say `containsNUL`)
    let nul = Fixtures.sqliteDump.replacingOccurrences(of: "'a;b'", with: "'a\0b'")
    #expect(nul != Fixtures.sqliteDump)
    let (sqlite, url) = try Self.plan(Fixtures.sqliteDump, .sqlite, then: nul)
    defer { try? FileManager.default.removeItem(at: url) }
    // Found in the chunk that holds it: when the file is opened, or after statements before it
    for chunkSize in [16, 1_048_576] {
      let error: Error?
      do {
        var source = try RestoreStatementSource(plan: sqlite, chunkSize: chunkSize)
        error = Self.drain(&source).1
      } catch let thrown {
        error = thrown
      }
      guard case .fileChanged(_, .sqlite)? = error as? SQLRestoreError else {
        Issue.record("Expected fileChanged, got \(String(describing: error))")
        return
      }
    }
    // A cut code point (pass 1 would say `notUTF8`): the statements before it are handed out
    let bytes = Array(Fixtures.postgresDump.utf8)
    let emoji = try #require(bytes.firstIndex(of: 0xF0))
    let insert = try Self.index(of: "('2', NULL)", in: Fixtures.postgresDump, .postgresql)
    let (cut, cutURL) = try Self.plan(Fixtures.postgresDump, .postgresql)
    defer { try? FileManager.default.removeItem(at: cutURL) }
    try Data(bytes[...emoji]).write(to: cutURL)
    try Self.expectChanged(cut, at: insert, "cut code point", chunkSize: 16)
    // A statement the planner refuses (pass 1 would say `statementRefused`)
    let refused = Fixtures.postgresDump.replacingOccurrences(
      of: "CREATE VIEW \"app\".\"v\" AS SELECT 1;", with: "GRANT ALL ON app.logs TO x;")
    let view = try Self.index(of: "CREATE VIEW", in: Fixtures.postgresDump, .postgresql)
    let (postgres, other) = try Self.plan(Fixtures.postgresDump, .postgresql, then: refused)
    defer { try? FileManager.default.removeItem(at: other) }
    try Self.expectChanged(postgres, at: view, "refused")
    // A statement over the cap (pass 1 would say `statementTooLarge`)
    let table = try Self.index(of: "CREATE TABLE app.logs", in: Fixtures.postgresDump, .postgresql)
    try Self.expectChanged(
      postgres, at: table, "over the cap", chunkSize: 16, maxStatementBytes: 200)
  }

  @Test("A header changed after pass 1 stops before the first statement")
  func changedHeader() throws {
    let text = Fixtures.postgresDump
    let cases = [
      text.replacingOccurrences(of: "dump 2 engine=", with: "dump 1 engine="),
      text.replacingOccurrences(of: "engine=PostgreSQL", with: "engine=SQLite"),
      "-- something else\n" + text,
    ]
    for changed in cases {
      #expect(changed != text)
      let (plan, url) = try Self.plan(text, .postgresql, then: changed)
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(throws: SQLRestoreError.fileChanged(index: 0, engine: .postgresql)) {
        try RestoreStatementSource(plan: plan)
      }
    }
  }

  // MARK: - Runners

  /// Schema, sequence, data (one statement changed by `changedBetweenPasses`) and a view
  private static let postgresRun = Fixtures.script(
    .postgresql,
    [
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "CREATE SEQUENCE \"app\".\"s\" AS integer START WITH 1;",
      "CREATE TABLE \"app\".\"items\" (\"id\" integer, \"name\" text);",
      "INSERT INTO \"app\".\"items\" (\"id\", \"name\") VALUES\n('1', 'a'),\n('2', 'é😀');",
      "INSERT INTO \"app\".\"items\" (\"id\", \"name\") VALUES\n('3', 'c');",
      "SELECT pg_catalog.setval('\"app\".\"s\"', 2, true);",
      "CREATE VIEW \"app\".\"v\" AS SELECT 1;",
    ])

  private static let sqliteRun = Fixtures.script(
    .sqlite,
    [
      "PRAGMA defer_foreign_keys = ON;",
      "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT);",
      "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(1, 'a;b');",
      "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(2, 'c');",
      "CREATE INDEX parent_name ON parent (name);",
    ])

  /// What a MySQL restore sends after its statements, on every path (settings read as
  /// `connect` answers them)
  private static let mysqlReset = [
    "UNLOCK TABLES", "SET NAMES utf8mb4", "SET FOREIGN_KEY_CHECKS=1",
    "SET SESSION unique_checks = 1, sql_notes = 1",
    "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION', time_zone = '+00:00'",
    "SET @OLD_CHARACTER_SET_CLIENT = NULL, @OLD_CHARACTER_SET_RESULTS = NULL, "
      + "@OLD_COLLATION_CONNECTION = NULL, @OLD_TIME_ZONE = NULL, @OLD_UNIQUE_CHECKS = NULL, "
      + "@OLD_FOREIGN_KEY_CHECKS = NULL, @OLD_SQL_MODE = NULL, @OLD_SQL_NOTES = NULL, "
      + "@OLD_NOTE_VERBOSITY = NULL, @saved_cs_client = NULL",
  ]

  /// A fake connection; on MySQL it answers the restore's settings read (a MySQL 8.4 server)
  private static func connect(
    _ engine: DatabaseType, protectedMode: Bool = false
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let settings: [CellValue] = [
      .string("STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION"), .string("+00:00"), .int(1), .int(1),
      .string("8.4.11"),
    ]
    let factory = FakeDatabaseSessionFactory(
      capabilities: engine.capabilities, rows: engine == .mysql ? [settings] : [])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: engine, host: "fake", port: engine == .mysql ? 3306 : 5432,
        database: engine == .duckdb ? DuckDBSession.inMemoryPath : "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: protectedMode))
    return (manager, try #require(factory.sessions.last))
  }

  /// The restore's summary or error, and the statements it sent
  private static func restore(
    _ plan: SQLRestorePlan, protectedMode: Bool = false
  ) async throws -> (Result<SQLRestoreSummary, Error>, [String], DatabaseConnectionManager) {
    let (manager, session) = try await connect(plan.engine, protectedMode: protectedMode)
    let before = session.statements.count
    let result: Result<SQLRestoreSummary, Error>
    do {
      result = .success(
        try await manager.executeGatedRestore(
          plan, policy: ProtectionPolicy(protectionLevel: .none),
          connectionEpoch: await manager.connectionEpoch))
    } catch {
      result = .failure(error)
    }
    return (result, Array(session.statements.dropFirst(before)), manager)
  }

  @Test("A file-backed plan sends exactly what the text plan sends, in order")
  func fileRunMatchesTextRun() async throws {
    let cases: [(DatabaseType, String, String)] = [
      (.postgresql, Self.postgresRun, "('3', 'c')"), (.sqlite, Self.sqliteRun, "(2, 'c')"),
      (.mysql, MySQLDumpFixtures.mysqlDump, "(10,1,'fruit')"),
      (.mysql, MySQLDumpFixtures.mariaDBDump, "(10,1,'fruit')"),
    ]
    for (engine, text, data) in cases {
      let (plan, url) = try Self.plan(text, engine)
      defer { try? FileManager.default.removeItem(at: url) }
      let (expected, expectedSent, _) = try await Self.restore(
        try SQLRestorePlan(script: text, engine: engine))
      let (result, sent, _) = try await Self.restore(plan)
      #expect(try result.get() == expected.get(), "\(engine)")
      #expect(sent == expectedSent, "\(engine)")
      #expect(sent.contains { $0.contains(data) }, "\(engine)")
      switch engine {
      case .postgresql: #expect(sent.contains(DatabaseConnectionManager.SearchPathPin.pinSQL))
      case .mysql: #expect(Array(sent.suffix(Self.mysqlReset.count)) == Self.mysqlReset)
      default: #expect(sent.last == "COMMIT")
      }
    }
  }

  @Test("A changed statement is never sent: the batch rolls back, MySQL stops and resets")
  func changedBetweenPasses() async throws {
    let cases: [(DatabaseType, String, String, String)] = [
      (.postgresql, Self.postgresRun, "('3', 'c')", "('4', 'c')"),
      (.sqlite, Self.sqliteRun, "(2, 'c')", "(3, 'c')"),
      (.mysql, MySQLDumpFixtures.mysqlDump, "(10,1,'fruit')", "(19,1,'fruit')"),
    ]
    for (engine, text, from, to) in cases {
      let texts = try SQLRestorePlan(script: text, engine: engine).statements.map(\.text)
      let index = try Self.index(of: from, in: text, engine)
      let (plan, url) = try Self.plan(
        text, engine, then: text.replacingOccurrences(of: from, with: to))
      defer { try? FileManager.default.removeItem(at: url) }
      let (result, sent, manager) = try await Self.restore(plan)
      guard case .failure(let error) = result else {
        Issue.record("\(engine): the restore ran a changed file")
        continue
      }
      #expect(error as? SQLRestoreError == .fileChanged(index: index, engine: engine))
      #expect(!sent.contains { $0.contains(to) || $0.contains(from) }, "\(engine)")
      if engine == .mysql {
        #expect(sent.first == DatabaseConnectionManager.restoreSessionQuery)
        #expect(Array(sent.dropFirst().prefix(index)) == Array(texts[..<index]))
        #expect(Array(sent.dropFirst(1 + index)) == Self.mysqlReset)
      } else {
        #expect(sent.last == "ROLLBACK", "\(engine)")
        #expect(!sent.contains("COMMIT"), "\(engine)")
        #expect(Array(sent.dropLast().suffix(index)) == Array(texts[..<index]), "\(engine)")
        #expect(await manager.transactionSnapshot() == .idle, "\(engine)")
      }
    }
  }

  @Test("A statement appended after pass 1 is never sent, on every engine")
  func appendedStatementNeverSent() async throws {
    let duckdbRun = Fixtures.script(
      .duckdb,
      ["CREATE TABLE t1(id INTEGER);", "INSERT INTO \"main\".\"t1\" (\"id\") VALUES\n('1');"])
    let cases: [(DatabaseType, String, String, String)] = [
      (.postgresql, Self.postgresRun, "CREATE VIEW \"app\".\"w\" AS SELECT 1;\n", "\"w\""),
      (
        .sqlite, Self.sqliteRun, "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(3, 'z');\n",
        "'z'"
      ),
      (.duckdb, duckdbRun, "CREATE VIEW w AS SELECT 1;\n", "VIEW w"),
      (.mysql, MySQLDumpFixtures.mysqlDump, "INSERT INTO `tags` VALUES (12,1,'z');\n", "'z'"),
    ]
    for (engine, text, appended, fragment) in cases {
      let texts = try SQLRestorePlan(script: text, engine: engine).statements.map(\.text)
      let (plan, url) = try Self.plan(text, engine, then: text + appended)
      defer { try? FileManager.default.removeItem(at: url) }
      let (result, sent, manager) = try await Self.restore(plan)
      guard case .failure(let error) = result else {
        Issue.record("\(engine): the restore ran an appended statement")
        continue
      }
      #expect(
        error as? SQLRestoreError == .fileChanged(index: texts.count, engine: engine), "\(engine)")
      #expect(!sent.contains { $0.contains(fragment) }, "\(engine)")
      if engine == .mysql {
        #expect(sent == [DatabaseConnectionManager.restoreSessionQuery] + texts + Self.mysqlReset)
      } else {
        #expect(sent.last == "ROLLBACK", "\(engine)")
        #expect(!sent.contains("COMMIT"), "\(engine)")
        #expect(Array(sent.dropLast().suffix(texts.count)) == texts, "\(engine)")
        #expect(await manager.transactionSnapshot() == .idle, "\(engine)")
      }
    }
  }

  @Test("Pass 2 binds by digest: the same statements at other offsets run as checked")
  func movedStatementsRun() async throws {
    let view = "CREATE VIEW \"app\".\"v\" AS SELECT 1;"
    #expect(Self.postgresRun.contains(view))
    let (_, expectedSent, _) = try await Self.restore(
      try SQLRestorePlan(script: Self.postgresRun, engine: .postgresql))
    for moved in ["\n\n   \n", "/* moved */;\n", ";\n"] {
      let changed = Self.postgresRun.replacingOccurrences(of: view, with: moved + view)
      let (plan, url) = try Self.plan(Self.postgresRun, .postgresql, then: changed)
      defer { try? FileManager.default.removeItem(at: url) }
      let (result, sent, _) = try await Self.restore(plan)
      #expect(throws: Never.self, "\(moved.debugDescription)") { try result.get() }
      #expect(sent == expectedSent, "\(moved.debugDescription)")
    }
  }

  @Test("A statement one byte over the cap is refused in pass 1; one at the cap runs")
  func statementCap() async throws {
    let cap = 4_096
    let prefix = "INSERT INTO \"app\".\"items\" (\"id\", \"name\") VALUES\n('9', '"
    let insert = { (bytes: Int) in
      prefix + String(repeating: "x", count: bytes - prefix.utf8.count - 2) + "')"
    }
    let statements = [
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "CREATE TABLE \"app\".\"items\" (\"id\" integer, \"name\" text);",
    ]
    #expect(insert(cap).utf8.count == cap)
    let atCap = try Fixtures.file(Fixtures.script(.postgresql, statements + [insert(cap) + ";"]))
    defer { try? FileManager.default.removeItem(at: atCap) }
    let plan = try SQLRestorePlan(file: atCap, engine: .postgresql, maxStatementBytes: cap)
    var source = try RestoreStatementSource(plan: plan, maxStatementBytes: cap)
    let (yielded, error) = Self.drain(&source)
    #expect(error == nil)
    #expect(yielded.last?.statement.text == insert(cap))
    let over = try Fixtures.file(
      Fixtures.script(.postgresql, statements + [insert(cap + 1) + ";"]))
    defer { try? FileManager.default.removeItem(at: over) }
    #expect(throws: SQLRestoreError.statementTooLarge(index: 2, bytes: cap + 1)) {
      try SQLRestorePlan(file: over, engine: .postgresql, maxStatementBytes: cap)
    }
  }

  @Test("MySQL: a cancel while the next statement is read stops with the batch's cancel error")
  func mysqlCancelWhileReading() async throws {
    let (manager, session) = try await Self.connect(.mysql)
    await manager.setBatchCheckpointHook { _ in
      let status = await manager.runningStatementStatus()
      let outcome = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      #expect(outcome == .cancelled)
    }
    let insert = "INSERT INTO t VALUES (1)"
    let reads = ReadCount()
    let before = session.statements.count
    let error: Error?
    do {
      try await manager.executeGatedSequentialBatch(
        gated: SQLStatementClassifier.classify(insert, dialect: .mysql), total: 2,
        next: {
          // The file is read after the cancel: the stream's own check throws
          guard reads.next() == 1 else { throw CancellationError() }
          return insert
        }, policy: ProtectionPolicy(protectionLevel: .none),
        connectionEpoch: await manager.connectionEpoch)
      error = nil
    } catch let thrown {
      error = thrown
    }
    await manager.setBatchCheckpointHook(nil)
    guard
      case .batchPartiallyApplied(let applied, let total, let reason, _)? =
        error as? DatabaseError
    else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 1 && total == 2)
    #expect(
      reason
        == DatabaseError.queryCancelled(
          pendingCount: 0, userTxRolledBack: false, connectionKept: true
        ).errorDescription)
    #expect(Array(session.statements.dropFirst(before)) == [insert])
  }

  @Test("Protected mode records one pending summary per statement kind")
  func protectedModeSummaries() async throws {
    let (plan, url) = try Self.plan(Self.postgresRun, .postgresql)
    defer { try? FileManager.default.removeItem(at: url) }
    let (result, sent, manager) = try await Self.restore(plan, protectedMode: true)
    #expect(try result.get().pending)
    #expect(sent.contains("RELEASE SAVEPOINT \(DatabaseConnectionManager.batchSavepoint)"))
    // The pending list shows the kind label, then the text: one clean line per kind
    #expect(
      await manager.transactionSnapshot().pending.map { "\($0.kindLabel) \($0.sqlPreview)" } == [
        "RESTORE 4 schema statements", "RESTORE 2 data statements", "RESTORE 1 sequence value",
      ])
  }

  // MARK: - Messages

  @Test("The file-changed message says what ran, per engine")
  func messages() {
    for engine in [DatabaseType.postgresql, .sqlite, .duckdb] {
      #expect(
        SQLRestoreError.fileChanged(index: 4, engine: engine).errorDescription
          == "The file changed after it was checked (statement 5). The restore was rolled back.")
    }
    #expect(
      SQLRestoreError.fileChanged(index: 4, engine: .mysql).errorDescription
        == "The file changed after it was checked: statements 1 to 4 ran, statement 5 and later "
        + "did not.")
    #expect(
      SQLRestoreError.fileChanged(index: 1, engine: .mysql).errorDescription
        == "The file changed after it was checked: statement 1 ran, statement 2 and later did "
        + "not.")
    #expect(
      SQLRestoreError.fileChanged(index: 0, engine: .mysql).errorDescription
        == "The file changed after it was checked (statement 1). Nothing was executed.")
  }
}

/// How many times a statement source was read (its closure runs inside the connection actor)
private final class ReadCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  /// The read's number, from 1
  func next() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}
