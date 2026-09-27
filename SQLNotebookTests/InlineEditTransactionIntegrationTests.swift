// InlineEditTransactionIntegrationTests.swift
// Inline grid edit inside transactions (P6) against the docker test database (TEST_DB_* env,
// port 5435 in autopilot): Protected ON joins/opens the app transaction and undoes a change
// that did not hit exactly one row with a savepoint; Protected OFF runs the edit in its own
// BEGIN ... COMMIT (ROLLBACK when rows != 1) or inside the user's open transaction; results
// read inside a pending transaction stay editable through the pre-transaction edit table cache.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Inline Edit Transaction - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct InlineEditTransactionIntegrationTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func config(protectedMode: Bool) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      protectedMode: protectedMode
    )
  }

  /// Creates `table (id int PRIMARY KEY, v int)` with rows (1, 10), (2, 20) through an
  /// unprotected observer, runs `body` with a manager (Protected per `protectedMode`) and always
  /// cleans up (a thrown error is recorded).
  private func withTable(
    _ table: String, protectedMode: Bool,
    _ body: (DatabaseConnectionManager, DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10), (2, 20)")
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config(protectedMode: protectedMode))
    do {
      try await body(manager, observer)
    } catch {
      Issue.record(error)
    }
    try? await manager.rollbackAppTransaction()
    await manager.disconnect()
    _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    await observer.disconnect()
  }

  private func value(
    _ manager: DatabaseConnectionManager, _ table: String, id: Int = 1
  ) async throws -> CellValue? {
    try await manager.executeInternal("SELECT v FROM \(table) WHERE id = \(id)").rows.first?.first
  }

  private func edit(
    _ manager: DatabaseConnectionManager, _ table: String, id: Int, to newValue: String
  ) async throws -> Int {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.\(table)", columnName: "v", newValue: newValue,
      primaryKeyColumns: ["id"], rowData: ["id": .int(id)], updateOnly: true)
    return try await manager.executeGatedUpdate(
      statement, policy: open, connectionEpoch: await manager.connectionEpoch)
  }

  /// The edit must fail with the "expected 1 row" error
  private func expectRowCountError(
    _ manager: DatabaseConnectionManager, _ table: String, id: Int, to newValue: String
  ) async {
    let error = await #expect(throws: DatabaseError.self) {
      _ = try await edit(manager, table, id: id, to: newValue)
    }
    #expect(error?.localizedDescription.contains("Expected to update 1 row, updated 0") == true)
  }

  private func target(
    _ query: String, _ manager: DatabaseConnectionManager
  ) async throws -> EditTarget? {
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(userSQL: query, policy: open)
    return await NotebookViewModel().editTarget(
      for: query, result: result, connectionManager: manager, epoch: epoch)
  }

  /// Commit what the manager currently reports as pending (the reviewed generation)
  private func commit(_ manager: DatabaseConnectionManager) async throws {
    try await manager.commitAppTransaction(
      expectedGeneration: await manager.transactionStatus().generation)
  }

  private func isAppTx(_ manager: DatabaseConnectionManager) async -> Bool {
    if case .appTx = await manager.transactionSnapshot() { return true }
    return false
  }

  // MARK: - Protected ON

  @Test("Protected ON: edit is pending with 1 row, Rollback restores", .timeLimit(.minutes(1)))
  func protectedEditPendingThenRollback() async throws {
    let table = "p6_on_rollback"
    try await withTable(table, protectedMode: true) { manager, observer in
      #expect(try await edit(manager, table, id: 1, to: "11") == 1)
      let pending = await manager.transactionSnapshot().pending
      #expect(pending.count == 1)
      #expect(pending.first?.affectedRows == 1)
      #expect(try await value(observer, table) == .int(10))
      try await manager.rollbackAppTransaction()
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(try await value(observer, table) == .int(10))
    }
  }

  @Test(
    "Protected ON: edit of a row deleted by another session is undone, pending intact",
    .timeLimit(.minutes(1)))
  func protectedEditZeroRowsKeepsTransaction() async throws {
    let table = "p6_on_zero"
    try await withTable(table, protectedMode: true) { manager, observer in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)
      _ = try await observer.executeInternal("DELETE FROM \(table) WHERE id = 2")

      await expectRowCountError(manager, table, id: 2, to: "21")
      #expect(await isAppTx(manager))
      let pending = await manager.transactionSnapshot().pending
      #expect(pending.count == 1)
      #expect(pending.first?.kindLabel == "UPDATE")
      // Not aborted on the server: reads and Commit still work
      #expect(try await value(manager, table) == .int(11))
      try await commit(manager)
      #expect(try await value(observer, table) == .int(11))
    }
  }

  @Test(
    "Protected ON: first edit hitting 0 rows rolls back its own transaction",
    .timeLimit(.minutes(1)))
  func protectedFirstEditZeroRowsBackToIdle() async throws {
    let table = "p6_on_zero_first"
    try await withTable(table, protectedMode: true) { manager, _ in
      await expectRowCountError(manager, table, id: 99, to: "1")
      #expect(await manager.transactionSnapshot().isIdle)
    }
  }

  @Test(
    "Protected ON: failing edit inside a pending transaction does not abort it",
    .timeLimit(.minutes(1)))
  func protectedFailingEditKeepsTransaction() async throws {
    let table = "p6_on_fail"
    try await withTable(table, protectedMode: true) { manager, observer in
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)
      await #expect(throws: DatabaseError.self) {
        _ = try await edit(manager, table, id: 2, to: "not a number")
      }
      #expect(await isAppTx(manager))
      #expect(await manager.transactionSnapshot().pending.count == 1)
      try await commit(manager)
      #expect(try await value(observer, table) == .int(11))
    }
  }

  @Test(
    "Protected ON: result read inside the transaction stays editable until DDL",
    .timeLimit(.minutes(1)))
  func protectedCachedEditTable() async throws {
    let table = "p6_on_cache"
    try await withTable(table, protectedMode: true) { manager, observer in
      let before = try #require(try await target("SELECT * FROM \(table)", manager))
      #expect(before.primaryKeyColumns == ["id"])
      #expect(try await edit(manager, table, id: 1, to: "11") == 1)

      let inside = try #require(try await target("SELECT * FROM \(table)", manager))
      #expect(inside.qualifiedName == "public.\(table)")
      #expect(inside.oid == before.oid)
      #expect(try await edit(manager, table, id: 2, to: "21") == 1)
      #expect(await manager.transactionSnapshot().pending.count == 2)

      _ = try await manager.execute(
        userSQL: "ALTER TABLE \(table) ADD COLUMN w int", policy: open)
      #expect(try await target("SELECT id, v FROM \(table)", manager) == nil)
      #expect(await isAppTx(manager))

      try await manager.rollbackAppTransaction()
      #expect(try await value(observer, table, id: 2) == .int(20))
      #expect(try await target("SELECT * FROM \(table)", manager) != nil)
    }
  }

  @Test(
    "Protected ON: edit as the first gated action adopts the user's open transaction",
    .timeLimit(.minutes(1)))
  func protectedEditAdoptsUserTransaction() async throws {
    let table = "p6_on_adopt"
    try await withTable(table, protectedMode: false) { manager, observer in
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)
      await manager.updateConnectedProtection(from: Self.config(protectedMode: true))

      #expect(try await edit(manager, table, id: 2, to: "21") == 1)
      #expect(!(await manager.userTxOpen))
      #expect(await isAppTx(manager))
      // The adopted transaction's earlier contents (synthetic entry), then the edit
      let pending = await manager.transactionSnapshot().pending
      #expect(pending.map(\.isEarlierChanges) == [true, false])
      #expect(try await value(observer, table) == .int(10))

      try await commit(manager)
      #expect(try await value(observer, table) == .int(11))
      #expect(try await value(observer, table, id: 2) == .int(21))
    }
  }

  // MARK: - Protected OFF

  @Test("Protected OFF: edit is committed immediately", .timeLimit(.minutes(1)))
  func unprotectedEditCommits() async throws {
    let table = "p6_off_commit"
    try await withTable(table, protectedMode: false) { manager, observer in
      let rows = try await edit(manager, table, id: 1, to: "11")
      #expect(rows == 1)
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(!(await manager.userTxOpen))
      #expect(try await value(observer, table) == .int(11))
    }
  }

  @Test("Protected OFF: edit hitting 0 rows is rolled back with an error", .timeLimit(.minutes(1)))
  func unprotectedEditZeroRowsRollsBack() async throws {
    let table = "p6_off_zero"
    try await withTable(table, protectedMode: false) { manager, observer in
      _ = try await observer.executeInternal("DELETE FROM \(table) WHERE id = 2")
      await expectRowCountError(manager, table, id: 2, to: "21")
      #expect(await manager.transactionSnapshot().isIdle)
      // No transaction left open: a later statement autocommits
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 12 WHERE id = 1", policy: open)
      #expect(try await value(observer, table) == .int(12))
    }
  }

  @Test(
    "Protected OFF with a user transaction: edit runs inside it, never commits it",
    .timeLimit(.minutes(1)))
  func unprotectedEditInsideUserTransaction() async throws {
    let table = "p6_off_user_tx"
    try await withTable(table, protectedMode: false) { manager, observer in
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)

      #expect(try await edit(manager, table, id: 2, to: "21") == 1)
      #expect(await manager.userTxOpen)
      // An app BEGIN ... COMMIT would have committed the user's transaction
      #expect(try await value(observer, table) == .int(10))
      #expect(try await value(observer, table, id: 2) == .int(20))

      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
      #expect(try await value(observer, table, id: 2) == .int(20))
    }
  }

  @Test(
    "Protected OFF: after COMMIT AND CHAIN the edit runs in the chained transaction",
    .timeLimit(.minutes(1)))
  func unprotectedEditAfterCommitAndChain() async throws {
    let table = "p3_off_and_chain"
    try await withTable(table, protectedMode: false) { manager, observer in
      _ = try await manager.execute(
        userSQL:
          "BEGIN; UPDATE \(table) SET v = 11 WHERE id = 1; COMMIT AND CHAIN; "
          + "UPDATE \(table) SET v = 12 WHERE id = 1",
        policy: open)
      #expect(await manager.userTxOpen)
      #expect(try await value(observer, table) == .int(11))

      #expect(try await edit(manager, table, id: 2, to: "21") == 1)
      #expect(await manager.userTxOpen)
      // An app BEGIN ... COMMIT would have committed the chained transaction
      #expect(try await value(observer, table) == .int(11))
      #expect(try await value(observer, table, id: 2) == .int(20))

      _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
      #expect(!(await manager.userTxOpen))
      #expect(try await value(observer, table) == .int(11))
      #expect(try await value(observer, table, id: 2) == .int(20))
    }
  }

  @Test(
    "Protected OFF with a user transaction: 0 rows → error, the user's transaction is kept",
    .timeLimit(.minutes(1)))
  func unprotectedEditZeroRowsKeepsUserTransaction() async throws {
    let table = "p6_off_user_zero"
    try await withTable(table, protectedMode: false) { manager, observer in
      _ = try await manager.execute(userSQL: "BEGIN", policy: open)
      _ = try await manager.execute(
        userSQL: "UPDATE \(table) SET v = 11 WHERE id = 1", policy: open)

      await expectRowCountError(manager, table, id: 99, to: "1")
      #expect(await manager.userTxOpen)
      #expect(try await value(manager, table) == .int(11))
      #expect(try await value(observer, table) == .int(10))

      _ = try await manager.execute(userSQL: "COMMIT", policy: open)
      #expect(try await value(observer, table) == .int(11))
    }
  }
}
