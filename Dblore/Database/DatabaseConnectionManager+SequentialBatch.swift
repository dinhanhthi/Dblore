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
    try refuseIfRelocked(config)
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
    var remaining = statements.makeIterator()
    var results: [CommandResult] = []
    results.reserveCapacity(statements.count)
    try await sendGatedSequentially(
      total: statements.count, next: { remaining.next() }, effective: effective, caller: caller,
      expectedRows: expectedRows
    ) {
      results.append($0)
      progress?(results.count)
    }
    return results
  }

  /// `executeGatedSequentialCommands` for a SQL dump restore (MySQL), over statements `next`
  /// hands out one at a time until it returns nil (`total`: how many it sends). The gate checks
  /// `gated`, every statement of the plan as pass 1 classified it, instead of classifying the
  /// text; then the same refusals apply before anything is sent. A throw from `next` stops the
  /// batch and is thrown as is (the statements before it stay applied). Nothing is kept per
  /// statement.
  func executeGatedSequentialBatch(
    gated: some Sequence<ClassifiedStatement>, total: Int, next: () throws -> String?,
    policy: ProtectionPolicy, connectionEpoch epoch: UInt64, caller: UUID? = nil
  ) async throws {
    try refuseIfRelocked(config)
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    let effective = effectivePolicy(for: policy)
    // Decision is pure and finishes before any await that could send anything.
    if case .blocked(let index, let kind, let reason) = Self.evaluate(
      gated, policy: effective, dialect: Self.dialect(of: config))
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    try await sendGatedSequentially(
      total: total, next: next, effective: effective, caller: caller, expectedRows: nil
    ) { _ in }
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
  static let sequentialProtectedModeRefusal =
    "Turn Protected mode off for this connection to run these changes one by one."

  /// The refusals after the gate (another caller's transaction, an open transaction, Protected
  /// mode, no session), then `sendSequentially`
  private func sendGatedSequentially(
    total: Int, next: () throws -> String?, effective: ProtectionPolicy, caller: UUID?,
    expectedRows: [Int]?, sent: (CommandResult) -> Void
  ) async throws {
    try refuseIfOwnedByAnotherCaller(caller)
    // Checked before Protected mode: a pending app transaction always forces Protected mode.
    if !txState.isIdle || userTxOpen {
      throw DatabaseError.sequentialBatchRefused(Self.sequentialTransactionOpenRefusal)
    }
    if effective.protectedMode {
      throw DatabaseError.sequentialBatchRefused(Self.sequentialProtectedModeRefusal)
    }
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    try await sendSequentially(
      total: total, next: next, expectedRows: expectedRows, sent: sent)
  }

  /// Send each statement `next` hands out on its own (`total` of them, for the counts in the
  /// errors); `sent` gets each result. Stops at the first failure, once the connection changed
  /// or was cancelled, or once a transaction was opened meanwhile (the rest would run in it). A
  /// throw from `next` is thrown as is, unless the batch was cancelled or the connection changed
  /// meanwhile: then as a statement's send would be.
  private func sendSequentially(
    total: Int, next: () throws -> String?, expectedRows: [Int]?,
    sent: (CommandResult) -> Void
  ) async throws {
    let dialect = Self.dialect(of: config)
    let epoch = connectionEpoch
    let generation = batchCancellationGeneration
    var index = 0
    while true {
      let pulled: String?
      do {
        pulled = try next()
      } catch {
        do {
          try refuseIfSessionChanged(
            since: epoch, generation: generation, remaining: total - index)
        } catch let stopped {
          let reason =
            (stopped as? LocalizedError)?.errorDescription ?? stopped.localizedDescription
          throw DatabaseError.batchPartiallyApplied(applied: index, total: total, reason: reason)
        }
        throw error
      }
      guard let sql = pulled else { return }
      if !txState.isIdle || userTxOpen {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: total,
          reason: "A transaction was opened meanwhile; the rest would run in it")
      }
      let result: CommandResult
      do {
        try refuseIfSessionChanged(
          since: epoch, generation: generation, remaining: total - index)
        result = try await commandResult(sql: sql, binds: [])
      } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        throw DatabaseError.batchPartiallyApplied(applied: index, total: total, reason: reason)
      }
      if let classified = SQLStatementClassifier.classify(sql, dialect: dialect).first {
        noteSchemaChange(classified)
        noteTemporaryTable(classified)
      }
      let rows = result.affectedRows
      if let expected = expectedRows?[index], rows != expected {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: total,
          reason: "expected to affect \(expected) row\(expected == 1 ? "" : "s"), affected \(rows)")
      }
      sent(result)
      await batchCheckpointHook?(index)
      index += 1
    }
  }
}
