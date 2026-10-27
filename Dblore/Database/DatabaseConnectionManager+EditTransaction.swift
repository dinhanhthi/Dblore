// DatabaseConnectionManager+EditTransaction.swift
// Inline grid edits must update exactly one row. Protected mode runs the edit in the app
// transaction behind an app-owned savepoint; without Protected mode the edit gets its own
// app-owned BEGIN ... COMMIT, or runs inside the transaction the user opened.
// A staged batch uses the same rules behind savepoint `dblore_batch`, one summary per statement;
// a streamed batch (Generate Rows) too, with one summary per run.
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
      _ = try await sendTransactionControl("SAVEPOINT \(Self.editSavepoint)")
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
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.editSavepoint)")
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
  func runStagedBatch(
    _ statements: [BoundStatement], caller: UUID?, protectedMode: Bool,
    cancellationGeneration: UInt64, progress: (@Sendable (Int) -> Void)? = nil,
    rewind: RewindPlan? = nil, rewinding: [Int64] = []
  ) async throws -> [Int] {
    // User writes: refused after a DuckDB interrupt cancel since admission (`withSession`)
    let admission = UserStatementAdmission(
      epoch: connectionEpoch, generation: cancellationGeneration)
    return try await Self.$userStatementAdmission.withValue(admission) {
      if protectedMode {
        return try await runProtectedBatch(
          statements, caller: caller, cancellationGeneration: cancellationGeneration,
          progress: progress, rewind: rewind, rewinding: rewinding)
      }
      return try await runUnprotectedBatch(
        statements, cancellationGeneration: cancellationGeneration, progress: progress,
        rewind: rewind, rewinding: rewinding)
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
  /// never a name, and the read is refused as `readGenerateRows` is.
  func readGenerateRowsEnumLabels(_ structure: TableStructure) async throws -> [String: [String]] {
    guard let oid = structure.tableID.postgresOID else { return [:] }
    try refuseGenerateRowsRead()
    let result = try await executeSingleStatement(
      """
      SELECT a.attname::text, e.enumlabel::text
      FROM pg_attribute a JOIN pg_enum e ON e.enumtypid = a.atttypid
      WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
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
  /// BEGIN ... COMMIT), its `cancellationGeneration` check and `progress` (chunks done). No Data
  /// Rewind capture and no schema note (INSERT only); Protected mode records one pending summary
  /// for the run ("INSERT INTO <relation>: N generated rows"), so memory stays bounded whatever
  /// the row count. Each chunk is checked against `policy`, the effective one.
  func runStreamedBatch(
    _ source: StreamedBatch, caller: UUID?, policy: ProtectionPolicy,
    cancellationGeneration: UInt64, progress: (@Sendable (Int) -> Void)?
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
          _ = try await sendTransactionControl("SAVEPOINT \(Self.batchSavepoint)")
        } catch {
          throw await transactionFailure(error, openedHere: opens)
        }
        let rows: Int
        do {
          rows = try await applyStreamedBatch(
            source, policy: policy, cancellationGeneration: cancellationGeneration,
            progress: progress)
        } catch {
          try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
          throw await undoBatch(error, openedHere: opens)
        }
        do {
          _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.batchSavepoint)")
        } catch {
          throw await transactionFailure(error, openedHere: opens)
        }
        let dialect = Self.dialect(of: config)
        if let summary = SQLStatementClassifier.classifyStatement(
          "INSERT INTO \(source.relation): \(rows) generated rows", dialect: dialect)
        {
          recordPending(StatementSummary(statement: summary, affectedRows: rows, dialect: dialect))
        }
        return rows
      }
      if userTxOpen {
        _ = try await sendTransactionControl("SAVEPOINT \(Self.batchSavepoint)")
        let rows: Int
        do {
          rows = try await applyStreamedBatch(
            source, policy: policy, cancellationGeneration: cancellationGeneration,
            progress: progress)
        } catch {
          try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
          throw await undoBatch(error, openedHere: false)
        }
        _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.batchSavepoint)")
        return rows
      }
      _ = try await sendTransactionControl(appOwnedBeginSQL)
      let rows: Int
      do {
        rows = try await applyStreamedBatch(
          source, policy: policy, cancellationGeneration: cancellationGeneration,
          progress: progress)
      } catch {
        _ = try? await sendTransactionControl("ROLLBACK")
        throw error
      }
      try await commitOwnBatch()
      return rows
    }
  }

  // MARK: - Private

  private func runProtectedBatch(
    _ statements: [BoundStatement], caller: UUID?, cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?, rewind: RewindPlan?, rewinding: [Int64]
  ) async throws -> [Int] {
    let epoch = connectionEpoch
    try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
    let opens = txState.isIdle
    if opens { try await beginAppTransaction(caller: caller) }
    do {
      _ = try await sendTransactionControl("SAVEPOINT \(Self.batchSavepoint)")
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    var capture = startRewindCapture(rewind, statementCount: statements.count)
    let counts: [Int]
    do {
      counts = try await applyBatch(
        statements, rolledBack: true, cancellationGeneration: cancellationGeneration,
        progress: progress, capture: &capture)
      try refuseCancelledBatch(since: cancellationGeneration)
    } catch {
      try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
      throw await undoBatch(error, openedHere: opens)
    }
    do {
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.batchSavepoint)")
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    recordBatch(statements, counts: counts)
    recordRewind(capture, committed: false)
    recordRewound(rewinding, committed: false)
    noteSchemaSQL(statements)
    return counts
  }

  private func runUnprotectedBatch(
    _ statements: [BoundStatement], cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?, rewind: RewindPlan?, rewinding: [Int64]
  ) async throws -> [Int] {
    var capture = startRewindCapture(rewind, statementCount: statements.count)
    if userTxOpen {
      let epoch = connectionEpoch
      _ = try await sendTransactionControl("SAVEPOINT \(Self.batchSavepoint)")
      let counts: [Int]
      do {
        counts = try await applyBatch(
          statements, rolledBack: true, cancellationGeneration: cancellationGeneration,
          progress: progress, capture: &capture)
        try refuseCancelledBatch(since: cancellationGeneration)
      } catch {
        discardUserEntriesIfLost(capture)
        try await throwIfInterruptRolledBack(since: epoch, generation: cancellationGeneration)
        throw await undoBatch(error, openedHere: false)
      }
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.batchSavepoint)")
      recordRewind(capture, committed: false)
      recordRewound(rewinding, committed: false)
      noteSchemaSQL(statements)
      return counts
    }
    _ = try await sendTransactionControl(appOwnedBeginSQL)
    let counts: [Int]
    do {
      counts = try await applyBatch(
        statements, rolledBack: true, cancellationGeneration: cancellationGeneration,
        progress: progress, capture: &capture)
      try refuseCancelledBatch(since: cancellationGeneration)
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw error
    }
    try await commitOwnBatch()
    recordRewind(capture, committed: true)
    recordRewound(rewinding, committed: true)
    noteSchemaSQL(statements)
    return counts
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
  }

  /// Send each statement and check its expected affected rows when set. The caller owns the
  /// transaction. `rolledBack` is only the flag on the thrown error. With a `capture`, each
  /// statement's row is read right before and right after it.
  private func applyBatch(
    _ statements: [BoundStatement], rolledBack: Bool, cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?, capture: inout RewindCapture?
  ) async throws -> [Int] {
    var counts: [Int] = []
    counts.reserveCapacity(statements.count)
    for (index, statement) in statements.enumerated() {
      try refuseCancelledBatch(since: cancellationGeneration)
      let rows: Int
      do {
        // A capture read that throws lost the transaction: fail as the statement would
        try await captureBefore(index, into: &capture)
        rows = try await sendBound(statement)
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
      counts.append(statement.expectedRows == nil && isDDL ? 0 : rows)
      progress?(counts.count)
    }
    return counts
  }

  /// Make, check and send each chunk of `source` in turn; the caller owns the transaction. A
  /// relock or a cancel stops the run before the next chunk is made, and a chunk that is not
  /// DML or that `policy` forbids before it is sent. Each statement's expected rows are checked
  /// as `applyBatch` does, and a failure names it by its index in the run. Returns the rows sent.
  private func applyStreamedBatch(
    _ source: StreamedBatch, policy: ProtectionPolicy, cancellationGeneration: UInt64,
    progress: (@Sendable (Int) -> Void)?
  ) async throws -> Int {
    let dialect = Self.dialect(of: config)
    var index = 0
    var rows = 0
    var chunks = 0
    while true {
      try refuseCancelledBatch(since: cancellationGeneration)
      try refuseIfRelocked(config)
      let chunk = try await source.nextChunk()
      try refuseCancelledBatch(since: cancellationGeneration)
      guard let chunk else { return rows }
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

  /// Undo the edit with `ROLLBACK TO SAVEPOINT` (+ `RELEASE`) and return `editError` to throw. A
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
      _ = try await sendTransactionControl("ROLLBACK TO SAVEPOINT \(name)")
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(name)")
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

  private func sendBound(_ statement: BoundStatement) async throws -> Int {
    let rows = try await affectedRows(sql: statement.sql, binds: statement.binds)
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
  func commandResult(sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    let startTime = Date()
    do {
      return try await withSession { try await $0.command(sql, binds: binds) }
    } catch let error as DatabaseError {
      throw error
    } catch {
      throw queryFailure(error, query: sql, startTime: startTime)
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
