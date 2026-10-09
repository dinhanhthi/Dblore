// ExplainRequestGateTests.swift
// EXPLAIN text goes through the same protection gate and Safe Mode confirmation as a normal run.

import Foundation
import Testing

@testable import Dblore

@Suite("Explain request gate")
@MainActor
struct ExplainRequestGateTests {
  private let update = "  UPDATE t SET a = 1; "
  private let analyzedUpdate =
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) UPDATE t SET a = 1"
  private let wrappedUpdate =
    "BEGIN; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) UPDATE t SET a = 1; ROLLBACK;"

  @Test("Read-only blocks EXPLAIN ANALYZE UPDATE and allows EXPLAIN SELECT")
  func readOnlyPolicy() async throws {
    let analyzeUpdate = try ExplainRequest(statement: update, analyze: true, buffers: true)
    let plainSelect = try ExplainRequest(
      statement: "SELECT * FROM t", analyze: false, buffers: false)
    let blocked = viewModel(protection: .readOnly, safeMode: .alertRead, protectedMode: true)
    #expect(blocked.protectionBlockMessage(for: analyzeUpdate.sql) != nil)
    #expect(blocked.protectionBlockMessage(for: plainSelect.sql) == nil)

    await blocked.explain(statement: update, analyze: true, buffers: true)
    #expect(blocked.queryConfirmationState.showDialog == false)
  }

  @Test("Safe Mode prompts for ANALYZE of DML and not for a plain EXPLAIN of a SELECT")
  func safeModeConfirmation() async throws {
    let writing = viewModel(protection: .none, safeMode: .alertRead, protectedMode: false)
    await writing.explain(statement: update, analyze: true, buffers: true)
    #expect(writing.queryConfirmationState.showDialog)
    #expect(writing.queryConfirmationState.pendingQuery == wrappedUpdate)

    let reading = viewModel(protection: .none, safeMode: .alertRead, protectedMode: false)
    await reading.explain(statement: "SELECT * FROM t", analyze: false, buffers: false)
    #expect(reading.queryConfirmationState.showDialog == false)
  }

  @Test("Rollback wrapper is BEGIN … ROLLBACK only when analyze of DML should roll back")
  func rollbackWrapper() throws {
    let wrapped = try ExplainRequest(statement: update, analyze: true, buffers: true)
    #expect(wrapped.wrappedSQL == wrappedUpdate)
    #expect(wrapped.sql == analyzedUpdate)

    let bare = try ExplainRequest(
      statement: update, analyze: true, buffers: true, rollbackAfterAnalyze: false)
    #expect(bare.wrappedSQL == analyzedUpdate)
    #expect(
      wrapped.sqlToRun(protectedTransactionOpen: true) == analyzedUpdate)

    let select = try ExplainRequest(statement: "SELECT 1", analyze: true, buffers: true)
    #expect(select.wrappedSQL == "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT 1")
  }

  @Test("Multi-statement input and a statement that already starts with EXPLAIN throw")
  func rejectsMultipleStatementsAndExistingExplain() {
    #expect(throws: ExplainRequestError.multipleStatements) {
      try ExplainRequest(
        statement: "UPDATE t SET a = 1; DELETE FROM t", analyze: true, buffers: true)
    }
    #expect(throws: ExplainRequestError.alreadyExplain) {
      try ExplainRequest(statement: "  -- note\nEXPLAIN SELECT 1", analyze: false, buffers: false)
    }
  }

  private func viewModel(
    protection: ConnectionProtectionLevel, safeMode: SafeMode, protectedMode: Bool
  ) -> NotebookViewModel {
    NotebookViewModel(
      notebook: DbloreNotebook(
        connectionConfig: ConnectionConfig(
          protectionLevel: protection, safeMode: safeMode, protectedMode: protectedMode)))
  }
}
