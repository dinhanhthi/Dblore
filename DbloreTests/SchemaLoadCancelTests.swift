// SchemaLoadCancelTests.swift
// The sidebar's Cancel stops a schema load that Refresh started: the column read ends at its
// next chunk instead of reading every remaining relation. A SQLite file of several chunks.

import Foundation
import Testing

@testable import Dblore

@Suite("Schema load cancel")
@MainActor
struct SchemaLoadCancelTests {
  /// Over two chunks of the introspector's 500 relations
  private static let tableCount = 1_200

  @Test("Cancel during a Refresh stops its column read after the current chunk")
  func cancelStopsRefreshRead() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-schema-cancel-\(UUID().uuidString).sqlite")
    defer { removeDatabase(url) }
    let handle = try SQLiteHandle(url: url)
    try handle.transaction {
      for index in 0..<Self.tableCount {
        try handle.execute("CREATE TABLE t\(index) (id INTEGER)")
      }
    }
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let probe = ColumnReadProbe()
    let manager = DatabaseConnectionManager(sessionFactory: ProbingSQLiteFactory(probe: probe))
    try await manager.connect(config: config)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: manager)
    workspace.connectionState = .connected
    // The first column read presses Cancel
    probe.onFirstRead = { await workspace.userCancelledSchemaLoad() }

    await workspace.refreshDatabaseSchema()

    #expect(probe.reads > 0)
    #expect(probe.reads <= 500)
    #expect(workspace.databaseTables.isEmpty)
    #expect(!workspace.isLoadingSchema)
    #expect(workspace.isSchemaLoadCancelledByUser)
    await manager.disconnect()
  }

  private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}

/// Counts the per-relation column reads (`pragma_table_xinfo`); runs `onFirstRead` on the first
private final class ColumnReadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var hook: (@Sendable () async -> Void)?

  var reads: Int { lock.withLock { count } }

  var onFirstRead: (@Sendable () async -> Void)? {
    get { lock.withLock { hook } }
    set { lock.withLock { hook = newValue } }
  }

  /// The hook to run for this read: set on the first one only
  func noteRead() -> (@Sendable () async -> Void)? {
    lock.withLock {
      count += 1
      return count == 1 ? hook : nil
    }
  }
}

private struct ProbingSQLiteFactory: DatabaseSessionFactory {
  let probe: ColumnReadProbe

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    ProbingSession(base: SQLiteSession(config: config), probe: probe)
  }
}

/// Forwards to a SQLite session and reports each column read to the probe before it runs
private final class ProbingSession: DatabaseSession, @unchecked Sendable {
  private let base: SQLiteSession
  private let probe: ColumnReadProbe

  init(base: SQLiteSession, probe: ColumnReadProbe) {
    self.base = base
    self.probe = probe
  }

  var capabilities: DatabaseCapabilities { base.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { base.closeEvents }

  func open() async throws { try await base.open() }

  func close() async { await base.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    if sql.contains("pragma_table_xinfo"), let hook = probe.noteRead() {
      await hook()
    }
    return try await base.query(sql, binds: binds)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await base.command(sql, binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await base.openCursor(sql, binds: binds)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    try await base.fetch(cursor, maxRows: maxRows)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    try await base.closeCursor(cursor)
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await base.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await base.interrupt() }

  func formatError(_ error: Error) -> String { base.formatError(error) }
}
