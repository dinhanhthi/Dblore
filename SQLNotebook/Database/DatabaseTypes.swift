//
//  DatabaseTypes.swift
//  SQLNotebook
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
  /// Row identifiers (ctid for PostgreSQL, rowid for SQLite) - one per row
  nonisolated let rowIdentifiers: [CellValue]
  /// True if user's LIMIT in query exceeded maxRows and was capped
  nonisolated let userLimitExceeded: Bool
  /// The original LIMIT value user specified (if any)
  nonisolated let userRequestedLimit: Int?
  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  nonisolated let affectedRows: Int?
  /// True if user's LIMIT was capped to maxRows (even if no limiting occurred in result)
  /// This is for display purposes - to show correct query in UI
  nonisolated let limitWasCapped: Bool
  /// The actual LIMIT used in executed query (after capping)
  nonisolated let actualLimitUsed: Int?

  nonisolated init(
    columns: [ColumnInfo], rows: [[CellValue]], rowCount: Int, executionTime: TimeInterval,
    wasLimited: Bool = false, rowIdentifiers: [CellValue] = [],
    userLimitExceeded: Bool = false, userRequestedLimit: Int? = nil,
    affectedRows: Int? = nil,
    limitWasCapped: Bool = false, actualLimitUsed: Int? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.rowCount = rowCount
    self.executionTime = executionTime
    self.wasLimited = wasLimited
    self.rowIdentifiers = rowIdentifiers
    self.userLimitExceeded = userLimitExceeded
    self.userRequestedLimit = userRequestedLimit
    self.affectedRows = affectedRows
    self.limitWasCapped = limitWasCapped
    self.actualLimitUsed = actualLimitUsed
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
  /// Commit refused before COMMIT was sent: a statement of the transaction is still running, or
  /// the pending list changed since the confirmation was shown (nothing was committed)
  case commitRefusedTransactionChanged
  /// COMMIT / ROLLBACK of the app transaction is awaited: gated statements, edits and a second
  /// Commit / Rollback are refused before anything is sent
  case transactionEnding(TransactionEndKind)
  /// Rollback refused before ROLLBACK was sent: a statement of the transaction is still running
  case rollbackRefusedStatementRunning

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
    case .notEditable(let reason):
      return "Cannot edit this value: \(reason). Nothing was executed."
    case .transactionAborted(let message):
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
    }
  }

  var executionTime: TimeInterval? {
    if case .queryFailed(_, let time) = self {
      return time
    }
    return nil
  }
}
