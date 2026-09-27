// ProtectedTransactionRulesTests.swift
// Pure decisions of Protected mode (P1): which statements open / join the app transaction,
// which are refused by the gate, and how user transaction control is tracked when it is off.

import Foundation
import Testing

@testable import SQLNotebook

private func statement(_ sql: String) -> ClassifiedStatement {
  guard let classified = SQLStatementClassifier.classify(sql).first else {
    Issue.record("\(sql) classified to nothing")
    return ClassifiedStatement(
      text: sql, kind: .unknown, hasReturning: false, hasTopLevelReturning: false,
      affectsAllRows: false,
      nonTransactional: false, resetsSessionBrakes: false, changesPrivileges: false,
      createsTable: false)
  }
  return classified
}

private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
private let unprotected = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

private func decide(_ sql: String, _ policy: ProtectionPolicy) -> GateDecision {
  DatabaseConnectionManager.evaluate(SQLStatementClassifier.classify(sql), policy: policy)
}

@Suite("Protected Transaction - rules")
struct ProtectedTransactionRulesTests {

  // MARK: Statement actions

  @Test(
    "Writes open the app transaction when none is pending",
    arguments: [
      "UPDATE t SET a = 1 WHERE id = 1", "INSERT INTO t VALUES (1)", "DELETE FROM t WHERE id = 1",
      "CREATE TABLE t (id int)", "DROP TABLE t", "TRUNCATE t", "EXPLAIN ANALYZE DELETE FROM t",
      "DO $$ BEGIN PERFORM 1; END $$", "CALL p()", "COPY t FROM STDIN", "FROBNICATE t",
      "SELECT 1 INTO new_table",
    ])
  func writesOpenTransaction(sql: String) {
    #expect(ProtectedTransactionRules.action(for: statement(sql), inTransaction: false) == .open)
    #expect(ProtectedTransactionRules.action(for: statement(sql), inTransaction: true) == .record)
  }

  @Test("Reads run as is, inside or outside the transaction", arguments: [false, true])
  func readsRunAsIs(inTransaction: Bool) {
    for sql in ["SELECT * FROM t", "SHOW search_path", "EXPLAIN DELETE FROM t", "VALUES (1)"] {
      #expect(
        ProtectedTransactionRules.action(for: statement(sql), inTransaction: inTransaction)
          == .run)
    }
  }

  @Test("Session SET does not open a transaction but is recorded inside one")
  func sessionSetRecordedOnlyInsideTransaction() {
    let set = statement("SET search_path TO public")
    #expect(ProtectedTransactionRules.action(for: set, inTransaction: false) == .run)
    #expect(ProtectedTransactionRules.action(for: set, inTransaction: true) == .record)
  }

  // MARK: Gate refusals under Protected mode

  @Test(
    "Protected mode blocks user transaction control",
    arguments: [
      "BEGIN", "START TRANSACTION", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT s",
      "RELEASE SAVEPOINT s", "ROLLBACK TO SAVEPOINT s", "PREPARE TRANSACTION 'x'",
    ])
  func protectedBlocksTransactionControl(sql: String) {
    guard case .blocked(0, .tcl, let reason) = decide(sql, protected) else {
      Issue.record("\(sql) should be blocked under Protected mode")
      return
    }
    #expect(reason.contains("Protected mode"))
    #expect(decide(sql, unprotected) == .allowed)
  }

  @Test(
    "Protected mode blocks statements that cannot run in a transaction",
    arguments: [
      "VACUUM t", "CREATE INDEX CONCURRENTLY i ON t (a)", "CREATE DATABASE d", "DROP DATABASE d",
      "ALTER SYSTEM SET work_mem = '4MB'", "REINDEX DATABASE d",
    ])
  func protectedBlocksNonTransactional(sql: String) {
    guard case .blocked(0, _, let reason) = decide(sql, protected) else {
      Issue.record("\(sql) should be blocked under Protected mode")
      return
    }
    #expect(reason.contains("Protected mode off"))
    #expect(decide(sql, unprotected) == .allowed)
  }

  @Test("A blocked statement anywhere in the cell blocks the whole cell")
  func blockedAnywhereBlocksCell() {
    guard case .blocked(1, .tcl, _) = decide("UPDATE t SET a = 1; COMMIT", protected) else {
      Issue.record("Expected COMMIT at index 1 to block the cell")
      return
    }
  }

  @Test("Protected mode allows writes, reads and session SET")
  func protectedAllowsOrdinaryStatements() {
    #expect(
      decide("SELECT 1; UPDATE t SET a = 1; SET search_path TO public", protected) == .allowed)
  }

  // MARK: userTxOpen tracking (Protected off)

  @Test("BEGIN / START open, COMMIT / END / ROLLBACK / ABORT close the user transaction")
  func userTransactionTracking() {
    let rules = ProtectedTransactionRules.self
    #expect(rules.userTxOpen(after: statement("BEGIN"), current: false, succeeded: true))
    #expect(
      rules.userTxOpen(after: statement("START TRANSACTION"), current: false, succeeded: true))
    for close in ["COMMIT", "END", "ROLLBACK", "ABORT", "PREPARE TRANSACTION 'x'"] {
      #expect(!rules.userTxOpen(after: statement(close), current: true, succeeded: true))
    }
  }

  @Test(
    "... AND CHAIN ends the transaction and opens a new one: still open",
    arguments: [
      "COMMIT AND CHAIN", "END AND CHAIN", "ROLLBACK AND CHAIN", "ABORT AND CHAIN",
      "commit work and chain", "ROLLBACK TRANSACTION AND CHAIN",
    ])
  func andChainKeepsTransactionOpen(sql: String) {
    let rules = ProtectedTransactionRules.self
    #expect(rules.userTxOpen(after: statement(sql), current: true, succeeded: true))
  }

  @Test(
    "... AND NO CHAIN closes the user transaction",
    arguments: [
      "COMMIT AND NO CHAIN", "END AND NO CHAIN", "ROLLBACK AND NO CHAIN", "ABORT AND NO CHAIN",
    ])
  func andNoChainClosesTransaction(sql: String) {
    let rules = ProtectedTransactionRules.self
    #expect(!rules.userTxOpen(after: statement(sql), current: true, succeeded: true))
  }

  @Test("A failed COMMIT AND CHAIN ends the transaction (no chained transaction is started)")
  func failedCommitAndChainCloses() {
    let rules = ProtectedTransactionRules.self
    #expect(
      !rules.userTxOpen(after: statement("COMMIT AND CHAIN"), current: true, succeeded: false))
  }

  @Test(
    "Protected mode blocks ... AND CHAIN transaction control",
    arguments: ["COMMIT AND CHAIN", "END AND CHAIN", "ROLLBACK AND CHAIN", "ABORT AND CHAIN"])
  func protectedBlocksAndChain(sql: String) {
    guard case .blocked(0, .tcl, _) = decide(sql, protected) else {
      Issue.record("\(sql) should be blocked under Protected mode")
      return
    }
  }

  @Test("Savepoints and non-TCL statements leave the user transaction as it is")
  func savepointsKeepTracking() {
    let rules = ProtectedTransactionRules.self
    for sql in [
      "ROLLBACK TO SAVEPOINT s", "ROLLBACK TO s", "SAVEPOINT s", "RELEASE s", "UPDATE t SET a = 1",
    ] {
      #expect(rules.userTxOpen(after: statement(sql), current: true, succeeded: true))
      #expect(!rules.userTxOpen(after: statement(sql), current: false, succeeded: true))
    }
  }

  @Test("A failed statement changes nothing, except a failed COMMIT which ends the transaction")
  func failedStatementTracking() {
    let rules = ProtectedTransactionRules.self
    #expect(!rules.userTxOpen(after: statement("BEGIN"), current: false, succeeded: false))
    #expect(rules.userTxOpen(after: statement("ROLLBACK TO s"), current: true, succeeded: false))
    #expect(
      rules.userTxOpen(after: statement("UPDATE t SET a = 1"), current: true, succeeded: false))
    #expect(!rules.userTxOpen(after: statement("COMMIT"), current: true, succeeded: false))
  }

  // MARK: Edit table cache (P6)

  @Test(
    "Schema-changing statements invalidate cached edit tables",
    arguments: [
      "ALTER TABLE t ADD COLUMN w int", "DROP TABLE t",
      "EXPLAIN ANALYZE CREATE TABLE x AS SELECT 1",
      "DO $$ BEGIN PERFORM 1; END $$", "FROBNICATE t",
    ])
  func schemaChangesInvalidateEditTables(sql: String) {
    #expect(ProtectedTransactionRules.invalidatesEditTables(statement(sql)))
  }

  @Test(
    "Reads, DML and SET keep cached edit tables",
    arguments: ["SELECT * FROM t", "UPDATE t SET a = 1 WHERE id = 1", "SET search_path = s"])
  func dataStatementsKeepEditTables(sql: String) {
    #expect(!ProtectedTransactionRules.invalidatesEditTables(statement(sql)))
  }

  // MARK: Summary and state

  @Test("StatementSummary keeps a collapsed, bounded preview and the first keyword as label")
  func statementSummaryPreview() {
    let long =
      "UPDATE t\n   SET a = 1\n WHERE " + String(repeating: "x = 1 AND ", count: 50) + "true"
    let summary = StatementSummary(statement: statement(long), affectedRows: 3)
    #expect(summary.kindLabel == "UPDATE")
    #expect(summary.affectedRows == 3)
    #expect(!summary.sqlPreview.contains("\n"))
    #expect(summary.sqlPreview.hasPrefix("UPDATE t SET a = 1 WHERE x = 1"))
    #expect(summary.sqlPreview.count <= StatementSummary.maxPreviewLength + 1)
  }

  @Test("Commit guard refuses while a gated statement runs or when the list changed")
  func commitGuardRefusal() {
    var commitGuard = CommitGuard()
    #expect(!commitGuard.refusesCommit(expectedGeneration: 0))
    commitGuard.generation = 3
    #expect(commitGuard.refusesCommit(expectedGeneration: 2))
    #expect(!commitGuard.refusesCommit(expectedGeneration: 3))
    commitGuard.inFlight = 1
    #expect(commitGuard.refusesCommit(expectedGeneration: 3))
    commitGuard.inFlight = 0
    #expect(!commitGuard.refusesCommit(expectedGeneration: 3))
  }

  @Test("TransactionState exposes the pending list of every state")
  func transactionStatePending() {
    let summary = StatementSummary(statement: statement("DELETE FROM t"), affectedRows: nil)
    #expect(TransactionState.idle.pending.isEmpty)
    #expect(TransactionState.idle.isIdle)
    #expect(TransactionState.appTx(pending: [summary]).pending == [summary])
    #expect(TransactionState.aborted(reason: "x", pending: [summary]).pending == [summary])
    #expect(!TransactionState.appTx(pending: []).isIdle)
  }

  // MARK: - Commit / Rollback in progress

  @Test("While COMMIT / ROLLBACK is awaited the state is ending: not idle, pending kept")
  func endingStateKeepsPending() {
    let summary = StatementSummary(statement: statement("DELETE FROM t"), affectedRows: 2)
    let committing = TransactionState.ending(kind: .commit, pending: [summary])
    #expect(!committing.isIdle)
    #expect(committing.pending == [summary])
    #expect(committing.endingKind == .commit)
    #expect(TransactionState.ending(kind: .rollback, pending: []).endingKind == .rollback)
    #expect(TransactionState.idle.endingKind == nil)
    #expect(TransactionState.appTx(pending: [summary]).endingKind == nil)
    #expect(TransactionState.aborted(reason: "x", pending: [summary]).endingKind == nil)
  }

  @Test("Rollback is refused while a gated statement runs (it would run after ROLLBACK)")
  func commitGuardRefusesRollbackInFlight() {
    var commitGuard = CommitGuard()
    #expect(!commitGuard.refusesRollback)
    commitGuard.inFlight = 1
    #expect(commitGuard.refusesRollback)
  }

  @Test("Gated entry during Commit / Rollback gets a typed 'in progress' error")
  func endingErrorDescription() {
    let commit = DatabaseError.transactionEnding(.commit).localizedDescription
    #expect(commit.contains("Commit in progress"))
    #expect(commit.contains("Nothing was executed"))
    let rollback = DatabaseError.transactionEnding(.rollback).localizedDescription
    #expect(rollback.contains("Rollback in progress"))
  }

  @Test("Banner and prompt while ending: 'Committing…' headline, disconnect (unknown) or Cancel")
  func endingBannerAndResolutions() {
    let summary = StatementSummary(statement: statement("DELETE FROM t"), affectedRows: 2)
    let committing = TransactionState.ending(kind: .commit, pending: [summary])
    let rollingBack = TransactionState.ending(kind: .rollback, pending: [summary])
    #expect(PendingTransactionSummary(state: committing).headline.hasPrefix("Committing"))
    #expect(PendingTransactionSummary(state: rollingBack).headline.hasPrefix("Rolling back"))
    #expect(PendingTransactionSummary(state: committing).ending == .commit)
    #expect(PendingTransactionSummary(state: .appTx(pending: [summary])).ending == nil)
    #expect(
      WorkspaceTransactionRules.resolutions(for: committing) == [
        .disconnectUnknownOutcome, .cancel,
      ])
    #expect(WorkspaceTransactionRules.resolutions(for: rollingBack) == [.disconnect, .cancel])
  }
}
