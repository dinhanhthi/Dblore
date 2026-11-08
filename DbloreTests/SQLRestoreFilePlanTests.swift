// SQLRestoreFilePlanTests.swift
// A dump planned from its file (pass 1, read in chunks) gives the plan its text gives: counts,
// kinds, drops, digests, the gate's classification and the Safe Mode rows. Rows past their cap
// refuse the file; a statement over the cap is numbered as the planner numbers statements.

import CryptoKit
import Foundation
import Testing

@testable import Dblore

@Suite("SQL restore file plan")
struct SQLRestoreFilePlanTests {

  // MARK: - Fixtures

  static func script(
    _ engine: DatabaseType, version: Int = 2, _ statements: [String]
  )
    -> String
  {
    let header = SQLDumpAssembler.header(
      engine: engine, created: Date(timeIntervalSince1970: 1_760_000_000), version: version)
    return ([header] + statements).map { $0 + "\n" }.joined()
  }

  /// Drops, a cut preview, a backslash string, a sequence value and multi-byte data
  static let postgresDump = script(
    .postgresql,
    [
      "-- Not dumped: functions, procedures, extensions, roles, ownership, grants",
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "DROP TABLE IF EXISTS \"app\".\"events\", app.Logs;",
      "DROP TYPE IF EXISTS \"app\".\"mood\";",
      "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok');",
      "CREATE SEQUENCE \"app\".\"logs_id_seq\" AS integer START WITH 1;",
      "CREATE TABLE \"app\".\"events\" (\"at\" date) PARTITION BY RANGE (at);",
      "CREATE TABLE app.logs (\"id\" integer, \"code\" text,\n"
        + (1...12).map { "  \"column_\($0)\" integer DEFAULT \($0)" }.joined(separator: ",\n")
        + "\n);",
      "INSERT INTO \"app\".\"logs\" (\"id\", \"code\") VALUES\n('1', 'é😀;列'),\n('2', NULL);",
      "ALTER TABLE \"app\".\"logs\" ADD CONSTRAINT \"logs_code\" CHECK ((code ~ '^\\d+$'::text));",
      "SELECT pg_catalog.setval('\"app\".\"logs_id_seq\"', 2, true);",
      "CREATE VIEW \"app\".\"v\" AS SELECT 1;",
    ])

  /// Drops and a trigger (whole text behind "Show full statement")
  static let sqliteDump = script(
    .sqlite,
    [
      "PRAGMA defer_foreign_keys = ON;", "DROP VIEW IF EXISTS \"V\";",
      "DROP TABLE IF EXISTS \"Parent\";",
      "CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);",
      "CREATE TABLE log (msg TEXT);",
      "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(1, 'a;b'),\n(2, 'ß😀');",
      "CREATE VIEW v AS SELECT 1;",
      "CREATE TRIGGER parent_log AFTER INSERT ON parent BEGIN\n"
        + "  INSERT INTO log VALUES ('added; ' || new.name);\nEND;",
      "DELETE FROM sqlite_sequence WHERE name = 'parent';",
      "INSERT INTO sqlite_sequence (name, seq) VALUES ('parent', 2);",
    ])

  static let duckdbDump = script(
    .duckdb,
    [
      "CREATE SCHEMA IF NOT EXISTS \"S\";", "DROP VIEW IF EXISTS \"main\".\"v\";",
      "DROP TABLE IF EXISTS \"S\".\"t\";",
      "CREATE SEQUENCE \"main\".\"seq1\" START WITH 9 INCREMENT BY 2 MINVALUE 1"
        + " MAXVALUE 9223372036854775807 NO CYCLE;",
      "CREATE TABLE s.t(id INTEGER);", "CREATE TABLE t1(id INTEGER DEFAULT(nextval('seq1')));",
      "INSERT INTO \"main\".\"t1\" (\"id\") VALUES\n('1'),\n('2');", "CREATE VIEW v AS SELECT 1;",
    ])

  /// (engine, the file's text, the same dump as `init(script:)` takes it: decoded, no byte order
  /// mark)
  static let fixtures: [(DatabaseType, String, String)] = [
    (.postgresql, postgresDump, postgresDump),
    (.postgresql, "\u{FEFF}" + postgresDump, postgresDump),
    (.sqlite, sqliteDump, sqliteDump), (.duckdb, duckdbDump, duckdbDump),
    (.mysql, MySQLDumpFixtures.mysqlDump, MySQLDumpFixtures.mysqlDump),
    (.mysql, MySQLDumpFixtures.mariaDBDump, MySQLDumpFixtures.mariaDBDump),
  ]

  static func file(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-file-plan-\(UUID().uuidString).sql")
    try Data(text.utf8).write(to: url)
    return url
  }

  private static func hash(_ text: String) -> SHA256Digest { SHA256.hash(data: Data(text.utf8)) }

  /// The digests pass 1 binds: each split piece that holds a statement (on MySQL a session
  /// line runs as its opened text, so the piece, not the text sent, is what the file holds)
  private static func pieceDigests(_ text: String, _ engine: DatabaseType) -> [SHA256Digest] {
    let sandbox = engine == .mysql ? SQLRestorePlan.mariaDBSandboxPrefix(text) : 0
    return SQLTokenizer(dialect: engine.dialect)
      .splitStatements(scalars: Array(text.unicodeScalars.dropFirst(sandbox)))
      .filter { SQLStatementClassifier.classifyStatement($0, dialect: engine.dialect) != nil }
      .map(hash)
  }

  // MARK: - Tests

  @Test("A plan from the file equals the plan from its text, at any chunk size")
  func filePlanEqualsTextPlan() throws {
    for (engine, fileText, text) in Self.fixtures {
      let memory = try SQLRestorePlan(script: text, engine: engine)
      let url = try Self.file(fileText)
      defer { try? FileManager.default.removeItem(at: url) }
      for chunkSize in [7, 1_048_576] {
        let label = "\(engine) chunk \(chunkSize)"
        var reports: [SQLRestoreReadProgress] = []
        let plan = try SQLRestorePlan(
          file: url, engine: engine, chunkSize: chunkSize
        ) { reports.append($0) }
        let size = Data(fileText.utf8).count
        #expect(reports.last == .reading(bytesRead: size, byteCount: size), "\(label)")
        guard case .file(let source, let records) = plan.source else {
          Issue.record("\(label): not a file-backed plan")
          continue
        }
        #expect(source == url)
        #expect(plan.engine == memory.engine)
        #expect(plan.summary == memory.summary, "\(label)")
        #expect(plan.kinds == memory.kinds, "\(label)")
        #expect(records.map(\.kind) == memory.kinds, "\(label)")
        #expect(
          records.map(\.classification)
            == memory.statements.map(SQLRestorePlan.GateClassification.init), "\(label)")
        #expect(records.map(\.digest) == Self.pieceDigests(text, engine), "\(label)")
        if engine != .mysql {
          #expect(records.map(\.digest) == memory.statements.map { Self.hash($0.text) })
        }
        #expect(plan.standardStringsStatement == memory.standardStringsStatement, "\(label)")
        #expect(plan.postgresDrops == memory.postgresDrops, "\(label)")
        #expect(plan.droppedSQLiteTables == memory.droppedSQLiteTables, "\(label)")
        #expect(plan.droppedSQLiteNames == memory.droppedSQLiteNames, "\(label)")
        #expect(plan.droppedDuckDBSchemas == memory.droppedDuckDBSchemas, "\(label)")
        #expect(plan.mariaDBStatements == memory.mariaDBStatements, "\(label)")
        #expect(
          DatabaseBackupModel.restoreConfirmation(plan)
            == DatabaseBackupModel.restoreConfirmation(memory), "\(label)")
      }
    }
    // The fixtures reach every field compared above
    let plans = try Self.fixtures.map { try SQLRestorePlan(script: $0.2, engine: $0.0) }
    #expect(plans.contains { $0.postgresDrops != nil && $0.standardStringsStatement != nil })
    #expect(plans.contains { !$0.droppedSQLiteTables.isEmpty })
    #expect(plans.contains { !$0.droppedDuckDBSchemas.isEmpty })
    #expect(plans.contains { !$0.mariaDBStatements.isEmpty })
    let rows = plans.flatMap(DatabaseBackupModel.restoreConfirmation)
    #expect(rows.contains { $0.isTruncated } && rows.contains { $0.kindLabel == "Trigger" })
  }

  @Test("Safe Mode rows past their cap refuse the file in pass 1")
  func confirmationCap() throws {
    #expect(SQLRestorePlan.maxConfirmationBytes == 16 * 1024 * 1024)
    let url = try Self.file(Self.postgresDump)
    defer { try? FileManager.default.removeItem(at: url) }
    let memory = try SQLRestorePlan(script: Self.postgresDump, engine: .postgresql)
    let bytes = DatabaseBackupModel.restoreConfirmation(memory).reduce(0) {
      $0 + $1.preview.utf8.count + ($1.fullText?.utf8.count ?? 0)
    }
    _ = try SQLRestorePlan(file: url, engine: .postgresql, maxConfirmationBytes: bytes)
    #expect(throws: SQLRestoreError.confirmationTooLarge) {
      try SQLRestorePlan(file: url, engine: .postgresql, maxConfirmationBytes: bytes - 1)
    }
    #expect(
      SQLRestoreError.confirmationTooLarge.errorDescription
        == "This dump has more schema statements than Dblore can list for confirmation (over "
        + "16 MiB of text). Nothing was executed.")
  }

  @Test("A statement over the cap is numbered as the planner numbers statements")
  func statementTooLargeIndex() throws {
    // The comment-only piece takes no statement number
    let insert =
      "INSERT INTO \"app\".\"t\" (\"v\") VALUES\n('" + String(repeating: "x", count: 300)
      + "');"
    let url = try Self.file(
      Self.script(.postgresql, ["CREATE SCHEMA IF NOT EXISTS \"app\";", "/* note */;", insert]))
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      _ = try SQLRestorePlan(
        file: url, engine: .postgresql, chunkSize: 64, maxStatementBytes: 200)
      Issue.record("The statement over the cap was read")
    } catch SQLRestoreError.statementTooLarge(let index, _) {
      #expect(index == 1)
    }
  }
}
