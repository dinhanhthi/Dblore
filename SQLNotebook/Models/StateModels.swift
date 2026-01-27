//
//  StateModels.swift
//  SQLNotebook
//
//  Contains state structs for grouping related ViewModel properties
//  Optimization 10.3.2: Reduce observable surface area
//

import Foundation

// MARK: - Toast State

/// Toast notification state (grouped for 10.3.2 optimization)
struct ToastState: Equatable, Sendable {
  var currentToast: ToastMessage?
  var isHovered: Bool = false

  mutating func show(_ message: String, type: ToastMessage.ToastType = .info) {
    currentToast = ToastMessage(message: message, type: type)
  }

  mutating func dismiss() {
    currentToast = nil
  }

  mutating func setHovered(_ hovered: Bool) {
    isHovered = hovered
  }
}

// MARK: - File Size State

/// File size tracking state (grouped for 10.3.2 optimization)
struct FileSizeState: Equatable, Sendable {
  var showWarningDialog: Bool = false
  var showLargeDialog: Bool = false
  var hasShownWarningDialog: Bool = false
  var hasShownLargeDialog: Bool = false
  var cachedSize: Int64 = 0

  /// Check if file size is large
  var isLarge: Bool {
    cachedSize > FileOptimizationService.largeSizeThreshold
  }

  /// Check if file size is approaching warning threshold
  var isWarning: Bool {
    cachedSize > FileOptimizationService.warningSizeThreshold
  }

  /// Get formatted file size string
  var formattedSize: String {
    FileOptimizationService.formatFileSize(cachedSize)
  }
}

// MARK: - Query Confirmation State

/// Query confirmation dialog state (grouped for 10.3.2 optimization)
struct QueryConfirmationState: Equatable, Sendable {
  var showDialog: Bool = false
  var pendingCellId: UUID?
  var pendingQuery: String = ""
  var affectsAllRows: Bool = false  // True if DELETE/UPDATE without WHERE clause
  var requiresPassword: Bool = false  // True for Safe Mode levels 3-4

  // Run All Cells destructive query confirmation
  var showRunAllConfirmation: Bool = false
  var runAllDestructiveCount: Int = 0
  var runAllPendingCells: [(id: UUID, query: String, isDestructive: Bool)] = []

  mutating func clear() {
    showDialog = false
    pendingCellId = nil
    pendingQuery = ""
    affectsAllRows = false
    requiresPassword = false
  }

  mutating func clearRunAll() {
    showRunAllConfirmation = false
    runAllDestructiveCount = 0
    runAllPendingCells = []
  }

  // Custom Equatable implementation since tuples aren't Equatable
  static func == (lhs: QueryConfirmationState, rhs: QueryConfirmationState) -> Bool {
    lhs.showDialog == rhs.showDialog
      && lhs.pendingCellId == rhs.pendingCellId
      && lhs.pendingQuery == rhs.pendingQuery
      && lhs.affectsAllRows == rhs.affectsAllRows
      && lhs.requiresPassword == rhs.requiresPassword
      && lhs.showRunAllConfirmation == rhs.showRunAllConfirmation
      && lhs.runAllDestructiveCount == rhs.runAllDestructiveCount
      && lhs.runAllPendingCells.count == rhs.runAllPendingCells.count
  }
}

// MARK: - Search State

/// Search match representing a single match trong notebook
struct SearchMatch: Identifiable, Equatable, Sendable {
  let id: UUID = UUID()
  let cellId: UUID
  let matchType: SearchMatchType
  let matchRange: Range<String.Index>
  let contextText: String  // Preview text với match highlighted
  let lineNumber: Int?  // For SQL content matches

  enum SearchMatchType: Equatable, Sendable {
    case sqlContent
    case tableData(rowIndex: Int, columnName: String)
    case errorMessage
    case columnName(String)
  }
}

/// Search state configuration
struct SearchState: Equatable, Sendable {
  var query: String = ""
  var isCaseSensitive: Bool = false
  var matches: [SearchMatch] = []
  var currentMatchIndex: Int = 0
  var isSearching: Bool = false

  var currentMatch: SearchMatch? {
    guard !matches.isEmpty, currentMatchIndex < matches.count else { return nil }
    return matches[currentMatchIndex]
  }

  var matchCountText: String {
    guard !matches.isEmpty else { return "No matches" }
    return "\(currentMatchIndex + 1) of \(matches.count)"
  }
}

// MARK: - Schema Search

/// Search match for schema visualizer (table names and column names)
struct SchemaSearchMatch: Identifiable, Equatable, Sendable {
  let id: UUID = UUID()
  let nodeId: UUID  // SchemaNode ID
  let tableName: String  // Full table name (schema.table)
  let matchType: SchemaMatchType
  let matchedText: String  // The actual matched text
  let matchRange: Range<String.Index>  // Range within the matched text

  enum SchemaMatchType: Equatable, Sendable {
    case tableName
    case columnName(columnIndex: Int)  // Index of the column in the table
  }
}

/// Schema search state
struct SchemaSearchState: Equatable, Sendable {
  var query: String = ""
  var isCaseSensitive: Bool = false
  var matches: [SchemaSearchMatch] = []
  var currentMatchIndex: Int = 0
  var isSearching: Bool = false

  var currentMatch: SchemaSearchMatch? {
    guard !matches.isEmpty, currentMatchIndex < matches.count else { return nil }
    return matches[currentMatchIndex]
  }

  var matchCountText: String {
    guard !matches.isEmpty else { return "No matches" }
    return "\(currentMatchIndex + 1) of \(matches.count)"
  }
}
