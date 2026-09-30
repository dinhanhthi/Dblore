// DatabaseConnectionManager+CappedRead.swift
// Row cap without SQL rewrites: the statement is sent as written and the reader stops after
// N rows by its own counter (rows already buffered keep arriving after a close, so the close
// never stops the reader). What happens to the rest of the result is decided per statement:
// - a read with no app transaction and no user transaction open, that calls no function, while
//   no other caller uses the connection: the session is closed and reopened with the same config
//   (`resetSessionIfCapped`), the remaining statements of the script are not run;
// - a plain SELECT / VALUES / TABLE / WITH read calling no function and locking no rows, inside
//   the app transaction or the user's own BEGIN: sent as a server-side cursor
//   (`executeCursorRead`: DECLARE, FETCH cap + 1, CLOSE), so the server stops at the cap and the
//   transaction survives. The planner prefers a fast-start plan for a cursor: an index matching
//   ORDER BY skips the sort. Without one the server still sorts every row first, and only
//   statement_timeout stops it;
// - any other read (SHOW, EXPLAIN, calling a function, a row lock such as FOR UPDATE / FOR
//   SHARE that a cursor would apply to fetched rows only, another tab's statement in flight
//   with no transaction open): the loop breaks and PostgresNIO drains the rest (bounded by
//   statement_timeout), the session, its transaction and pending changes survive;
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
struct CollectedRows: Sendable {
  var columns: [ColumnInfo] = []
  var rows: [[CellValue]] = []
  /// Rows the stream returned (past the cap only when read to the end)
  var total = 0
  /// The stream had more rows than the cap
  var truncated = false
}

extension DatabaseConnectionManager {
  /// Read at most `maxRows` rows of `source`, taking column names / types from the first row
  /// that is kept. One row past the cap is looked at to know whether the result was truncated.
  /// Then the loop breaks (the session stops reading and PostgresNIO drains the rest on the
  /// next query, unless the session is closed), or, with `readToEnd`, keeps counting rows
  /// without keeping them.
  func readCapped(
    _ source: SessionRowSource, maxRows: Int, readToEnd: Bool
  ) async throws -> CollectedRows {
    var collected = CollectedRows()
    for try await row in source.rows {
      collected.total += 1
      if collected.rows.count >= maxRows {
        collected.truncated = true
        if readToEnd { continue }
        break
      }
      if collected.total == 1 {
        collected.columns = source.columns
      }
      collected.rows.append(row)
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
    let forgotten = forgetConnection()
    lastSessionLoss = nil
    do {
      await Self.closeForgotten(forgotten, includingConnection: true)
      try await connect(config: config)
      sessionResetsContinuation.yield(
        SessionResetEvent(epoch: connectionEpoch, userTxRolledBack: false))
    } catch {
      guard session == nil else { return reset }
      let event = SessionLostEvent(
        state: .idle, userTxOpen: false, epoch: connectionEpoch)
      lastSessionLoss = event
      sessionEventsContinuation.yield(event)
      await AppLogger.shared.warning(
        "Reconnect after capped read failed: \(error.localizedDescription)", category: "Database")
    }
    return reset
  }

  /// Inside a transaction, read `query` through a server-side cursor: DECLARE, FETCH cap + 1,
  /// CLOSE. The server stops at the cap instead of draining. Errors point at the text sent
  /// (the server position is relative to it).
  func executeCursorRead(
    _ query: String, maxRows: Int, startTime: Date
  ) async throws -> QueryResult {
    let cursor: SessionCursor
    do {
      cursor = try await withSession { session in
        try await session.openCursor(query, binds: [])
      }
    } catch {
      throw unwrapFailure(error, fallbackSQL: query, startTime: startTime)
    }
    let fetchCount = maxRows + 1
    let fetchSQL = PostgresSession.fetchSQL(name: cursor.name, maxRows: fetchCount)
    let collected: CollectedRows
    do {
      collected = try await withSession { session in
        let source = try await session.fetch(cursor, maxRows: fetchCount)
        return try await self.readCapped(source, maxRows: maxRows, readToEnd: false)
      }
    } catch {
      throw unwrapFailure(error, fallbackSQL: fetchSQL, startTime: startTime)
    }
    let closeSQL = PostgresSession.closeSQL(name: cursor.name)
    do {
      try await withSession { session in
        try await session.closeCursor(cursor)
      }
    } catch {
      throw unwrapFailure(error, fallbackSQL: closeSQL, startTime: startTime)
    }
    let executionTime = Date().timeIntervalSince(startTime)
    // Not after a truncated read, as on the drain path: a failed catalog query inside the
    // user's BEGIN would abort their transaction
    let enrichedColumns =
      collected.truncated
      ? collected.columns : await enrichColumnTypes(columns: collected.columns, query: query)
    var result = QueryResult(
      columns: enrichedColumns, rows: collected.rows, rowCount: collected.rows.count,
      executionTime: executionTime, wasLimited: collected.truncated, affectedRows: 0)
    result.truncated = collected.truncated
    cursorReadCount += 1
    return result
  }

  /// Test hook (see `scriptCheckpointHook`): lets a test interleave other callers at a
  /// `ScriptCheckpoint`. Nil in the app.
  func setScriptCheckpointHook(_ hook: (@Sendable (ScriptCheckpoint) async -> Void)?) {
    scriptCheckpointHook = hook
  }

  /// A plain read a cursor can run: SELECT / VALUES / TABLE / WITH (not SHOW or EXPLAIN) that
  /// calls no function (its side effects would stop at the cap) and locks no rows.
  nonisolated static func usesCursor(_ statement: ClassifiedStatement) -> Bool {
    guard statement.kind == .read else { return false }
    let tokens = SQLTokenizer.tokens(statement.text)
    let first = tokens.first { $0.kind == .word }?.keyword ?? ""
    return ["SELECT", "VALUES", "TABLE", "WITH"].contains(first)
      && !SQLStatementClassifier.mayCallFunctions(statement.text)
      && !hasLockingClause(tokens)
  }

  /// `FOR UPDATE / NO KEY UPDATE / SHARE / KEY SHARE` at any depth: in a cursor it locks only
  /// the rows fetched, not every matching row. Fails closed (words, so not in strings/comments).
  private nonisolated static func hasLockingClause(_ tokens: [SQLToken]) -> Bool {
    let locks: [[String]] = [["UPDATE"], ["NO", "KEY", "UPDATE"], ["SHARE"], ["KEY", "SHARE"]]
    return tokens.indices.contains { index in
      guard tokens[index].isWord("FOR") else { return false }
      let next = tokens[(index + 1)...].prefix(3).map { $0.keyword ?? "" }
      return locks.contains { next.starts(with: $0) }
    }
  }

  /// EXPLAIN ANALYZE runs its statement, and a called function may write: closing before the
  /// result completes would abort the statement and roll back what it changed in autocommit.
  private nonisolated static func mustDrain(_ statement: ClassifiedStatement) -> Bool {
    if case .explain(_, analyze: true) = statement.kind { return true }
    return SQLStatementClassifier.mayCallFunctions(statement.text)
  }
}
