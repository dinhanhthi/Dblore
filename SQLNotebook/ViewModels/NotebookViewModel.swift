//
//  NotebookViewModel.swift
//  SQLNotebook
//

import Observation
import SwiftUI

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
@Observable
class NotebookViewModel {
  var notebook: SQLNotebook
  var connectionState: ConnectionState = .disconnected
  var selectedCellId: UUID?
  var rightSidebarContent: SidebarContent?
  var isRightSidebarVisible: Bool = false
  var executionCounter: Int = 0

  // Left sidebar state
  var isLeftSidebarVisible: Bool = AppSettings.shared.isLeftSidebarVisible
  var databaseTables: [DatabaseTable] = []
  var isLoadingSchema: Bool = false

  // Connection config for the sheet
  var editingConnectionConfig: ConnectionConfig

  // Database connection manager
  let connectionManager = DatabaseConnectionManager()

  // Undo/Redo manager
  let undoManager = UndoManager()

  // Callback to sync document after changes
  var onDocumentChanged: (() -> Void)?

  // Toast notification
  var currentToast: ToastMessage?
  var isToastHovered = false
  private var toastDismissTask: Task<Void, Never>?

  init(notebook: SQLNotebook = .newDocument()) {
    self.notebook = notebook
    self.editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()
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
    toastDismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(4))

      // Wait until toast is no longer hovered
      while isToastHovered {
        try? await Task.sleep(for: .seconds(0.5))
      }

      // Dismiss only if the message matches (user might have shown a new toast)
      if currentToast?.message == message {
        currentToast = nil
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
}
