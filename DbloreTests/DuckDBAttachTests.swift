// DuckDBAttachTests.swift
// ATTACH of other DuckDB files after the session's extension hardening and before
// `enable_external_access=false` + `lock_configuration=true`, with no `allowed_paths` set (as
// DuckDBSession does when `extraAllowedPaths` is empty). DuckDBSession has no hook between those steps, so this suite replays its open
// sequence on the raw C API of the dev plugin. It pins what the engine allows on attached files
// once the configuration is locked. Observed on DuckDB v1.5.6.
// - User statements go through `duckdb_query`; DuckDBSession runs them with C-API prepare +
//   execute, which this suite does not exercise.
// - The open options and the hardening tail are a hand copy of DuckDBSession.openDatabase and
//   hardeningStatements, so they can drift. A seam (static `openOptions` and
//   `hardeningStatements(extraAllowedPaths:)`) would let this suite reuse them.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB attach", .requiresDuckDBPlugin, .serialized)
struct DuckDBAttachTests {
  private static let disabled = "disabled by configuration"
  private static let readOnlyAttach = "which is attached in read-only mode"

  /// Observed: a file attached before the lock reads and writes after it (the lock put its path
  /// and WAL siblings in `allowed_paths`, see `lockAllowsAttachedPaths`), and the lock holds.
  /// Implication: attach-before-lock is workable for read-write attaches.
  @Test("A read-write attach made before the lock reads and writes after it")
  func readWriteAttachAfterLock() throws {
    let files = try Files()
    defer { files.remove() }
    let connection = try HardenedConnection(
      main: files.main, folder: files.root,
      attach: ["ATTACH \(literal(files.writable)) AS rw"])
    defer { connection.close() }

    #expect(try connection.rows("SELECT count(*) FROM rw.t") == [["1"]])
    #expect(try connection.rows("INSERT INTO rw.t VALUES (2)") == [["1"]])
    #expect(try connection.rows("SELECT count(*) FROM rw.t") == [["2"]])
    #expect(
      try connection.rows("SELECT readonly FROM duckdb_databases() WHERE database_name = 'rw'")
        == [["false"]])
    #expect(
      try connection.failure("SET enable_external_access = true")
        .contains("the configuration has been locked"))
  }

  /// Observed: INSERT, UPDATE and CREATE on a READ_ONLY attach fail; on a READ_ONLY main
  /// (`access_mode`) an attach without options is read-only too. Implication: DML refusal on a
  /// READ_ONLY attach is the engine's, as long as the attach itself is not replaced (see
  /// `detachThenReattachEscalates`).
  @Test("DML is refused on a READ_ONLY attach and on any attach of a READ_ONLY main")
  func readOnlyAttachRefusesDML() throws {
    let files = try Files()
    defer { files.remove() }
    for mainReadOnly in [false, true] {
      let connection = try HardenedConnection(
        main: files.main, folder: files.root, readOnly: mainReadOnly,
        attach: [
          "ATTACH \(literal(files.readOnly)) AS ro (READ_ONLY)",
          "ATTACH \(literal(files.writable)) AS rw",
        ])
      defer { connection.close() }
      #expect(try connection.rows("SELECT count(*) FROM ro.t") == [["1"]])
      for sql in [
        "INSERT INTO ro.t VALUES (2)", "UPDATE ro.t SET a = 3", "CREATE TABLE ro.x (a INTEGER)",
      ] {
        let message = try connection.failure(sql)
        #expect(message.contains(Self.readOnlyAttach), "\(sql): \(message)")
      }
      let insert = "INSERT INTO rw.t VALUES (2)"
      if mainReadOnly {
        #expect(try connection.failure(insert).contains(Self.readOnlyAttach))
      } else {
        #expect(try connection.rows(insert) == [["1"]])
      }
    }
  }

  /// Observed: after the lock a new path or a never-attached file (neither is in
  /// `allowed_paths`) cannot be attached, the same path cannot be attached twice, and `:memory:`
  /// attaches on a read-write main (it needs no file). Implication: the file list is fixed at
  /// open, so picking another file needs a new session (the `allowed_paths` rule).
  @Test("After the lock, ATTACH of a new or never-attached file is refused")
  func newPathsRefusedAfterLock() throws {
    let files = try Files()
    defer { files.remove() }
    let connection = try HardenedConnection(
      main: files.main, folder: files.root,
      attach: ["ATTACH \(literal(files.writable)) AS rw"])
    defer { connection.close() }

    let created = files.other.appendingPathComponent("new.duckdb").path
    for sql in [
      "ATTACH \(literal(created)) AS created",
      "ATTACH \(literal(files.readOnly)) AS never",
      "ATTACH \(literal(files.readOnly)) AS never (READ_ONLY)",
    ] {
      let message = try connection.failure(sql)
      #expect(message.contains(Self.disabled), "\(sql): \(message)")
    }
    #expect(!FileManager.default.fileExists(atPath: created))
    for sql in [
      "ATTACH \(literal(files.writable)) AS again", "ATTACH \(literal(files.main)) AS again",
    ] {
      let message = try connection.failure(sql)
      #expect(message.contains("Unique file handle conflict"), "\(sql): \(message)")
    }
    _ = try connection.rows("ATTACH ':memory:' AS scratch")
  }

  /// Observed: DETACH still runs after the lock, and a path attached before the lock can be
  /// attached again with any mode, `(READ_WRITE)` included, even on a READ_ONLY main (its
  /// `allowed_paths` entry stays after DETACH); INSERT then succeeds. DuckDB rejects DETACH
  /// inside `query()` and `PREPARE`. Implication: READ_ONLY on an attached file is no engine
  /// boundary against user SQL. ATTACH and DETACH are utility statements, and the app's gate
  /// refuses them only on Read-only / Schema-only connections.
  @Test("DETACH then ATTACH (READ_WRITE) turns a READ_ONLY attach writable after the lock")
  func detachThenReattachEscalates() throws {
    let files = try Files()
    defer { files.remove() }
    for mainReadOnly in [false, true] {
      let connection = try HardenedConnection(
        main: files.main, folder: files.root, readOnly: mainReadOnly,
        attach: ["ATTACH \(literal(files.readOnly)) AS ro (READ_ONLY)"])
      defer { connection.close() }

      #expect(
        try connection.failure("SELECT * FROM query('DETACH ro')")
          .contains("Expected a single SELECT statement"))
      #expect(try connection.failure("PREPARE p AS DETACH ro").contains("syntax error"))
      #expect(try connection.failure("INSERT INTO ro.t VALUES (2)").contains(Self.readOnlyAttach))

      _ = try connection.rows("DETACH ro")
      _ = try connection.rows("ATTACH \(literal(files.readOnly)) AS ro (READ_WRITE)")
      #expect(try connection.rows("INSERT INTO ro.t VALUES (2)") == [["1"]])
      #expect(try connection.rows("SELECT count(*) FROM ro.t") == [["2"]])
      _ = try connection.rows("DELETE FROM ro.t WHERE a = 2")
    }
  }

  /// Observed: COPY TO an attached file's own path in the default form is refused (its
  /// `tmp_<name>` sibling is not in `allowed_paths`), but with `USE_TMP_FILE false` it
  /// overwrites the file, a READ_ONLY attach included, and COPY TO `<attached>.wal` (also
  /// through PREPARE, and after DETACH) writes the WAL; attached files are readable with
  /// `read_blob`. These paths pass the file access check because the lock put them in
  /// `allowed_paths` (see `lockAllowsAttachedPaths`). Implication: the stop is the gate,
  /// which refuses COPY (a utility statement) only on Read-only / Schema-only connections; a
  /// connection with no protection level does not refuse it, so a READ_ONLY attach there can be
  /// destroyed.
  @Test("COPY TO an attached file or its .wal is allowed with USE_TMP_FILE false")
  func copyToAttachedPaths() throws {
    let files = try Files()
    defer { files.remove() }
    let connection = try HardenedConnection(
      main: files.main, folder: files.root,
      attach: [
        "ATTACH \(literal(files.readOnly)) AS ro (READ_ONLY)",
        "ATTACH \(literal(files.writable)) AS rw",
      ])
    defer { connection.close() }

    for path in [files.writable, files.readOnly] {
      let message = try connection.failure("COPY (SELECT 1) TO \(literal(path))")
      #expect(message.contains(Self.disabled), "\(message)")
      #expect(message.contains("tmp_"), "\(message)")
    }
    #expect(
      try connection.rows("SELECT count(*) FROM read_blob(\(literal(files.readOnly)))")
        == [["1"]])
    let sibling = files.other.appendingPathComponent("sibling.csv").path
    #expect(
      try connection.failure(
        "COPY (SELECT 1) TO \(literal(sibling)) (FORMAT CSV, USE_TMP_FILE false)"
      )
      .contains(Self.disabled))

    // Destructive, last: the session is closed without reading these files again
    let walCopy =
      "COPY (SELECT 1) TO \(literal(files.readOnly + ".wal")) (FORMAT CSV, USE_TMP_FILE false)"
    _ = try connection.rows("PREPARE copy_wal AS \(walCopy)")
    #expect(try connection.rows("EXECUTE copy_wal") == [["1"]])
    _ = try connection.rows("DETACH rw")
    #expect(
      try connection.rows(
        "COPY (SELECT 1) TO \(literal(files.writable + ".wal")) (FORMAT CSV, USE_TMP_FILE false)"
      ) == [["1"]])
    #expect(
      try connection.rows(
        "COPY (SELECT 1) TO \(literal(files.readOnly)) (FORMAT CSV, USE_TMP_FILE false)")
        == [["1"]])
    // A CSV header line ("1", the column name) and the value
    let csv = Data("1\n1\n".utf8)
    #expect(try Data(contentsOf: URL(fileURLWithPath: files.readOnly)) == csv)
    #expect(try Data(contentsOf: URL(fileURLWithPath: files.readOnly + ".wal")) == csv)
  }

  /// Observed: `SET enable_external_access = false` adds the main file and every attached file
  /// to `allowed_paths`, each with its `.wal`, `.wal.checkpoint` and `.wal.recovery` siblings,
  /// and `temp_directory` (with a trailing slash) to `allowed_directories`; this replay (like
  /// DuckDBSession with empty `extraAllowedPaths`) sets neither. The entries stay after DETACH. Implication: these entries are why attached
  /// files keep working after the lock, and why a detached path can still be re-attached, read
  /// with SQL file functions or overwritten with COPY (see `readWriteAttachAfterLock`, `detachThenReattachEscalates`, `copyToAttachedPaths`).
  @Test("The lock adds attached files and their WAL siblings to allowed_paths, kept after DETACH")
  func lockAllowsAttachedPaths() throws {
    let files = try Files()
    defer { files.remove() }
    let connection = try HardenedConnection(
      main: files.main, folder: files.root,
      attach: [
        "ATTACH \(literal(files.readOnly)) AS ro (READ_ONLY)",
        "ATTACH \(literal(files.writable)) AS rw",
      ])
    defer { connection.close() }

    let expected = Set(
      [files.main, files.readOnly, files.writable].flatMap { path in
        ["", ".wal", ".wal.checkpoint", ".wal.recovery"].map { path + $0 }
      })
    let temp = files.root.appendingPathComponent(".duckdb-temp").path + "/"
    #expect(try setting(connection, "allowed_paths") == expected)
    #expect(try setting(connection, "allowed_directories") == [temp])
    _ = try connection.rows("DETACH ro")
    #expect(try setting(connection, "allowed_paths") == expected)
    #expect(try setting(connection, "allowed_directories") == [temp])
  }

  // MARK: - Helpers

  private func literal(_ path: String) -> String {
    SQLDialect.duckdb.literal(.string(path))
  }

  /// A list setting from `duckdb_settings()` (text like `[a, b]`) as a set of entries.
  private func setting(_ connection: HardenedConnection, _ name: String) throws -> Set<String> {
    let rows = try connection.rows("SELECT value FROM duckdb_settings() WHERE name = '\(name)'")
    let text = try #require(rows.first?.first ?? nil)
    let list = text.dropFirst().dropLast()
    return list.isEmpty ? [] : Set(list.components(separatedBy: ", "))
  }

  /// A main file and two attachable files in a sibling folder, each with `t(a)` holding one row.
  private struct Files {
    let root: URL
    let other: URL
    let main: String
    let writable: String
    let readOnly: String

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dblore-duckdb-attach-\(UUID().uuidString)", isDirectory: true)
      other = root.appendingPathComponent("other", isDirectory: true)
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      main = root.appendingPathComponent("main.duckdb").path
      writable = other.appendingPathComponent("rw.duckdb").path
      readOnly = other.appendingPathComponent("ro.duckdb").path
      do {
        for path in [main, writable, readOnly] {
          let connection = try HardenedConnection(main: path, folder: root, attach: [])
          defer { connection.close() }
          _ = try connection.rows("CREATE TABLE t (a INTEGER)")
          _ = try connection.rows("INSERT INTO t VALUES (1)")
        }
      } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
      }
    }

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}

/// DuckDBSession's open sequence on the raw C API with `attach` statements run between the
/// open options and `enable_external_access=false`. Results come back as text.
private nonisolated final class HardenedConnection {
  private let library: DuckDBLibrary
  private var database: OpaquePointer?
  private var connection: OpaquePointer?

  init(main: String, folder: URL, readOnly: Bool = false, attach: [String]) throws {
    library = try DuckDBTestPlugin.library()
    var options = [
      ("autoinstall_known_extensions", "false"),
      ("autoload_known_extensions", "false"),
      ("allow_community_extensions", "false"),
      ("allow_unsigned_extensions", "false"),
      ("allow_persistent_secrets", "false"),
    ]
    for (option, name) in [
      ("temp_directory", "temp"), ("extension_directory", "extensions"),
      ("secret_directory", "secrets"),
    ] {
      let url = folder.appendingPathComponent(".duckdb-\(name)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      options.append((option, url.path))
    }
    if readOnly { options.append(("access_mode", "READ_ONLY")) }
    var config: OpaquePointer?
    guard library.createConfig(&config) == DuckDBState.success else {
      throw DuckDBSessionError(message: "duckdb_create_config failed")
    }
    defer { library.destroyConfig(&config) }
    for (name, value) in options {
      guard library.setConfig(config, name, value) == DuckDBState.success else {
        throw DuckDBSessionError(message: "duckdb_set_config \(name) failed")
      }
    }
    var message: UnsafeMutablePointer<CChar>?
    guard library.openExt(main, &database, config, &message) == DuckDBState.success else {
      let text = message.map { String(cString: $0) } ?? "duckdb_open_ext failed"
      library.free(message)
      throw DuckDBSessionError(message: text)
    }
    guard library.connect(database, &connection) == DuckDBState.success else {
      library.close(&database)
      throw DuckDBSessionError(message: "duckdb_connect failed")
    }
    do {
      for sql in attach + ["SET enable_external_access = false", "SET lock_configuration = true"] {
        _ = try rows(sql)
      }
    } catch {
      close()
      throw error
    }
  }

  func rows(_ sql: String) throws -> [[String?]] {
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

  /// The error message of a statement that must fail.
  func failure(_ sql: String) throws -> String {
    let rows: [[String?]]
    do {
      rows = try self.rows(sql)
    } catch let error as DuckDBSessionError {
      return error.message
    }
    throw UnexpectedSuccess(description: "\(sql) returned \(rows)")
  }

  struct UnexpectedSuccess: Error, CustomStringConvertible { let description: String }

  func close() {
    if connection != nil { library.disconnect(&connection) }
    if database != nil { library.close(&database) }
  }
}
