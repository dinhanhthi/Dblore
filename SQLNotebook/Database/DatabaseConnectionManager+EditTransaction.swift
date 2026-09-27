// DatabaseConnectionManager+EditTransaction.swift
// Inline grid edits must update exactly one row. Protected mode runs the edit in the app
// transaction behind an app-owned savepoint; without Protected mode the edit gets its own
// app-owned BEGIN ... COMMIT, or runs inside the transaction the user opened.

import Foundation
import Logging
import PostgresNIO

extension DatabaseConnectionManager {
  /// App-owned savepoint around one inline edit (user-typed SAVEPOINT stays blocked)
  static let editSavepoint = "sqlnb_edit"

  /// Protected mode: adopt an open user transaction or open the app transaction (no second
  /// BEGIN), then run the edit between `SAVEPOINT sqlnb_edit` and `RELEASE SAVEPOINT`, and record
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
    _ = try await sendTransactionControl("BEGIN")
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
    guard metadata.command == "COMMIT" else {
      throw DatabaseError.transactionAborted(
        "The server rolled back the edit instead of saving it.")
    }
    return rows
  }

  // MARK: - Private

  /// Undo the edit with `ROLLBACK TO SAVEPOINT` (+ `RELEASE`) and return `editError` to throw. A
  /// transaction this edit opened with nothing else pending is rolled back (back to idle). If
  /// the undo fails, the state follows `transactionFailure`.
  private func undoEdit(_ editError: Error, openedHere: Bool) async -> Error {
    do {
      _ = try await sendTransactionControl("ROLLBACK TO SAVEPOINT \(Self.editSavepoint)")
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.editSavepoint)")
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
    guard let connection = _connection else { throw DatabaseError.notConnected }
    let startTime = Date()
    do {
      let query = PostgresQuery(unsafeSQL: statement.sql, binds: statement.bindings)
      let metadata = try await send(on: connection) {
        try await $0.query(query, logger: Logger(label: "sqlnotebook.update")).get().metadata
      }
      return metadata.rows ?? 0
    } catch let error as DatabaseError {
      throw error
    } catch let error as PSQLError {
      throw DatabaseError.queryFailed(
        formatPostgresError(error, query: statement.sql), Date().timeIntervalSince(startTime))
    } catch {
      throw DatabaseError.queryFailed(
        error.localizedDescription, Date().timeIntervalSince(startTime))
    }
  }
}
