// DatabaseConnectionManager+MongoDocuments.swift
// Gated read of user mongosh text that returns the documents as typed BSON (`MongoValue`)
// instead of flattened rows, so explicit nulls and nested values survive (Export Data).
//
// Same gate as `execute`: `authorize` classifies the text and checks the stricter of the given
// policy and the connection's protection, and throws `blockedByProtection` before anything is
// sent. Then the text must be exactly one read, a find or an aggregate (an aggregate with
// `$out`/`$merge` is never a read), on a `MongoSession`; anything else is refused before
// anything is sent. The command sent is the one parsed from the classified text, capped at
// `maxRows + 1` documents (`MongoCommandRewriter`). The entry checks are those of
// `runUserStatements` (connection epoch, Commit / Rollback in progress, the transaction's
// owner, Cancel). A capped Mongo read never resets the session
// (`cappedReadResetsSession` is false), so there is no `resetSessionIfCapped` step.

import Foundation

extension DatabaseConnectionManager {
  /// The documents of one find or aggregate in `userSQL`, at most `maxRows`; `truncated` when
  /// more came back. Throws `DatabaseError.blockedByProtection` when `policy` (or the
  /// connection) forbids the text, and `MongoSessionError` for text that is not exactly one
  /// find or aggregate read or a session that is not MongoDB, all before anything is sent.
  /// `caller` and `expectedEpoch` work as in `execute`.
  func executeMongoDocuments(
    userSQL: String, policy: ProtectionPolicy, maxRows: Int, caller: UUID? = nil,
    expectedEpoch: UInt64? = nil
  ) async throws -> (documents: [MongoValue], truncated: Bool) {
    let (statements, protectedMode) = try authorize(userSQL, policy: policy)
    guard let statement = statements.first else { throw DatabaseError.emptyQuery }
    guard statements.count == 1 else {
      throw MongoSessionError(
        message: "Documents are read from one command; this text has \(statements.count).")
    }
    guard statement.kind == .read else {
      throw MongoSessionError(
        message: "Only a read returns documents; writes and $out/$merge pipelines run as "
          + "commands.")
    }
    let command = try MongoshParser.parse(statement.text)
    switch command {
    case .find, .aggregate: break
    default: throw MongoSessionError(message: "Only a find or an aggregate returns documents.")
    }
    let capped = MongoCommandRewriter.withLimit(command, maxRows: maxRows)

    // Entry checks of `runUserStatements`, in the same order
    guard session != nil else { throw DatabaseError.notConnected }
    if let expectedEpoch, expectedEpoch != connectionEpoch {
      throw DatabaseError.sessionChanged(skippedStatements: 1)
    }
    try refuseIfConnectionClosed()
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    let epoch = connectionEpoch
    let cancelGeneration = batchCancellationGeneration
    try await adoptUserTransactionIfNeeded(protectedMode: protectedMode, caller: caller)
    await scriptCheckpointHook?(.beforeStatement(caller: caller, index: 0))
    try refuseIfSessionChanged(since: epoch, generation: cancelGeneration, remaining: 1)
    try refuseIfOwnedByAnotherCaller(caller)
    // Checked synchronously before the send, so this refusal is not reported as a query failure
    guard session is MongoSession else {
      throw MongoSessionError(message: "Reading documents needs a MongoDB session.")
    }

    let startTime = Date()
    let documents: [MongoValue]
    do {
      documents = try await withSession { current in
        guard let mongo = current as? MongoSession else {
          throw MongoSessionError(message: "Reading documents needs a MongoDB session.")
        }
        return try await mongo.readDocuments(capped)
      }
    } catch {
      if let cancelled = cancelError(since: epoch, generation: cancelGeneration) {
        throw cancelled
      }
      throw queryFailure(error, query: statement.text, startTime: startTime)
    }
    return (Array(documents.prefix(max(maxRows, 0))), documents.count > max(maxRows, 0))
  }
}
