// QueryHistoryEntry.swift
// One recorded SQL statement: when it ran, how it ended, and which connection it used.

import Foundation

/// A row in the query-history database. `id` is 0 until the store assigns the SQLite rowid.
nonisolated struct QueryHistoryEntry: Sendable, Codable, Equatable {
  nonisolated enum Status: String, Sendable, Codable, Equatable {
    case success
    case error
    case cancelled
  }

  nonisolated enum Source: String, Sendable, Codable, Equatable {
    case cell
    case editor
    case dataViewerEdit
    case dataImport
  }

  /// Classified effect of the SQL. Nil when the row has not been classified.
  nonisolated enum Kind: String, Sendable, Codable, Equatable {
    case read
    case write
    case schema
    case transaction
    case other
  }

  var id: Int64
  var sql: String
  var executedAt: Date
  var durationMs: Int
  var rowCount: Int?
  var status: Status
  var errorMessage: String?
  var connectionKey: String
  var connectionLabel: String
  var workspaceID: UUID?
  var workspaceName: String?
  var source: Source
  /// Missing JSON decodes as nil. NULL in the database is not a write.
  var kind: Kind? = nil

  /// `COMMIT (n statements)` / `ROLLBACK (n statements)` is an audit label, not SQL that was sent.
  nonisolated static func isTransactionSummary(_ sql: String) -> Bool {
    for verb in ["COMMIT ", "ROLLBACK "] {
      guard sql.hasPrefix(verb), sql.hasSuffix(" statements)") else { continue }
      let inside = sql.dropFirst(verb.count).dropLast(" statements)".count)
      guard inside.first == "(", inside.dropFirst().allSatisfy(\.isNumber),
        !inside.dropFirst().isEmpty
      else { continue }
      return true
    }
    return false
  }
}
