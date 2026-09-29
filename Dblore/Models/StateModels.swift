//
//  StateModels.swift
//  Dblore
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

/// One statement of a cell that the Safe Mode confirmation dialog lists
nonisolated struct StatementConfirmation: Identifiable, Equatable, Sendable {
  let index: Int  // 0-based position in the cell (shown as index + 1)
  let preview: String  // First line of the statement, truncated
  let kindLabel: String
  let affectsAllRows: Bool  // UPDATE/DELETE without WHERE
  let touchesBrake: Bool  // Can change session brakes (timeouts, read-only)
  let changesPrivileges: Bool  // SET ROLE / SESSION AUTHORIZATION / DISCARD ALL

  var id: Int { index }

  /// Badge texts explaining why the statement needs attention
  var reasons: [String] {
    var reasons: [String] = []
    if affectsAllRows { reasons.append("No WHERE — affects all rows") }
    if touchesBrake { reasons.append("Changes session safety settings") }
    if changesPrivileges { reasons.append("Changes role/privileges") }
    return reasons
  }
}

/// One SQL cell queued by Run All, with the statements that need confirmation (empty if none)
nonisolated struct RunAllCell: Equatable, Sendable {
  let id: UUID
  let number: Int  // 1-based position in the notebook
  let query: String
  let statements: [StatementConfirmation]

  /// True if Run All's "Don't Allow" skips this cell
  var needsConfirmation: Bool { !statements.isEmpty }

  /// Changes session brakes or privileges: always confirmed, even with the destructive bypass
  var isSafetyCritical: Bool { statements.contains { $0.touchesBrake || $0.changesPrivileges } }
}

/// Query confirmation dialog state (grouped for 10.3.2 optimization)
struct QueryConfirmationState: Equatable, Sendable {
  var showDialog: Bool = false
  var pendingCellId: UUID?
  var pendingQuery: String = ""
  var affectsAllRows: Bool = false  // True if DELETE/UPDATE without WHERE clause
  var requiresPassword: Bool = false  // True for Safe Mode levels 3-4
  var statements: [StatementConfirmation] = []  // Statements that need confirmation

  // Run All Cells confirmation (destructive or safety-critical cells)
  var showRunAllConfirmation: Bool = false
  var runAllPendingCells: [RunAllCell] = []
  /// Run All waits for the Safe Mode unlock (password sheet) under safeRead/safeAll
  var runAllAwaitingUnlock: Bool = false

  /// Cells the Run All dialog lists ("Don't Allow" skips them)
  var runAllConfirmCells: [RunAllCell] { runAllPendingCells.filter(\.needsConfirmation) }

  mutating func clear() {
    showDialog = false
    pendingCellId = nil
    pendingQuery = ""
    affectsAllRows = false
    requiresPassword = false
    statements = []
    runAllAwaitingUnlock = false
  }

  mutating func clearRunAll() {
    showRunAllConfirmation = false
    runAllPendingCells = []
  }
}

/// An inline grid edit ready to send through the gate
struct PendingInlineEdit: Equatable, Sendable {
  let statement: CellUpdateStatement
  let columnName: String
  let tableName: String
  let cellId: UUID?
  let connectionManager: DatabaseConnectionManager

  static func == (lhs: PendingInlineEdit, rhs: PendingInlineEdit) -> Bool {
    lhs.statement == rhs.statement && lhs.columnName == rhs.columnName
      && lhs.tableName == rhs.tableName && lhs.cellId == rhs.cellId
      && lhs.connectionManager === rhs.connectionManager
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
