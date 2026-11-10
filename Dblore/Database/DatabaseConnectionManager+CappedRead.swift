// DatabaseConnectionManager+CappedRead.swift
// Row cap without SQL rewrites: the statement is sent as written and the reader stops after
// N rows by its own counter (rows already buffered keep arriving after a close, so the close
// never stops the reader). What happens to the rest of the result is decided per statement:
// - a read with no app transaction and no user transaction open, that calls no function, while
//   no other caller uses the connection: the session is closed and reopened with the same config
//   (`resetSessionIfCapped`), the remaining statements of the script are not run;
// - a plain SELECT / VALUES / TABLE / WITH read calling no function and locking no rows, inside
//   the app transaction or the user's own BEGIN: sent as a server-side cursor
//   (`executeCursorRead`: DECLARE, FETCH cap + 1, CLOSE; one round trip, the FETCH streamed and
//   each row cut as it leaves PostgresNIO's buffer; that buffer is counted in rows, 256 growing
//   to 16,384 and never past cap + 1, so raw rows ahead of the cut are bounded by rows, not
//   bytes, as on the plain `.read` path), so the
//   server stops at the cap and the transaction survives. The planner prefers a fast-start plan
//   for a cursor: an index matching ORDER BY skips the sort. Without one the server still sorts
//   every row first, and only statement_timeout stops it;
// - any other read (SHOW, EXPLAIN, calling a function, a row lock such as FOR UPDATE / FOR
//   SHARE that a cursor would apply to fetched rows only, another tab's statement in flight
//   with no transaction open): the loop breaks and PostgresNIO drains the rest (bounded by
//   statement_timeout), the session, its transaction and pending changes survive. MySQL kills
//   a read left at the cap (KILL QUERY), so there a read calling a function is read to the end;
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
  /// Statement `index` of the script run for `caller` passed its last check and is sent next
  case beforeSend(caller: UUID?, index: Int)
  /// `cancelRunningStatement` confirmed the cancel and is about to stop the statement
  case cancelling
}

/// Rows read from a stream, at most the row cap.
struct CollectedRows: Sendable {
  var columns: [ColumnInfo] = []
  var rows: [[CellValue]] = []
  /// Rows the stream returned (past the cap only when read to the end)
  var total = 0
  /// The stream had more rows than the cap
  var truncated = false
  /// Cells the read limits cut (`CappedReadLimits.marksCutCells`), by kept row
  var cutCells: Set<CellPosition> = []
  /// The kept cells passed `CappedReadLimits.maxResultBytes`
  var stoppedAtByteBudget = false
}

/// Bounds on what a capped read keeps, applied to each row as it arrives, and the read stops,
/// truncated, once the kept cells would pass `maxResultBytes`. A row is held whole only while it
/// is cut. MCP managers: text (decimal text too) longer than `maxCellCharacters` keeps
/// `maxCellCharacters + 1` characters and binary longer than its base64 would be keeps
/// `maxCellCharacters / 4 * 3 + 1` bytes (one past, so the reader can still tell it was cut).
/// With `marksCutCells` (the app): text keeps exactly `maxCellCharacters` characters, binary as
/// many bytes, and the read records each cut cell (`CollectedRows.cutCells`).
nonisolated struct CappedReadLimits: Sendable, Equatable {
  let maxCellCharacters: Int
  let maxResultBytes: Int
  var marksCutCells = false

  /// The app's editor and notebook results: 1 MiB of characters (binary: bytes) per cell,
  /// 256 MiB per result, cut cells marked
  static let app = CappedReadLimits(
    maxCellCharacters: 1_048_576, maxResultBytes: 256 * 1_048_576, marksCutCells: true)

  /// `row` with long cells cut, the bytes it keeps (UTF-8 text, binary, 8 per scalar) and the
  /// indexes of the cells that were cut.
  func cut(_ row: [CellValue]) -> (row: [CellValue], bytes: Int, cutColumns: [Int]) {
    var bytes = 0
    var cutColumns: [Int] = []
    let cells = row.enumerated().map { index, cell -> CellValue in
      let kept: CellValue? =
        switch cell {
        case .string(let text): cutText(text).map(CellValue.string)
        case .json(let text): cutText(text).map(CellValue.json)
        case .decimal(let text): cutText(text).map(CellValue.decimal)
        case .data(let data) where data.count > maxBinaryBytes:
          .data(Data(Array(data.prefix(maxBinaryBytes))))
        default: nil
        }
      if kept != nil { cutColumns.append(index) }
      let value = kept ?? cell
      switch value {
      case .string(let text), .json(let text), .decimal(let text): bytes += text.utf8.count
      case .data(let data): bytes += data.count
      default: bytes += 8
      }
      return value
    }
    return (cells, bytes, cutColumns)
  }

  private var maxBinaryBytes: Int {
    marksCutCells ? maxCellCharacters : maxCellCharacters / 4 * 3 + 1
  }

  /// Characters a cut text keeps: one past the limit unless cut cells are marked
  private var keptCharacters: Int { marksCutCells ? maxCellCharacters : maxCellCharacters + 1 }

  /// `text` cut to `keptCharacters` characters, without counting the rest; nil when it fits.
  private func cutText(_ text: String) -> String? {
    guard
      let end = text.index(text.startIndex, offsetBy: keptCharacters, limitedBy: text.endIndex),
      end < text.endIndex
    else { return nil }
    return String(text[..<end])
  }
}

extension DatabaseConnectionManager {
  /// Set around a data-viewer page read (`executeEditorQuery` with a page state): its result
  /// keeps the column list of an empty page on every engine, so an empty table shows its
  /// columns and its lazy page keeps the shape its SQL asked for
  @TaskLocal static var keepsEmptyResultColumns = false

  /// Read at most `maxRows` rows of `source`, taking column names / types from the first row
  /// that is kept. One row past the cap is looked at to know whether the result was truncated.
  /// Then the loop breaks (the session stops reading and PostgresNIO drains the rest on the
  /// next query, unless the session is closed), or, with `readToEnd`, keeps counting rows
  /// without keeping them. MySQL keeps the column list of a zero-row result too (the session
  /// reads its headers), so the result keeps its column origins; so does MongoDB (the session
  /// buffers the documents first), so an empty find keeps its `_id` column; and so does a
  /// data-viewer page on any engine (`keepsEmptyResultColumns`). With `readLimits`,
  /// rows are cut as they arrive and a row past the byte budget ends the read like a row past
  /// the cap (`stoppedAtByteBudget`). With `marksCutCells`, each cut cell of a kept row is
  /// recorded in `cutCells`. The limits are the manager's (`readLimits`, MCP), else `limits`
  /// (the read's own, `execute(userSQL:readLimits:)`).
  func readCapped(
    _ source: SessionRowSource, maxRows: Int, readToEnd: Bool, limits: CappedReadLimits? = nil
  ) async throws -> CollectedRows {
    var collected = CollectedRows()
    var keptBytes = 0
    let readLimits = self.readLimits ?? limits
    if Self.keepsEmptyResultColumns || config?.databaseType == .mysql
      || config?.databaseType.capabilities.queryLanguage == .mongosh
    {
      collected.columns = source.columns
    }
    for try await row in source.rows {
      collected.total += 1
      var kept = row
      var cutColumns: [Int] = []
      if !collected.truncated, collected.rows.count < maxRows, let readLimits {
        let cut = readLimits.cut(row)
        keptBytes += cut.bytes
        if keptBytes > readLimits.maxResultBytes {
          collected.truncated = true
          collected.stoppedAtByteBudget = true
        }
        kept = cut.row
        if readLimits.marksCutCells { cutColumns = cut.cutColumns }
      }
      if collected.truncated || collected.rows.count >= maxRows {
        collected.truncated = true
        if readToEnd { continue }
        break
      }
      if collected.total == 1 {
        collected.columns = source.columns
      }
      for column in cutColumns {
        collected.cutCells.insert(CellPosition(row: collected.rows.count, column: column))
      }
      collected.rows.append(kept)
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
  ///   in `send(on:)`): closing would roll back or drop its work; or the manager is closed right
  ///   after the read (`resetsSessionAfterCappedRead` false).
  ///   If reconnecting fails the session is reported lost (`SessionLostEvent`), rows kept.
  func resetSessionIfCapped(
    _ result: QueryResult, statement: ClassifiedStatement
  ) async -> QueryResult {
    let dialect = Self.dialect(of: config)
    guard resetsSessionAfterCappedRead, result.truncated,
      StatementRoute.route(for: statement, dialect: dialect) == .read
    else { return result }
    await scriptCheckpointHook?(.beforeCapReset)
    // `inFlight == 1`: only this script (its own count); its own send already returned
    guard !Self.mustDrain(statement, dialect: dialect), txState.isIdle, txOwner == nil, !userTxOpen,
      commitGuard.inFlight == 1, activeSends == 0, let config,
      config.databaseType.capabilities.cappedReadResetsSession
    else { return result }
    var reset = result
    reset.sessionReset = true
    let certificate = activeUnrememberedCertificate
    let sshCredential = activeUnrememberedSSHCredential
    let vaultSecret = activeUnrememberedVaultSecret
    // Forgotten in this actor turn: no caller entering meanwhile can send on the closing session
    let forgotten = forgetConnection()
    lastSessionLoss = nil
    do {
      await Self.closeForgotten(forgotten, includingConnection: true)
      try await reconnectWithActiveCertificate(
        config: config, material: certificate, sshCredential: sshCredential,
        vaultSecret: vaultSecret)
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
  /// (the server position is relative to it). The FETCH is one round trip, streamed:
  /// `readCapped` cuts each row as it arrives (`readLimits`, the read's own) and stops at the
  /// cap or the byte budget mid-FETCH. Raw rows not yet cut sit in PostgresNIO's row buffer,
  /// counted in rows (256 growing to 16,384, never past cap + 1), the same bound as `.read`.
  /// After a byte-budget stop the rest of the FETCH is discarded unread, so a runtime error in
  /// those rows aborts the transaction silently and surfaces as the CLOSE's "current transaction
  /// is aborted"; a cancel during that discard finds only the CLOSE in flight and resets.
  func executeCursorRead(
    _ query: String, maxRows: Int, startTime: Date, binds: [SQLBindValue] = [],
    readLimits perRead: CappedReadLimits? = nil
  ) async throws -> QueryResult {
    let cursor: SessionCursor
    do {
      cursor = try await withSession { session in
        try await session.openCursor(query, binds: binds)
      }
    } catch {
      throw unwrapFailure(error, fallbackSQL: query, startTime: startTime)
    }
    let fetchCount = maxRows + 1
    let fetchSQL = PostgresSession.fetchSQL(name: cursor.name, maxRows: fetchCount)
    let collected: CollectedRows
    do {
      // The source lives only inside this closure: once `readCapped` stops (cap or byte budget
      // mid-FETCH), its iterator and the source are released here, before the CLOSE below is
      // sent. Releasing the session's row stream ends the FETCH (`RowPull` deinit ends the
      // statement, and PostgresNIO cancels the row stream and discards its remaining rows), as
      // a drained `.read` does. PostgresNIO runs one statement at a time, so the CLOSE starts
      // once those rows are discarded. A source kept past this point would leave a FETCH nobody
      // reads in front of the CLOSE, which would then wait forever.
      collected = try await withSession { session in
        let source = try await session.fetch(cursor, maxRows: fetchCount)
        return try await self.readCapped(
          source, maxRows: maxRows, readToEnd: false, limits: perRead)
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
    result.cutCells = collected.cutCells
    result.stoppedAtByteBudget = collected.stoppedAtByteBudget
    cursorReadCount += 1
    return result
  }

  /// Test hook (see `scriptCheckpointHook`): lets a test interleave other callers at a
  /// `ScriptCheckpoint`. Nil in the app.
  func setScriptCheckpointHook(_ hook: (@Sendable (ScriptCheckpoint) async -> Void)?) {
    scriptCheckpointHook = hook
  }

  /// A plain read a cursor can run: SELECT / VALUES / TABLE / WITH (not SHOW or EXPLAIN) that
  /// calls no function (its side effects would stop at the cap) and locks no rows. Lexed with
  /// `dialect`.
  nonisolated static func usesCursor(
    _ statement: ClassifiedStatement, dialect: SQLDialect
  ) -> Bool {
    guard statement.kind == .read else { return false }
    let tokens = SQLTokenizer.tokens(statement.text, dialect: dialect)
    let first = tokens.first { $0.kind == .word }?.keyword ?? ""
    return ["SELECT", "VALUES", "TABLE", "WITH"].contains(first)
      && !SQLStatementClassifier.mayCallFunctions(statement.text, dialect: dialect)
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

  /// MySQL stops a read left at the cap with KILL QUERY (the session stays), which would abort a
  /// read that must drain (`mustDrain`) and roll back what it wrote: that read is read to the
  /// end instead, rows past the cap counted but not kept. Other engines break at the cap.
  nonisolated static func readsToEndAtCap(
    _ statement: ClassifiedStatement?, databaseType: DatabaseType?
  ) -> Bool {
    guard databaseType == .mysql, let statement else { return false }
    return mustDrain(statement, dialect: .mysql)
  }

  /// EXPLAIN ANALYZE runs its statement, and a called function may write: closing before the
  /// result completes would abort the statement and roll back what it changed in autocommit.
  private nonisolated static func mustDrain(
    _ statement: ClassifiedStatement, dialect: SQLDialect
  ) -> Bool {
    if case .explain(_, analyze: true) = statement.kind { return true }
    return SQLStatementClassifier.mayCallFunctions(statement.text, dialect: dialect)
  }
}
