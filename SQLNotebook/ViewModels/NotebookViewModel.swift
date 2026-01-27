//
//  NotebookViewModel.swift
//  SQLNotebook
//

import AppKit
import Observation
import SwiftUI

/// Drop position for drag and drop
enum DropPosition {
  case above
  case below
}

/// Content types for the right sidebar
enum SidebarContent: Equatable {
  case jsonViewer(json: String, path: String)
  case cellInfo(
    columnName: String,
    columnType: String,
    value: CellValue,
    tableName: String?,
    rowData: [String: CellValue]?,  // All column values for this row
    primaryKeyColumns: [String],  // Primary key column names
    rowIdentifier: CellValue?,  // Row identifier (ctid for PostgreSQL, rowid for SQLite)
    cellId: UUID?  // ID of the cell that produced this result (for re-running after edit)
  )
  case executedQuery(
    query: String, cellId: UUID?, limitWasCapped: Bool = false, actualLimit: Int? = nil)  // Show executed query with syntax highlighting
  case connectionDetails
  case connectionForm
  case settings
}

/// Main view model for the notebook editor
@MainActor
@Observable
class NotebookViewModel {
  // Unique identifier for this view model instance (to scope search notifications)
  let id: UUID = UUID()

  var notebook: SQLNotebook
  var connectionState: ConnectionState = .disconnected
  var selectedCellId: UUID?
  var rightSidebarContent: SidebarContent?
  var isRightSidebarVisible: Bool = false
  var executionCounter: Int = 0
  var draggingCellId: UUID? = nil  // Track which cell is currently being dragged
  var dropTargetCellId: UUID? = nil  // Track which cell is the drop target (for blue indicator)
  var dropPosition: DropPosition? = nil  // Track drop position (above or below target)

  // Left sidebar state
  var isLeftSidebarVisible: Bool = false
  var databaseTables: [DatabaseTable] = []
  var databaseViews: [DatabaseView] = []
  var databaseFunctions: [DatabaseFunction] = []
  var databaseProcedures: [DatabaseProcedure] = []
  var databaseUsers: [DatabaseUser] = []
  var databaseRoles: [DatabaseRole] = []
  var databaseForeignKeys: [ForeignKey] = []
  var isLoadingSchema: Bool = false
  var areAllEntitiesExpanded: Bool = false  // Track expand/collapse state

  // Schema visualizer state
  var schemaGraph: SchemaGraph?
  var visualizerScale: CGFloat = 1.0
  var visualizerOffset: CGPoint = .zero
  var selectedGraphNodeId: UUID?
  var isLoadingSchemaGraph: Bool = false
  var isSchemaVisualizerActive: Bool = false  // Show visualizer in main body instead of cells/editor
  weak var schemaGraphNSView: SchemaGraphNSView?  // Reference for export functionality
  var showTableConnections: Bool = true  // Show relationship lines between tables (default: true)
  var showColumnConnections: Bool = false  // Show dashed lines connecting FK columns

  // Connection config for the sheet
  var editingConnectionConfig: ConnectionConfig

  // Database connection manager
  let connectionManager = DatabaseConnectionManager()

  // Autocomplete provider
  let autocompleteProvider = SQLAutocompleteProvider()

  // Execution queue for managing cell executions
  private(set) var executionQueue: ExecutionQueue!

  // Undo/Redo manager
  let undoManager = UndoManager()

  // Callback to sync document after changes
  var onDocumentChanged: (() -> Void)?

  // MARK: - Toast State (10.3.2 optimization)
  var toastState: ToastState = ToastState()
  @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

  // MARK: - File Size State (10.3.2 optimization)
  var fileSizeState: FileSizeState = FileSizeState()
  @ObservationIgnored var fileSizeExecutionCounter: Int = 0
  @ObservationIgnored let fileSizeCheckInterval: Int = 5  // Check every 5 executions

  // MARK: - Search State (10.3.2 optimization)
  var isSearchPanelVisible: Bool = false
  var searchState: SearchState = SearchState()
  var searchFocusTrigger: UUID = UUID()  // Trigger to force re-focus search field
  @ObservationIgnored var searchTask: Task<Void, Never>?  // Task for cancellation support
  @ObservationIgnored var searchNavigationTask: Task<Void, Never>?  // Task for debounced navigation (10.1.3)
  @ObservationIgnored var previousFirstResponder: NSResponder?  // Store previous responder

  // Schema search state (for schema visualizer)
  var schemaSearchState: SchemaSearchState = SchemaSearchState()
  @ObservationIgnored var schemaSearchTask: Task<Void, Never>?

  // MARK: - Query Confirmation State (10.3.2 optimization)
  var queryConfirmationState: QueryConfirmationState = QueryConfirmationState()

  // MARK: - View Mode State
  var viewMode: ViewMode = .notebook
  var editorContent: String = ""  // Content for editor mode
  var editorResult: CellResult?  // Result for editor mode (single statement or legacy)
  var editorStatementResults: [StatementResult] = []  // Results for multi-statement queries
  var selectedStatementIndex: Int = 0  // Currently selected statement result (0-based)
  var totalExecutionTime: TimeInterval = 0  // Total time for all statements
  weak var editorTextView: SQLTextView?  // Reference to editor text view for getting selection

  // MARK: - Pagination State (Editor Mode)
  var editorPaginationInfo: PaginationInfo?  // Pagination info for editor result
  var editorStatementPaginationInfo: [UUID: PaginationInfo] = [:]  // Pagination info per statement

  // MARK: - Pagination State (Notebook Mode)
  /// Pagination info for cells with single statement results
  /// Key: cellId, Value: PaginationInfo
  var cellPaginationInfo: [UUID: PaginationInfo] = [:]
  /// Pagination info for multi-statement cell results
  /// Key: cellId, Value: [statementId: PaginationInfo]
  var cellStatementPaginationInfo: [UUID: [UUID: PaginationInfo]] = [:]

  init(notebook: SQLNotebook = .newDocument()) {
    self.notebook = notebook
    editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()

    // Initialize execution queue with execution handler
    executionQueue = ExecutionQueue { [weak self] task in
      await self?.executeTask(task)
    }

    // Set connection manager for autocomplete provider
    autocompleteProvider.setConnectionManager(connectionManager)

    // Restore pagination state from cells
    for cell in notebook.cells {
      if let paginationInfo = cell.paginationInfo {
        cellPaginationInfo[cell.id] = paginationInfo
      }
      if !cell.statementPaginationInfo.isEmpty {
        cellStatementPaginationInfo[cell.id] = cell.statementPaginationInfo
      }
    }

    // Load sidebar visibility from settings after init
    Task {
      self.isLeftSidebarVisible = AppSettings.shared.isLeftSidebarVisible
    }

    // Calculate initial file size for cache (10.3.4)
    recalculateFileSize()
  }

  // MARK: - Toast Notifications

  func showToast(_ message: String, type: ToastMessage.ToastType = .info) {
    toastState.show(message, type: type)
    startToastDismissTimer(for: message)
  }

  private func startToastDismissTimer(for message: String) {
    // Cancel any existing dismiss task
    toastDismissTask?.cancel()

    // Auto-dismiss after 4 seconds, but only if not hovered
    toastDismissTask = Task {
      try? await Task.sleep(for: .seconds(4))

      // Wait until toast is no longer hovered (max 20 seconds to prevent deadlock)
      var hoverWaitTime = 0
      while self.toastState.isHovered && hoverWaitTime < 40 {
        try? await Task.sleep(for: .seconds(0.5))
        hoverWaitTime += 1
      }

      // Dismiss only if the message matches (user might have shown a new toast)
      if self.toastState.currentToast?.message == message {
        self.toastState.dismiss()
      }
    }
  }

  func setToastHovered(_ hovered: Bool) {
    toastState.setHovered(hovered)
  }

  // MARK: - Statistics

  var cellCount: Int {
    notebook.cells.count
  }

  var executedCellCount: Int {
    notebook.cells.filter { $0.executionCount != nil }.count
  }

  /// Calculate current file size (with results if enabled in settings)
  /// Uses cached value for performance - recalculated every 5 executions (10.3.4)
  var estimatedFileSize: Int64 {
    fileSizeState.cachedSize
  }

  /// Force recalculate file size and update cache
  func recalculateFileSize() {
    let includeResults = AppSettings.getIncludeResultsOnSave()
    fileSizeState.cachedSize =
      (try? FileOptimizationService.calculateNotebookSize(notebook, includeResults: includeResults))
      ?? 0
  }

  /// Get formatted file size string
  var formattedFileSize: String {
    fileSizeState.formattedSize
  }

  /// Check if file size is large
  var isFileSizeLarge: Bool {
    fileSizeState.isLarge
  }

  /// Check if file size is approaching warning threshold
  var isFileSizeWarning: Bool {
    fileSizeState.isWarning
  }

  // MARK: - Query Confirmation

  /// Check if a query is a destructive modification statement
  /// Includes: UPDATE, DELETE, INSERT (data modification)
  /// And: DROP, TRUNCATE, ALTER (schema modification)
  func isModificationQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Data modification
    if trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE") || trimmed.hasPrefix("INSERT") {
      return true
    }
    // Schema modification (destructive)
    if trimmed.hasPrefix("DROP") || trimmed.hasPrefix("TRUNCATE") || trimmed.hasPrefix("ALTER") {
      return true
    }
    return false
  }

  /// Check if a query should be blocked in read-only mode
  /// Includes all modification queries + CREATE (schema creation)
  func isBlockedInReadOnlyMode(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // All modification queries are blocked
    if isModificationQuery(query) {
      return true
    }
    // CREATE is also blocked in read-only mode (schema creation)
    if trimmed.hasPrefix("CREATE") {
      return true
    }
    return false
  }

  /// Show confirmation dialog before executing a query based on Safe Mode level
  func confirmAndRunCell(id: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    let query = notebook.cells[index].content

    // Check if connection is in read-only mode
    if let config = notebook.connectionConfig, config.readOnly {
      // Block modification and schema queries in read-only mode
      if isBlockedInReadOnlyMode(query) {
        showToast("Cannot execute this query in read-only mode", type: .error)
        return
      }
    }

    let safeMode = AppSettings.shared.safeMode
    let isModification = isModificationQuery(query)

    // Determine if confirmation is needed based on Safe Mode level
    let needsConfirmation: Bool
    switch safeMode {
    case .silent:
      // No confirmation needed for any query
      needsConfirmation = false
    case .alertRead, .safeRead:
      // Only confirm modification queries
      needsConfirmation = isModification
    case .alertAll, .safeAll:
      // Confirm all queries
      needsConfirmation = true
    }

    if needsConfirmation {
      // Show confirmation dialog
      queryConfirmationState.pendingCellId = id
      queryConfirmationState.pendingQuery = query
      // Check if DELETE/UPDATE without WHERE clause (affects ALL rows)
      queryConfirmationState.affectsAllRows =
        isModification && connectionManager.affectsAllRows(query)
      queryConfirmationState.requiresPassword = safeMode.requiresPassword
      queryConfirmationState.showDialog = true
    } else {
      // Execute directly
      Task {
        await runCell(id: id)
      }
    }
  }

  /// Execute the pending query after user confirmation
  func executePendingQuery() async {
    // Check if it's editor mode or notebook mode
    if viewMode == .editor {
      await executeConfirmedEditorQuery()
    } else {
      guard let cellId = queryConfirmationState.pendingCellId else { return }
      await runCell(id: cellId)

      // Clear pending state
      queryConfirmationState.clear()
    }
  }

  /// Cancel the pending query execution
  func cancelPendingQuery() {
    queryConfirmationState.clear()
  }
}
