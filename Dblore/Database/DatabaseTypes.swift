//
//  DatabaseTypes.swift
//  Dblore
//
//  Supporting types and utilities for database operations
//
//  NOTE: This file has been split into focused modules:
//  - DatabaseTypes+PostgreSQL.swift (PostgreSQL type mapping and parsing)
//  - DatabaseTypes+ErrorFormatting.swift (error formatting utilities)
//

import Foundation
import NIOCore
import NIOFoundationCompat
import PostgresNIO

// MARK: - Supporting Types

/// Result of a query execution
struct QueryResult: Sendable {
  nonisolated let columns: [ColumnInfo]
  nonisolated let rows: [[CellValue]]
  nonisolated let rowCount: Int
  nonisolated let executionTime: TimeInterval
  /// True if the result was limited due to reaching maxFetchRows
  nonisolated let wasLimited: Bool
  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  nonisolated let affectedRows: Int?
  /// The statement returned more rows than the row cap; only the first `rowCount` were read
  nonisolated var truncated = false
  /// Reading stopped by closing the connection and reconnecting (no app transaction was
  /// pending): temp tables, SET values and search_path of the session were lost
  nonisolated var sessionReset = false
  /// Statements of the script that were not run because the session was reset before them
  nonisolated var skippedStatements: [String] = []

  nonisolated init(
    columns: [ColumnInfo], rows: [[CellValue]], rowCount: Int, executionTime: TimeInterval,
    wasLimited: Bool = false, affectedRows: Int? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.rowCount = rowCount
    self.executionTime = executionTime
    self.wasLimited = wasLimited
    self.affectedRows = affectedRows
  }
}

/// Database-specific errors
enum DatabaseError: LocalizedError {
  case notConnected
  case connectionFailed(String)
  case queryFailed(String, TimeInterval)
  case emptyQuery
  /// The execution gate refused the whole script before sending anything
  case blockedByProtection(statementIndex: Int, kind: StatementKind, reason: String)
  /// An allowed statement's `:name` has no value in the caller's dictionary
  case missingParameters([String])
  /// One statement uses both a `:name` and a positional placeholder
  case mixedPlaceholders
  /// An inline grid edit cannot be targeted at exactly one row (no primary key, ...)
  case notEditable(String)
  /// The Protected mode transaction failed, was lost, or cannot be committed (full message)
  case transactionAborted(String)
  /// Another tab (caller token) opened the pending app transaction; nothing was sent
  case transactionPendingInAnotherTab
  /// App catalog queries (schema, autocomplete, edit targets) are not sent while the app
  /// transaction is pending: a failing one would abort it
  case metadataPausedDuringTransaction
  /// An inline edit updated `updated` rows instead of exactly one. `rolledBack`: the change was
  /// undone by the app; false: it stays in the user's own open transaction
  case editRowCountMismatch(updated: Int, rolledBack: Bool)
  /// One statement of a staged batch failed or affected a row count other than 1.
  /// `index` is 0-based. When `rolledBack` is true the whole batch was undone; when false the
  /// statement stays in the user's own open transaction.
  case batchStatementFailed(index: Int, sqlPrefix: String, reason: String, rolledBack: Bool)
  /// Cancel arrived between batch statements; the batch transaction is being rolled back.
  case batchCancelled
  /// Commit refused before COMMIT was sent: a statement of the transaction is still running, or
  /// the pending list changed since the confirmation was shown (nothing was committed)
  case commitRefusedTransactionChanged
  /// COMMIT / ROLLBACK of the app transaction is awaited: gated statements, edits and a second
  /// Commit / Rollback are refused before anything is sent
  case transactionEnding(TransactionEndKind)
  /// Rollback refused before ROLLBACK was sent: a statement of the transaction is still running
  case rollbackRefusedStatementRunning
  /// The server (or the network) closed the session; it was forgotten (full message, see
  /// `SessionLostEvent.message`)
  case connectionLost(String)
  /// The user cancelled the running statement: the connection was closed (stopping the server
  /// work) and reopened. `pendingCount` app-transaction changes / the user's open transaction
  /// were rolled back with the old session.
  case queryCancelled(pendingCount: Int, userTxRolledBack: Bool)
  /// The connection was closed and reopened (another tab's capped read, a cancel, a reconnect)
  /// while a script was between statements: its remaining `skippedStatements` were not run
  case sessionChanged(skippedStatements: Int)

  var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Not connected to database"
    case .connectionFailed(let message):
      return "Connection failed: \(message)"
    case .queryFailed(let message, _):
      return "Query failed: \(message)"
    case .emptyQuery:
      return "Query is empty"
    case .blockedByProtection(let statementIndex, _, let reason):
      return
        "Blocked by connection protection (statement \(statementIndex + 1)): \(reason). Nothing was executed."
    case .missingParameters(let names):
      return "Missing parameters: \(names.joined(separator: ", ")). Nothing was executed."
    case .mixedPlaceholders:
      return "Named and positional placeholders cannot be mixed in one statement. "
        + "Nothing was executed."
    case .notEditable(let reason):
      return "Cannot edit this value: \(reason). Nothing was executed."
    case .transactionAborted(let message), .connectionLost(let message):
      return message
    case .transactionPendingInAnotherTab:
      return "Commit or roll back pending changes first (another tab has an uncommitted "
        + "transaction). Nothing was executed."
    case .metadataPausedDuringTransaction:
      return "Schema is paused until Commit/Rollback"
    case .editRowCountMismatch(let updated, true):
      return "Expected to update 1 row, updated \(updated) — change rolled back"
    case .commitRefusedTransactionChanged:
      return "Changes are still running or the list changed — review again. Nothing was committed."
    case .transactionEnding(let kind):
      return "\(kind == .commit ? "Commit" : "Rollback") in progress — try again when it "
        + "finishes. Nothing was executed."
    case .rollbackRefusedStatementRunning:
      return "Statements of the pending transaction are still running — roll back when they "
        + "finish. Nothing was rolled back."
    case .editRowCountMismatch(let updated, false):
      return "Expected to update 1 row, updated \(updated) — the change is still in your open "
        + "transaction; roll it back (ROLLBACK) to undo it"
    case .batchStatementFailed(let index, let sqlPrefix, let reason, let rolledBack):
      let outcome =
        rolledBack
        ? "The batch was rolled back."
        : "It is still in your open transaction; roll it back (ROLLBACK) to undo it."
      return "Batch statement \(index + 1) (\(sqlPrefix)) failed: \(reason). \(outcome)"
    case .batchCancelled:
      return "Batch cancelled before the next statement."
    case .queryCancelled(let pendingCount, let userTxRolledBack):
      return Self.cancelMessage(pendingCount: pendingCount, userTxRolledBack: userTxRolledBack)
    case .sessionChanged(let count):
      return "The connection was reset by another tab or action — the remaining \(count) "
        + "statement\(count == 1 ? " was" : "s were") not run."
    }
  }

  /// "Query cancelled — connection was reset (…)" plus what the reset rolled back
  nonisolated static func cancelMessage(pendingCount: Int, userTxRolledBack: Bool) -> String {
    var parts = ["Query cancelled — connection was reset (temp tables, SET, search_path lost)."]
    if pendingCount > 0 {
      let verb = pendingCount == 1 ? "was" : "were"
      parts.append(
        "\(pendingCount) pending change\(pendingCount == 1 ? "" : "s") \(verb) rolled back.")
    }
    if userTxRolledBack { parts.append("Your open transaction was rolled back.") }
    return parts.joined(separator: " ")
  }

  var executionTime: TimeInterval? {
    if case .queryFailed(_, let time) = self {
      return time
    }
    return nil
  }
}
