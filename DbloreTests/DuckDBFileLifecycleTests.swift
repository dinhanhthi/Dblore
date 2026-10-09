// DuckDBFileLifecycleTests.swift
// Picked DuckDB files over the connection lifecycle, with fake sessions (no plugin): which
// paths each new session gets, when the access tokens are released, and what the Query
// Parquet/CSV File action does when the connection changes while its panel is open.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB picked files lifecycle")
@MainActor
struct DuckDBFileLifecycleTests {
  private static func duckDB(_ database: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: database, sslMode: .disable, rememberConnection: false,
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  private static let postgres = ConnectionConfig(
    databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
    password: "p", sslMode: .disable, rememberConnection: false, protectionLevel: .none,
    safeMode: .silent, protectedMode: false)

  private let first = Self.duckDB("/tmp/dblore-first.duckdb")
  private let second = Self.duckDB("/tmp/dblore-second.duckdb")

  private func makeManager(
    _ factory: AllowedPathsRecordingFactory, config: ConnectionConfig, counter: TokenCounter
  ) -> WorkspaceManager {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory))
    manager.accessHooks.startAccess = { url in
      SecurityScopedAccessToken(
        url: url,
        start: { _ in
          counter.started += 1
          return true
        },
        stop: { _ in counter.stopped += 1 })
    }
    return manager
  }

  // MARK: - Connection actor

  @Test("A disconnect clears the actor's paths; its internal reconnect keeps them")
  func actorClearsOnDisconnectOnly() async throws {
    let factory = AllowedPathsRecordingFactory()
    let connection = DatabaseConnectionManager(sessionFactory: factory)

    try await connection.connect(config: first, extraAllowedPaths: ["/data/a.csv"])
    // Cancel and the capped read reopen the session through this call
    try await connection.reconnectWithActiveCertificate(config: first, material: nil)
    #expect(factory.recorded.last == ["/data/a.csv"])
    #expect(await connection.duckDBAllowedPaths == ["/data/a.csv"])

    await connection.disconnect()
    #expect(await connection.duckDBAllowedPaths.isEmpty)
    try await connection.connect(config: first)
    #expect(factory.recorded.last == [])
    await connection.disconnect()
  }

  // MARK: - Workspace

  @Test(
    "Another DuckDB database or another engine opens with no files and releases them",
    arguments: [false, true])
  func otherConnectDropsFiles(switchesEngine: Bool) async throws {
    let factory = AllowedPathsRecordingFactory()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: first)
    manager.addDuckDBFileAccess(URL(fileURLWithPath: "/data/a.csv"), path: "/data/a.csv")

    try await manager.connect(config: first)
    #expect(factory.recorded.last == ["/data/a.csv"])
    #expect(counter.stopped == 0)

    try await manager.connect(config: switchesEngine ? Self.postgres : second)
    #expect(factory.recorded.last == [])
    #expect(await manager.connectionManager.duckDBAllowedPaths.isEmpty)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(counter.started == 1)
    #expect(counter.stopped == 1)
  }

  @Test("A failed reconnect for a picked file releases that file")
  func failedGrantReleasesFile() async throws {
    let folder = try DuckDBFileQueryTests.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("data.csv")
    try Data("a\n1\n".utf8).write(to: file)
    let factory = AllowedPathsRecordingFactory()
    factory.openError = FakeQueryError()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    manager.accessHooks.chooseDataFile = { _ in file }

    #expect(await manager.queryDuckDBFile() == nil)
    #expect(factory.recorded.last == [try DuckDBFileQuery.canonicalPath(of: file)])
    #expect(counter.started == 1)
    #expect(counter.stopped == 1)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(manager.connectionState == .disconnected)
  }

  enum DuringPick: CaseIterable {
    case connectsOtherDatabase, switchesEngine, disconnects
  }

  @Test(
    "A connection changed while the panel is open: nothing reconnects, no file is held",
    arguments: DuringPick.allCases)
  func connectionChangedDuringPick(change: DuringPick) async throws {
    let folder = try DuckDBFileQueryTests.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("data.csv")
    try Data("a\n1\n".utf8).write(to: file)
    let factory = AllowedPathsRecordingFactory()
    let counter = TokenCounter()
    let manager = makeManager(factory, config: first, counter: counter)
    defer { Task { await manager.performDisconnect() } }
    try await manager.connect(config: first)
    let other = change == .switchesEngine ? Self.postgres : second
    manager.accessHooks.chooseDataFile = { _ in
      switch change {
      case .connectsOtherDatabase, .switchesEngine: try? await manager.connect(config: other)
      case .disconnects: await manager.performDisconnect()
      }
      return file
    }
    let sessionsBefore = factory.recorded.count

    #expect(await manager.queryDuckDBFile() == nil)

    let expectedSessions = sessionsBefore + (change == .disconnects ? 0 : 1)
    #expect(factory.recorded.count == expectedSessions)
    #expect(
      manager.workspace.connectionConfig?.database
        == (change == .disconnects ? first : other).database)
    #expect(counter.started == 0)
    #expect(manager.duckDBAllowedPaths.isEmpty)
    #expect(await manager.connectionManager.duckDBAllowedPaths.isEmpty)
  }
}

private nonisolated final class TokenCounter: @unchecked Sendable {
  var started = 0
  var stopped = 0
}

/// Fake sessions that record the `extraAllowedPaths` each one was made with.
private nonisolated final class AllowedPathsRecordingFactory: DatabaseSessionFactory,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var paths: [[String]] = []
  private var error: (any Error)?

  /// Every session made from now on fails to open.
  var openError: (any Error)? {
    get { lock.withLock { error } }
    set { lock.withLock { error = newValue } }
  }

  var recorded: [[String]] { lock.withLock { paths } }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    try await makeSession(config: config, extraAllowedPaths: [])
  }

  func makeSession(
    config: ConnectionConfig, extraAllowedPaths: [String]
  ) async throws -> any DatabaseSession {
    lock.withLock { paths.append(extraAllowedPaths) }
    return FakeDatabaseSessionFactory(capabilities: .contract(), openError: openError)
      .makeSession(config: config)
  }
}
