// DatabaseConnectionManager+EditTransaction.swift
// Inline grid edits must update exactly one row. Protected mode runs the edit in the app
// transaction behind an app-owned savepoint; without Protected mode the edit gets its own
// app-owned BEGIN ... COMMIT, or runs inside the transaction the user opened.
// A staged batch uses the same rules behind savepoint `dblore_batch`, one summary per statement
// (a SQL dump restore pulls its statements one at a time and records one per statement kind);
// a streamed batch (Generate Rows, Copy Objects) too, with one summary per run plus one per
// prelude and postlude statement.
// MySQL counts changed rows (CLIENT_FOUND_ROWS is off): an UPDATE with a row check that
// affects 0 rows counts as 1 when a locking read still finds the row (a same-value write).
// A `RewindPlan` adds the Data Rewind reads around each statement (`+Rewind.swift`); without
// one the statements sent are unchanged.

import Foundation

extension DatabaseConnectionManager {
  /// App-owned savepoint around one inline edit (user-typed SAVEPOINT stays blocked)
  static let editSavepoint = "dblore_edit"
  /// App-owned savepoint around one staged batch (not reused for a single-cell edit)
  static let batchSavepoint = "dblore_batch"
  /// Start of a batch failure's reason when a statement affected another row count
  static let unexpectedRowCountReason = "expected to affect "

  /// Restore-only hook of a staged batch (PostgreSQL): right after SAVEPOINT / BEGIN the
  /// user's search_path is read and pinned to `pg_catalog, pg_temp`, so a planted function or
  /// operator on that path never binds into restored objects; right before RELEASE / COMMIT the
  /// read value is put back (bound, `is_local` true). `RELEASE` keeps a `SET LOCAL`, so the
  /// put-back is what ends the pin on success; on failure `ROLLBACK TO SAVEPOINT` (or ROLLBACK)
  /// undoes it. None of these statements is recorded, counted or numbered with the batch.
  struct SearchPathPin: Sendable {
    static let readSQL = "SELECT pg_catalog.current_setting('search_path'::pg_catalog.text)"
    static let pinSQL = CopyObjectsRun.postgresPinnedSearchPath
    static let putBackSQL =
      "SELECT pg_catalog.set_config('search_path'::pg_catalog.text, $1, true)"
    /// Appended to a batch statement's error with one of `hintSQLStates` while the pin is active
    static let hint =
      "During a restore, functions and triggers run with search_path = pg_catalog, pg_temp: "
      + "if one of them uses an unqualified name, qualify it or set its search_path"
    /// Undefined function, table or object: a server-side body that used an unqualified name
    static let hintSQLStates: Set<String> = ["42883", "42P01", "42704"]
  }

  func setBatchCheckpointHook(_ hook: (@Sendable (Int) async -> Void)?) {
    batchCheckpointHook = hook
  }

  /// Protected mode: adopt an open user transaction or open the app transaction (no second
  /// BEGIN), then run the edit between `SAVEPOINT dblore_edit` and `RELEASE SAVEPOINT`, and record
  /// it as pending. When the edit fails or does not update exactly one row it is undone with
  /// `ROLLBACK TO SAVEPOINT`: the transaction and its other pending changes stay intact (not
  /// aborted), nothing is recorded, and a transaction opened by this edit alone is rolled back.
  /// With `rewind`, the entry is recorded pending after RELEASE (Commit decides).
  /// A cancel that interrupted the edit is reconciled like a statement's
  /// (`cancelErrorAfterInterrupt`): when it rolled the transaction back there is no savepoint
  /// left to undo.
  /// - Throws: `DatabaseError.editRowCountMismatch(rolledBack: true)`; the edit's error; a
  ///   savepoint failure (the transaction then follows `transactionFailure`);
  ///   `DatabaseError.queryCancelled`.
  func runProtectedEdit(
    _ statement: CellUpdateStatement, classified: ClassifiedStatement?, caller: UUID?,
    rewind: RewindPlan? = nil
  ) async throws -> Int {
    let epoch = connectionEpoch
    let generation = batchCancellationGeneration
    try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
    let opens = txState.isIdle
    if opens { try await beginAppTransaction(caller: caller) }
    do {
      try await sendSavepoint(Self.editSavepoint)
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    var capture = startRewindCapture(rewind, statementCount: 1)
    let rows: Int
    do {
      rows = try await sendEdit(statement, capture: &capture)
    } catch {
      if let cancelled = await cancelErrorAfterInterrupt(since: epoch, generation: generation) {
        if txState.isIdle { throw cancelled }
        throw await undoEdit(cancelled, openedHere: opens)
      }
      throw await undoEdit(error, openedHere: opens)
    }
    guard rows == 1 else {
      throw await undoEdit(
        DatabaseError.editRowCountMismatch(updated: rows, rolledBack: true), openedHere: opens)
    }
    do {
      try await releaseSavepoint(Self.editSavepoint)
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    recordRewind(capture, committed: false)
    if let classified {
      recordPending(
        StatementSummary(
          statement: classified, affectedRows: rows, dialect: Self.dialect(of: config)))
    }
    return rows
  }

  /// Protected mode off. No user transaction: the edit runs in its own app-owned
  /// `BEGIN ... COMMIT` (never a pending transaction); a failure or a row count other than 1 is
  /// rolled back. With a user transaction open (`userTxOpen`): no nested BEGIN, the edit runs
  /// inside it and a row count other than 1 is reported WITHOUT rolling back the user's
  /// transaction (the user decides; an edit error leaves it aborted on the server, as any failing
  /// statement would). With `rewind`, the entry is recorded committed after the app's COMMIT,
  /// or pending inside the user's transaction (the user's COMMIT / ROLLBACK decides). A cancel
  /// that interrupted the edit inside the user's transaction is reconciled like a statement's
  /// (`cancelErrorAfterInterrupt`).
  /// - Throws: `DatabaseError.editRowCountMismatch`; the edit or COMMIT error;
  ///   `DatabaseError.queryCancelled`.
  func runUnprotectedEdit(
    _ statement: CellUpdateStatement, rewind: RewindPlan? = nil
  ) async throws -> Int {
    var capture = startRewindCapture(rewind, statementCount: 1)
    if userTxOpen {
      let epoch = connectionEpoch
      let generation = batchCancellationGeneration
      let rows: Int
      do {
        rows = try await sendEdit(statement, capture: &capture)
      } catch {
        discardUserEntriesIfLost(capture)
        throw await cancelErrorAfterInterrupt(since: epoch, generation: generation) ?? error
      }
      guard rows == 1 else {
        throw DatabaseError.editRowCountMismatch(updated: rows, rolledBack: false)
      }
      recordRewind(capture, committed: false)
      return rows
    }
    try await refuseUntrackedServerTransaction()
    _ = try await sendTransactionControl(appOwnedBeginSQL)
    let rows: Int
    do {
      rows = try await sendEdit(statement, capture: &capture)
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw error
    }
    guard rows == 1 else {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw DatabaseError.editRowCountMismatch(updated: rows, rolledBack: true)
    }
    let metadata = try await sendTransactionControl("COMMIT")
    guard metadata.tag == "COMMIT" else {
      throw DatabaseError.transactionAborted(
        "The server rolled back the edit instead of saving it.")
    }
    try await requireOwnCommitFinished()
    recordRewind(capture, committed: true)
    return rows
  }

  /// Staged batch. Protected mode: adopt or begin the app transaction, run every statement
  /// inside `SAVEPOINT dblore_batch`, check each statement's expected rows, then `RELEASE` and
  /// record one pending summary per statement. A failure or any other row count rolls back to
  /// the savepoint (nothing from the batch is recorded) and names the statement. A transaction
  /// this batch opened, with nothing else pending, is rolled back the way `undoEdit` does.
  /// Unprotected, no user transaction: `BEGIN`, run each, `COMMIT`; any failure rolls the batch
  /// back (a COMMIT that fails is followed by ROLLBACK). Unprotected with a user transaction
  /// already open: use a savepoint so a failed chunk cannot leave earlier chunks committable.
  /// A cancel whose interrupt rolled that transaction back leaves nothing to undo
  /// (`throwIfInterruptRolledBack`). `progress` gets the number of statements done after each
  /// one (SQL dump restore).
  /// `rewind` (one step per statement) records the Data Rewind entry after RELEASE / COMMIT:
  /// committed after the app's own COMMIT, else pending until the transaction ends. The
  /// `rewinding` entries become rewound at the same points (`recordRewound`).
  /// `searchPathPin` (PostgreSQL restore only) wraps the statements in the pin, inside the
  /// savepoint or the batch's own transaction; a failing read (no row or NULL), pin or put-back
  /// fails the batch and rolls it back like a failing statement.
  func runStagedBatch(
    _ statements: [BoundStatement], caller: UUID?, protectedMode: Bool,
    cancellationGeneration: UInt64, progress: (@Sendable (Int) -> Void)? = nil,
    rewind: RewindPlan? = nil, rewinding: [Int64] = [], searchPathPin: SearchPathPin? = nil
  ) async throws -> [Int] {
    var remaining = statements.makeIterator()
    var counts: [Int] = []
    counts.reserveCapacity(statements.count)
    _ = try await runStagedBatch(
      count: statements.count, next: { remaining.next() }, caller: caller,
      protectedMode: protectedMode, cancellationGeneration: cancellationGeneration,
      progress: progress, rewind: rewind, rewinding: rewinding, searchPathPin: searchPathPin,
      ran: { counts.append($0) }, recordSummaries: { recordBatch(statements, counts: counts) },
      noteSchema: { noteSchemaSQL(statements) })
    return counts
  }

  /// The staged batch over statements `next` hands out one at a time inside the batch's
  /// transaction, after the pin (`count`: how many, for the Data Rewind capture). The batch pulls
  /// until `next` returns nil before it releases or commits; a throw from `next` rolls the batch
  /// back like a failing statement and is thrown as is. Nothing is kept per statement here: `ran`
  /// gets each statement's row count once it ran, `recordSummaries` records the Protected-mode
  /// pending summaries (after RELEASE) and `noteSchema` notes the schema changes (after RELEASE
  /// or COMMIT). Returns the statements run.
  func runStagedBatch(
    count: Int, next: () throws -> BoundStatement?, caller: UUID?, protectedMode: Bool,
    cancellationGeneration: UInt64, progress: (@Sendable (Int) -> Void)? = nil,
    rewind: RewindPlan? = nil, rewinding: [Int64] = [], searchPathPin: SearchPathPin? = nil,
    ran: (Int) -> Void, recordSummaries: () -> Void, noteSchema: () -> Void
  ) async throws -> Int {
    // User writes: refused after a DuckDB interrupt cancel since admission (`withSession`)
    let admission = UserStatementAdmission(
      epoch: connectionEpoch, generation: cancellationGeneration)
    return try await Self.$userStatementAdmission.withValue(admission) {
      if protectedMode {
        return try await runProtectedBatch(
          count: count, next: next, caller: caller,
          cancellationGeneration: cancellationGeneration, progress: progress, rewind: rewind,
          rewinding: rewinding, searchPathPin: searchPathPin, ran: ran,
          recordSummaries: recordSummaries, noteSchema: noteSchema)
      }
      return try await runUnprotectedBatch(
        count: count, next: next, cancellationGeneration: cancellationGeneration,
        progress: progress, rewind: rewind, rewinding: rewinding, searchPathPin: searchPathPin,
        ran: ran, noteSchema: noteSchema)
    }
  }

  /// One `ImportMatchPlanner` read of a keyed import, on this session before the import's
  /// batch opens a transaction: `(position, count)` rows. Refused while any transaction is
  /// open (a failing read would abort it, and its uncommitted rows would decide the match),
  /// and unless `ReadOnlyQueryGuard` passes the SQL. A read that hits the row cap fails rather
  /// than drop positions.
  func readImportMatches(_ read: BoundStatement) async throws -> [[CellValue]] {
    try refuseIfRelocked(config)
    guard isOutsideAnyTransaction else {
      throw DatabaseError.queryFailed(
        "Commit or roll back the open transaction before matching rows to the table.", 0)
    }
    _ = try ReadOnlyQueryGuard.check(read.sql, dialect: Self.dialect(of: config))
    let result = try await executeSingleStatement(
      read.sql, maxRows: ImportMatchPlanner.maxRowsPerRead + 1, binds: read.binds)
    guard !result.truncated, result.rows.count <= ImportMatchPlanner.maxRowsPerRead else {
      throw DatabaseError.queryFailed("The match read returned more rows than it lists.", 0)
    }
    return result.rows
  }

  /// PostgreSQL current_schema() for an import with no Schema (`TableImportModel.prepareBatch`):
  /// nil when it is NULL (no schema of the search_path exists). Refused while relocked. Allowed
  /// in a transaction, since the import runs in it (a SET LOCAL search_path counts). Runs with
  /// the user's search_path (the schema it resolves is the point), so the function names
  /// pg_catalog.
  func readImportCurrentSchema() async throws -> String? {
    try refuseIfRelocked(config)
    let result = try await executeSingleStatement(
      "SELECT pg_catalog.current_schema()", maxRows: 1)
    guard case .string(let schema)? = result.rows.first?.first else { return nil }
    return schema
  }

  /// One `GenerateRowsPlanner` read (a key's current MAX, or referenced keys), refused and
  /// guarded as `readImportMatches` is: on this session before the run's streamed batch opens a
  /// transaction. A read past its purpose's row count fails rather than drop keys.
  func readGenerateRows(_ read: GenerateRowsPlanner.Read) async throws -> [[CellValue]] {
    try refuseGenerateRowsRead()
    _ = try ReadOnlyQueryGuard.check(read.statement.sql, dialect: Self.dialect(of: config))
    let maxRows =
      switch read.purpose {
      case .currentMax: 1
      case .referencedKeys: GenerateRowsPlanner.maxSampledKeys
      }
    // `truncated`: a row past `maxRows`, or the byte budget cut one
    let result = try await executeSingleStatement(
      read.statement.sql, maxRows: maxRows, binds: read.statement.binds)
    guard !result.truncated else {
      throw DatabaseError.queryFailed("The read for generated rows returned too many rows.", 0)
    }
    return result.rows
  }

  /// The labels of each PostgreSQL enum column of `structure`, by column name in label order
  /// (`GenerateRowsPlanner.plan(enumLabels:)`); empty on other engines. The table OID is bound,
  /// never a name, and the read is refused as `readGenerateRows` is. It runs with the user's
  /// search_path, so every catalog name, operator and cast type names pg_catalog.
  func readGenerateRowsEnumLabels(_ structure: TableStructure) async throws -> [String: [String]] {
    guard let oid = structure.tableID.postgresOID else { return [:] }
    try refuseGenerateRowsRead()
    let result = try await executeSingleStatement(
      """
      SELECT a.attname::pg_catalog.text, e.enumlabel::pg_catalog.text
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_enum e ON e.enumtypid OPERATOR(pg_catalog.=) a.atttypid
      WHERE a.attrelid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
        AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
      ORDER BY a.attnum, e.enumsortorder
      """, maxRows: GenerateRowsPlanner.maxSampledKeys, binds: [.text(String(oid))])
    guard !result.truncated else {
      throw DatabaseError.queryFailed("The read for generated rows returned too many rows.", 0)
    }
    var labels: [String: [String]] = [:]
    for row in result.rows {
      guard row.count == 2, case .string(let column) = row[0], case .string(let label) = row[1]
      else { continue }
      labels[column, default: []].append(label)
    }
    return labels
  }

  /// A Generate Rows read runs on this session before the run's transaction: refused while
  /// relocked or while any transaction is open (a pending Protected-mode one too)
  private func refuseGenerateRowsRead() throws {
    try refuseIfRelocked(config)
    guard isOutsideAnyTransaction else {
      throw DatabaseError.queryFailed(
        "Commit or roll back the open transaction before generating rows.", 0)
    }
  }

  /// Streamed batch (`executeGatedBatch(streamed:)`): the staged batch's transaction rules
  /// (savepoint `dblore_batch` in Protected mode or inside the user's transaction, else its own
  /// BEGIN ... COMMIT), its `cancellationGeneration` check and `progress` (chunks done).
  /// `prelude` and `postlude` (already checked by the gate) run before the first and after the
  /// last chunk inside that transaction, and are noted as schema SQL once it succeeds. No Data
  /// Rewind capture; Protected mode records one pending summary for the rows ("INSERT INTO
  /// <relation>: N <rowsLabel>") between those of the prelude and the postlude, so memory
  /// stays bounded whatever the row count. Each chunk is checked against `policy`, the effective
  /// one.
  func runStreamedBatch(
    _ source: StreamedBatch, caller: UUID?, policy: ProtectionPolicy,
    cancellationGeneration: UInt64, prelude: [BoundStatement] = [],
    postlude: [BoundStatement] = [], progress: (@Sendable (Int) -> Void)?
  ) async throws -> Int {
    let admission = UserStatementAdmission(
      epoch: connectionEpoch, generation: cancellationGeneration)
    return try await Self.$userStatementAdmission.withValue(admission) {
      let epoch = connectionEpoch
      if policy.protectedMode {
        try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
        let opens = txState.isIdle
        if opens { try await beginAppTransaction(caller: caller) }
        do {
          try await sendSavepoint(Self.batchSavepoint)
        } catch {
          throw await transactionFailure(error, openedHere: opens)
        }
        let rows: Int
        do {
          rows = try await applyStreamedBatch(
            source, policy: policy, cancellationGeneration: cancellationGeneration,
            prelude: prelude, postlude: postlude, progress: progress)
        } catch {
          try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
          throw await undoBatch(error, openedHere: opens)
        }
        do {
          try await releaseSavepoint(Self.batchSavepoint)
        } catch {
          throw await transactionFailure(error, openedHere: opens)
        }
        let dialect = Self.dialect(of: config)
        recordBatch(prelude, counts: Array(repeating: 0, count: prelude.count))
        if let summary = SQLStatementClassifier.classifyStatement(
          "INSERT INTO \(source.relation): \(rows) \(source.rowsLabel)", dialect: dialect)
        {
          recordPending(StatementSummary(statement: summary, affectedRows: rows, dialect: dialect))
        }
        recordBatch(postlude, counts: Array(repeating: 0, count: postlude.count))
        noteSchemaSQL(prelude + postlude)
        return rows
      }
      if userTxOpen {
        try await sendSavepoint(Self.batchSavepoint)
        let rows: Int
        do {
          rows = try await applyStreamedBatch(
            source, policy: policy, cancellationGeneration: cancellationGeneration,
            prelude: prelude, postlude: postlude, progress: progress)
        } catch {
          try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
          throw await undoBatch(error, openedHere: false)
        }
        try await releaseSavepoint(Self.batchSavepoint)
        noteSchemaSQL(prelude + postlude)
        return rows
      }
      try await refuseUntrackedServerTransaction()
      _ = try await sendTransactionControl(appOwnedBeginSQL)
      let rows: Int
      do {
        rows = try await applyStreamedBatch(
          source, policy: policy, cancellationGeneration: cancellationGeneration,
          prelude: prelude, postlude: postlude, progress: progress)
      } catch {
        _ = try? await sendTransactionControl("ROLLBACK")
        throw error
      }
      try await commitOwnBatch()
      noteSchemaSQL(prelude + postlude)
      return rows
    }
  }

  // MARK: - Private

  private func runProtectedBatch(
    count: Int, next: () throws -> BoundStatement?, caller: UUID?,
    cancellationGeneration: UInt64, progress: (@Sendable (Int) -> Void)?, rewind: RewindPlan?,
    rewinding: [Int64], searchPathPin: SearchPathPin?, ran: (Int) -> Void,
    recordSummaries: () -> Void, noteSchema: () -> Void
  ) async throws -> Int {
    let epoch = connectionEpoch
    try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
    let opens = txState.isIdle
    if opens { try await beginAppTransaction(caller: caller) }
    do {
      try await sendSavepoint(Self.batchSavepoint)
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    var capture = startRewindCapture(rewind, statementCount: count)
    let done: Int
    do {
      let userSearchPath = try await pinSearchPath(searchPathPin)
      done = try await applyBatch(
        next, rolledBack: true, cancellationGeneration: cancellationGeneration,
        progress: progress, capture: &capture, searchPathPinned: userSearchPath != nil, ran: ran)
      try refuseCancelledBatch(since: cancellationGeneration)
      try await putBackSearchPath(userSearchPath)
    } catch {
      try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
      throw await undoBatch(error, openedHere: opens)
    }
    do {
      try await releaseSavepoint(Self.batchSavepoint)
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    recordSummaries()
    recordRewind(capture, committed: false)
    recordRewound(rewinding, committed: false)
    noteSchema()
    return done
  }

  private func runUnprotectedBatch(
    count: Int, next: () throws -> BoundStatement?, cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?, rewind: RewindPlan?, rewinding: [Int64],
    searchPathPin: SearchPathPin?, ran: (Int) -> Void, noteSchema: () -> Void
  ) async throws -> Int {
    var capture = startRewindCapture(rewind, statementCount: count)
    if userTxOpen {
      let epoch = connectionEpoch
      try await sendSavepoint(Self.batchSavepoint)
      let done: Int
      do {
        let userSearchPath = try await pinSearchPath(searchPathPin)
        done = try await applyBatch(
          next, rolledBack: true, cancellationGeneration: cancellationGeneration,
          progress: progress, capture: &capture, searchPathPinned: userSearchPath != nil,
          ran: ran)
        try refuseCancelledBatch(since: cancellationGeneration)
        try await putBackSearchPath(userSearchPath)
      } catch {
        discardUserEntriesIfLost(capture)
        try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
        throw await undoBatch(error, openedHere: false)
      }
      try await releaseSavepoint(Self.batchSavepoint)
      recordRewind(capture, committed: false)
      recordRewound(rewinding, committed: false)
      noteSchema()
      return done
    }
    try await refuseUntrackedServerTransaction()
    _ = try await sendTransactionControl(appOwnedBeginSQL)
    let done: Int
    do {
      let userSearchPath = try await pinSearchPath(searchPathPin)
      done = try await applyBatch(
        next, rolledBack: true, cancellationGeneration: cancellationGeneration,
        progress: progress, capture: &capture, searchPathPinned: userSearchPath != nil, ran: ran)
      try refuseCancelledBatch(since: cancellationGeneration)
      try await putBackSearchPath(userSearchPath)
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw error
    }
    try await commitOwnBatch()
    recordRewind(capture, committed: true)
    recordRewound(rewinding, committed: true)
    noteSchema()
    return done
  }

  /// COMMIT of a batch's own BEGIN; a COMMIT that fails or is answered with a rollback is
  /// followed by ROLLBACK.
  private func commitOwnBatch() async throws {
    // SQLite keeps the transaction open after a deferred foreign key failure at COMMIT: without
    // the ROLLBACK its write lock would stay held while nothing tracks the transaction
    let metadata: CommandResult
    do {
      metadata = try await sendTransactionControl("COMMIT")
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw error
    }
    guard metadata.tag == "COMMIT" else {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw DatabaseError.transactionAborted(
        "The server rolled back the batch instead of saving it.")
    }
    try await requireOwnCommitFinished()
  }

  /// With `pin`: the user's search_path (`SearchPathPin.readSQL`, fails closed on no row or
  /// NULL), then the pin. Nil without `pin`, and nothing is sent.
  private func pinSearchPath(_ pin: SearchPathPin?) async throws -> String? {
    guard pin != nil else { return nil }
    guard let row = try await readTransactionRow(SearchPathPin.readSQL), row.count == 1,
      case .string(let userSearchPath) = row[0]
    else {
      throw DatabaseError.queryFailed(
        "The restore could not read the session's search_path. Nothing was restored.", 0)
    }
    _ = try await sendTransactionControl(SearchPathPin.pinSQL)
    return userSearchPath
  }

  /// The value `pinSearchPath` read, put back for the rest of the transaction (none: nothing)
  private func putBackSearchPath(_ userSearchPath: String?) async throws {
    guard let userSearchPath else { return }
    _ = try await sendTransactionControl(SearchPathPin.putBackSQL, binds: [.text(userSearchPath)])
  }

  /// Pull each statement from `next` until it returns nil, send it and check its expected
  /// affected rows when set; `ran` gets its count. The caller owns the transaction. A throw from
  /// `next` is thrown as is (a cancel meanwhile as `batchCancelled`). `rolledBack` is only the
  /// flag on the thrown error. With a `capture`, each statement's row is read right before and
  /// right after it. `searchPathPinned`: a statement error gets `SearchPathPin.hint`
  /// (`commandResult`). Returns the statements run.
  private func applyBatch(
    _ next: () throws -> BoundStatement?, rolledBack: Bool, cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?, capture: inout RewindCapture?,
    searchPathPinned: Bool = false, ran: (Int) -> Void
  ) async throws -> Int {
    var index = 0
    while true {
      try refuseCancelledBatch(since: cancellationGeneration)
      let pulled: BoundStatement?
      do {
        pulled = try next()
      } catch {
        try refuseCancelledBatch(since: cancellationGeneration)
        throw error
      }
      guard let statement = pulled else { return index }
      let rows: Int
      do {
        // A capture read that throws lost the transaction: fail as the statement would
        try await captureBefore(index, into: &capture)
        rows = try await sendBound(statement, searchPathPinned: searchPathPinned)
      } catch {
        try refuseCancelledBatch(since: cancellationGeneration)
        throw Self.batchStatementFailed(
          index, sql: statement.sql, underlying: error, rolledBack: rolledBack)
      }
      await batchCheckpointHook?(index)
      try refuseCancelledBatch(since: cancellationGeneration)
      if let expected = statement.expectedRows, rows != expected {
        let reason =
          Self.unexpectedRowCountReason
          + "\(expected) row\(expected == 1 ? "" : "s"), affected \(rows)"
        throw Self.batchStatementFailed(
          index, sql: statement.sql, reason: reason, rolledBack: rolledBack)
      }
      do {
        try await captureAfter(index, into: &capture)
      } catch {
        throw Self.batchStatementFailed(
          index, sql: statement.sql, underlying: error, rolledBack: rolledBack)
      }
      // SQLite's sqlite3_changes64 can retain the previous DML count after CREATE TABLE.
      let isDDL = classification(of: statement)?.kind == .ddl
      ran(statement.expectedRows == nil && isDDL ? 0 : rows)
      index += 1
      progress?(index)
    }
  }

  /// Send `prelude`, then make, check and send each chunk of `source` in turn, then `postlude`;
  /// the caller owns the transaction. A relock or a cancel stops the run before the next chunk
  /// is made, and a chunk that is not DML or that `policy` forbids before it is sent. Each
  /// statement's expected rows are checked as `applyBatch` does, and a failure names it by its
  /// index in the run (prelude first). Returns the rows the chunks sent.
  private func applyStreamedBatch(
    _ source: StreamedBatch, policy: ProtectionPolicy, cancellationGeneration: UInt64,
    prelude: [BoundStatement], postlude: [BoundStatement], progress: (@Sendable (Int) -> Void)?
  ) async throws -> Int {
    let dialect = Self.dialect(of: config)
    var index = 0
    var rows = 0
    var chunks = 0
    try await sendFraming(prelude, from: &index, cancellationGeneration: cancellationGeneration)
    while true {
      try refuseCancelledBatch(since: cancellationGeneration)
      try refuseIfRelocked(config)
      let chunk = try await source.nextChunk()
      try refuseCancelledBatch(since: cancellationGeneration)
      guard let chunk else {
        try await sendFraming(
          postlude, from: &index, cancellationGeneration: cancellationGeneration)
        return rows
      }
      for (offset, statement) in chunk.enumerated() {
        let classified = SQLStatementClassifier.classify(statement.sql, dialect: dialect)
        guard classified.count == 1, classified[0].kind == .dml else {
          throw DatabaseError.blockedByProtection(
            statementIndex: index + offset, kind: classified.first?.kind ?? .unknown,
            reason: "Generated rows are sent only as INSERT statements")
        }
        if case .blocked(_, let kind, let reason) = Self.evaluate(
          classified, policy: policy, dialect: dialect)
        {
          throw DatabaseError.blockedByProtection(
            statementIndex: index + offset, kind: kind, reason: reason)
        }
      }
      for statement in chunk {
        let count: Int
        do {
          count = try await sendBound(statement)
        } catch {
          try refuseCancelledBatch(since: cancellationGeneration)
          throw Self.batchStatementFailed(
            index, sql: statement.sql, underlying: error, rolledBack: true)
        }
        await batchCheckpointHook?(index)
        try refuseCancelledBatch(since: cancellationGeneration)
        if let expected = statement.expectedRows, count != expected {
          let reason =
            Self.unexpectedRowCountReason
            + "\(expected) row\(expected == 1 ? "" : "s"), affected \(count)"
          throw Self.batchStatementFailed(
            index, sql: statement.sql, reason: reason, rolledBack: true)
        }
        rows += count
        index += 1
      }
      chunks += 1
      progress?(chunks)
    }
  }

  /// A streamed batch's prelude or postlude, statement by statement from run index `index`
  /// (advanced past them); a relock or a cancel stops it before the next statement
  private func sendFraming(
    _ statements: [BoundStatement], from index: inout Int, cancellationGeneration: UInt64
  ) async throws {
    for statement in statements {
      try refuseCancelledBatch(since: cancellationGeneration)
      try refuseIfRelocked(config)
      let count: Int
      do {
        count = try await sendBound(statement)
      } catch {
        try refuseCancelledBatch(since: cancellationGeneration)
        throw Self.batchStatementFailed(
          index, sql: statement.sql, underlying: error, rolledBack: true)
      }
      try refuseCancelledBatch(since: cancellationGeneration)
      if let expected = statement.expectedRows, count != expected {
        let reason =
          Self.unexpectedRowCountReason
          + "\(expected) row\(expected == 1 ? "" : "s"), affected \(count)"
        throw Self.batchStatementFailed(
          index, sql: statement.sql, reason: reason, rolledBack: true)
      }
      index += 1
    }
  }

  /// Inside the user's transaction, a capture read that lost it (MySQL rolls it back whole on
  /// a deadlock) took the earlier statements with it: their Data Rewind entries are discarded,
  /// so the user's later COMMIT (answered OK with no transaction left) cannot commit them.
  private func discardUserEntriesIfLost(_ capture: RewindCapture?) {
    if capture?.transactionLost == true { closeRewindEntries(as: .discarded) }
  }

  /// The same for a statement's own error (an edit, a batch or a typed statement; called from
  /// `queryFailure`): a MySQL deadlock (ER_LOCK_DEADLOCK) rolls the user's transaction back
  /// whole, so it is no longer open either. A lock wait timeout (1205) undoes the statement
  /// alone. Checked on the raw error: the thrown `DatabaseError` keeps only its text.
  func discardUserEntriesIfRolledBack(_ error: Error) {
    guard userTxOpen, (error as? MySQLSessionError)?.code == 1213 else { return }
    userTxOpen = false
    schemaDirtyInUserTx = false
    closeRewindEntries(as: .discarded)
  }

  /// A cancel stopped the batch: reconciled like a statement's (`cancelErrorAfterInterrupt`).
  /// When the interrupt rolled the whole transaction back (SQLite stopping a write), there is no
  /// savepoint left to undo: throws `DatabaseError.queryCancelled`, saying what was rolled back.
  private func throwIfInterruptRolledBack(since epoch: UInt64, generation: UInt64) async throws {
    guard let cancelled = await cancelErrorAfterInterrupt(since: epoch, generation: generation),
      txState.isIdle, !userTxOpen
    else { return }
    throw cancelled
  }

  private func refuseCancelledBatch(since generation: UInt64) throws {
    guard batchCancellationGeneration == generation else {
      throw DatabaseError.batchCancelled
    }
  }

  private func recordBatch(_ statements: [BoundStatement], counts: [Int]) {
    let dialect = Self.dialect(of: config)
    for (index, statement) in statements.enumerated() {
      guard let classified = classification(of: statement) else { continue }
      recordPending(
        StatementSummary(statement: classified, affectedRows: counts[index], dialect: dialect))
    }
  }

  /// The dialect's savepoint `name` (`SAVEPOINT`, SQL Server `SAVE TRANSACTION`)
  private func sendSavepoint(_ name: String) async throws {
    _ = try await sendTransactionControl(Self.dialect(of: config).savepointSQL(name))
  }

  /// The dialect's release of savepoint `name`; nothing on SQL Server, which has none
  private func releaseSavepoint(_ name: String) async throws {
    guard let sql = Self.dialect(of: config).releaseSavepointSQL(name) else { return }
    _ = try await sendTransactionControl(sql)
  }

  /// Undo the edit with `ROLLBACK TO SAVEPOINT` (+ `RELEASE`), the dialect's
  /// (`SQLDialect.rollbackToSavepointSQL`), and return `editError` to throw. A
  /// transaction this edit opened with nothing else pending is rolled back (back to idle). If
  /// the undo fails, the state follows `transactionFailure`.
  private func undoEdit(_ editError: Error, openedHere: Bool) async -> Error {
    await undoSavepoint(Self.editSavepoint, editError, openedHere: openedHere)
  }

  private func undoBatch(_ batchError: Error, openedHere: Bool) async -> Error {
    await undoSavepoint(Self.batchSavepoint, batchError, openedHere: openedHere)
  }

  private func undoSavepoint(_ name: String, _ editError: Error, openedHere: Bool) async -> Error {
    do {
      _ = try await sendTransactionControl(Self.dialect(of: config).rollbackToSavepointSQL(name))
      try await releaseSavepoint(name)
    } catch {
      return await transactionFailure(editError, openedHere: openedHere)
    }
    if openedHere, txState == .appTx(pending: []),
      (try? await sendTransactionControl("ROLLBACK")) != nil
    {
      txState = .idle
    }
    return editError
  }

  /// Send the app-built UPDATE (values as bind parameters) and return the command tag row count.
  /// With a `capture`, the row is read right before and, when one row was updated, right after.
  private func sendEdit(
    _ statement: CellUpdateStatement, capture: inout RewindCapture?
  ) async throws -> Int {
    try await captureBefore(0, into: &capture)
    let rows = try await affectedRows(sql: statement.sql, binds: statement.binds)
    let confirmed = try await confirmedRows(rows, check: statement.rowCheck)
    if confirmed == 1 { try await captureAfter(0, into: &capture) }
    return confirmed
  }

  private func sendBound(
    _ statement: BoundStatement, searchPathPinned: Bool = false
  ) async throws -> Int {
    let rows = try await commandResult(
      sql: statement.sql, binds: statement.binds, searchPathPinned: searchPathPinned
    ).affectedRows
    return try await confirmedRows(rows, check: statement.rowCheck)
  }

  /// `rows`, or 1 when the statement affected none and `check` still finds its row.
  private func confirmedRows(_ rows: Int, check: RowExistenceCheck?) async throws -> Int {
    guard rows == 0, let check else { return rows }
    let startTime = Date()
    do {
      let found = try await withSession { session in
        var found = false
        for try await _ in try await session.query(check.sql, binds: check.binds).rows {
          found = true
        }
        return found
      }
      return found ? 1 : 0
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw queryFailure(error, query: check.sql, startTime: startTime)
    }
  }

  func affectedRows(sql: String, binds: [SQLBindValue]) async throws -> Int {
    try await commandResult(sql: sql, binds: binds).affectedRows
  }

  /// The full reply of one command (MongoDB updates also carry `modifiedRows`).
  /// `searchPathPinned`: a server error with one of `SearchPathPin.hintSQLStates` gets
  /// `SearchPathPin.hint` appended.
  func commandResult(
    sql: String, binds: [SQLBindValue], searchPathPinned: Bool = false
  ) async throws -> CommandResult {
    let startTime = Date()
    do {
      return try await withSession { try await $0.command(sql, binds: binds) }
    } catch let error as DatabaseError {
      throw error
    } catch {
      let failure = queryFailure(error, query: sql, startTime: startTime)
      guard searchPathPinned, let state = Self.serverSQLState(error),
        SearchPathPin.hintSQLStates.contains(state),
        case .queryFailed(let message, let executionTime) = failure
      else { throw failure }
      throw DatabaseError.queryFailed(message + "\n\n" + SearchPathPin.hint, executionTime)
    }
  }

  private nonisolated static func batchStatementFailed(
    _ index: Int, sql: String, reason: String, rolledBack: Bool
  ) -> DatabaseError {
    .batchStatementFailed(
      index: index, sqlPrefix: batchSQLPrefix(sql), reason: reason, rolledBack: rolledBack)
  }

  private nonisolated static func batchStatementFailed(
    _ index: Int, sql: String, underlying: Error, rolledBack: Bool
  ) -> DatabaseError {
    let reason =
      (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    return batchStatementFailed(index, sql: sql, reason: reason, rolledBack: rolledBack)
  }

  private nonisolated static func batchSQLPrefix(_ sql: String) -> String {
    let limit = 80
    let collapsed = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
  }
}
