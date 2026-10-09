// DuckDBFileAccessTests.swift
// DuckDB files through the sandbox open path and the session factory: .duckdb accepted,
// read-only by default, a `.wal` write probe instead of SQLite's, `.wal` presenter, in-memory without file access,
// and the plugin-missing error before any dlopen. The end-to-end test needs the dev plugin.

import Foundation
import Testing
import os

@testable import Dblore

@Suite("DuckDB file access and factory")
@MainActor
struct DuckDBFileAccessTests {
  private struct LoadAttempted: Error {}

  private func isMissingDuckDB(_ error: DatabaseError?) -> Bool {
    guard case .engineUnavailable(.duckdb)? = error else { return false }
    return true
  }

  private let databaseURL = URL(fileURLWithPath: "/tmp/dblore-access-test.duckdb")

  private func hooks(probes: OSAllocatedUnfairLock<Int>) -> SQLiteFileAccess.Hooks {
    var hooks = SQLiteFileAccess.Hooks()
    hooks.resolve = { [databaseURL] _ in (databaseURL, false) }
    hooks.startAccess = { url in
      SecurityScopedAccessToken(url: url, start: { _ in true }, stop: { _ in })
    }
    hooks.addPresenter = { _ in }
    hooks.removePresenter = { _ in }
    hooks.probe = { _ in probes.withLock { $0 += 1 } }
    hooks.probeDuckDB = { _ in }
    hooks.chooseFolder = { _ in nil }
    return hooks
  }

  @Test("A .duckdb file opens through the bookmark path with a .wal presenter")
  func duckDBFileAccepted() async throws {
    let added = OSAllocatedUnfairLock(initialState: [String]())
    var hooks = hooks(probes: OSAllocatedUnfairLock(initialState: 0))
    hooks.addPresenter = { presenter in
      added.withLock { $0.append(presenter.presentedItemURL?.path ?? "") }
    }
    let config = ConnectionConfig(
      databaseType: .duckdb, database: databaseURL.path, fileBookmark: Data([1]))

    let grant = try await SQLiteFileAccess.open(config: config, hooks: hooks)
    defer { grant.release() }

    #expect(grant.url == databaseURL)
    #expect(added.withLock { $0 } == [databaseURL.path + ".wal"])
  }

  @Test("DuckDB files are read-only by default; SQLite files are not")
  func duckDBDefaultsToReadOnly() async throws {
    #expect(ConnectionConfig(databaseType: .duckdb, database: databaseURL.path).readOnlyFile)
    #expect(!ConnectionConfig(databaseType: .sqlite, database: "/tmp/x.sqlite").readOnlyFile)
    #expect(
      !ConnectionConfig(databaseType: .duckdb, database: databaseURL.path, readOnlyFile: false)
        .readOnlyFile)

    // A saved DuckDB connection without the key decodes read-only too.
    var json = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(ConnectionConfig(databaseType: .duckdb, database: "/tmp/a")))
        as? [String: Any])
    json.removeValue(forKey: "readOnlyFile")
    let decoded = try JSONDecoder().decode(
      ConnectionConfig.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.readOnlyFile)

    let grant = try await SQLiteFileAccess.open(
      config: ConnectionConfig(
        databaseType: .duckdb, database: databaseURL.path, fileBookmark: Data([1])),
      hooks: hooks(probes: OSAllocatedUnfairLock(initialState: 0)))
    defer { grant.release() }
    #expect(grant.readOnly)
    #expect(grant.bannerReason == nil)
  }

  @Test("A read-write DuckDB file probes its .wal, not with SQLite")
  func duckDBProbesWAL() async throws {
    let probes = OSAllocatedUnfairLock(initialState: 0)
    let walProbes = OSAllocatedUnfairLock(initialState: [URL]())
    var hooks = hooks(probes: probes)
    hooks.probeDuckDB = { url in walProbes.withLock { $0.append(url) } }
    let grant = try await SQLiteFileAccess.open(
      config: ConnectionConfig(
        databaseType: .duckdb, database: databaseURL.path, fileBookmark: Data([1]),
        readOnlyFile: false),
      hooks: hooks)
    defer { grant.release() }

    #expect(probes.withLock { $0 } == 0)
    #expect(walProbes.withLock { $0 } == [databaseURL])
    #expect(grant.readOnly == false)
    #expect(grant.bannerReason == nil)
  }

  @Test("A denied DuckDB .wal asks for the folder; declining opens read-only")
  func duckDBWALDeniedOpensReadOnly() async throws {
    let asked = OSAllocatedUnfairLock(initialState: 0)
    var hooks = hooks(probes: OSAllocatedUnfairLock(initialState: 0))
    hooks.probeDuckDB = { _ in throw SQLiteFileAccess.SidecarDenied() }
    hooks.chooseFolder = { _ in
      asked.withLock { $0 += 1 }
      return nil
    }
    let grant = try await SQLiteFileAccess.open(
      config: ConnectionConfig(
        databaseType: .duckdb, database: databaseURL.path, fileBookmark: Data([1]),
        readOnlyFile: false),
      hooks: hooks)
    defer { grant.release() }

    #expect(asked.withLock { $0 } == 1)
    #expect(grant.readOnly)
    #expect(grant.bannerReason == SQLiteFileAccess.duckDBReadOnlyBannerReason)
  }

  @Test("A new read-write DuckDB file without a bookmark still gets the .wal probe")
  func newDuckDBFileWithoutBookmark() async throws {
    let walProbes = OSAllocatedUnfairLock(initialState: 0)
    var hooks = hooks(probes: OSAllocatedUnfairLock(initialState: 0))
    hooks.resolve = { _ in throw SQLiteFileAccess.Failure.missingBookmark }
    hooks.probeDuckDB = { _ in walProbes.withLock { $0 += 1 } }
    let grant = try await SQLiteFileAccess.open(
      config: ConnectionConfig(
        databaseType: .duckdb, database: databaseURL.path, readOnlyFile: false),
      hooks: hooks)
    defer { grant.release() }

    #expect(grant.url == databaseURL)
    #expect(grant.bookmark == nil)
    #expect(walProbes.withLock { $0 } == 1)
  }

  @Test("The .wal probe leaves no file behind and keeps an existing one")
  func walProbeOnDisk() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-wal-probe-\(UUID().uuidString).duckdb")
    let wal = URL(fileURLWithPath: url.path + ".wal")
    try SQLiteFileAccess.probeDuckDBWAL(url)
    #expect(!FileManager.default.fileExists(atPath: wal.path))

    try Data([7]).write(to: wal)
    defer { try? FileManager.default.removeItem(at: wal) }
    try SQLiteFileAccess.probeDuckDBWAL(url)
    #expect(try Data(contentsOf: wal) == Data([7]))
  }

  @Test("In-memory DuckDB needs no file access, even with a stale bookmark")
  func inMemoryNeedsNoFileAccess() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    // An unresolvable bookmark would fail `SQLiteFileAccess.open`.
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        safeMode: .silent, protectedMode: false, fileBookmark: Data([1])))
    #expect(await manager.isConnected)
    #expect(await manager.config?.database == DuckDBSession.inMemoryPath)
    await manager.disconnect()
  }

  @Test("The app factory makes a DuckDBSession without loading the plugin yet")
  func factoryMakesDuckDBSession() async throws {
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let factory = AppDatabaseSessionFactory(
      duckDBLibraryLoader: {
        { () throws -> DuckDBLibrary in
          loads.withLock { $0 += 1 }
          throw LoadAttempted()
        }
      })
    let session = try await factory.makeSession(
      config: ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath))
    #expect(session is DuckDBSession)
    #expect(loads.withLock { $0 } == 0)
  }

  @Test("Plugin not installed: connect and test fail with the install error, no dlopen")
  func pluginMissingIsActionable() async throws {
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let factory = AppDatabaseSessionFactory(duckDBLibraryLoader: {
      loads.withLock { $0 += 1 }
      return nil
    })
    let config = ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath)

    let direct = await #expect(throws: DatabaseError.self) {
      _ = try await factory.makeSession(config: config)
    }
    #expect(isMissingDuckDB(direct))

    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let connectError = await #expect(throws: DatabaseError.self) {
      try await manager.connect(config: config)
    }
    #expect(isMissingDuckDB(connectError))
    #expect(ConnectionErrorAction.action(for: try #require(connectError)) == .openPluginSettings)
    #expect(await manager.session == nil)

    let testError = await #expect(throws: DatabaseError.self) {
      _ = try await manager.testConnection(config: config)
    }
    #expect(isMissingDuckDB(testError))
    // The loader is asked for, but nothing is loaded when the plugin is not installed.
    #expect(loads.withLock { $0 } == 3)
  }

  // MARK: - Read-only file gating

  nonisolated private static let writesToOwnFile = [
    "COPY (SELECT 1) TO '/tmp/dblore-access-test.duckdb' (USE_TMP_FILE false)",
    "INSERT INTO t VALUES (1)",
    "CREATE TABLE t2 (id INTEGER)",
    "EXPORT DATABASE '/tmp/dblore-export'",
    "ATTACH '/tmp/other.duckdb' AS other",
  ]

  private func gate(_ sql: String, _ config: ConnectionConfig) -> GateDecision {
    DatabaseConnectionManager.evaluate(
      DatabaseConnectionManager.classifyUserSQL(sql, config: config),
      policy: ProtectionPolicy(config: config))
  }

  private func isBlocked(_ decision: GateDecision) -> Bool {
    if case .blocked = decision { return true }
    return false
  }

  @Test(
    "A read-only DuckDB file with protection off gates writes as Read-only",
    arguments: writesToOwnFile)
  func readOnlyDuckDBFileGatesWrites(sql: String) {
    let config = ConnectionConfig(databaseType: .duckdb, database: databaseURL.path)
    #expect(config.readOnlyFile && config.protectionLevel == .none)
    #expect(isBlocked(gate(sql, config)))
  }

  @Test("A read-only DuckDB file still runs reads and plain EXPLAIN")
  func readOnlyDuckDBFileAllowsReads() {
    let config = ConnectionConfig(databaseType: .duckdb, database: databaseURL.path)
    #expect(!isBlocked(gate("SELECT 1", config)))
    #expect(!isBlocked(gate("EXPLAIN SELECT 1", config)))
    #expect(!isBlocked(gate("SHOW TABLES", config)))
    #expect(!isBlocked(gate("DESCRIBE t", config)))
    #expect(!isBlocked(gate("SUMMARIZE t", config)))
  }

  @Test(
    "SQLite read-only files, read-write and in-memory DuckDB keep their configured level",
    arguments: writesToOwnFile)
  func otherConfigsUnchanged(sql: String) {
    let sqlite = ConnectionConfig(
      databaseType: .sqlite, database: "/tmp/x.sqlite", readOnlyFile: true)
    let readWrite = ConnectionConfig(
      databaseType: .duckdb, database: databaseURL.path, readOnlyFile: false)
    let inMemory = ConnectionConfig(databaseType: .duckdb, database: DuckDBSession.inMemoryPath)
    for config in [sqlite, readWrite, inMemory] {
      #expect(ProtectionPolicy(config: config).protectionLevel == .none)
      #expect(!isBlocked(gate(sql, config)))
    }
  }

  @Test("The displayed protection level of a read-only DuckDB file is unchanged")
  func displayedLevelUnchanged() {
    let config = ConnectionConfig(databaseType: .duckdb, database: databaseURL.path)
    #expect(config.protectionLevel == .none)
    #expect(ProtectionPolicy(config: config).protectionLevel == .readOnly)
  }
}

/// Nested so `-only-testing:DbloreTests/DuckDBFileAccessTests` runs it when the gate is on.
extension DuckDBFileAccessTests {
  @Suite("DuckDB file through the factory", .requiresDuckDBPlugin, .serialized)
  struct FactoryIntegration {
    private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

    private var factory: AppDatabaseSessionFactory {
      AppDatabaseSessionFactory(duckDBLibraryLoader: { { try DuckDBTestPlugin.library() } })
    }

    private func config(_ path: String, readOnlyFile: Bool? = nil) -> ConnectionConfig {
      ConnectionConfig(
        databaseType: .duckdb, database: path, sslMode: .disable, safeMode: .silent,
        protectedMode: false, readOnlyFile: readOnlyFile)
    }

    @Test("A temp .duckdb file opens through the factory, queries, and closes")
    func openQueryClose() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("dblore-duckdb-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let path = folder.appendingPathComponent("sample.duckdb").path

      // Read-only refuses a missing file, so the first open writes it explicitly.
      let writer = DatabaseConnectionManager(sessionFactory: factory)
      try await writer.connect(config: config(path, readOnlyFile: false))
      #expect(await writer.session is DuckDBSession)
      _ = try await writer.execute(
        userSQL: "CREATE TABLE t AS SELECT 42 AS answer", policy: open)
      await writer.disconnect()
      #expect(FileManager.default.fileExists(atPath: path))

      // Default (read-only) open reads the file and refuses writes at the engine.
      let reader = DatabaseConnectionManager(sessionFactory: factory)
      #expect(try await reader.testConnection(config: config(path)))
      try await reader.connect(config: config(path))
      let read = try await reader.execute(userSQL: "SELECT answer FROM t", policy: open)
      #expect(read.rows == [[.int(42)]])
      await #expect(throws: (any Error).self) {
        _ = try await reader.execute(userSQL: "INSERT INTO t VALUES (1)", policy: open)
      }
      await reader.disconnect()
      #expect(await reader.isConnected == false)
    }

    @Test("Default config: COPY to the database file is refused and the file still opens")
    func copyOntoOwnFileRefused() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("dblore-duckdb-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let path = folder.appendingPathComponent("sample.duckdb").path

      let writer = DatabaseConnectionManager(sessionFactory: factory)
      try await writer.connect(config: config(path, readOnlyFile: false))
      _ = try await writer.execute(
        userSQL: "CREATE TABLE t AS SELECT 42 AS answer", policy: open)
      await writer.disconnect()

      // Default config: read-only file, protection off; the caller's policy is open too.
      let reader = DatabaseConnectionManager(sessionFactory: factory)
      try await reader.connect(config: config(path))
      let error = await #expect(throws: DatabaseError.self) {
        _ = try await reader.execute(
          userSQL: "COPY (SELECT 1) TO '\(path)' (USE_TMP_FILE false)", policy: open)
      }
      guard case .blockedByProtection? = error else {
        Issue.record("expected blockedByProtection, got \(String(describing: error))")
        return
      }
      await reader.disconnect()

      let again = DatabaseConnectionManager(sessionFactory: factory)
      try await again.connect(config: config(path))
      let read = try await again.execute(userSQL: "SELECT answer FROM t", policy: open)
      #expect(read.rows == [[.int(42)]])
      await again.disconnect()
    }
  }
}
