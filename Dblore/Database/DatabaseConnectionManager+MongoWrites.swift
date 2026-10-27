// DatabaseConnectionManager+MongoWrites.swift
// Typed MongoDB writes built by the app (restore, import, admin forms): each `MongoCommand` is
// classified as is (never rendered to text and parsed again) and sent through
// `MongoTypedCommandSending`. Same gate, in the same order, as `executeGatedSequentialCommands`.

import Foundation

extension DatabaseConnectionManager {
  /// Send `commands` one by one, each applied on its own. Before anything is sent:
  /// `connectionEpoch` must still be `epoch` (`DatabaseError.notEditable`), `expectedRows` (when
  /// set) must have one count per command, every command's typed classification must pass
  /// `evaluate` against `effectivePolicy(for:)` (`DatabaseError.blockedByProtection`), another
  /// caller's pending app transaction is refused, and an open app or user transaction, then
  /// Protected mode, are refused (`DatabaseError.sequentialBatchRefused`). An empty batch
  /// returns `[]`. The first send error (a cancel included) or count other than
  /// `expectedRows[i]` stops the batch: `DatabaseError.batchPartiallyApplied`. Callers sending
  /// several batches pass the same `epoch` each time, so a reconnect refuses the rest.
  func executeGatedMongoCommands(
    _ commands: [MongoCommand], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, expectedRows: [Int]?, progress: (@Sendable (Int) -> Void)? = nil
  ) async throws -> [CommandResult] {
    try await PerfSignpost.interval("mongo.typedWrites") {
      try refuseIfRelocked(config)
      guard epoch == connectionEpoch else {
        throw DatabaseError.notEditable("the connection changed; run the query again to edit")
      }
      if let expectedRows, expectedRows.count != commands.count {
        throw DatabaseError.sequentialBatchRefused(
          "Each change needs exactly one expected row count.")
      }
      let effective = effectivePolicy(for: policy)
      let classified = commands.map {
        MongoCommandClassifier.classify($0, summary: Self.typedSummary(of: $0))
      }
      // Decision is pure and finishes before any await that could send anything.
      if case .blocked(let index, let kind, let reason) = Self.evaluate(
        classified, policy: effective, dialect: .mongodb)
      {
        throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
      }
      if commands.isEmpty { return [] }
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
      return try await sendTypedSequentially(
        commands, classified: classified, expectedRows: expectedRows, progress: progress)
    }
  }

  /// The session's write limits (`MongoTypedCommandSending.writeLimits()`); `.fallback` when
  /// not connected to MongoDB.
  func mongoWriteLimits() async -> MongoWriteLimits {
    guard let typed = session as? any MongoTypedCommandSending else { return .fallback }
    return await typed.writeLimits()
  }

  // MARK: - Private

  /// A short statement text for the classification: an insert's documents are never rendered.
  private nonisolated static func typedSummary(of command: MongoCommand) -> String {
    switch command {
    case .insertMany(let collection, let documents):
      "db.\(collection).insertMany(\(documents.count) documents)"
    case .insertOne(let collection, _):
      "db.\(collection).insertOne(1 document)"
    default:
      command.render()
    }
  }

  /// `sendSequentially` for typed commands; `classified` (one per command) drives
  /// `noteSchemaChange`.
  private func sendTypedSequentially(
    _ commands: [MongoCommand], classified: [ClassifiedStatement], expectedRows: [Int]?,
    progress: (@Sendable (Int) -> Void)?
  ) async throws -> [CommandResult] {
    let epoch = connectionEpoch
    let generation = batchCancellationGeneration
    var results: [CommandResult] = []
    results.reserveCapacity(commands.count)
    for (index, command) in commands.enumerated() {
      if !txState.isIdle || userTxOpen {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: commands.count,
          reason: "A transaction was opened meanwhile; the rest would run in it")
      }
      let result: CommandResult
      do {
        try refuseIfSessionChanged(
          since: epoch, generation: generation, remaining: commands.count - index)
        result = try await typedCommandResult(command)
      } catch {
        let failure = error as? TypedSendFailure
        let error = failure?.error ?? error
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: commands.count, reason: reason, written: failure?.written)
      }
      noteSchemaChange(classified[index])
      let rows = result.affectedRows
      if let expected = expectedRows?[index], rows != expected {
        throw DatabaseError.batchPartiallyApplied(
          applied: index, total: commands.count,
          reason: "expected to affect \(expected) row\(expected == 1 ? "" : "s"), affected \(rows)")
      }
      results.append(result)
      progress?(results.count)
      await batchCheckpointHook?(index)
    }
    return results
  }

  /// A driver error in the session's text, with the documents a failing write wrote before it
  private struct TypedSendFailure: Error {
    let error: DatabaseError
    let written: Int?
  }

  /// `commandResult(sql:binds:)` for one typed command: driver errors get the session's text
  /// (`TypedSendFailure`).
  private func typedCommandResult(_ command: MongoCommand) async throws -> CommandResult {
    let startTime = Date()
    do {
      return try await withSession { current in
        guard let typed = current as? any MongoTypedCommandSending else {
          throw MongoSessionError(message: "Typed writes need a MongoDB session.")
        }
        return try await typed.command(command)
      }
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw TypedSendFailure(
        error: queryFailure(error, query: Self.typedSummary(of: command), startTime: startTime),
        written: (error as? MongoSessionError)?.written)
    }
  }
}
