// SchemaChangeConfirmation.swift
// The Safe Mode step and the gated send shared by the schema editors that build their own DDL
// (types editor, diagram editor). The step follows the connection's resolved commit style, read
// when the user applies: Confirm and Password list the statements (the sheet's
// `SafeModeConfirmationPanel`; Password verifies the password or Touch ID there) and nothing is
// sent until the sheet confirms; Immediate asks nothing; Review asks nothing either, and the
// change joins the Protected mode transaction, pending until Commit. Statements that must run
// outside a transaction go first through `executeGatedSequentialCommands` (one by one, each
// committing; refused while a transaction is open or Protected mode applies), the rest as one
// `executeGatedSchemaChange`. Both gates re-check every refusal. Each send is one History row
// (source `.structure`); a sequential step that stopped part way is two (committed, failed).

import Foundation
import Observation

/// The connection, rules and history sink of the tab a schema editor was opened from
struct SchemaChangeContext {
  var manager: DatabaseConnectionManager
  var databaseType: DatabaseType
  var policy: ProtectionPolicy
  /// Read at Apply, so a commit style changed while the editor is open counts
  var commitStyle: @MainActor () -> CommitStyle
  /// The tab's caller token, so the change joins that tab's Protected mode transaction
  var caller: UUID?
  /// Records outcomes in History as `.structure` (the tab honours the History setting)
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void
}

extension SchemaChangeContext {
  /// `tab`'s connection, rules and History. Nil when the tab is not connected.
  init?(tab: NotebookViewModel) {
    guard let manager = tab.connectionManager, let config = tab.notebook.connectionConfig else {
      return nil
    }
    self.init(
      manager: manager, databaseType: config.databaseType, policy: tab.protectionPolicy,
      commitStyle: { [weak tab] in
        (tab?.notebook.connectionConfig ?? config)
          .resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
      },
      caller: tab.id,
      recordHistory: { [weak tab] in await tab?.recordExecution($0, source: .structure) })
  }
}

/// The sequential step went through, then the batch failed: those statements stay applied
nonisolated struct SchemaChangePartialFailure: Error, LocalizedError, Equatable {
  /// Statements of the sequential step (committed one by one)
  let applied: Int
  let total: Int
  let reason: String

  var errorDescription: String? {
    "Applied \(applied) of \(total) changes, which run one by one and stay; the rest failed: "
      + reason
  }
}

@MainActor
@Observable
final class SchemaChangeConfirmation {
  /// What one apply sends
  nonisolated struct Plan: Sendable, Equatable {
    /// Run first, one by one outside any transaction
    var sequential: [String] = []
    /// Then one gated schema change
    var batch: [String] = []

    var all: [String] { sequential + batch }
  }

  /// The statements Safe Mode lists while it waits for the user
  private(set) var pendingConfirmation: [StatementConfirmation]?
  private(set) var requiresPassword = false

  @ObservationIgnored let context: SchemaChangeContext
  @ObservationIgnored private var confirmedPlan: Plan?

  init(context: SchemaChangeContext) {
    self.context = context
  }

  /// Arms the Safe Mode step for `plan` when the commit style confirms writes. True when it
  /// asks: nothing may be sent until `takeConfirmed()` hands the plan back.
  func ask(_ plan: Plan) -> Bool {
    let dialect = context.databaseType.dialect
    let commitStyle = context.commitStyle()
    let classified = plan.all.flatMap { SQLStatementClassifier.classify($0, dialect: dialect) }
    guard
      let listed = NotebookViewModel.statementsNeedingConfirmation(
        classified, commitStyle: commitStyle, dialect: dialect)
    else { return false }
    confirmedPlan = plan
    requiresPassword = commitStyle.requiresPassword
    pendingConfirmation = listed
    return true
  }

  /// The plan Safe Mode showed, once the user confirmed it; clears the step
  func takeConfirmed() -> Plan? {
    let plan = pendingConfirmation == nil ? nil : confirmedPlan
    cancel()
    return plan
  }

  func cancel() {
    pendingConfirmation = nil
    confirmedPlan = nil
    requiresPassword = false
  }

  /// Sends `plan` through the gates. A refusal or failure of the sequential step throws as is
  /// (nothing of the batch is sent); a batch failure after it throws
  /// `SchemaChangePartialFailure`. The result covers every statement sent.
  func send(_ plan: Plan, connectionEpoch: UInt64) async throws -> SchemaChangeResult {
    let started = Date()
    if !plan.sequential.isEmpty {
      try await recorded(plan.sequential) {
        _ = try await context.manager.executeGatedSequentialCommands(
          plan.sequential, policy: context.policy, connectionEpoch: connectionEpoch,
          caller: context.caller, expectedRows: nil)
      }
    }
    guard !plan.batch.isEmpty else {
      return SchemaChangeResult(
        statements: plan.all, pending: false, insideUserTransaction: false,
        duration: Date().timeIntervalSince(started))
    }
    do {
      let result = try await recorded(plan.batch) {
        try await context.manager.executeGatedSchemaChange(
          plan.batch, policy: context.policy, connectionEpoch: connectionEpoch,
          caller: context.caller)
      }
      return SchemaChangeResult(
        statements: plan.all, pending: result.pending,
        insideUserTransaction: result.insideUserTransaction,
        duration: Date().timeIntervalSince(started))
    } catch let error where !plan.sequential.isEmpty {
      throw SchemaChangePartialFailure(
        applied: plan.sequential.count, total: plan.all.count,
        reason: error.localizedDescription)
    }
  }

  /// Runs `send` and records one History row for `statements`. When the sequential step
  /// stopped after some statements committed, those get their own success row.
  private func recorded<T>(
    _ statements: [String], _ send: () async throws -> T
  ) async throws -> T {
    let started = Date()
    func outcome(_ part: ArraySlice<String>, error: (any Error)?) -> QueryHistoryOutcome {
      QueryHistoryOutcome(
        sql: part.joined(separator: ";\n"), duration: Date().timeIntervalSince(started),
        rowCount: nil, status: error == nil ? .success : .error,
        errorMessage: error?.localizedDescription)
    }
    do {
      let value = try await send()
      await context.recordHistory([outcome(statements[...], error: nil)])
      return value
    } catch {
      if case DatabaseError.batchPartiallyApplied(let applied, _, _, _) = error,
        applied > 0, applied < statements.count
      {
        await context.recordHistory([
          outcome(statements.prefix(applied), error: nil),
          outcome(statements.dropFirst(applied), error: error),
        ])
      } else {
        await context.recordHistory([outcome(statements[...], error: error)])
      }
      throw error
    }
  }
}
