// DatabaseConnectionManager+EditTransaction.swift
// Inline grid edits must update exactly one row. Protected mode runs the edit in the app
// transaction behind an app-owned savepoint; without Protected mode the edit gets its own
// app-owned BEGIN ... COMMIT, or runs inside the transaction the user opened.
// A staged batch uses the same rules behind savepoint `dblore_batch`, one summary per statement.

import Foundation

extension DatabaseConnectionManager {
  /// App-owned savepoint around one inline edit (user-typed SAVEPOINT stays blocked)
  static let editSavepoint = "dblore_edit"
  /// App-owned savepoint around one staged batch (not reused for a single-cell edit)
  static let batchSavepoint = "dblore_batch"

  /// Protected mode: adopt an open user transaction or open the app transaction (no second
  /// BEGIN), then run the edit between `SAVEPOINT dblore_edit` and `RELEASE SAVEPOINT`, and record
  /// it as pending. When the edit fails or does not update exactly one row it is undone with
  /// `ROLLBACK TO SAVEPOINT`: the transaction and its other pending changes stay intact (not
  /// aborted), nothing is recorded, and a transaction opened by this edit alone is rolled back.
  /// - Throws: `DatabaseError.editRowCountMismatch(rolledBack: true)`; the edit's error; a
  ///   savepoint failure (the transaction then follows `transactionFailure`).
  func runProtectedEdit(
    _ statement: CellUpdateStatement, classified: ClassifiedStatement?, caller: UUID?
  ) async throws -> Int {
    try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
    let opens = txState.isIdle
    if opens { try await beginAppTransaction(caller: caller) }
    do {
      _ = try await sendTransactionControl("SAVEPOINT \(Self.editSavepoint)")
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    let rows: Int
    do {
      rows = try await sendEdit(statement)
    } catch {
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
    if let classified { recordPending(StatementSummary(statement: classified, affectedRows: rows)) }
    return rows
  }

  /// Protected mode off. No user transaction: the edit runs in its own app-owned
  /// `BEGIN ... COMMIT` (never a pending transaction); a failure or a row count other than 1 is
  /// rolled back. With a user transaction open (`userTxOpen`): no nested BEGIN, the edit runs
  /// inside it and a row count other than 1 is reported WITHOUT rolling back the user's
  /// transaction (the user decides; an edit error leaves it aborted on the server, as any failing
  /// statement would).
  /// - Throws: `DatabaseError.editRowCountMismatch`; the edit or COMMIT error.
  func runUnprotectedEdit(_ statement: CellUpdateStatement) async throws -> Int {
    if userTxOpen {
      let rows = try await sendEdit(statement)
      guard rows == 1 else {
        throw DatabaseError.editRowCountMismatch(updated: rows, rolledBack: false)
      }
      return rows
    }
    _ = try await sendTransactionControl(appOwnedBeginSQL)
    let rows: Int
    do {
      rows = try await sendEdit(statement)
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
    return rows
  }

  /// Staged batch. Protected mode: adopt or begin the app transaction, run every statement
  /// inside `SAVEPOINT dblore_batch`, check each statement's expected rows, then `RELEASE` and
  /// record one pending summary per statement. A failure or any other row count rolls back to
  /// the savepoint (nothing from the batch is recorded) and names the statement. A transaction
  /// this batch opened, with nothing else pending, is rolled back the way `undoEdit` does.
  /// Unprotected, no user transaction: `BEGIN`, run each, `COMMIT`; any failure rolls the batch
  /// back. Unprotected with a user transaction already open: run inside it, and do not roll that
  /// transaction back on a bad row count.
  func runStagedBatch(
    _ statements: [BoundStatement], caller: UUID?, protectedMode: Bool
  ) async throws -> [Int] {
    if protectedMode {
      return try await runProtectedBatch(statements, caller: caller)
    }
    return try await runUnprotectedBatch(statements)
  }

  // MARK: - Private

  private func runProtectedBatch(
    _ statements: [BoundStatement], caller: UUID?
  ) async throws -> [Int] {
    try await adoptUserTransactionIfNeeded(protectedMode: true, caller: caller)
    let opens = txState.isIdle
    if opens { try await beginAppTransaction(caller: caller) }
    do {
      _ = try await sendTransactionControl("SAVEPOINT \(Self.batchSavepoint)")
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    let counts: [Int]
    do {
      counts = try await applyBatch(statements, rolledBack: true)
    } catch {
      throw await undoBatch(error, openedHere: opens)
    }
    do {
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.batchSavepoint)")
    } catch {
      throw await transactionFailure(error, openedHere: opens)
    }
    recordBatch(statements, counts: counts)
    return counts
  }

  private func runUnprotectedBatch(_ statements: [BoundStatement]) async throws -> [Int] {
    if userTxOpen {
      return try await applyBatch(statements, rolledBack: false)
    }
    _ = try await sendTransactionControl(appOwnedBeginSQL)
    let counts: [Int]
    do {
      counts = try await applyBatch(statements, rolledBack: true)
    } catch {
      _ = try? await sendTransactionControl("ROLLBACK")
      throw error
    }
    let metadata = try await sendTransactionControl("COMMIT")
    guard metadata.tag == "COMMIT" else {
      throw DatabaseError.transactionAborted(
        "The server rolled back the batch instead of saving it.")
    }
    return counts
  }

  /// Send each statement and check its expected affected rows when set. The caller owns the
  /// transaction. `rolledBack` is only the flag on the thrown error.
  private func applyBatch(_ statements: [BoundStatement], rolledBack: Bool) async throws -> [Int] {
    var counts: [Int] = []
    counts.reserveCapacity(statements.count)
    for (index, statement) in statements.enumerated() {
      let rows: Int
      do {
        rows = try await sendBound(statement)
      } catch {
        throw Self.batchStatementFailed(
          index, sql: statement.sql, underlying: error, rolledBack: rolledBack)
      }
      if let expected = statement.expectedRows, rows != expected {
        let reason =
          "expected to affect \(expected) row\(expected == 1 ? "" : "s"), affected \(rows)"
        throw Self.batchStatementFailed(
          index, sql: statement.sql, reason: reason, rolledBack: rolledBack)
      }
      // SQLite's sqlite3_changes64 can retain the previous DML count after CREATE TABLE.
      let isDDL = SQLStatementClassifier.classify(statement.sql).first?.kind == .ddl
      counts.append(statement.expectedRows == nil && isDDL ? 0 : rows)
    }
    return counts
  }

  private func recordBatch(_ statements: [BoundStatement], counts: [Int]) {
    for (index, statement) in statements.enumerated() {
      guard let classified = SQLStatementClassifier.classify(statement.sql).first else { continue }
      recordPending(StatementSummary(statement: classified, affectedRows: counts[index]))
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
  private func sendEdit(_ statement: CellUpdateStatement) async throws -> Int {
    try await affectedRows(sql: statement.sql, binds: statement.binds)
  }

  private func sendBound(_ statement: BoundStatement) async throws -> Int {
    try await affectedRows(sql: statement.sql, binds: statement.binds)
  }

  private func affectedRows(sql: String, binds: [SQLBindValue]) async throws -> Int {
    let startTime = Date()
    do {
      return try await withSession { try await $0.command(sql, binds: binds) }.affectedRows
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
