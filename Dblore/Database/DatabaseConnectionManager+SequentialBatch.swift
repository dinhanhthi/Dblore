// DatabaseConnectionManager+SequentialBatch.swift
// A batch sent one statement at a time in autocommit, with no BEGIN / COMMIT: MongoDB staged
// document edits (no transactions) and MySQL restore (`executeGatedRestore`). Gated like `executeGatedBatch`, but
// refused while a transaction is open or Protected mode applies, since it would skip both.

import Foundation

extension DatabaseConnectionManager {
  /// Send `statements` one by one, each committing on its own. Before anything is sent:
  /// `connectionEpoch` must still be `epoch` (`DatabaseError.notEditable`), `expectedRows` (when
  /// set) must have one count per statement, every statement must pass `evaluateBatch` against
  /// `effectivePolicy(for:)` (`DatabaseError.blockedByProtection`), another caller's pending
  /// app transaction is refused (`DatabaseError.transactionPendingInAnotherTab`), and an open
  /// app or user transaction, then Protected mode, are refused
  /// (`DatabaseError.sequentialBatchRefused`). An empty batch returns `[]`.
  /// The first send error or count other than `expectedRows[i]` stops the batch:
  /// `DatabaseError.batchPartiallyApplied` (the statements before it stay applied).
  /// Returns each statement's result (MongoDB updates also carry `modifiedRows`). `progress`
  /// gets the number of statements done after each one (SQL dump restore).
  func executeGatedSequentialCommands(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, expectedRows: [Int]?, progress: (@Sendable (Int) -> Void)? = nil
  ) async throws -> [CommandResult] {
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    if let expectedRows, expectedRows.count != statements.count {
      throw DatabaseError.sequentialBatchRefused(
        "Each change needs exactly one expected row count.")
    }
    let effective = effectivePolicy(for: policy)
    let bound = statements.map { BoundStatement(sql: $0, values: [], expectedRows: nil) }
    // Decision is pure and finishes before any await that could send anything.
    if case .blocked(let index, let kind, let reason) = Self.evaluateBatch(
      bound, policy: effective, dialect: Self.dialect(of: config))
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    if statements.isEmpty { return [] }
    try refuseIfOwnedByAnotherCaller(caller)
    // Checked before Protected mode: a pending app transaction always forces Protected mode.
    if !txState.isIdle || userTxOpen {
      throw DatabaseError.sequentialBatchRefused(Self.sequentialTransactionOpenRefusal)
    }
    if effective.protectedMode {
      throw DatabaseError.sequentialBatchRefused(
        "Turn Protected mode off for this connection to run these changes one by one.")
    }
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    return try await sendSequentially(
      statements, expectedRows: expectedRows, progress: progress)
  }

  /// `executeGatedSequentialCommands`, returning each statement's affected rows.
  func executeGatedSequentialBatch(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, expectedRows: [Int]?, progress: (@Sendable (Int) -> Void)? = nil
  ) async throws -> [Int] {
    try await executeGatedSequentialCommands(
      statements, policy: policy, connectionEpoch: epoch, caller: caller,
      expectedRows: expectedRows, progress: progress
    ).map(\.affectedRows)
  }

  // MARK: - Private

  static let sequentialTransactionOpenRefusal =
    "Commit or roll back the open transaction first, then run these changes."

  /// Send each statement on its own. Stops at the first failure, once the connection changed
  /// or was cancelled, or once a transaction was opened meanwhile (the rest would run in it).
  private func sendSequentially(
    _ statements: [String], expectedRows: [Int]?, progress: (@Sendable (Int) -> Void)?
  ) async throws -> [CommandResult] {
    let dialect = Self.dialect(of: config)
    let epoch = connectionEpoch
    let generation = batchCancellationGeneration
    var results: [CommandResult] = []
    results.reserveCapacity(statements.count)
    for (index, sql) in statements.enumerated() {
      if !txState.isIdle || userTxOpen {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: statements.count,
          reason: "A transaction was opened meanwhile; the rest would run in it")
      }
      let result: CommandResult
      do {
        try refuseIfSessionChanged(
          since: epoch, generation: generation, remaining: statements.count - index)
        result = try await commandResult(sql: sql, binds: [])
      } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: statements.count, reason: reason)
      }
      if let classified = SQLStatementClassifier.classify(sql, dialect: dialect).first {
        noteSchemaChange(classified)
      }
      let rows = result.affectedRows
      if let expected = expectedRows?[index], rows != expected {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: statements.count,
          reason: "expected to affect \(expected) row\(expected == 1 ? "" : "s"), affected \(rows)")
      }
      results.append(result)
      progress?(results.count)
      await batchCheckpointHook?(index)
    }
    return results
  }
}
