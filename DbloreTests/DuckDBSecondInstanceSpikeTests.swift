// DuckDBSecondInstanceSpikeTests.swift
// Spike 2.4: can MCP open a second, read-only DuckDBSession on a .duckdb file that the app
// already holds read-write in the same process?

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB second instance spike", .requiresDuckDBPlugin, .serialized)
struct DuckDBSecondInstanceSpikeTests {
  @Test("A read-only session opens a file held read-write in-process")
  func secondReadOnlyInstance() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-second-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("held.duckdb").path

    let writer = session(path: path, readOnlyFile: false)
    try await writer.open()
    _ = try await writer.command("CREATE TABLE t (a INTEGER)", binds: [])
    _ = try await writer.command("INSERT INTO t VALUES (1), (2)", binds: [])

    // SPIKE RESULT: works. duckdb_open_ext does not use DuckDB's instance cache, so the second
    // open builds a separate read-only instance; it reads the writer's committed (WAL) rows.
    let reader = session(path: path, readOnlyFile: true)
    try await reader.open()
    #expect(try await collect(reader, "SELECT count(*) FROM t") == [[.int(2)]])

    // The writer stays usable while the reader is open.
    _ = try await writer.command("INSERT INTO t VALUES (3)", binds: [])
    #expect(try await collect(writer, "SELECT count(*) FROM t") == [[.int(3)]])
    // An open reader keeps the snapshot it opened with: it does not see later commits.
    #expect(try await collect(reader, "SELECT count(*) FROM t") == [[.int(2)]])
    await reader.close()

    // A reader opened after the commit sees it; the writer survives the reader's close.
    let fresh = session(path: path, readOnlyFile: true)
    try await fresh.open()
    #expect(try await collect(fresh, "SELECT count(*) FROM t") == [[.int(3)]])
    await fresh.close()
    // Not assertable here (needs a second process): POSIX fcntl locks are per process, so
    // closing a reader also drops the writer's exclusive file lock. Probed by hand: after the
    // reader closed, another process got LOCK_EX on the file while the writer was still open.
    _ = try await writer.command("INSERT INTO t VALUES (4)", binds: [])
    await writer.close()
  }

  // MARK: - Helpers

  private func session(path: String, readOnlyFile: Bool) -> DuckDBSession {
    DuckDBSession(
      config: ConnectionConfig(
        databaseType: .duckdb, database: path, sslMode: .disable, readOnlyFile: readOnlyFile)
    ) { try DuckDBTestPlugin.library() }
  }

  private func collect(_ session: DuckDBSession, _ sql: String) async throws -> [[CellValue]] {
    let source = try await session.query(sql, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return rows
  }
}
