// DuckDBExportSpikeTests.swift
// Spike 2.2: in an in-memory DuckDB session through the plugin loader, is Parquet built in, how
// fast is a 100,000-row typed insert through the session's bind path, does COPY ... (FORMAT
// PARQUET) work inside allowed_paths (and fail outside), and what does EXPLAIN (FORMAT JSON) give?
// Findings go to $TMPDIR/dblore-duckdb-spike.txt (xcodebuild drops test host stdout).

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB export spike", .requiresDuckDBPlugin, .serialized)
struct DuckDBExportSpikeTests {
  private static let rowCount = 100_000
  private static let createTable = """
    CREATE TABLE t (i INTEGER, big BIGINT, d DOUBLE, amount DECIMAL(38,10), label VARCHAR,
      flag BOOLEAN, day DATE, ts TIMESTAMP, payload BLOB)
    """
  private static let insertRow = "INSERT INTO t VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)"
  private static let explainedQuery = """
    SELECT c.name, count(*) AS n, sum(t.d) AS total
    FROM t JOIN cats c ON c.id = t.i % 3
    WHERE t.flag
    GROUP BY c.name
    ORDER BY c.name
    """

  @Test("Parquet is loaded without INSTALL")
  func parquetIsBuiltIn() async throws {
    let library = try DuckDBTestPlugin.library()
    Self.record("SPIKE duckdb version: \(library.version)")
    let extensions =
      "SELECT extension_name, loaded, installed, install_mode, extension_version"
      + " FROM duckdb_extensions() WHERE extension_name = 'parquet'"
    try await withSession { session in
      // duckdb_extensions() lists the extension directory, a file system operation.
      let refused = try await failure(session, extensions)
      Self.record("SPIKE duckdb_extensions() in the hardened session: \(refused)")
      #expect(refused.contains("disabled by configuration"), "\(refused)")
      // The Parquet functions are registered without INSTALL or LOAD.
      let functions = try await collect(
        session,
        "SELECT DISTINCT function_name FROM duckdb_functions()"
          + " WHERE function_name IN ('read_parquet', 'parquet_metadata') ORDER BY 1")
      Self.record("SPIKE parquet functions in the hardened session: \(functions.rows)")
      #expect(functions.rows.count == 2)
    }
    // The same dylib without the file access lock (autoinstall and autoload off, empty
    // extension directory) shows the extension row.
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let row = try Self.rawRows(
      library, extensionDirectory: folder.path, extensions)
    Self.record("SPIKE parquet extension row (unhardened): \(row)")
    #expect(row.first?[1] == "true")
  }

  @Test("100k-row typed insert, COPY TO Parquet inside allowed_paths and read-back")
  func insertAndExport() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = try DuckDBFileQuery.canonicalPath(of: folder) + "/out.parquet"
    try await withSession(extraAllowedPaths: [output]) { session in
      _ = try await session.command(Self.createTable, binds: [])
      let rows = (0..<Self.rowCount).map(Self.binds(row:))

      let clock = ContinuousClock()
      let start = clock.now
      _ = try await session.command("BEGIN TRANSACTION", binds: [])
      for binds in rows {
        _ = try await session.command(Self.insertRow, binds: binds)
      }
      _ = try await session.command("COMMIT", binds: [])
      let elapsed = start.duration(to: clock.now)
      // SPIKE RESULT (2026-10-19, v1.5.6): ~14.3 s, over the 10 s budget. Each call re-prepares
      // (the session has no prepare-once/bind-many) and hops the serial queue.
      Self.record(
        "SPIKE insert \(Self.rowCount) rows (session.command per row, varchar binds, one"
          + " transaction): \(elapsed)")

      let count = try await collect(session, "SELECT count(*) FROM t")
      #expect(count.rows == [[.int(Self.rowCount)]])
      let sample = try await collect(session, "SELECT * FROM t WHERE i = 12345")
      Self.record("SPIKE sample row 12345: \(sample.rows)")

      let copy = try await session.command(
        "COPY t TO \(literal(output)) (FORMAT PARQUET)", binds: [])
      Self.record("SPIKE COPY TO inside allowed_paths: affectedRows=\(copy.affectedRows)")
      #expect(FileManager.default.fileExists(atPath: output))

      let readBack = try await collect(
        session, "SELECT count(*) FROM read_parquet(\(literal(output)))")
      #expect(readBack.rows == [[.int(Self.rowCount)]])
      let described = try await collect(
        session, "DESCRIBE SELECT * FROM read_parquet(\(literal(output)))")
      let types = described.rows.map { row in "\(row[0]) \(row[1])" }
      Self.record("SPIKE read_parquet types: \(types)")
      #expect(
        described.rows.map { Self.text($0[1]) } == [
          "INTEGER", "BIGINT", "DOUBLE", "DECIMAL(38,10)", "VARCHAR", "BOOLEAN", "DATE",
          "TIMESTAMP", "BLOB",
        ])
      let original = try await collect(session, "SELECT * FROM t ORDER BY i LIMIT 3")
      let copied = try await collect(
        session, "SELECT * FROM read_parquet(\(literal(output))) ORDER BY i LIMIT 3")
      #expect(copied.rows == original.rows)
    }
  }

  /// Reference for the 10 s budget: the same rows, 1,000 per INSERT (9,000 varchar binds per
  /// statement), so 100 prepares instead of 100,000.
  @Test("100k-row typed insert, 1,000 rows per statement")
  func batchedInsertTiming() async throws {
    try await withSession { session in
      _ = try await session.command(Self.createTable, binds: [])
      let batch = 1000
      let placeholders = (0..<batch).map { row in
        "(" + (1...9).map { "$\(row * 9 + $0)" }.joined(separator: ", ") + ")"
      }
      let sql = "INSERT INTO t VALUES " + placeholders.joined(separator: ", ")
      let batches = stride(from: 0, to: Self.rowCount, by: batch).map { first in
        (first..<first + batch).flatMap(Self.binds(row:))
      }

      let clock = ContinuousClock()
      let start = clock.now
      _ = try await session.command("BEGIN TRANSACTION", binds: [])
      for binds in batches {
        _ = try await session.command(sql, binds: binds)
      }
      _ = try await session.command("COMMIT", binds: [])
      let elapsed = start.duration(to: clock.now)
      // SPIKE RESULT (2026-10-19, v1.5.6): ~2.4 s.
      Self.record(
        "SPIKE insert \(Self.rowCount) rows (\(batch) rows per session.command, varchar binds,"
          + " one transaction): \(elapsed)")
      let count = try await collect(session, "SELECT count(*) FROM t")
      #expect(count.rows == [[.int(Self.rowCount)]])
    }
  }

  @Test("COPY TO a path outside allowed_paths is refused, a folder grant included")
  func copyOutsideAllowedPathsIsRefused() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let root = try DuckDBFileQuery.canonicalPath(of: folder)
    let granted = root + "/out.parquet"
    // The folder itself in allowed_paths: allowed_paths matches exact files only.
    try await withSession(extraAllowedPaths: [granted, root]) { session in
      _ = try await session.command(
        "CREATE TABLE t AS SELECT range AS i FROM range(10)", binds: [])
      for target in [root + "/other.parquet", root + "/sub/out.parquet"] {
        let message = try await failure(
          session, "COPY t TO \(literal(target)) (FORMAT PARQUET)")
        Self.record("SPIKE COPY TO outside allowed_paths: \(message)")
        #expect(message.contains("disabled by configuration"), "\(message)")
      }
      #expect(!FileManager.default.fileExists(atPath: root + "/other.parquet"))
    }
  }

  @Test("EXPLAIN (FORMAT JSON) of a join + filter + aggregate")
  func explainJSON() async throws {
    try await withSession { session in
      _ = try await session.command(Self.createTable, binds: [])
      _ = try await session.command(
        "INSERT INTO t SELECT range, range * 10, range / 7, range, 'row-' || range,"
          + " range % 2 = 0, DATE '2026-01-01' + range::INTEGER,"
          + " TIMESTAMP '2026-01-01 00:00:00' + to_seconds(range), 'x'::BLOB FROM range(1000)",
        binds: [])
      _ = try await session.command("CREATE TABLE cats (id INTEGER, name VARCHAR)", binds: [])
      _ = try await session.command(
        "INSERT INTO cats VALUES (0, 'zero'), (1, 'one'), (2, 'two')", binds: [])

      let plan = try await collect(session, "EXPLAIN (FORMAT JSON) \(Self.explainedQuery)")
      Self.record("SPIKE EXPLAIN JSON columns: \(plan.columns.map(\.name))")
      let json = try #require(plan.rows.first.flatMap { Self.text($0.last) })
      Self.record("SPIKE EXPLAIN JSON BEGIN\n\(json)\nSPIKE EXPLAIN JSON END")

      let analyzed = try await collect(
        session, "EXPLAIN (ANALYZE, FORMAT JSON) \(Self.explainedQuery)")
      Self.record("SPIKE EXPLAIN ANALYZE JSON columns: \(analyzed.columns.map(\.name))")
      let analyzedJSON = try #require(analyzed.rows.first.flatMap { Self.text($0.last) })
      Self.record(
        "SPIKE EXPLAIN ANALYZE JSON BEGIN\n\(analyzedJSON)\nSPIKE EXPLAIN ANALYZE JSON END")

      #expect(try Self.shape(json) == Self.shape(DuckDBExplainFixtures.joinFilterAggregateJSON))
      // ANALYZE: one root object (query metrics: latency, cpu_time, rows_returned, …) whose
      // `children` nodes carry operator_name, operator_type, operator_timing (seconds),
      // operator_cardinality and the same extra_info object as the plain plan.
      let profile = try #require(
        try JSONSerialization.jsonObject(with: Data(analyzedJSON.utf8)) as? [String: Any])
      #expect(profile["latency"] is Double)
      let root = try #require((profile["children"] as? [[String: Any]])?.first)
      #expect(root["operator_name"] as? String == "EXPLAIN_ANALYZE")
      #expect(root["operator_timing"] is Double)
    }
  }

  // MARK: - Helpers

  /// One row of typed values as varchar binds (the session's only bind kinds are text and null).
  private static func binds(row i: Int) -> [SQLBindValue] {
    let year = 2000 + i % 30
    let month = (i / 28) % 12 + 1
    let dayOfMonth = i % 28 + 1
    let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    let time = String(format: "%02d:%02d:%02d.123456", i % 24, i % 60, (i / 60) % 60)
    return [
      .text(String(i)),
      .text(String(Int64(i) * 1_000_000_007)),
      .text(String(Double(i) / 7)),
      .text("\(i).0123456789"),
      i % 1000 == 0 ? .null : .text("row-\(i)"),
      .text(i % 2 == 0 ? "true" : "false"),
      .text(day),
      .text("\(day) \(time)"),
      .text("\\xDE\\xAD-\(i)"),
    ]
  }

  /// Top-level shape: the key set of each plan root, recursively for the first child chain.
  private static func shape(_ json: String) throws -> [String] {
    let root = try JSONSerialization.jsonObject(with: Data(json.utf8))
    var keys: [String] = []
    var node: Any? = root
    while let current = node {
      if let array = current as? [Any] {
        keys.append("array(\(array.count))")
        node = array.first
      } else if let object = current as? [String: Any] {
        keys.append(object.keys.sorted().joined(separator: ","))
        node = object["children"]
      } else {
        node = nil
      }
    }
    return keys
  }

  /// One query on a fresh in-memory database over the raw C API, without the session's file
  /// access lock. Values as text.
  private static func rawRows(
    _ library: DuckDBLibrary, extensionDirectory: String, _ sql: String
  ) throws -> [[String?]] {
    var config: OpaquePointer?
    guard library.createConfig(&config) == DuckDBState.success else {
      throw DuckDBSessionError(message: "duckdb_create_config failed")
    }
    defer { library.destroyConfig(&config) }
    let options = [
      ("autoinstall_known_extensions", "false"), ("autoload_known_extensions", "false"),
      ("extension_directory", extensionDirectory),
    ]
    for (name, value) in options {
      guard library.setConfig(config, name, value) == DuckDBState.success else {
        throw DuckDBSessionError(message: "duckdb_set_config \(name) failed")
      }
    }
    var database: OpaquePointer?
    var connection: OpaquePointer?
    guard library.openExt(nil, &database, config, nil) == DuckDBState.success else {
      throw DuckDBSessionError(message: "duckdb_open_ext failed")
    }
    defer { library.close(&database) }
    guard library.connect(database, &connection) == DuckDBState.success else {
      throw DuckDBSessionError(message: "duckdb_connect failed")
    }
    defer { library.disconnect(&connection) }
    var result = DuckDBResult()
    defer { library.destroyResult(&result) }
    guard library.query(connection, sql, &result) == DuckDBState.success else {
      let message = library.resultError(&result).map { String(cString: $0) } ?? "query failed"
      throw DuckDBSessionError(message: message)
    }
    return (0..<library.rowCount(&result)).map { row in
      (0..<library.columnCount(&result)).map { column in
        guard let text = library.valueVarchar(&result, column, row) else { return nil }
        defer { library.free(text) }
        return String(cString: text)
      }
    }
  }

  private static func text(_ value: CellValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }

  private func literal(_ path: String) -> String {
    SQLDialect.duckdb.literal(.string(path))
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func withSession(
    extraAllowedPaths: [String] = [], _ body: (DuckDBSession) async throws -> Void
  ) async throws {
    let session = DuckDBSession(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        statementTimeoutSeconds: 60),
      extraAllowedPaths: extraAllowedPaths
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
    _ session: DuckDBSession, _ sql: String
  ) async throws -> (columns: [ColumnInfo], rows: [[CellValue]]) {
    let source = try await session.query(sql, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return (source.columns, rows)
  }

  /// The formatted error of a statement that must fail.
  private func failure(_ session: DuckDBSession, _ sql: String) async throws -> String {
    let error = try #require(
      await #expect(throws: DuckDBSessionError.self, "\(sql)") {
        _ = try await session.command(sql, binds: [])
      })
    return session.formatError(error)
  }

  /// Prints and appends to $TMPDIR/dblore-duckdb-spike.txt.
  private static func record(_ line: String) {
    print(line)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-duckdb-spike.txt")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }
}
