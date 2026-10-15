// SQLiteFileBackupTests.swift
// SQLiteFileBackup against real files: plain and WAL copies, overwrite, refusal of the open
// database and its journal files, cancel and progress.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite("SQLite file backup")
struct SQLiteFileBackupTests {
  @Test func copiesASmallDatabase() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    try Self.exec(
      source.path,
      """
      CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, data BLOB);
      INSERT INTO notes VALUES (1, 'Hello', X'00FF'), (2, 'it''s', NULL);
      """)
    let destination = directory.appendingPathComponent("copy.db")
    let scratch = try Self.scratchDirectory(in: directory)

    let result = try await SQLiteFileBackup.copy(
      from: source, to: destination, temporaryDirectory: scratch)

    #expect(result.pageCount > 0)
    #expect(result.pagesCopied == result.pageCount)
    let sql = "SELECT id, body, quote(data) FROM notes ORDER BY id"
    #expect(
      try Self.query(destination.path, sql) == [["1", "Hello", "X'00FF'"], ["2", "it's", "NULL"]])
    #expect(try Self.leftovers(in: scratch).isEmpty)
    // Built private and moved in place: a new destination keeps the temporary file's mode
    let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
  }

  @Test func refusesADestinationWithJournalFilesOfAnotherDatabase() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    try Self.exec(source.path, "CREATE TABLE t (x); INSERT INTO t VALUES ('source');")
    // Another database's uncheckpointed WAL, left next to the destination's name
    let other = directory.appendingPathComponent("other.db")
    let writer = try Self.open(other.path)
    try Self.exec(
      writer,
      """
      PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
      CREATE TABLE t (x); INSERT INTO t VALUES ('other');
      """)
    let destination = directory.appendingPathComponent("copy.db")
    try FileManager.default.copyItem(
      atPath: other.path + "-wal", toPath: destination.path + "-wal")
    sqlite3_close_v2(writer)
    let scratch = try Self.scratchDirectory(in: directory)

    for suffix in ["-wal", "-journal", "-shm"] {
      let sidecar = destination.path + suffix
      if suffix != "-wal" { try Data("stale".utf8).write(to: URL(fileURLWithPath: sidecar)) }
      await #expect(
        throws: SQLiteFileBackupError.journalFileNextToDestination("copy.db" + suffix), "\(suffix)"
      ) {
        try await SQLiteFileBackup.copy(
          from: source, to: destination, temporaryDirectory: scratch)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path), "\(suffix)")
      try FileManager.default.removeItem(atPath: sidecar)
    }
    #expect(try Self.leftovers(in: scratch).isEmpty)
    #expect(
      SQLiteFileBackupError.journalFileNextToDestination("copy.db-wal").errorDescription
        == "Choose a different file: \"copy.db-wal\" next to it belongs to an earlier database."
        + " Delete it or pick another name.")

    // Without them the copy goes through and holds only the source's rows
    _ = try await SQLiteFileBackup.copy(from: source, to: destination, temporaryDirectory: scratch)
    #expect(try Self.query(destination.path, "SELECT x FROM t") == [["source"]])
  }

  @Test func copiesUncheckpointedRowsOfAWALDatabase() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    let writer = try Self.open(source.path)
    defer { sqlite3_close_v2(writer) }
    try Self.exec(
      writer,
      """
      PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
      CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
      INSERT INTO notes VALUES (1, 'in wal'), (2, 'also in wal');
      """)
    let walSize =
      try FileManager.default.attributesOfItem(atPath: source.path + "-wal")[.size] as? Int ?? 0
    #expect(walSize > 0)
    let destination = directory.appendingPathComponent("copy.db")
    let scratch = try Self.scratchDirectory(in: directory)

    _ = try await SQLiteFileBackup.copy(from: source, to: destination, temporaryDirectory: scratch)

    #expect(
      try Self.query(destination.path, "SELECT id, body FROM notes ORDER BY id")
        == [["1", "in wal"], ["2", "also in wal"]])
    #expect(try Self.leftovers(in: scratch).isEmpty)
  }

  @Test func replacesAnExistingDestination() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    try Self.exec(source.path, "CREATE TABLE t (x); INSERT INTO t VALUES (42);")
    let destination = directory.appendingPathComponent("copy.db")
    try Data("not a database".utf8).write(to: destination)

    _ = try await SQLiteFileBackup.copy(
      from: source, to: destination, temporaryDirectory: try Self.scratchDirectory(in: directory))

    #expect(try Self.query(destination.path, "SELECT x FROM t") == [["42"]])
  }

  @Test func refusesTheDatabaseAndItsJournalFiles() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.db")
    let writer = try Self.open(source.path)
    defer { sqlite3_close_v2(writer) }
    try Self.exec(
      writer,
      """
      PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
      CREATE TABLE t (x); INSERT INTO t VALUES (1);
      """)
    let linkToSource = directory.appendingPathComponent("link.db")
    try FileManager.default.createSymbolicLink(at: linkToSource, withDestinationURL: source)
    let linkToWAL = directory.appendingPathComponent("link-wal")
    try FileManager.default.createSymbolicLink(
      at: linkToWAL, withDestinationURL: URL(fileURLWithPath: source.path + "-wal"))
    let scratch = try Self.scratchDirectory(in: directory)
    let refused =
      [source, linkToSource, linkToWAL]
      + ["-wal", "-journal", "-shm"].map { URL(fileURLWithPath: source.path + $0) }
      + [directory.appendingPathComponent("./sub/../source.db")]

    for destination in refused {
      await #expect(throws: SQLiteFileBackupError.destinationIsDatabase, "\(destination.path)") {
        try await SQLiteFileBackup.copy(
          from: source, to: destination, temporaryDirectory: scratch)
      }
    }

    #expect(
      SQLiteFileBackupError.destinationIsDatabase.errorDescription
        == "Choose a different file: this is the open database.")
    #expect(try Self.query(source.path, "SELECT x FROM t") == [["1"]])
    #expect(try Self.leftovers(in: scratch).isEmpty)
  }

  @Test func cancelLeavesTheDestinationAndNoTemporaryFile() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try Self.largeDatabase(in: directory)
    let destination = directory.appendingPathComponent("copy.db")
    let original = Data("previous copy".utf8)
    try original.write(to: destination)
    let scratch = try Self.scratchDirectory(in: directory)
    let reports = BackupProgressRecorder()

    let task = Task {
      try await SQLiteFileBackup.copy(from: source, to: destination, temporaryDirectory: scratch) {
        reports.append($0)
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(reports.values.count == 1)
    #expect(try Data(contentsOf: destination) == original)
    #expect(try Self.leftovers(in: scratch).isEmpty)
  }

  @Test func reportsProgressPerBatchOfPages() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try Self.largeDatabase(in: directory)
    let destination = directory.appendingPathComponent("copy.db")
    let reports = BackupProgressRecorder()

    let result = try await SQLiteFileBackup.copy(
      from: source, to: destination, temporaryDirectory: try Self.scratchDirectory(in: directory)
    ) { reports.append($0) }

    let values = reports.values
    #expect(values.count > 2)
    #expect(values.map(\.pagesCopied) == values.map(\.pagesCopied).sorted())
    #expect(values.allSatisfy { $0.pageCount == result.pageCount })
    #expect(values.first?.pagesCopied == Int(SQLiteFileBackup.pagesPerStep))
    #expect(values.last == result)
    #expect(try Self.query(destination.path, "SELECT count(*) FROM blobs") == [["2000"]])
  }

  // MARK: - Helpers

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-backup-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func scratchDirectory(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func leftovers(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  /// A rollback-journal database of about 2 MB, many times `pagesPerStep`
  private static func largeDatabase(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("large.db")
    try exec(
      url.path,
      """
      CREATE TABLE blobs (id INTEGER PRIMARY KEY, data BLOB);
      WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 2000)
      INSERT INTO blobs SELECT x, randomblob(1000) FROM c;
      """)
    return url
  }

  private static func open(_ path: String) throws -> OpaquePointer {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
      sqlite3_close_v2(handle)
      throw SQLiteSessionError(extendedCode: SQLITE_CANTOPEN, message: "open failed")
    }
    return db
  }

  private static func exec(_ db: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(db, sql, nil, nil, &message)
    let text = message.map { String(cString: $0) } ?? ""
    sqlite3_free(message)
    guard code == SQLITE_OK else { throw SQLiteSessionError(extendedCode: code, message: text) }
  }

  /// Runs `sql` on a new connection to `path`
  private static func exec(_ path: String, _ sql: String) throws {
    let db = try open(path)
    defer { sqlite3_close_v2(db) }
    try exec(db, sql)
  }

  /// Rows of `sql` as text, read on a new connection to `path`
  private static func query(_ path: String, _ sql: String) throws -> [[String]] {
    let db = try open(path)
    defer { sqlite3_close_v2(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement
    else {
      throw SQLiteSessionError(
        extendedCode: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(prepared) }
    var rows: [[String]] = []
    while sqlite3_step(prepared) == SQLITE_ROW {
      rows.append(
        (0..<sqlite3_column_count(prepared)).map { index in
          sqlite3_column_text(prepared, index).map { String(cString: $0) } ?? "<null>"
        })
    }
    return rows
  }
}

private final class BackupProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [SQLiteFileBackup.Progress] = []

  func append(_ value: SQLiteFileBackup.Progress) {
    lock.withLock { recorded.append(value) }
  }

  var values: [SQLiteFileBackup.Progress] { lock.withLock { recorded } }
}
