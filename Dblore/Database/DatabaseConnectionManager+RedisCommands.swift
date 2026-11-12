// DatabaseConnectionManager+RedisCommands.swift
// The Redis gate: every Redis command, typed in the editor or built by the app, is checked here
// before its exact argument bytes go to the session through `RedisCommandSending`. This is the
// only place a session is cast to `RedisCommandSending` (a source scan in `RedisGateTests`
// keeps it that way). History is the callers' job.

import Foundation

/// A Redis command refused by the gate for a reason that is not the protection policy (a db
/// index out of range, a session that cannot send Redis commands). Nothing was sent.
nonisolated struct RedisCommandRefusal: LocalizedError, Equatable {
  let message: String

  var errorDescription: String? { message }
}

extension DatabaseConnectionManager {
  /// The highest db index the gate lets through. Redis numbers its databases from 0 and the
  /// server's `databases` setting is a 32-bit count; the server refuses an index it does not
  /// have, so this bound only keeps negative and absurd values from being sent.
  nonisolated static let maxRedisDatabaseIndex = Int(Int32.max)

  /// Send one Redis command and return its reply rows `[path, type, value]`
  /// (`RedisReply(rows:maxNodes:)`), read whole while the command counts as running; a reply of
  /// more than `RedisReply.defaultMaxNodes` rows is refused (`DatabaseError.queryFailed`) and
  /// the rest of it dropped.
  /// Before anything is sent, in this order: the connection must not be relocked
  /// (`DatabaseError.connectionLocked`), `connectionEpoch` must still be `epoch`
  /// (`DatabaseError.sessionChanged`), `command.db` must be in
  /// `0...maxRedisDatabaseIndex` (`RedisCommandRefusal`); `command.args` (the bytes sent) are
  /// classified: an editor-refused command, a command `evaluate` forbids under the stricter of
  /// `policy` and the connection's (`effectivePolicy`: a pending app transaction counts as
  /// Protected mode, whose Redis arm refuses every write: "Redis has no transactions, so
  /// Protected mode cannot hold this change. Use Confirm."), and a destructive command without
  /// `confirmed` are refused (`DatabaseError.blockedByProtection`); another caller's pending app
  /// transaction is refused; a write is refused while the user's own transaction is open
  /// (`sequentialTransactionOpenRefusal`; never in practice: Redis has no transactions); then a
  /// session must exist, be open and send Redis commands. `userInitiated` (editor runs and
  /// edits) counts the command in `commitGuard.inFlight`, so Cancel can stop it; the app's own
  /// reads are not counted.
  /// Logs name the command and its argument count only (`RedisCommand.logDescription`); a
  /// server error is cut before any argument it echoes, and a command holding a password keeps
  /// no server text at all (`withoutServerEcho`).
  func executeGatedRedisCommand(
    _ command: RedisCommand, policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, userInitiated: Bool, confirmed: Bool = false
  ) async throws -> QueryResult {
    try await PerfSignpost.interval("redis.command") {
      try refuseIfRelocked(config)
      guard epoch == connectionEpoch else {
        throw DatabaseError.sessionChanged(skippedStatements: 1)
      }
      guard (0...Self.maxRedisDatabaseIndex).contains(command.db) else {
        throw RedisCommandRefusal(
          message: "Database index \(command.db) is out of range. Nothing was sent.")
      }
      let effective = effectivePolicy(for: policy)
      // The exact array sent below: never rebuilt from the classification's display text
      let classification = RedisCommandClassifier.classify(command.args)
      let statement = classification.statement
      if let refusal = classification.refusal {
        throw DatabaseError.blockedByProtection(
          statementIndex: 0, kind: statement.kind, reason: refusal)
      }
      // Decision is pure and finishes before any await that could send anything.
      if case .blocked(let index, let kind, let reason) = Self.evaluate(
        [statement], policy: effective, dialect: .redis)
      {
        throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
      }
      // Never through `DestructiveStatementRule`, which reads SQL text
      if statement.isDestructive, !confirmed {
        throw DatabaseError.blockedByProtection(
          statementIndex: 0, kind: statement.kind,
          reason: "This command removes data or changes the server for good; confirm it first")
      }
      try refuseIfOwnedByAnotherCaller(caller)
      // A pending app transaction already made `effective` Protected, refused above
      if !statement.isReadOnlySafe, userTxOpen {
        throw DatabaseError.sequentialBatchRefused(Self.sequentialTransactionOpenRefusal)
      }
      guard let current = session else { throw DatabaseError.notConnected }
      try refuseIfConnectionClosed()
      guard current is any RedisCommandSending else { throw Self.notRedisSession }
      // Counted before the first suspension, so Cancel sees it from the start
      if userInitiated { commitGuard.inFlight += 1 }
      defer { if userInitiated { commitGuard.inFlight -= 1 } }
      return try await sendRedis(command, epoch: epoch)
    }
  }

  // MARK: - Private

  private nonisolated static let notRedisSession = RedisCommandRefusal(
    message: "This connection cannot run Redis commands. Nothing was sent.")

  /// Sends `command` on the current session and reads the whole reply, up to
  /// `RedisReply.defaultMaxNodes` rows: past it the rows are dropped, which cancels the rest
  /// (`EnginePluginSession`). Errors other than the manager's own are reported with
  /// `command.logDescription`, never its arguments.
  private func sendRedis(_ command: RedisCommand, epoch: UInt64) async throws -> QueryResult {
    let startTime = Date()
    do {
      return try await withSession { current in
        guard connectionEpoch == epoch else {
          throw DatabaseError.sessionChanged(skippedStatements: 1)
        }
        guard let sender = current as? any RedisCommandSending else { throw Self.notRedisSession }
        let source = try await sender.send(command)
        var rows: [[CellValue]] = []
        for try await row in source.rows {
          guard rows.count < RedisReply.defaultMaxNodes else {
            throw DatabaseError.queryFailed(
              "The reply has more than \(RedisReply.defaultMaxNodes) nodes; it was not read.",
              Date().timeIntervalSince(startTime))
          }
          rows.append(row)
        }
        return QueryResult(
          columns: source.columns, rows: rows, rowCount: rows.count,
          executionTime: Date().timeIntervalSince(startTime))
      }
    } catch let error as DatabaseError {
      throw Self.withoutServerEcho(error, of: command)
    } catch let error as RedisCommandRefusal {
      throw error
    } catch {
      throw Self.withoutServerEcho(
        queryFailure(error, query: command.logDescription, startTime: startTime), of: command)
    }
  }

  /// `error` without what the server may echo of `command`: a command holding a password
  /// (`RedisCommandClassifier.containsSecret`) keeps no server or session text at all (`ACL
  /// SETUSER` echoes a mistyped rule, password included; a session may word a lost or failed
  /// connection with what it was sending), only the error's case; any other is cut by
  /// `withoutArgumentEcho`. The other cases a send can end in carry no text or only the app's own.
  private nonisolated static func withoutServerEcho(
    _ error: DatabaseError, of command: RedisCommand
  ) -> DatabaseError {
    guard RedisCommandClassifier.containsSecret(command.args) else {
      return withoutArgumentEcho(error)
    }
    let hidden = "Its message is hidden because the command holds a password."
    switch error {
    case .queryFailed(_, let time):
      return .queryFailed("The server refused the command. " + hidden, time)
    case .connectionLost: return .connectionLost("The connection was lost. " + hidden)
    case .connectionFailed: return .connectionFailed("The connection failed. " + hidden)
    default: return error
    }
  }

  /// `error` with a server message cut before ", with args beginning with" (any case): the
  /// server echoes the arguments there (a password, say). The plugin cuts it too; this is the
  /// app's own cut, for any session.
  private nonisolated static func withoutArgumentEcho(_ error: DatabaseError) -> DatabaseError {
    guard case .queryFailed(let message, let time) = error,
      let echo = message.range(of: "with args beginning with", options: .caseInsensitive)
    else { return error }
    let kept = message[..<echo.lowerBound].trimmingCharacters(
      in: CharacterSet(charactersIn: " ,").union(.whitespacesAndNewlines))
    return .queryFailed(kept.isEmpty ? "The server refused the command." : kept, time)
  }
}
