//
//  NotebookViewModel.swift
//  SQLNotebook
//

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
  case connectionDetails
  case connectionForm
  case settings
}

/// Main view model for the notebook editor
@MainActor
@Observable
class NotebookViewModel {
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
  var isLoadingSchema: Bool = false
  var areAllEntitiesExpanded: Bool = false  // Track expand/collapse state

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

  // Toast notification
  var currentToast: ToastMessage?
  var isToastHovered = false
  private var toastDismissTask: Task<Void, Never>?

  // File size warning tracking
  var showFileSizeWarningDialog = false
  var showFileSizeLargeDialog = false
  var hasShownWarningDialog = false
  var hasShownLargeDialog = false

  // MARK: - Search State
  var isSearchPanelVisible: Bool = false
  var searchState: SearchState = SearchState()
  var searchFocusTrigger: UUID = UUID()  // Trigger to force re-focus search field
  var searchTask: Task<Void, Never>?  // Task for cancellation support

  // MARK: - Query Confirmation State
  var showQueryConfirmationDialog = false
  var pendingQueryCellId: UUID?
  var pendingQuery: String = ""

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

  init(notebook: SQLNotebook = .newDocument()) {
    self.notebook = notebook
    editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()

    // Initialize execution queue with execution handler
    executionQueue = ExecutionQueue { [weak self] task in
      await self?.executeTask(task)
    }

    // Set connection manager for autocomplete provider
    autocompleteProvider.setConnectionManager(connectionManager)

    // Load sidebar visibility from settings after init
    Task {
      self.isLeftSidebarVisible = AppSettings.shared.isLeftSidebarVisible
    }
  }

  // MARK: - Toast Notifications

  func showToast(_ message: String, type: ToastMessage.ToastType = .info) {
    currentToast = ToastMessage(message: message, type: type)
    startToastDismissTimer(for: message)
  }

  private func startToastDismissTimer(for message: String) {
    // Cancel any existing dismiss task
    toastDismissTask?.cancel()

    // Auto-dismiss after 4 seconds, but only if not hovered
    toastDismissTask = Task {
      try? await Task.sleep(for: .seconds(4))

      // Wait until toast is no longer hovered
      while self.isToastHovered {
        try? await Task.sleep(for: .seconds(0.5))
      }

      // Dismiss only if the message matches (user might have shown a new toast)
      if self.currentToast?.message == message {
        self.currentToast = nil
      }
    }
  }

  func setToastHovered(_ hovered: Bool) {
    isToastHovered = hovered
  }

  // MARK: - Statistics

  var cellCount: Int {
    notebook.cells.count
  }

  var executedCellCount: Int {
    notebook.cells.filter { $0.executionCount != nil }.count
  }

  /// Calculate current file size (with results if enabled in settings)
  var estimatedFileSize: Int64 {
    let includeResults = AppSettings.getIncludeResultsOnSave()
    return
      (try? FileOptimizationService.calculateNotebookSize(notebook, includeResults: includeResults))
      ?? 0
  }

  /// Get formatted file size string
  var formattedFileSize: String {
    FileOptimizationService.formatFileSize(estimatedFileSize)
  }

  /// Check if file size is large
  var isFileSizeLarge: Bool {
    estimatedFileSize > FileOptimizationService.largeSizeThreshold
  }

  /// Check if file size is approaching warning threshold
  var isFileSizeWarning: Bool {
    estimatedFileSize > FileOptimizationService.warningSizeThreshold
  }

  // MARK: - Query Confirmation

  /// Check if a query is a destructive modification statement (UPDATE, DELETE, INSERT)
  func isModificationQuery(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE") || trimmed.hasPrefix("INSERT")
  }

  /// Show confirmation dialog before executing a destructive query
  func confirmAndRunCell(id: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    let query = notebook.cells[index].content

    // Check if connection is in read-only mode
    if let config = notebook.connectionConfig, config.readOnly {
      // Block modification queries in read-only mode
      if isModificationQuery(query) {
        showToast("Cannot execute modification queries in read-only mode", type: .error)
        return
      }
    }

    // Check if query is a modification query
    if isModificationQuery(query) {
      // Check if user wants to bypass confirmation
      if AppSettings.shared.bypassDestructiveQueryConfirmation {
        // Execute directly if bypass is enabled
        Task {
          await runCell(id: id)
        }
      } else {
        // Show confirmation dialog
        pendingQueryCellId = id
        pendingQuery = query
        showQueryConfirmationDialog = true
      }
    } else {
      // Execute directly if not a modification query
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
      guard let cellId = pendingQueryCellId else { return }
      await runCell(id: cellId)

      // Clear pending state
      pendingQueryCellId = nil
      pendingQuery = ""
    }
  }

  /// Cancel the pending query execution
  func cancelPendingQuery() {
    pendingQueryCellId = nil
    pendingQuery = ""
    showQueryConfirmationDialog = false
  }
}
