// WorkspaceAIQueryTests.swift
// History rows of AI Assistant queries and the workspace runner: guarded, then run on an
// ephemeral read-only session (never the workspace's own), recorded in History.

import Foundation
import Testing

@testable import Dblore

/// Appends recorded entries, so a test sees what the AI runner recorded.
private actor RecordingHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// Opening a session fails with a server text that must not reach the chat
private struct SecretConnectError: LocalizedError {
  var errorDescription: String? { "password authentication failed for user \"ana-secret\"" }
}

@Suite("Workspace AI query")
@MainActor
struct WorkspaceAIQueryTests {
  private static let workspaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  @Test("An AI query is recorded as a read from the AI Assistant in its workspace")
  func entryFields() {
    let config = ConnectionConfig(
      host: "db.example", port: 5432, database: "shop", username: "ana", name: "  Prod  ")
    let entry = WorkspaceManager.aiHistoryEntry(
      sql: "SELECT email FROM customers WHERE id = 11", config: config,
      workspaceID: Self.workspaceID, workspaceName: "Shop", durationMs: 12, rowCount: 1,
      status: .success, error: nil)

    #expect(entry.sql == "SELECT email FROM customers WHERE id = 11")
    #expect(entry.source == .ai)
    #expect(entry.kind == .read)
    #expect(entry.status == .success)
    #expect(entry.rowCount == 1)
    #expect(entry.durationMs == 12)
    #expect(entry.errorMessage == nil)
    #expect(entry.workspaceID == Self.workspaceID)
    #expect(entry.workspaceName == "Shop")
    #expect(entry.connectionKey == QueryHistoryIdentity.connectionKey(for: config))
    #expect(entry.connectionLabel == "Prod")
  }

  @Test("A failed AI query keeps its error")
  func failureKeepsError() {
    let entry = WorkspaceManager.aiHistoryEntry(
      sql: "SELECT nope FROM t", config: ConnectionConfig(host: "h", database: "d"),
      workspaceID: nil, workspaceName: nil, durationMs: 3, rowCount: nil, status: .error,
      error: "column \"nope\" does not exist")

    #expect(entry.status == .error)
    #expect(entry.rowCount == nil)
    #expect(entry.errorMessage == "column \"nope\" does not exist")
  }

  @Test("SQL that carries a password is recorded with its strings redacted and no error")
  func passwordRedacted() {
    let config = ConnectionConfig(databaseType: .mysql, host: "h", port: 3306, database: "d")
    let entry = WorkspaceManager.aiHistoryEntry(
      sql: "SELECT secret FROM t WHERE PASSWORD('hunter2')", config: config,
      workspaceID: Self.workspaceID, workspaceName: "Shop", durationMs: 1, rowCount: nil,
      status: .error, error: "near 'hunter2': bad value hunter2")

    #expect(entry.sql == "SELECT secret FROM t WHERE PASSWORD('…')")
    #expect(entry.errorMessage == nil)
  }

  @Test("A connection without a name is labelled host/database")
  func unnamedConnectionLabel() {
    let entry = WorkspaceManager.aiHistoryEntry(
      sql: "SELECT 1", config: ConnectionConfig(host: "db.example", database: "shop", name: " "),
      workspaceID: nil, workspaceName: nil, durationMs: 0, rowCount: 1, status: .success,
      error: nil)

    #expect(entry.connectionLabel == "db.example/shop")
  }

  @Test("Without a connection the runner throws not connected")
  func notConnectedThrows() async {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    await #expect(throws: AIAssistantViewModel.QueryRunError.self) {
      _ = try await manager.runAIQuery("SELECT 1")
    }
    #expect(manager.aiAssistant.queryRunner != nil)
  }

  @Test("The runner guards the SQL for the live connection before sending it")
  func guardsForLiveConnection() async {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: ConnectionConfig(host: "h", database: "d")),
      restoreTabs: false)
    manager.connectionState = .connected

    await #expect(throws: ReadOnlyQueryGuard.Refusal.sideEffectFunction) {
      _ = try await manager.runAIQuery("SELECT pg_terminate_backend(pid) FROM pg_stat_activity")
    }
  }

  /// A workspace whose live manager is connected to `live`; AI queries open sessions of `aiRead`
  private func connectedManager(
    live: FakeDatabaseSessionFactory, aiRead: FakeDatabaseSessionFactory,
    databaseType: DatabaseType = .postgresql
  ) async throws -> WorkspaceManager {
    let config = ConnectionConfig(
      databaseType: databaseType, host: "fake", port: 1,
      database: databaseType == .duckdb ? DuckDBSession.inMemoryPath : "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: live))
    try await manager.connectionManager.connect(config: config)
    manager.connectionState = .connected
    manager.aiReadSessionFactory = aiRead
    return manager
  }

  @Test("PostgreSQL: the query runs in a READ ONLY transaction on its own session, then closes")
  func runsOnEphemeralReadOnlySession() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let aiRead = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]])
    let manager = try await connectedManager(live: live, aiRead: aiRead)

    let result = try await manager.runAIQuery("SELECT archive_row(id) FROM t")

    #expect(result.rowCount == 1)
    #expect(
      aiRead.statements == [
        "BEGIN TRANSACTION READ ONLY", "SELECT archive_row(id) FROM t", "ROLLBACK",
      ])
    #expect(aiRead.sessions.count == 1)
    #expect(aiRead.sessions.allSatisfy { $0.didClose })
    #expect(live.statements.isEmpty)
  }

  @Test("A PostgreSQL read cut by the row cap closes its session without reopening it")
  func cappedReadDoesNotReconnect() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let aiRead = FakeDatabaseSessionFactory(
      capabilities: .contract(), rows: Array(repeating: [.int(1)], count: 60))
    let manager = try await connectedManager(live: live, aiRead: aiRead)

    let result = try await manager.runAIQuery("SELECT id FROM t")

    #expect(result.rowCount == AIAssistantViewModel.modelRowCap + 1)
    #expect(result.truncated)
    #expect(aiRead.sessions.count == 1)
    #expect(aiRead.sessions.allSatisfy { $0.didClose })
    // The ROLLBACK after the close races it; the closed session ends the transaction anyway
    #expect(
      aiRead.statements.prefix(2) == ["BEGIN TRANSACTION READ ONLY", "SELECT id FROM t"])
    #expect(live.statements.isEmpty)
  }

  @Test("DuckDB: the query runs on the workspace session, no read-only session is opened")
  func duckDBRunsOnLiveSession() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]])
    let aiRead = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]])
    let manager = try await connectedManager(live: live, aiRead: aiRead, databaseType: .duckdb)

    let result = try await manager.runAIQuery("SELECT 1")

    #expect(result.rowCount == 1)
    #expect(live.statements == ["SELECT 1"])
    #expect(aiRead.sessions.isEmpty)
  }

  @Test("A failing query is rolled back and its session closed")
  func failingQueryClosesSession() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let aiRead = FakeDatabaseSessionFactory(capabilities: .contract(), failingQuery: "boom")
    let manager = try await connectedManager(live: live, aiRead: aiRead)

    await #expect(throws: (any Error).self) {
      _ = try await manager.runAIQuery("SELECT boom FROM t")
    }

    #expect(aiRead.statements == ["BEGIN TRANSACTION READ ONLY", "SELECT boom FROM t", "ROLLBACK"])
    #expect(aiRead.sessions.allSatisfy { $0.didClose })
    #expect(live.statements.isEmpty)
  }

  @Test("A read-only session that cannot open fails without the server's text")
  func connectFailureIsGeneric() async throws {
    let live = FakeDatabaseSessionFactory(capabilities: .contract())
    let aiRead = FakeDatabaseSessionFactory(
      capabilities: .contract(), openError: SecretConnectError())
    let manager = try await connectedManager(live: live, aiRead: aiRead)

    do {
      _ = try await manager.runAIQuery("SELECT 1")
      Issue.record("expected a failure")
    } catch {
      #expect(error as? AIAssistantViewModel.QueryRunError == .readSessionFailed)
      #expect(!error.localizedDescription.contains("ana-secret"))
    }
    #expect(live.statements.isEmpty)
  }

  @Test("SQL the guard refuses is not recorded in History")
  func refusalNotRecorded() async throws {
    let recorder = RecordingHistory()
    let manager = try await connectedManager(
      live: FakeDatabaseSessionFactory(capabilities: .contract()),
      aiRead: FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(1)]]))
    manager.aiHistoryRecorder = recorder

    await #expect(throws: ReadOnlyQueryGuard.Refusal.self) {
      _ = try await manager.runAIQuery("DELETE FROM t")
    }
    _ = try await manager.runAIQuery("SELECT 1")
    for _ in 0..<500 where await recorder.entries.isEmpty {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(await recorder.entries.map(\.sql) == ["SELECT 1"])
  }
}
