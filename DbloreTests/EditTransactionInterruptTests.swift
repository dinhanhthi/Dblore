// EditTransactionInterruptTests.swift
// An inline edit or a staged batch cancelled inside a transaction (opened with BEGIN, or the
// pending Protected mode transaction): SQLite rolls the whole transaction back when the
// interrupted UPDATE was writing. The manager state and the cancel message follow what SQLite
// reports, as for a typed statement. A trigger makes the UPDATE run long enough to cancel. Real
// SQLite file in the temporary folder, no server.

import Foundation
import Testing

@testable import Dblore

@Suite("Inline edit interrupted inside a transaction", .serialized)
struct EditTransactionInterruptTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

  @Test(
    "An interrupted edit or batch inside a transaction reports the rollback, none left open",
    arguments: [false, true], [false, true])
  func interruptedEditEndsTransaction(protectedMode: Bool, staged: Bool) async throws {
    let policy = protectedMode ? protected : open
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-edit-interrupt-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    let connection = DatabaseConnectionManager()
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: false, statementTimeoutSeconds: 30))
    for sql in [
      "CREATE TABLE t (x INTEGER)",
      "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)",
      "INSERT INTO items VALUES (1, 'a')",
      """
      CREATE TRIGGER slow AFTER UPDATE ON items BEGIN
        INSERT INTO t WITH RECURSIVE c(x) AS
          (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 1000000000) SELECT x FROM c;
      END
      """,
    ] {
      _ = try await connection.execute(userSQL: sql, policy: open)
    }
    let table = try #require(
      try await connection.fetchEditTable(
        tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
    let edit = try CellUpdateStatement.make(
      qualifiedName: table.qualifiedName, columnName: "label", newValue: "x",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)], dialect: .sqlite)
    // A user transaction, or a pending Protected mode change, holding one row of `t`
    if !protectedMode { _ = try await connection.execute(userSQL: "BEGIN", policy: open) }
    _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: policy)
    #expect(await connection.runningStatementStatus().userTxOpen == !protectedMode)
    #expect(await connection.transactionSnapshot().pending.count == (protectedMode ? 1 : 0))

    let running = Task {
      if staged {
        _ = try await connection.executeGatedBatch(
          [BoundStatement(sql: "UPDATE items SET label = ?1 WHERE id = ?2", values: ["x", "1"])],
          policy: policy, connectionEpoch: table.connectionEpoch)
      } else {
        _ = try await connection.executeGatedUpdate(
          edit, policy: policy, connectionEpoch: table.connectionEpoch)
      }
    }
    var status = await connection.runningStatementStatus()
    while !status.inFlight {
      try await Task.sleep(for: .milliseconds(10))
      status = await connection.runningStatementStatus()
    }
    try await Task.sleep(for: .milliseconds(300))
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let error = try #require(await #expect(throws: DatabaseError.self) { try await running.value })
    guard case .queryCancelled(let pendingCount, let rolledBack, let kept) = error else {
      Issue.record("Expected queryCancelled, got \(error)")
      return
    }
    #expect(pendingCount == (protectedMode ? 1 : 0))
    #expect(rolledBack == !protectedMode)
    #expect(kept)
    #expect(await connection.runningStatementStatus().userTxOpen == false)
    #expect(await connection.transactionSnapshot().isIdle)
    // The edit and the row inserted before it went with the transaction
    let label = try await connection.execute(
      userSQL: "SELECT label FROM items WHERE id = 1", policy: open)
    #expect(label.rows == [[.string("a")]])
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }
}
