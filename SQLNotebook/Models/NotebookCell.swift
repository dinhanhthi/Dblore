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
  var isResultVisible: Bool
  /// Results for multi-statement queries (empty for single statement)
  var statementResults: [StatementResult]
  /// Currently selected statement index (0-based) for multi-statement queries
  var selectedStatementIndex: Int
  /// Total execution time for all statements (for multi-statement queries)
  var totalExecutionTime: TimeInterval?
  /// Pagination info for single statement result (nil if not paginated)
  var paginationInfo: PaginationInfo?
  /// Pagination info for multi-statement results (key: statementId)
  var statementPaginationInfo: [UUID: PaginationInfo]

  // MARK: - Codable

  enum CodingKeys: String, CodingKey {
    case id
    case cellType
    case content
    case executionCount
    case result
    case isRunning
    case isResultVisible
    case statementResults
    case selectedStatementIndex
    case totalExecutionTime
    case paginationInfo
    case statementPaginationInfo
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    cellType = try container.decode(CellType.self, forKey: .cellType)
    content = try container.decode(String.self, forKey: .content)
    executionCount = try container.decodeIfPresent(Int.self, forKey: .executionCount)
    result = try container.decodeIfPresent(CellResult.self, forKey: .result)
    isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
    isResultVisible = try container.decodeIfPresent(Bool.self, forKey: .isResultVisible) ?? true
    // New properties with default values for backward compatibility
    statementResults =
      try container.decodeIfPresent([StatementResult].self, forKey: .statementResults) ?? []
    selectedStatementIndex =
      try container.decodeIfPresent(Int.self, forKey: .selectedStatementIndex) ?? 0
    totalExecutionTime =
      try container.decodeIfPresent(TimeInterval.self, forKey: .totalExecutionTime)
    paginationInfo = try container.decodeIfPresent(PaginationInfo.self, forKey: .paginationInfo)
    statementPaginationInfo =
      try container.decodeIfPresent([UUID: PaginationInfo].self, forKey: .statementPaginationInfo)
      ?? [:]
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(cellType, forKey: .cellType)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(executionCount, forKey: .executionCount)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encode(isRunning, forKey: .isRunning)
    try container.encode(isResultVisible, forKey: .isResultVisible)
    try container.encode(statementResults, forKey: .statementResults)
    try container.encode(selectedStatementIndex, forKey: .selectedStatementIndex)
    try container.encodeIfPresent(totalExecutionTime, forKey: .totalExecutionTime)
    try container.encodeIfPresent(paginationInfo, forKey: .paginationInfo)
    try container.encode(statementPaginationInfo, forKey: .statementPaginationInfo)
  }

  nonisolated init(
    id: UUID = UUID(),
    cellType: CellType = .sql,
    content: String = "",
    executionCount: Int? = nil,
    result: CellResult? = nil,
    isRunning: Bool = false,
    isResultVisible: Bool = true,
    statementResults: [StatementResult] = [],
    selectedStatementIndex: Int = 0,
    totalExecutionTime: TimeInterval? = nil,
    paginationInfo: PaginationInfo? = nil,
    statementPaginationInfo: [UUID: PaginationInfo] = [:]
  ) {
    self.id = id
    self.cellType = cellType
    self.content = content
    self.executionCount = executionCount
    self.result = result
    self.isRunning = isRunning
    self.isResultVisible = isResultVisible
    self.statementResults = statementResults
    self.selectedStatementIndex = selectedStatementIndex
    self.totalExecutionTime = totalExecutionTime
    self.paginationInfo = paginationInfo
    self.statementPaginationInfo = statementPaginationInfo
  }
}

/// The type of cell content (SQL only)
enum CellType: String, Codable, Sendable {
  case sql
}

/// Result of executing a single SQL statement (within a multi-statement query)
struct StatementResult: Codable, Sendable, Identifiable {
  let id: UUID
  let queryText: String  // The individual statement text
  let result: CellResult  // The execution result
  let statementIndex: Int  // 0-based index in the query

  nonisolated init(
    id: UUID = UUID(),
    queryText: String,
    result: CellResult,
    statementIndex: Int
  ) {
    self.id = id
    self.queryText = queryText
    self.result = result
    self.statementIndex = statementIndex
  }
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
  /// True if user's LIMIT was capped to maxRows (even if no limiting occurred in result)
  /// This is for display purposes - to show correct query in UI
  let limitWasCapped: Bool
  /// The actual LIMIT used in executed query (after capping)
  let actualLimitUsed: Int?

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
    affectedRows: Int? = nil,
    limitWasCapped: Bool = false,
    actualLimitUsed: Int? = nil
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
    self.limitWasCapped = limitWasCapped
    self.actualLimitUsed = actualLimitUsed
  }

  /// Creates an error result
  nonisolated static func errorResult(
    _ message: String, executionTime: TimeInterval = 0, sourceQuery: String? = nil
  )
    -> CellResult
  {
    CellResult(
      executionTime: executionTime,
      timestamp: Date(),
      error: message,
      sourceQuery: sourceQuery
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
enum CellValue: Codable, Equatable, Sendable, Comparable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case json(String)
  case date(Date)
  case data(Data)

  // Cached date formatters for performance
  // Note: DateFormatter is thread-safe for reading after initialization
  private static let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
  }()

  private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

  /// Display string for the value
  var displayString: String {
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
      return Self.displayDateFormatter.string(from: value)
    case .data(let value):
      return "<\(value.count) bytes>"
    }
  }

  /// Full string representation (not truncated)
  var fullString: String {
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
      return Self.iso8601Formatter.string(from: value)
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

  // MARK: - Comparable

  /// Sort priority for different types (null always last)
  private var sortPriority: Int {
    switch self {
    case .null: return 999  // Nulls sort last
    case .bool: return 0
    case .int: return 1
    case .double: return 2
    case .date: return 3
    case .string: return 4
    case .json: return 5
    case .data: return 6
    }
  }

  static func < (lhs: CellValue, rhs: CellValue) -> Bool {
    // Nulls always sort last
    if case .null = lhs { return false }
    if case .null = rhs { return true }

    // Compare same types directly
    switch (lhs, rhs) {
    case (.int(let l), .int(let r)):
      return l < r
    case (.double(let l), .double(let r)):
      return l < r
    case (.int(let l), .double(let r)):
      return Double(l) < r
    case (.double(let l), .int(let r)):
      return l < Double(r)
    case (.string(let l), .string(let r)):
      return l.localizedStandardCompare(r) == .orderedAscending
    case (.bool(let l), .bool(let r)):
      return !l && r  // false < true
    case (.date(let l), .date(let r)):
      return l < r
    case (.json(let l), .json(let r)):
      return l.localizedStandardCompare(r) == .orderedAscending
    case (.data(let l), .data(let r)):
      return l.count < r.count
    default:
      // Different types: compare by sort priority
      return lhs.sortPriority < rhs.sortPriority
    }
  }
}
