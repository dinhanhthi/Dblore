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
