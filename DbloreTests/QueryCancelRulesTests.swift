// QueryCancelRulesTests.swift
// C3: cancelling a running query closes the connection, so the ViewModel first warns when that
// discards pending Protected changes or the user's open transaction (pure rule).

import Foundation
import Testing

@testable import Dblore

@Suite("Query Cancel - Rules")
struct QueryCancelRulesTests {
  private func summary(_ sql: String, rows: Int?) -> StatementSummary {
    guard let statement = SQLStatementClassifier.classifyStatement(sql) else {
      Issue.record("Could not classify \(sql)")
      return StatementSummary(
        statement: SQLStatementClassifier.classify("SELECT 1")[0], affectedRows: rows)
    }
    return StatementSummary(statement: statement, affectedRows: rows)
  }

  @Test("Nothing pending and no user transaction: cancel without a warning")
  func idleNeedsNoWarning() {
    #expect(QueryCancelWarning.make(state: .idle, userTxOpen: false) == nil)
  }

  @Test("An interrupt that keeps the transaction (MySQL, MongoDB) warns about nothing")
  func keptTransactionNeedsNoWarning() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    #expect(
      QueryCancelWarning.make(
        state: .appTx(pending: pending), userTxOpen: true, keepsTransaction: true) == nil)
    #expect(QueryCancelWarning.statementInterrupt.detail.contains("kept"))
    #expect(!QueryCancelWarning.statementInterrupt.detail.contains("reset"))
  }

  /// Both ViewModel paths: the cancel button (only asks when something is discarded) and the
  /// editor Run button (`alwaysConfirm`). MongoDB has no transactions: nothing is staged.
  @Test(
    "MySQL and MongoDB never ask to roll back on cancel; PostgreSQL does",
    .timeLimit(.minutes(1)), arguments: [DatabaseType.mysql, .mongodb, .postgresql])
  @MainActor
  func cancelPromptPerEngine(type: DatabaseType) async throws {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: type.capabilities.cancelStrategy),
      slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "fake", username: "u",
        password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    if type.capabilities.supportsTransactions {
      _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
      #expect(await connection.transactionSnapshot().pending.count == 1)
    }
    let read = type == .mongodb ? "db.t.find({})" : "SELECT pg_sleep(30)"
    let running = Task { try await connection.execute(userSQL: read, policy: protected) }
    await session.waitUntilQueryStarted()

    let viewModel = NotebookViewModel()
    viewModel.connectionManager = connection
    var warnings: [QueryCancelWarning] = []
    // Keep running: the statement stays in flight for the next path
    viewModel.cancelQueryPrompt = { warning in
      warnings.append(warning)
      return false
    }
    let keeps = type.interruptKeepsTransaction
    let rollBack = "Cancelling will roll back 1 pending change"

    // Editor Run button: always asks, with the kept wording when nothing is discarded
    #expect(
      await viewModel.cancelRunningStatement(cancelQueue: false, alwaysConfirm: true) == false)
    if keeps {
      #expect(warnings == [.statementInterrupt])
    } else {
      #expect(warnings.map(\.title) == [rollBack])
    }

    // Cancel button: no prompt at all when the interrupt keeps the transaction (it cancels)
    warnings = []
    #expect(await viewModel.cancelRunningStatement(cancelQueue: false) == keeps)
    #expect(warnings.map(\.title) == (keeps ? [] : [rollBack]))

    await session.interrupt()
    _ = try? await running.value
    await connection.disconnect()
  }

  /// The interrupt keeps the session. SQLite may roll back the transaction (it keeps it after
  /// a read): hedged, and its button only stops the query. DuckDB always rolls it back: definite,
  /// with the discard button. Neither says the connection is closed or reset, or that a server
  /// stops the statement (both run in the app).
  @Test(
    "SQLite and DuckDB: the prompt says the statement is stopped, not the connection closed",
    .timeLimit(.minutes(1)), arguments: [DatabaseType.sqlite, .duckdb])
  @MainActor
  func interruptPromptNeverSaysClosed(type: DatabaseType) async throws {
    // Nothing open: the editor Run button asks with the in-process interrupt wording
    let idle = try await cancelPrompts(type: type, staged: false, alwaysConfirm: true)
    #expect(idle == [.inProcessInterrupt])
    #expect(!QueryCancelWarning.inProcessInterrupt.detail.contains("server"))
    #expect(QueryCancelWarning.inProcessInterrupt.buttonTitle == QueryCancelWarning.stopTitle)
    let pending = try await cancelPrompts(type: type, staged: true, alwaysConfirm: false)
    if type == .duckdb {
      #expect(pending.map(\.title) == ["Cancelling will roll back 1 pending change"])
      #expect(pending.map(\.buttonTitle) == [QueryCancelWarning.confirmTitle])
    } else {
      #expect(pending.map(\.title) == ["Cancelling may roll back 1 pending change"])
      #expect(pending.map(\.buttonTitle) == [QueryCancelWarning.stopTitle])
    }
  }

  @Test("Interrupt: SQLite may roll back the open transaction, DuckDB will; never closed")
  func interruptUserTransactionWording() throws {
    let sqlite = try #require(
      QueryCancelWarning.make(state: .idle, userTxOpen: true, interrupts: true))
    #expect(sqlite.title == "Cancelling may roll back the open transaction")
    #expect(sqlite.buttonTitle == QueryCancelWarning.stopTitle)
    let duckdb = try #require(
      QueryCancelWarning.make(
        state: .idle, userTxOpen: true, interrupts: true, interruptRollsBack: true))
    #expect(duckdb.title == "Cancelling will roll back the open transaction")
    #expect(duckdb.buttonTitle == QueryCancelWarning.confirmTitle)
    for warning in [sqlite, duckdb] {
      #expect(!warning.detail.contains("closed"))
      #expect(!warning.detail.contains("reset"))
      #expect(!warning.detail.contains("server"))
    }
    // The connection is closed: the rollback is certain
    let reset = try #require(QueryCancelWarning.make(state: .idle, userTxOpen: true))
    #expect(reset.buttonTitle == QueryCancelWarning.confirmTitle)
  }

  /// The prompts the ViewModel shows (answered Keep running) for a slow read on a fake `type`
  /// connection in Protected mode, with one pending change when `staged`
  @MainActor
  private func cancelPrompts(
    type: DatabaseType, staged: Bool, alwaysConfirm: Bool
  ) async throws -> [QueryCancelWarning] {
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(cancelStrategy: type.capabilities.cancelStrategy),
      slowQueries: true)
    let connection = DatabaseConnectionManager(sessionFactory: factory)
    // In-memory and read-only: no file grant for SQLite / DuckDB
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: DuckDBSession.inMemoryPath,
        username: "u", password: "p", sslMode: .disable, safeMode: .silent, protectedMode: true,
        readOnlyFile: true))
    let session = try #require(factory.sessions.first)
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    if staged {
      _ = try await connection.execute(userSQL: "UPDATE t SET a = 1", policy: protected)
    }
    // A function call: never a cursor read, so the fake's slow query runs
    let running = Task {
      try await connection.execute(userSQL: "SELECT pg_sleep(30)", policy: protected)
    }
    await session.waitUntilQueryStarted()
    let viewModel = NotebookViewModel()
    viewModel.connectionManager = connection
    var warnings: [QueryCancelWarning] = []
    viewModel.cancelQueryPrompt = { warning in
      warnings.append(warning)
      return false
    }
    #expect(
      await viewModel.cancelRunningStatement(cancelQueue: false, alwaysConfirm: alwaysConfirm)
        == false)
    await session.interrupt()
    _ = try? await running.value
    await connection.disconnect()
    return warnings
  }

  @Test("Pending app transaction: warns with the count and the itemized review text")
  func pendingChangesWarn() {
    let pending = [
      summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1),
      summary("DELETE FROM t WHERE id = 2", rows: 1),
    ]
    let warning = QueryCancelWarning.make(state: .appTx(pending: pending), userTxOpen: false)
    #expect(warning?.title == "Cancelling will roll back 2 pending changes")
    #expect(warning?.detail.contains("UPDATE t SET v = 1 WHERE id = 1") == true)
    #expect(warning?.detail.contains("DELETE FROM t WHERE id = 2") == true)
  }

  @Test("Aborted app transaction also warns (its changes are discarded)")
  func abortedWarns() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    let warning = QueryCancelWarning.make(
      state: .aborted(reason: "boom", pending: pending), userTxOpen: false)
    #expect(warning?.title == "Cancelling will roll back 1 pending change")
  }

  @Test("Another tab's pending app transaction: named as that tab's changes")
  func anotherTabsPendingChanges() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    let warning = QueryCancelWarning.make(
      state: .appTx(pending: pending), userTxOpen: false, ownedByAnotherTab: true)
    #expect(warning?.title == "Cancelling will roll back another tab's 1 pending change")
    #expect(warning?.detail.contains("UPDATE t SET v = 1 WHERE id = 1") == true)
  }

  // Any tab may have sent the BEGIN: never "your" transaction
  @Test("User transaction open (Protected off): warns that it will be rolled back")
  func userTransactionWarns() {
    let warning = QueryCancelWarning.make(state: .idle, userTxOpen: true)
    #expect(warning?.title == "Cancelling will roll back the open transaction")
    #expect(warning?.title.contains("your") == false)
    #expect(warning?.detail.contains("this tab or another tab") == true)
  }
}
