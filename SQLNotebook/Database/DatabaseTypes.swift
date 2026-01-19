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

  nonisolated init(
    columns: [ColumnInfo], rows: [[CellValue]], rowCount: Int, executionTime: TimeInterval,
    wasLimited: Bool = false, rowIdentifiers: [CellValue] = [],
    userLimitExceeded: Bool = false, userRequestedLimit: Int? = nil,
    affectedRows: Int? = nil
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
  }
}

/// Database-specific errors
enum DatabaseError: LocalizedError {
  case notConnected
  case connectionFailed(String)
  case queryFailed(String, TimeInterval)
  case emptyQuery

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
    }
  }

  var executionTime: TimeInterval? {
    if case .queryFailed(_, let time) = self {
      return time
    }
    return nil
  }
}
