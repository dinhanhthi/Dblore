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
}
