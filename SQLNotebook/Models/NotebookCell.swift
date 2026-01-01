//
//  NotebookCell.swift
//  SQLNotebook
//

import Foundation

/// A single cell in the notebook (SQL only)
struct NotebookCell: Codable, Identifiable, Sendable {
  let id: UUID
  var cellType: CellType
  var content: String
  var executionCount: Int?
  var result: CellResult?
  var isRunning: Bool

  nonisolated init(
    id: UUID = UUID(),
    cellType: CellType = .sql,
    content: String = "",
    executionCount: Int? = nil,
    result: CellResult? = nil,
    isRunning: Bool = false
  ) {
    self.id = id
    self.cellType = cellType
    self.content = content
    self.executionCount = executionCount
    self.result = result
    self.isRunning = isRunning
  }
}

/// The type of cell content (SQL only)
enum CellType: String, Codable, Sendable {
  case sql
}

/// Result of executing a SQL cell
struct CellResult: Codable, Sendable {
  let columns: [ColumnInfo]
  let rows: [[CellValue]]
  let executionTime: TimeInterval
  let rowCount: Int
  let timestamp: Date
  var error: String?
  /// True if the result was limited due to reaching max fetch rows
  let wasLimited: Bool
  /// The original SQL query that produced this result
  let sourceQuery: String?
  /// Table name if this is a simple SELECT from a single table
  let tableName: String?
  /// Primary key column names for the table (empty if no PK or unable to fetch)
  let primaryKeyColumns: [String]
  /// Row identifiers (ctid for PostgreSQL, rowid for SQLite) - one per row
  let rowIdentifiers: [CellValue]
  /// True if user's LIMIT in query exceeded maxRows and was capped
  let userLimitExceeded: Bool
  /// The original LIMIT value user specified (if any)
  let userRequestedLimit: Int?
  /// Number of rows affected by UPDATE/DELETE/INSERT (nil for SELECT queries)
  let affectedRows: Int?

  nonisolated init(
    columns: [ColumnInfo] = [],
    rows: [[CellValue]] = [],
    executionTime: TimeInterval = 0,
    rowCount: Int = 0,
    timestamp: Date = Date(),
    error: String? = nil,
    wasLimited: Bool = false,
    sourceQuery: String? = nil,
    tableName: String? = nil,
    primaryKeyColumns: [String] = [],
    rowIdentifiers: [CellValue] = [],
    userLimitExceeded: Bool = false,
    userRequestedLimit: Int? = nil,
    affectedRows: Int? = nil
  ) {
    self.columns = columns
    self.rows = rows
    self.executionTime = executionTime
    self.rowCount = rowCount
    self.timestamp = timestamp
    self.error = error
    self.wasLimited = wasLimited
    self.sourceQuery = sourceQuery
    self.tableName = tableName
    self.primaryKeyColumns = primaryKeyColumns
    self.rowIdentifiers = rowIdentifiers
    self.userLimitExceeded = userLimitExceeded
    self.userRequestedLimit = userRequestedLimit
    self.affectedRows = affectedRows
  }

  /// Creates an error result
  nonisolated static func errorResult(_ message: String, executionTime: TimeInterval = 0)
    -> CellResult
  {
    CellResult(
      executionTime: executionTime,
      timestamp: Date(),
      error: message
    )
  }
}

/// Information about a result column
struct ColumnInfo: Codable, Identifiable, Sendable {
  nonisolated var id: String { name }
  nonisolated let name: String
  nonisolated let type: String
}

/// A value in a result cell, supporting multiple SQL types
enum CellValue: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case json(String)
  case date(Date)
  case data(Data)

  /// Display string for the value
  nonisolated var displayString: String {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return String(value)
    case .double(let value):
      return String(format: "%.2f", value)
    case .bool(let value):
      return value ? "true" : "false"
    case .null:
      return "NULL"
    case .json(let value):
      // Show preview for JSON
      if value.hasPrefix("{") {
        return "{...}"
      } else if value.hasPrefix("[") {
        return "[...]"
      }
      return value
    case .date(let value):
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      formatter.timeStyle = .medium
      return formatter.string(from: value)
    case .data(let value):
      return "<\(value.count) bytes>"
    }
  }

  /// Full string representation (not truncated)
  nonisolated var fullString: String {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return String(value)
    case .double(let value):
      return String(value)
    case .bool(let value):
      return value ? "true" : "false"
    case .null:
      return "NULL"
    case .json(let value):
      return value
    case .date(let value):
      return ISO8601DateFormatter().string(from: value)
    case .data(let value):
      return value.base64EncodedString()
    }
  }

  nonisolated var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  nonisolated var isJSON: Bool {
    if case .json = self { return true }
    return false
  }
}
