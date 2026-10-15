//
//  WorkspaceManager+AIQuery.swift
//  Dblore
//
//  Runs the AI Assistant's guarded read-only query on a read-only session of the workspace
//  connection and records it in History (source AI Assistant).
//

import Foundation

extension WorkspaceManager {
  /// Runs `sql` under a read-only policy, reading at most `modelRowCap + 1` rows so a cut
  /// result is visible. `ReadOnlyQueryGuard` checks it again for the live connection's dialect
  /// (the connection may have changed since the reply was asked for); a refusal is not recorded.
  /// The guard only classifies (a function it does not know may still write), so PostgreSQL,
  /// MySQL, SQLite and MongoDB queries run on a read-only session of their own
  /// (`runOnReadOnlySession`; MongoDB: a plain session that runs reads only, after the guard
  /// refused server-side JavaScript), never the workspace's: no write commits, and the tabs'
  /// transactions are neither joined nor read. DuckDB runs on the workspace session. Records
  /// History on success and failure, then rethrows.
  func runAIQuery(_ sql: String) async throws -> QueryResult {
    guard connectionState.isConnected, let config = workspace.connectionConfig else {
      throw AIAssistantViewModel.QueryRunError.notConnected
    }
    _ = try ReadOnlyQueryGuard.check(
      sql, dialect: config.databaseType.dialect, refuseFileAccess: true)
    let started = ContinuousClock.now
    do {
      let result: QueryResult
      if config.databaseType == .duckdb {
        // `MCPReadOnlySessionFactory` refuses DuckDB (a second in-process instance is a frozen
        // snapshot, and closing it drops the writer's file lock), and DuckDB has no SQL-defined
        // function that writes. The guard refuses its file reads; rows never go to the model.
        // `caller` nil: refused while a tab owns a pending transaction.
        result = try await connectionManager.execute(
          userSQL: sql, policy: ProtectionPolicy(protectionLevel: .readOnly),
          maxRows: AIAssistantViewModel.modelRowCap + 1, caller: nil)
      } else {
        result = try await runOnReadOnlySession(sql)
      }
      scheduleAIHistory(
        sql, config: config, started: started, rowCount: result.rowCount, status: .success,
        error: nil)
      return result
    } catch {
      scheduleAIHistory(
        sql, config: config, started: started, rowCount: nil,
        status: Self.aiHistoryStatus(for: error), error: error.localizedDescription)
      throw error
    }
  }

  /// Runs `sql` on a new session as MCP does (`MCPReadOnlySessionFactory`: PostgreSQL / MySQL
  /// inside a READ ONLY transaction that is always rolled back, SQLite on the file opened
  /// read-only, MongoDB on a plain session that runs reads only), connected like the workspace session (its config, unremembered certificate and
  /// SSH secret, host-key policy), then closed. A failed connect throws `.readSessionFailed`,
  /// without the server's text.
  private func runOnReadOnlySession(_ sql: String) async throws -> QueryResult {
    guard let config = await connectionManager.config else {
      throw AIAssistantViewModel.QueryRunError.notConnected
    }
    let manager = DatabaseConnectionManager(
      sessionFactory: MCPReadOnlySessionFactory(
        inner: aiReadSessionFactory
          ?? AppDatabaseSessionFactory(hostKeyValidator: connectionManager.sshHostKeyPolicy)),
      readLimits: MCPConnectionPool.readLimits, resetsSessionAfterCappedRead: false)
    do {
      try await manager.reconnectWithActiveCertificate(
        config: config, material: activeUnrememberedCertificate,
        sshCredential: activeUnrememberedSSHCredential)
    } catch {
      await manager.disconnect()
      throw AIAssistantViewModel.QueryRunError.readSessionFailed
    }
    do {
      let result = try await manager.execute(
        userSQL: sql, policy: ProtectionPolicy(protectionLevel: .readOnly),
        maxRows: AIAssistantViewModel.modelRowCap + 1)
      await manager.disconnect()
      return result
    } catch {
      await manager.disconnect()
      throw error
    }
  }

  /// One History row for an AI query. SQL that carries a password is stored with its string
  /// literals redacted and without its error text (a server may echo the literal), as MCP does.
  nonisolated static func aiHistoryEntry(
    sql: String, config: ConnectionConfig, workspaceID: UUID?, workspaceName: String?,
    durationMs: Int, rowCount: Int?, status: QueryHistoryEntry.Status, error: String?
  ) -> QueryHistoryEntry {
    let dialect = config.databaseType.dialect
    let redacted = SQLStatementClassifier.containsPasswordLiteral(sql, dialect: dialect)
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return QueryHistoryEntry(
      id: 0, sql: redacted ? MCPToolService.redactingStrings(sql, dialect: dialect) : sql,
      executedAt: Date(), durationMs: durationMs, rowCount: rowCount, status: status,
      errorMessage: redacted ? nil : error,
      connectionKey: QueryHistoryIdentity.connectionKey(for: config),
      connectionLabel: name.isEmpty ? "\(config.host)/\(config.database)" : name,
      workspaceID: workspaceID, workspaceName: workspaceName, source: .ai, kind: .read)
  }

  /// Records after the query has returned, when History is on, then reloads the History list.
  /// A recorder failure cannot fail the query.
  private func scheduleAIHistory(
    _ sql: String, config: ConnectionConfig, started: ContinuousClock.Instant, rowCount: Int?,
    status: QueryHistoryEntry.Status, error: String?
  ) {
    guard AppSettings.shared.historyEnabled else { return }
    let entry = Self.aiHistoryEntry(
      sql: sql, config: config, workspaceID: workspace.id, workspaceName: workspace.name,
      durationMs: Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded()),
      rowCount: rowCount, status: status, error: error)
    let recorder = aiHistoryRecorder
    Task { [weak self] in
      await recorder.record(entry)
      await self?.refreshHistory()
    }
  }

  private static func aiHistoryStatus(for error: Error) -> QueryHistoryEntry.Status {
    switch error as? DatabaseError {
    case .queryCancelled, .batchCancelled: .cancelled
    default: .error
    }
  }
}
