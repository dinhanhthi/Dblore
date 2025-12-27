//
//  NotebookViewModel.swift
//  SQLNotebook
//

import Observation
import SwiftUI

/// Content types for the right sidebar
enum SidebarContent: Equatable {
  case jsonViewer(json: String, path: String)
  case cellInfo(columnName: String, columnType: String, value: CellValue)
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
  var isLeftSidebarVisible: Bool = false
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

  init(notebook: SQLNotebook = .newDocument()) {
    self.notebook = notebook
    self.editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()
  }

  // MARK: - Statistics

  var cellCount: Int {
    notebook.cells.count
  }

  var executedCellCount: Int {
    notebook.cells.filter { $0.executionCount != nil }.count
  }
}
