//
//  NotebookViewModel.swift
//  Dblore
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
    cellId: UUID?  // ID of the cell that produced this result (for re-running after edit)
  )
  case executedQuery(query: String, cellId: UUID?)  // Show executed query with syntax highlighting
  case tableFilter  // Filter form of the data viewer tab
  case tableHighlight  // Highlight form of the data viewer tab
}

/// Main view model for the notebook editor
@MainActor
@Observable
class NotebookViewModel {
  // Unique identifier for this view model instance (to scope search notifications)
  let id: UUID = UUID()

  var notebook: DbloreNotebook {
    didSet { connectionConfigDidChange() }
  }
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

  // Note: Connection is now managed at workspace level (WorkspaceManager)
  // These properties are synced from WorkspaceManager for backward compatibility

  // Connection manager reference from workspace (synced from WorkspaceManager)
  // This allows NotebookViewModel extensions to execute queries without refactoring
  var connectionManager: DatabaseConnectionManager?
  /// Workspace mode: another tab opened the pending Protected transaction, so this tab runs
  /// nothing until Commit / Rollback (the actor refuses this tab's `id` too). Set by
  /// `WorkspaceManager`.
  var isTransactionPendingElsewhere = false

  /// Workspace mode: called when the connection's protection level, Safe Mode or protected mode
  /// is changed in this tab (sidebar/footer dialogs), so the workspace, the actor and the other
  /// tabs follow. Set by `WorkspaceManager`.
  @ObservationIgnored var onConnectionProtectionChanged: ((ConnectionConfig) -> Void)?
  /// Workspace mode: awaited after every statement execution in this tab, so the workspace
  /// refreshes its pending-transaction mirror. Set by `WorkspaceManager`.
  @ObservationIgnored var onStatementsExecuted: (@MainActor () async -> Void)?
  /// Global result row cap source (tests pin a value without touching the shared settings)
  @ObservationIgnored var globalRowCap: @MainActor () -> Int = { AppSettings.shared.resultRowCap }
  /// Current Run All batch and the connection epoch its first cell started on (see
  /// `NotebookViewModel+QueueReset.swift`)
  @ObservationIgnored var runAllBatch: (id: UUID, epoch: UInt64)?
  /// Last `notebook.connectionConfig` seen by `connectionConfigDidChange`
  @ObservationIgnored private var observedConnectionConfig: ConnectionConfig?
  @ObservationIgnored private var isApplyingWorkspaceConfig = false

  // Autocomplete provider (replaced by the workspace's shared, schema-loaded provider)
  var autocompleteProvider = SQLAutocompleteProvider()

  // Execution queue for managing cell executions
  private(set) var executionQueue: ExecutionQueue!

  // Undo/Redo manager
  let undoManager = UndoManager()

  // Callback to sync document after changes
  var onDocumentChanged: (() -> Void)?
  /// Last time this tab synced its document (shown in the window footer)
  var lastSaved: Date?

  // MARK: - Toast (delegated to WorkspaceWindowManager)
  // Toast is now managed at app level via WorkspaceWindowManager.shared

  // MARK: - File Size State (10.3.2 optimization)
  var fileSizeState: FileSizeState = FileSizeState()
  @ObservationIgnored var fileSizeExecutionCounter: Int = 0
  @ObservationIgnored let fileSizeCheckInterval: Int = 5  // Check every 5 executions

  // MARK: - Search State (10.3.2 optimization)
  var isSearchPanelVisible: Bool = false
  var searchState: SearchState = SearchState()
  var searchFocusTrigger: UUID = UUID()  // Trigger to force re-focus search field
  @ObservationIgnored var searchTask: Task<Void, Never>?  // Task for cancellation support
  // Task for debounced navigation (10.1.3)
  @ObservationIgnored var searchNavigationTask: Task<Void, Never>?
  @ObservationIgnored var previousFirstResponder: NSResponder?  // Store previous responder

  // MARK: - Query Confirmation State (10.3.2 optimization)
  var queryConfirmationState: QueryConfirmationState = QueryConfirmationState()
  /// Live edit target of the result the sidebar cell was opened from (session-only)
  var cellDetailEditTarget: EditTarget?
  /// Row of the sidebar cell in its result (index into `rows`), to find it again after a re-run
  var cellDetailRow: Int?

  // MARK: - View Mode State
  var viewMode: ViewMode = .notebook
  var editorContent: String = ""  // Content for editor mode
  /// Editor and result side by side (left/right) in this tab; starts from the user default
  var isEditorSideBySide: Bool = AppSettings.shared.editorSideBySideDefault
  var editorResult: CellResult?  // Result for editor mode (single statement or legacy)
  var editorStatementResults: [StatementResult] = []  // Results for multi-statement queries
  var selectedStatementIndex: Int = 0  // Currently selected statement result (0-based)
  var totalExecutionTime: TimeInterval = 0  // Total time for all statements
  /// Table/view data viewer tab state (nil for every other tab)
  var dataViewer: DataViewerState?
  /// Filter form of the data viewer: edited freely, only `applyFilter()` copies it to
  /// `dataViewer.filter`
  var filterDraft = TableFilter(conditions: [])
  /// Filters saved for the connection and table of the data viewer (refreshed on save/delete)
  var savedFilters: [SavedFilter] = []
  /// Relation (`schema.name`) the draft belongs to, to reset it when the viewer shows another
  @ObservationIgnored var filterDraftRelation: String?
  /// Persistent store of the saved filters; tests inject an isolated one
  @ObservationIgnored var savedFilterStore = SavedFilterStore()
  /// Highlight form of the data viewer: only `applyHighlight()` copies it to `dataViewer.highlight`
  var highlightDraft = TableHighlight(filter: TableFilter(conditions: []))
  /// Highlights saved for the connection and table of the data viewer
  var savedHighlights: [SavedHighlight] = []
  /// Relation (`schema.name`) the highlight draft belongs to
  @ObservationIgnored var highlightDraftRelation: String?
  /// An editor run is in flight (Cancel button, `WorkspaceManager.isTransactionOriginRunning`)
  var isEditorQueryRunning = false
  /// Asks before a cancel that discards pending changes (true = cancel); nil shows an alert.
  /// Tests inject the answer.
  @ObservationIgnored var cancelQueryPrompt: (@MainActor (QueryCancelWarning) async -> Bool)?
  weak var editorTextView: SQLTextView?  // Reference to editor text view for getting selection

  init(notebook: DbloreNotebook = .newDocument()) {
    self.notebook = notebook
    observedConnectionConfig = notebook.connectionConfig

    // Initialize execution queue with execution handler
    executionQueue = ExecutionQueue { [weak self] task in
      await self?.executeTask(task)
    }

    // Load sidebar visibility from settings after init
    Task {
      self.isLeftSidebarVisible = AppSettings.shared.isLeftSidebarVisible
    }

    // Calculate initial file size for cache (10.3.4)
    recalculateFileSize()
  }

  // MARK: - Toast Notifications (delegated to WorkspaceWindowManager)

  /// Show toast via app-level toast system
  func showToast(_ message: String, type: ToastMessage.ToastType = .info) {
    WorkspaceWindowManager.shared.showToast(message, type: type)
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

  // MARK: - Workspace Connection Config

  /// Workspace mode: adopt the workspace connection's config, the single source for the
  /// protection policy, per-connection Safe Mode and the DB-password fallback of this tab.
  /// (`connectionConfig` is never written to the notebook file.)
  func applyWorkspaceConnectionConfig(_ config: ConnectionConfig?) {
    guard notebook.connectionConfig != config else { return }
    isApplyingWorkspaceConfig = true
    notebook.connectionConfig = config
    isApplyingWorkspaceConfig = false
  }

  private func connectionConfigDidChange() {
    let current = notebook.connectionConfig
    guard current != observedConnectionConfig else { return }
    let previous = observedConnectionConfig
    observedConnectionConfig = current
    guard !isApplyingWorkspaceConfig, let current, let previous,
      current.protectionLevel != previous.protectionLevel
        || current.safeMode != previous.safeMode
        || current.protectedMode != previous.protectedMode
    else { return }
    onConnectionProtectionChanged?(current)
  }

  // MARK: - Query Confirmation

  /// Protection policy of this notebook's connection, built per execution because the
  /// protection level can change at runtime. Passed to the database execution gate.
  var protectionPolicy: ProtectionPolicy {
    ProtectionPolicy(config: notebook.connectionConfig)
  }

  /// Rows read per statement (notebook cells, editor, Run All, inline-edit refresh): the
  /// connection's row cap override, else the global result row cap.
  var effectiveRowCap: Int {
    SettingsResolver.effectiveRowCap(
      override: notebook.connectionConfig?.rowCapOverride, global: globalRowCap())
  }

  /// The gate's error message if the connection's protection level blocks `query`, else nil.
  /// Same pure check the actor runs before sending, used here to fail fast (no dialog).
  func protectionBlockMessage(for query: String) -> String? {
    let decision = DatabaseConnectionManager.evaluate(
      SQLStatementClassifier.classify(query), policy: protectionPolicy)
    guard case .blocked(let index, let kind, let reason) = decision else { return nil }
    return DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
      .localizedDescription
  }

  /// Show confirmation dialog before executing a query based on Safe Mode level
  func confirmAndRunCell(id: UUID) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    let query = notebook.cells[index].content

    // Protection level is enforced by the database gate; fail fast with its message
    if let message = protectionBlockMessage(for: query) {
      showToast(message, type: .error)
      return
    }

    // Safe Mode: confirm based on every statement of the cell (see statementsNeedingConfirmation)
    if presentConfirmationIfNeeded(for: query, cellId: id) { return }

    Task {
      await runCell(id: id)
    }
  }

  /// Execute the pending query after user confirmation
  func executePendingQuery() async {
    // Run All waiting for the Safe Mode unlock
    if queryConfirmationState.runAllAwaitingUnlock {
      executeUnlockedRunAll()
      return
    }
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
    if queryConfirmationState.runAllAwaitingUnlock {
      queryConfirmationState.clearRunAll()
    }
    queryConfirmationState.clear()
  }
}
