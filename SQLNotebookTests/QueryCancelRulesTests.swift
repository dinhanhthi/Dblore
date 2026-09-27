// QueryCancelRulesTests.swift
// C3: cancelling a running query closes the connection, so the ViewModel first warns when that
// discards pending Protected changes or the user's open transaction (pure rule).

import Foundation
import Testing

@testable import SQLNotebook

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

  @Test("One pending change: singular title")
  func onePendingChange() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    let warning = QueryCancelWarning.make(state: .appTx(pending: pending), userTxOpen: false)
    #expect(warning?.title == "Cancelling will roll back 1 pending change")
  }

  @Test("Aborted app transaction also warns (its changes are discarded)")
  func abortedWarns() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    let warning = QueryCancelWarning.make(
      state: .aborted(reason: "boom", pending: pending), userTxOpen: false)
    #expect(warning?.title == "Cancelling will roll back 1 pending change")
  }

  @Test("User transaction open (Protected off): warns that it will be rolled back")
  func userTransactionWarns() {
    let warning = QueryCancelWarning.make(state: .idle, userTxOpen: true)
    #expect(warning?.title == "Cancelling will roll back your open transaction")
    #expect(warning?.detail.isEmpty == false)
  }

  @Test("Button titles")
  func buttonTitles() {
    #expect(QueryCancelWarning.confirmTitle == "Cancel query & discard")
    #expect(QueryCancelWarning.keepTitle == "Keep running")
  }
}
