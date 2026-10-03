// StagedBatchRulesTests.swift
// Pure gate for a staged row batch: the whole batch is rejected before send if any
// statement violates the protection policy. No database needed.

import Foundation
import Testing

@testable import Dblore

private func batchDecision(
  _ statements: [BoundStatement], _ policy: ProtectionPolicy
) -> GateDecision {
  DatabaseConnectionManager.evaluateBatch(statements, policy: policy)
}

@Suite("Staged batch - rules")
struct StagedBatchRulesTests {

  @Test("Staged statements expect one row unless explicitly overridden")
  func expectedRowsDefault() {
    #expect(BoundStatement(sql: "DELETE FROM t", values: []).expectedRows == 1)
    #expect(
      BoundStatement(sql: "CREATE TABLE t (x int)", values: [], expectedRows: nil).expectedRows
        == nil)
  }

  @Test("Batch accepts a zero-row CREATE and checks multi-row INSERT counts")
  @MainActor
  func expectedRowsApplied() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-batch-count-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let manager = DatabaseConnectionManager()
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
    let epoch = await manager.connectionEpoch

    let counts = try await manager.executeGatedBatch(
      [
        BoundStatement(sql: "CREATE TABLE t (v TEXT)", values: [], expectedRows: nil),
        BoundStatement(
          sql: "INSERT INTO t (v) VALUES (?1), (?2)", values: ["a", "b"], expectedRows: 2),
        BoundStatement(sql: "CREATE TABLE u (v TEXT)", values: [], expectedRows: nil),
      ], policy: policy, connectionEpoch: epoch)
    #expect(counts == [0, 2, 0])

    let booleanColumns = [ImportSQLBuilder.Column(name: "flag", kind: .boolean)]
    let booleanCreate = try ImportSQLBuilder.createTable(
      schema: nil, table: "booleans", columns: booleanColumns, dialect: .sqlite)
    let booleanInserts = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "booleans", columns: booleanColumns,
      rows: [["true"], ["false"]], dialect: .sqlite)
    let booleanCounts = try await manager.executeGatedBatch(
      [booleanCreate] + booleanInserts, policy: policy, connectionEpoch: epoch)
    #expect(booleanCounts == [0, 2])
    let stored = try await manager.execute(
      userSQL: "SELECT typeof(flag), flag FROM booleans ORDER BY rowid", policy: policy)
    #expect(stored.rows == [[.string("integer"), .int(1)], [.string("integer"), .int(0)]])

    do {
      _ = try await manager.executeGatedBatch(
        [
          BoundStatement(sql: "INSERT INTO t (v) VALUES (?1)", values: ["c"], expectedRows: 2)
        ], policy: policy, connectionEpoch: epoch)
      Issue.record("Expected the affected-row check to reject one inserted row")
    } catch DatabaseError.batchStatementFailed(let index, _, let reason, let rolledBack) {
      #expect(index == 0)
      #expect(reason.contains("expected to affect 2 rows, affected 1"))
      #expect(rolledBack)
    }
  }

  @Test("A later DELETE blocks the whole batch under read-only and names that statement")
  func readOnlyBlocksLaterDelete() {
    let decision = batchDecision(
      [
        BoundStatement(sql: "SELECT 1", values: []),
        BoundStatement(sql: "DELETE FROM t WHERE id = $1", values: ["1"]),
      ], ProtectionPolicy(protectionLevel: .readOnly))
    guard case .blocked(let index, let kind, let reason) = decision else {
      Issue.record("Expected the DELETE to block the batch")
      return
    }
    #expect(index == 1)
    #expect(kind == .dml)
    #expect(reason.contains("read-only"))
  }

  @Test("UPDATE is not allowed on a read-only connection")
  func updateIsNotReadOnly() {
    let decision = batchDecision(
      [BoundStatement(sql: "UPDATE t SET a = $1 WHERE id = $2", values: ["1", "2"])],
      ProtectionPolicy(protectionLevel: .readOnly))
    guard case .blocked(let index, let kind, _) = decision else {
      Issue.record("Expected the UPDATE to be blocked")
      return
    }
    #expect(index == 0)
    #expect(kind == .dml)
  }

  @Test("Ordinary writes are allowed when protection is off")
  func noneAllowsWrites() {
    let decision = batchDecision(
      [
        BoundStatement(sql: "DELETE FROM t WHERE id = $1", values: ["1"]),
        BoundStatement(sql: "UPDATE t SET a = $1 WHERE id = $2", values: ["x", "1"]),
        BoundStatement(sql: "INSERT INTO t (a) VALUES ($1)", values: ["y"]),
      ], ProtectionPolicy(protectionLevel: .none))
    #expect(decision == .allowed)
  }

  @Test("A batch failure names the statement by index and SQL prefix")
  func batchFailureNamesTheStatement() {
    let rolledBack = DatabaseError.batchStatementFailed(
      index: 1, sqlPrefix: "DELETE FROM t WHERE id = $1",
      reason: "expected to affect 1 row, affected 0", rolledBack: true)
    let text = rolledBack.localizedDescription
    #expect(text.contains("statement 2"))
    #expect(text.contains("DELETE FROM t WHERE id = $1"))
    #expect(text.contains("rolled back"))

    let kept = DatabaseError.batchStatementFailed(
      index: 0, sqlPrefix: "UPDATE t SET a = $1",
      reason: "expected to affect 1 row, affected 3", rolledBack: false)
    #expect(kept.localizedDescription.contains("statement 1"))
    #expect(kept.localizedDescription.contains("UPDATE t SET a = $1"))
    #expect(kept.localizedDescription.contains("open transaction"))
  }

  @Test("The actor rejects a blocked batch before it needs a connection")
  func actorRejectsBlockedBatch() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeGatedBatch(
        [
          BoundStatement(sql: "SELECT 1", values: []),
          BoundStatement(sql: "DELETE FROM t WHERE id = $1", values: ["1"]),
        ], policy: ProtectionPolicy(protectionLevel: .readOnly), connectionEpoch: 0)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, _) {
      #expect(index == 1)
      #expect(kind == .dml)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("An empty batch returns no row counts")
  func emptyBatchReturnsNothing() async throws {
    let manager = DatabaseConnectionManager()
    let rows = try await manager.executeGatedBatch(
      [], policy: ProtectionPolicy(protectionLevel: .readOnly), connectionEpoch: 0)
    #expect(rows.isEmpty)
  }

  @Test("A batch the policy allows reaches the connection check")
  func allowedBatchReachesConnection() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeGatedBatch(
        [BoundStatement(sql: "UPDATE t SET a = $1 WHERE id = $2", values: ["1", "2"])],
        policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: 0)
      Issue.record("Expected notConnected")
    } catch DatabaseError.notConnected {
      // The gate allowed the batch; nothing is sent without a connection.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Epoch mismatch is refused before anything is sent")
  func epochMismatchRefusedFirst() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeGatedBatch(
        [BoundStatement(sql: "UPDATE t SET a = $1 WHERE id = $2", values: ["1", "2"])],
        policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: 1)
      Issue.record("Expected notEditable")
    } catch DatabaseError.notEditable(let reason) {
      #expect(reason.contains("connection changed"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
