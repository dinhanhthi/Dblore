// DuckDBSessionTests.swift
// DuckDBSession against the dev plugin: hardening (the hard boundary behind the classifier's
// best-effort DuckDB rules, see DuckDBClassifierTests.runtimeBuiltURLIsAKnownGap), value
// mapping, row cap, cancel, timeout, read-only files and error text.

import Foundation
import Testing

@testable import Dblore

/// Needs no plugin: the library load runs on the session queue and its failure is reported.
@Suite("DuckDB session (no plugin)")
struct DuckDBSessionUnitTests {
  private struct LoadFailure: Error, CustomStringConvertible {
    var description: String { "plugin missing" }
  }

  @Test("open loads the plugin off the main thread and reports a load failure")
  @MainActor
  func libraryLoadsOffMainAndFailureIsReported() async throws {
    let calledOnMain = LockedFlag()
    let session = DuckDBSession(
      config: ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath)
    ) {
      calledOnMain.set(Thread.isMainThread)
      throw LoadFailure()
    }
    let error = try #require(
      await #expect(throws: DuckDBSessionError.self) { try await session.open() })
    #expect(calledOnMain.value == false)
    #expect(session.formatError(error) == "DuckDB plugin could not be loaded: plugin missing")
  }
}

@Suite("DuckDB session", .requiresDuckDBPlugin, .serialized)
struct DuckDBSessionTests {
  private static let secretBind = "dblore-duckdb-bind-secret"
  /// Hashes every row of a huge range; runs far longer than any test waits.
  private static let endlessQuery =
    "SELECT count(*) FROM range(100000000000) t(a) WHERE md5(a::VARCHAR) LIKE 'xyz%'"

  // MARK: - Hardening

  @Test("URLs, runtime-built URLs and writes from URLs fail without installing httpfs")
  func externalAccessBlocked() async throws {
    try await withSession { session in
      _ = try await session.command("CREATE TABLE t (a INTEGER)", binds: [])
      let blocked = [
        "SELECT * FROM read_csv('https://example.invalid/x')",
        "SELECT * FROM read_csv('ht' || 'tps://x/y.csv')",
        "SELECT * FROM read_csv(concat('s3:', '//b/k'))",
        "INSERT INTO t SELECT * FROM read_parquet('s3://b/k.parquet')",
        "CREATE TABLE u AS SELECT * FROM read_csv('https://example.invalid/u.csv')",
        "SELECT * FROM query('SELECT * FROM read_csv(''https://x/y'')')",
        "SELECT * FROM query_table('https://x/y.csv')",
        "SELECT * FROM query_table(['/tmp/dblore-outside.csv'])",
        "SELECT * FROM '/tmp/dblore-outside.csv'",
      ]
      for sql in blocked {
        let message = try await failure(session, sql)
        #expect(message.contains("disabled by configuration"), "\(sql): \(message)")
      }
      let count = try await collect(session, "SELECT count(*) FROM t")
      #expect(count.rows == [[.int(0)]])
      #expect(Self.installedExtensionFiles().isEmpty)
    }
  }

  @Test("Local files: picked paths only, no sibling of the database, on every write mode")
  func localFilesLimitedToAllowedPaths() async throws {
    let root = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("db", isDirectory: true)
    let twinFolder = root.appendingPathComponent("dbx", isDirectory: true)
    for url in [folder, twinFolder] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let sibling = folder.appendingPathComponent("sibling.csv")
    let outside = root.appendingPathComponent("outside.csv")
    let prefixTwin = twinFolder.appendingPathComponent("twin.csv")
    let picked = root.appendingPathComponent("picked.csv")
    for url in [sibling, outside, prefixTwin, picked] {
      try Data("a\n1\n".utf8).write(to: url)
    }
    let path = folder.appendingPathComponent("local.duckdb").path
    let siblingDatabase = folder.appendingPathComponent("sibling.duckdb").path
    for file in [path, siblingDatabase] {
      try await withSession(makeConfig(path: file)) { session in
        _ = try await session.command("CREATE TABLE t (a INTEGER)", binds: [])
      }
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let configs = [
      makeConfig(path: path),
      makeConfig(path: path, readOnlyFile: true),
      makeConfig(path: path, protectionLevel: .readOnly),
    ]
    for config in configs {
      try await withSession(config, extraAllowedPaths: [picked.path]) { session in
        let read = try await collect(session, "SELECT a FROM read_csv('\(picked.path)')")
        #expect(read.rows == [[.int(1)]])
        let denied = [
          "SELECT * FROM read_csv('\(sibling.path)')",
          "SELECT * FROM read_text('\(sibling.path)')",
          "SELECT * FROM read_blob('\(sibling.path)')",
          "SELECT * FROM glob('\(folder.path)/*')",
          "SELECT * FROM read_csv('\(outside.path)')",
          "SELECT * FROM read_csv('\(prefixTwin.path)')",
          "SELECT * FROM read_csv('\(folder.path)/../outside.csv')",
          "COPY (SELECT 1) TO '\(folder.path)/x.csv'",
          "EXPORT DATABASE '\(folder.path)/exp'",
          "ATTACH '\(siblingDatabase)' AS sibling",
          "ATTACH '\(folder.path)/new.duckdb' AS created",
          "COPY (SELECT 1) TO '\(root.appendingPathComponent("out.csv").path)'",
          "ATTACH '\(root.appendingPathComponent("other.duckdb").path)'",
        ]
        for sql in denied {
          let message = try await failure(session, sql)
          #expect(message.contains("disabled by configuration"), "\(sql): \(message)")
        }
        _ = try await failure(session, "INSERT INTO sibling.t VALUES (1)")
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    try await withSession(makeConfig(path: siblingDatabase, readOnlyFile: true)) { session in
      let count = try await collect(session, "SELECT count(*) FROM t")
      #expect(count.rows == [[.int(0)]])
    }
  }

  /// Accepted gap: DuckDB allows SQL file I/O on the database file and its `.wal` itself, so
  /// COPY to those paths passes the session even when it is read-only (with `USE_TMP_FILE false`
  /// it can overwrite the database file). The stop is the actor: COPY is a utility statement,
  /// refused on a Read-only connection (DuckDBClassifierTests). Only a `readOnlyFile` session
  /// with protection off lets it through. Pinned so a DuckDB change shows.
  @Test("Known gap: COPY can still write the database's own WAL path on a read-only session")
  func copyToOwnWALIsNotBlockedBySession() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("gap.duckdb").path
    try await withSession(makeConfig(path: path)) { session in
      _ = try await session.command("CREATE TABLE t (a INTEGER)", binds: [])
    }
    try await withSession(makeConfig(path: path, readOnlyFile: true)) { session in
      _ = try await collect(session, "COPY (SELECT 1) TO '\(path).wal' (USE_TMP_FILE false)")
    }
    #expect(FileManager.default.fileExists(atPath: path + ".wal"))
  }

  @Test("Directories are owner-only; the temp directory goes away on close and on open failure")
  func containerDirectories() async throws {
    let tempRoot = Self.containerURL(.cachesDirectory, "Dblore/DuckDB/tmp")
    let before = Self.entries(tempRoot)
    try await withSession { _ in
      let created = Self.entries(tempRoot).subtracting(before)
      #expect(!created.isEmpty)
      for name in created {
        #expect(Self.permissions(tempRoot.appendingPathComponent(name).path) == 0o700, "\(name)")
      }
      for name in ["extensions", "secrets"] {
        let url = Self.containerURL(.applicationSupportDirectory, "Dblore/DuckDB/\(name)")
        #expect(Self.permissions(url.path) == 0o700, "\(name)")
      }
    }
    // Read-only refuses a missing file, so `open` fails after the directories exist.
    let missing = temporaryFolder().appendingPathComponent("missing.duckdb").path
    let failing = DuckDBSession(config: makeConfig(path: missing, readOnlyFile: true)) {
      try DuckDBTestPlugin.library()
    }
    await #expect(throws: DuckDBSessionError.self) { try await failing.open() }
    // Other suites' sessions may hold a temp directory for a moment; the leaked one never goes.
    let start = ContinuousClock.now
    while !Self.entries(tempRoot).subtracting(before).isEmpty,
      start.duration(to: .now) < .seconds(10)
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    withExtendedLifetime(failing) {
      #expect(Self.entries(tempRoot).subtracting(before).isEmpty)
    }
  }

  @Test("The configuration is locked and extensions cannot be installed or loaded")
  func configurationLocked() async throws {
    try await withSession { session in
      let locked = [
        "SET autoinstall_known_extensions = true",
        "SET autoload_known_extensions = true",
        "SET allowed_directories = ['/']",
        "SET allowed_paths = ['/']",
        "RESET lock_configuration",
        "RESET enable_external_access",
        "SET GLOBAL enable_external_access = true",
        "SET GLOBAL lock_configuration = false",
      ]
      for sql in locked {
        let message = try await failure(session, sql)
        #expect(message.contains("configuration has been locked"), "\(sql): \(message)")
      }
      for sql in ["SET enable_external_access = true", "INSTALL httpfs", "LOAD httpfs"] {
        _ = try await failure(session, sql)
      }
      let settings = try await collect(
        session,
        """
        SELECT current_setting('enable_external_access'), current_setting('lock_configuration'),
          current_setting('autoinstall_known_extensions'),
          current_setting('autoload_known_extensions'),
          current_setting('allow_community_extensions')
        """)
      #expect(
        settings.rows == [[.bool(false), .bool(true), .bool(false), .bool(false), .bool(false)]])
      #expect(Self.installedExtensionFiles().isEmpty)
    }
  }

  @Test("duckdb_secrets() is empty and the postgres scanner is unavailable")
  func secretsAndScannersUnavailable() async throws {
    try await withSession { session in
      let secrets = try await collect(session, "SELECT * FROM duckdb_secrets()")
      #expect(secrets.rows.isEmpty)
      let scan = try await failure(session, "SELECT * FROM postgres_scan('host=x', 'public', 't')")
      #expect(scan.contains("postgres_scan"))
      _ = try await failure(
        session, "CREATE SECRET s (TYPE s3, KEY_ID 'AKIA', SECRET 'shh')")
      let after = try await collect(session, "SELECT count(*) FROM duckdb_secrets()")
      #expect(after.rows == [[.int(0)]])
    }
  }

  @Test("A read-only file and a Read-only connection reject writes in the engine")
  func readOnlyRejectsWrites() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("ro.duckdb").path
    try await withSession(makeConfig(path: path)) { session in
      _ = try await session.command("CREATE TABLE notes (body VARCHAR)", binds: [])
      _ = try await session.command("INSERT INTO notes VALUES ($1)", binds: [.text("kept")])
    }
    // Close checkpoints the WAL into the file (no folder grant needed for the engine's own I/O).
    #expect(!FileManager.default.fileExists(atPath: path + ".wal"))
    let configs = [
      makeConfig(path: path, readOnlyFile: true),
      makeConfig(path: path, protectionLevel: .readOnly),
    ]
    for config in configs {
      try await withSession(config) { session in
        let message = try await failure(
          session, "INSERT INTO notes VALUES ($1)", binds: [.text(Self.secretBind)])
        #expect(message.contains("read-only"), "\(message)")
        #expect(!message.contains(Self.secretBind))
        let rows = try await collect(session, "SELECT body FROM notes")
        #expect(rows.rows == [[.string("kept")]])
      }
    }
  }

  // MARK: - Values

  @Test("Values map like the other engines; nested values are DuckDB text")
  func valueMapping() async throws {
    try await withSession { session in
      _ = try await session.command("CREATE TYPE mood AS ENUM ('sad', 'happy')", binds: [])
      let result = try await collect(
        session,
        #"""
        SELECT 42::TINYINT, 7::INTEGER, 9007199254740993::BIGINT, 255::UTINYINT,
          18446744073709551615::UBIGINT, 12::HUGEINT,
          170141183460469231731687303715884105727::HUGEINT,
          (-170141183460469231731687303715884105727 - 1)::HUGEINT,
          123.45::DECIMAL(5,2), -0.05::DECIMAL(4,3), 1.5::DOUBLE, true,
          'héllo', 'a string longer than twelve bytes', '\xAA\x00'::BLOB,
          DATE '2024-02-29', TIMESTAMP '2024-02-29 12:34:56.789', 'infinity'::DATE,
          INTERVAL '1 year 2 months 3 days 04:05:06.789', TIME '12:34:56',
          '550e8400-e29b-41d4-a716-446655440000'::UUID, 'happy'::mood,
          [1, 2, NULL], [[1.50, 2.25]]::DECIMAL(4,2)[][], {'a': 1, 'b': 'x y'}, MAP {'k': 1},
          NULL::INTEGER, '{"a": [1, 2]}'::JSON, [1, 2, 3]::INTEGER[3],
          union_value(n := 5), {'l': [1, NULL], 's': NULL},
          to_microseconds(-9223372036854775807 - 1)
        """#)
      let row = try #require(result.rows.first)
      let expected: [CellValue] = [
        .int(42), .int(7), .int(9_007_199_254_740_993), .int(255),
        .string("18446744073709551615"), .int(12),
        .string("170141183460469231731687303715884105727"),
        .string("-170141183460469231731687303715884105728"),
        .double(123.45), .double(-0.05), .double(1.5), .bool(true),
        .string("héllo"), .string("a string longer than twelve bytes"), .data(Data([0xAA, 0x00])),
        .date(Date(timeIntervalSince1970: 1_709_164_800)),
        .date(Date(timeIntervalSince1970: 1_709_210_096.789)), .string("infinity"),
        .string("1 year 2 months 3 days 04:05:06.789"), .string("12:34:56"),
        .string("550E8400-E29B-41D4-A716-446655440000"), .string("happy"),
        .string("[1, 2, NULL]"), .string("[[1.50, 2.25]]"), .string("{'a': 1, 'b': x y}"),
        .string("{k=1}"), .null, .json(#"{"a": [1, 2]}"#), .string("[1, 2, 3]"), .string("5"),
        .string("{'l': [1, NULL], 's': NULL}"), .string("-2562047788:00:54.775808"),
      ]
      #expect(row.count == expected.count)
      for (index, pair) in zip(row, expected).enumerated() {
        if case .date(let actual) = pair.0, case .date(let wanted) = pair.1 {
          #expect(
            abs(actual.timeIntervalSince1970 - wanted.timeIntervalSince1970) < 0.000_5,
            "column \(index)")
        } else {
          // String(describing:) keeps the case and payload exact.
          #expect(String(describing: pair.0) == String(describing: pair.1), "column \(index)")
        }
      }
      let types = result.columns.map(\.type)
      #expect(types[0] == "TINYINT")
      #expect(types[8] == "DECIMAL(5,2)")
      #expect(types[22] == "INTEGER[]")
      #expect(types[24] == "STRUCT(a INTEGER, b VARCHAR)")
      #expect(types[25] == "MAP(VARCHAR, INTEGER)")
      #expect(types[27] == "JSON")
    }
  }

  @Test("In-memory database: binds, affected rows and a rolled-back transaction")
  func inMemoryDatabase() async throws {
    try await withSession { session in
      _ = try await session.command("CREATE TABLE notes (id INTEGER, body VARCHAR)", binds: [])
      let inserted = try await session.command(
        "INSERT INTO notes VALUES ($1, $2), (2, NULL)", binds: [.text("1"), .text("o'brien")])
      #expect(inserted.affectedRows == 2)
      #expect(inserted.tag == "INSERT")
      _ = try await session.command("BEGIN", binds: [])
      _ = try await session.command("DELETE FROM notes", binds: [])
      _ = try await session.command("ROLLBACK", binds: [])
      let selected = try await collect(
        session, "SELECT id, body FROM notes WHERE id = $1 OR body IS NULL ORDER BY id",
        binds: [.text("1")])
      #expect(selected.columns.map(\.name) == ["id", "body"])
      #expect(selected.rows == [[.int(1), .string("o'brien")], [.int(2), .null]])
    }
  }

  // MARK: - Cap, cancel, timeout, errors

  @Test("Stopping a read early keeps the session and its temp table")
  func cappedReadKeepsSession() async throws {
    try await withSession { session in
      _ = try await session.command("CREATE TEMP TABLE kept AS SELECT 1 AS id", binds: [])
      let source = try await session.query("SELECT * FROM range(1000000000)", binds: [])
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

  /// One connection holds one open result: a new statement closes it in DuckDB (on 1.5.6 the
  /// next fetch fails with "closed pending query result"). The first stream must fail clearly.
  @Test("A new statement interrupts an open read with a clear error; a full read still ends")
  func newStatementInterruptsOpenRead() async throws {
    try await withSession { session in
      let source = try await session.query("SELECT * FROM range(100000)", binds: [])
      var rows = source.rows.makeAsyncIterator()
      #expect(try await rows.next() == [.int(0)])
      let second = try await collect(session, "SELECT 42")
      #expect(second.rows == [[.int(42)]])
      let error = try #require(
        await #expect(throws: DuckDBSessionError.self) { _ = try await rows.next() })
      #expect(session.formatError(error).contains("interrupted by another query"))
      let full = try await collect(session, "SELECT * FROM range(100000)")
      #expect(full.rows.count == 100000)
      #expect(full.rows.last == [.int(99999)])
    }
  }

  @Test("interrupt stops a long query without closing the session")
  func interruptCancelsLongQuery() async throws {
    try await withSession(makeConfig(statementTimeoutSeconds: 60)) { session in
      let gate = DuckDBFinishGate()
      let running = Task {
        defer { gate.finish() }
        let source = try await session.query(Self.endlessQuery, binds: [])
        for try await _ in source.rows {}
      }
      let start = ContinuousClock.now
      while !gate.isFinished, start.duration(to: .now) < .seconds(5) {
        await session.interrupt()
        try await Task.sleep(for: .milliseconds(25))
      }
      let error = try #require(
        await #expect(throws: DuckDBSessionError.self) { try await running.value })
      let message = session.formatError(error)
      #expect(message.contains("Interrupted"), "\(message)")
      #expect(!message.contains("timed out"))
      #expect(start.duration(to: .now) < .seconds(8))
      let stillOpen = try await collect(session, "SELECT 1")
      #expect(stillOpen.rows == [[.int(1)]])
    }
  }

  @Test("The watchdog stops a statement at the connection timeout")
  func statementTimeout() async throws {
    try await withSession(makeConfig(statementTimeoutSeconds: 1)) { session in
      let start = ContinuousClock.now
      let error = try #require(
        await #expect(throws: DuckDBSessionError.self) {
          let source = try await session.query(Self.endlessQuery, binds: [])
          for try await _ in source.rows {}
        })
      #expect(session.formatError(error).contains("statement timed out"))
      #expect(start.duration(to: .now) < .seconds(5))
      let commandError = try #require(
        await #expect(throws: DuckDBSessionError.self) {
          try await session.command(Self.endlessQuery, binds: [])
        })
      #expect(session.formatError(commandError).contains("statement timed out"))
      let stillOpen = try await collect(session, "SELECT 1")
      #expect(stillOpen.rows == [[.int(1)]])
    }
  }

  @Test("Errors carry DuckDB's message; cursors are unsupported")
  func errorFormatting() async throws {
    try await withSession { session in
      let missing = try await failure(session, "SELECT * FROM missing_table")
      #expect(missing.hasPrefix("Catalog Error"), "\(missing)")
      #expect(missing.contains("missing_table"))
      let syntax = try await failure(session, "SELEC 1")
      #expect(syntax.hasPrefix("Parser Error"), "\(syntax)")
      let error = try #require(
        await #expect(throws: DuckDBSessionError.self) {
          try await session.openCursor("SELECT 1", binds: [])
        })
      #expect(session.formatError(error).localizedCaseInsensitiveContains("cursor"))
    }
  }

  // MARK: - Helpers

  private func makeConfig(
    path: String = DuckDBSession.inMemoryPath, readOnlyFile: Bool = false,
    protectionLevel: ConnectionProtectionLevel = .none, statementTimeoutSeconds: Int = 60
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: path, sslMode: .disable, protectionLevel: protectionLevel,
      statementTimeoutSeconds: statementTimeoutSeconds, readOnlyFile: readOnlyFile)
  }

  private func withSession(
    _ config: ConnectionConfig? = nil, extraAllowedPaths: [String] = [],
    _ body: (DuckDBSession) async throws -> Void
  ) async throws {
    let session = DuckDBSession(
      config: config ?? makeConfig(), extraAllowedPaths: extraAllowedPaths
    ) { try DuckDBTestPlugin.library() }
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
    _ session: DuckDBSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> (columns: [ColumnInfo], rows: [[CellValue]]) {
    let source = try await session.query(sql, binds: binds)
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return (source.columns, rows)
  }

  /// The formatted error of a statement that must fail, run as a read.
  private func failure(
    _ session: DuckDBSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> String {
    let error = try #require(
      await #expect(throws: DuckDBSessionError.self, "\(sql)") {
        _ = try await collect(session, sql, binds: binds)
      })
    return session.formatError(error)
  }

  private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-\(UUID().uuidString)", isDirectory: true)
  }

  private static func containerURL(
    _ directory: FileManager.SearchPathDirectory, _ path: String
  ) -> URL {
    FileManager.default.urls(for: directory, in: .userDomainMask)[0]
      .appendingPathComponent(path, isDirectory: true)
  }

  private static func entries(_ url: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
  }

  private static func permissions(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
  }

  /// Files under the container's DuckDB extension directory.
  private static func installedExtensionFiles() -> [String] {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return [] }
    let root = support.appendingPathComponent("Dblore/DuckDB/extensions", isDirectory: true)
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    return (enumerator?.allObjects as? [String] ?? []).filter { $0.contains("duckdb_extension") }
  }
}

/// Set when a query task has left `query`. The interrupt loop stops once the statement returns.
private final class DuckDBFinishGate: @unchecked Sendable {
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

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool?

  var value: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: Bool) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}
