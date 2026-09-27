// DatabaseConnectionManager+CappedRead.swift
// Row cap without SQL rewrites: the statement is sent as written and the reader stops after
// N rows by its own counter (rows already buffered keep arriving after a close, so the close
// never stops the reader). What happens to the rest of the result is decided per statement:
// - a read with no app transaction and no user transaction open, that calls no function, while
//   no other caller uses the connection: the session is closed and reopened with the same config
//   (`resetSessionIfCapped`), the remaining statements of the script are not run;
// - any other read (inside the app transaction or the user's own BEGIN, calling a function,
//   another tab's statement in flight): the loop breaks and PostgresNIO drains the rest (bounded
//   by statement_timeout), the session, its transaction and pending changes survive;
// - a statement that may write (RETURNING, utility, data-modifying WITH): read to the end,
//   rows past the cap counted but not kept. Closing mid-stream would roll back its changes.

import Foundation
import PostgresNIO

/// Why the manager closed and reopened the session
nonisolated enum SessionResetReason: Sendable, Equatable {
  /// To stop a capped read (no app transaction was pending)
  case rowCap
  /// The user cancelled the running statement; `pendingCount` app-transaction changes were
  /// rolled back with the old session
  case cancelled(pendingCount: Int)
}

/// Published when the manager closed and reopened the session (`reason`). Not a loss: the
/// workspace stays connected.
nonisolated struct SessionResetEvent: Sendable, Equatable {
  /// `connectionEpoch` of the new connection
  let epoch: UInt64
  /// A transaction the user opened with BEGIN (Protected mode off) was rolled back
  let userTxRolledBack: Bool
  var reason: SessionResetReason = .rowCap
}

/// Points inside `runUserStatements` where the test hook (`setScriptCheckpointHook`) is awaited
nonisolated enum ScriptCheckpoint: Sendable, Equatable {
  /// Before statement `index` of the script run for `caller`
  case beforeStatement(caller: UUID?, index: Int)
  /// A read was cut by the row cap; whether the session is reset is decided next
  case beforeCapReset
}

/// Rows read from a stream, at most the row cap.
struct CollectedRows {
  var columns: [ColumnInfo] = []
  var rows: [[CellValue]] = []
  /// Rows the stream returned (past the cap only when read to the end)
  var total = 0
  /// The stream had more rows than the cap
  var truncated = false
}

extension DatabaseConnectionManager {
  /// Read at most `maxRows` rows of `stream`, taking column names / types from the first row.
  /// One row past the cap is looked at to know whether the result was truncated. Then the loop
  /// breaks (PostgresNIO drains the rest on the next query, unless the session is closed), or,
  /// with `readToEnd`, keeps counting rows without keeping them.
  func readCapped(
    _ stream: PostgresRowSequence, maxRows: Int, readToEnd: Bool
  ) async throws -> CollectedRows {
    var collected = CollectedRows()
    for try await row in stream {
      collected.total += 1
      if collected.rows.count >= maxRows {
        collected.truncated = true
        if readToEnd { continue }
        break
      }
      let randomAccess = row.makeRandomAccess()
      if collected.total == 1 {
        for (index, cell) in randomAccess.enumerated() {
          collected.columns.append(
            ColumnInfo(
              name: cell.columnName, type: postgresDataTypeName(cell.dataType),
              origin: stream.columns.dropFirst(index).first))
        }
      }
      collected.rows.append(randomAccess.map { parseCellValue(from: $0) })
    }
    return collected
  }

  /// A capped read of `statement` stopped early with no transaction open: close the session
  /// (the server discards the rest of the result) and reconnect with the current config (session brakes re-applied, epoch advanced, so
  /// edit targets of the old session are refused). Marks `result` as reset.
  /// - Returns: `result` unchanged (drained instead) when the session must be kept: an app
  ///   transaction is pending or its BEGIN is in flight; the user opened a transaction with
  ///   BEGIN (Protected off: its uncommitted work is never discarded by the cap, only Cancel
  ///   rolls it back, after confirmation); the statement may write (EXPLAIN
  ///   ANALYZE, or it calls a function: `SQLStatementClassifier.mayCallFunctions`); or another
  ///   caller shares the connection right now (another gated script / edit, or any query waiting
  ///   in `send(on:)`): closing would roll back or drop its work.
  ///   If reconnecting fails the session is reported lost (`SessionLostEvent`), rows kept.
  func resetSessionIfCapped(
    _ result: QueryResult, statement: ClassifiedStatement
  ) async -> QueryResult {
    guard result.truncated, StatementRoute.route(for: statement) == .read else { return result }
    await scriptCheckpointHook?(.beforeCapReset)
    // `inFlight == 1`: only this script (its own count); its own send already returned
    guard !Self.mustDrain(statement), txState.isIdle, txOwner == nil, !userTxOpen,
      commitGuard.inFlight == 1, activeSends == 0, let config
    else { return result }
    var reset = result
    reset.sessionReset = true
    // Forgotten in this actor turn: no caller entering meanwhile can send on the closing session
    let (closing, group) = forgetConnection()
    lastSessionLoss = nil
    do {
      try? await closing?.close()
      try? await group?.shutdownGracefully()
      try await connect(config: config)
      sessionResetsContinuation.yield(
        SessionResetEvent(epoch: connectionEpoch, userTxRolledBack: reset.userTxRolledBack))
    } catch {
      guard _connection == nil else { return reset }
      let event = SessionLostEvent(
        state: .idle, userTxOpen: reset.userTxRolledBack, epoch: connectionEpoch)
      lastSessionLoss = event
      sessionEventsContinuation.yield(event)
      await AppLogger.shared.warning(
        "Reconnect after capped read failed: \(error.localizedDescription)", category: "Database")
    }
    return reset
  }

  /// Test hook (see `scriptCheckpointHook`): lets a test interleave other callers at a
  /// `ScriptCheckpoint`. Nil in the app.
  func setScriptCheckpointHook(_ hook: (@Sendable (ScriptCheckpoint) async -> Void)?) {
    scriptCheckpointHook = hook
  }

  /// EXPLAIN ANALYZE runs its statement, and a called function may write: closing before the
  /// result completes would abort the statement and roll back what it changed in autocommit.
  private nonisolated static func mustDrain(_ statement: ClassifiedStatement) -> Bool {
    if case .explain(_, analyze: true) = statement.kind { return true }
    return SQLStatementClassifier.mayCallFunctions(statement.text)
  }
}
