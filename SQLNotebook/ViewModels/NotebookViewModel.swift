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
  private let connectionManager = DatabaseConnectionManager()

  // Undo/Redo manager
  let undoManager = UndoManager()

  // Callback to sync document after changes
  var onDocumentChanged: (() -> Void)?

  init(notebook: SQLNotebook = .newDocument()) {
    self.notebook = notebook
    self.editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()
  }

  // MARK: - Cell Management

  /// Add a new cell of the specified type
  func addCell(type: CellType, after cellId: UUID? = nil, registerUndo: Bool = true) {
    let newCell = NotebookCell(cellType: type, content: "")
    let insertionIndex: Int

    if let afterId = cellId ?? selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == afterId })
    {
      insertionIndex = index + 1
      notebook.cells.insert(newCell, at: insertionIndex)
    } else {
      insertionIndex = notebook.cells.count
      notebook.cells.append(newCell)
    }

    let previousSelection = selectedCellId
    selectedCellId = newCell.id

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.removeCellForUndo(
          id: newCell.id, restoreSelection: previousSelection, registerUndo: true)
      }
      undoManager.setActionName("Add Cell")
      onDocumentChanged?()
    }
  }

  /// Delete a cell by ID
  func deleteCell(id: UUID, registerUndo: Bool = true) {
    guard notebook.cells.count > 1 else { return }  // Keep at least one cell

    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let deletedCell = notebook.cells[index]
    let deletedIndex = index
    let previousSelection = selectedCellId

    notebook.cells.remove(at: index)

    // Update selection
    if selectedCellId == id {
      if index > 0 {
        selectedCellId = notebook.cells[index - 1].id
      } else if !notebook.cells.isEmpty {
        selectedCellId = notebook.cells[0].id
      } else {
        selectedCellId = nil
      }
    }

    // Register undo
    if registerUndo {
      let newSelection = selectedCellId
      undoManager.registerUndo(withTarget: self) { target in
        target.restoreCellForUndo(
          cell: deletedCell,
          at: deletedIndex,
          restoreSelection: previousSelection,
          currentSelection: newSelection,
          registerUndo: true
        )
      }
      undoManager.setActionName("Delete Cell")
      onDocumentChanged?()
    }
  }

  /// Helper: Remove cell without keeping at least one (used for undo of add)
  private func removeCellForUndo(id: UUID, restoreSelection: UUID?, registerUndo: Bool) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let deletedCell = notebook.cells[index]
    let deletedIndex = index

    notebook.cells.remove(at: index)
    selectedCellId = restoreSelection

    // Register redo
    if registerUndo {
      let afterId = deletedIndex > 0 ? notebook.cells[deletedIndex - 1].id : nil
      undoManager.registerUndo(withTarget: self) { target in
        target.addCell(type: deletedCell.cellType, after: afterId, registerUndo: true)
      }
    }
  }

  /// Helper: Restore deleted cell (used for undo of delete)
  private func restoreCellForUndo(
    cell: NotebookCell,
    at index: Int,
    restoreSelection: UUID?,
    currentSelection: UUID?,
    registerUndo: Bool
  ) {
    notebook.cells.insert(cell, at: index)
    selectedCellId = restoreSelection

    // Register redo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.deleteCell(id: cell.id, registerUndo: true)
      }
    }
  }

  /// Duplicate a cell
  func duplicateCell(id: UUID, registerUndo: Bool = true) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let original = notebook.cells[index]
    var duplicate = NotebookCell(
      cellType: original.cellType,
      content: original.content
    )
    duplicate.result = nil
    duplicate.executionCount = nil

    let previousSelection = selectedCellId
    notebook.cells.insert(duplicate, at: index + 1)
    selectedCellId = duplicate.id

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.removeCellForUndo(
          id: duplicate.id, restoreSelection: previousSelection, registerUndo: true)
      }
      undoManager.setActionName("Duplicate Cell")
      onDocumentChanged?()
    }
  }

  /// Move a cell from one position to another
  func moveCell(from source: IndexSet, to destination: Int, registerUndo: Bool = true) {
    guard let sourceIndex = source.first else { return }

    // Calculate actual destination after removal
    let actualDestination = sourceIndex < destination ? destination - 1 : destination

    notebook.cells.move(fromOffsets: source, toOffset: destination)

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        // Move back from actualDestination to sourceIndex
        let reverseSource = IndexSet(integer: actualDestination)
        let reverseDestination = sourceIndex < actualDestination ? sourceIndex : sourceIndex + 1
        target.moveCell(from: reverseSource, to: reverseDestination, registerUndo: true)
      }
      undoManager.setActionName("Move Cell")
      onDocumentChanged?()
    }
  }

  /// Move selected cell up
  func moveSelectedCellUp(registerUndo: Bool = true) {
    guard let id = selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == id }),
      index > 0
    else { return }

    notebook.cells.swapAt(index, index - 1)

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.moveSelectedCellDown(registerUndo: true)
      }
      undoManager.setActionName("Move Cell Up")
      onDocumentChanged?()
    }
  }

  /// Move selected cell down
  func moveSelectedCellDown(registerUndo: Bool = true) {
    guard let id = selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == id }),
      index < notebook.cells.count - 1
    else { return }

    notebook.cells.swapAt(index, index + 1)

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.moveSelectedCellUp(registerUndo: true)
      }
      undoManager.setActionName("Move Cell Down")
      onDocumentChanged?()
    }
  }

  /// Select next cell, create new one if at the end
  func selectNextCell(createIfNeeded: Bool = true) {
    guard let currentId = selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == currentId })
    else {
      // If no cell selected, select first cell
      if !notebook.cells.isEmpty {
        selectedCellId = notebook.cells[0].id
      }
      return
    }

    if index < notebook.cells.count - 1 {
      selectedCellId = notebook.cells[index + 1].id
    } else if createIfNeeded {
      // At the last cell, create a new one
      addCell(type: .sql, after: currentId)
    }
  }

  /// Insert a new cell below and select it
  func insertCellBelow(type: CellType = .sql) {
    guard let currentId = selectedCellId else {
      addCell(type: type)
      return
    }
    addCell(type: type, after: currentId)
  }

  /// Select previous cell
  func selectPreviousCell() {
    guard let currentId = selectedCellId,
      let index = notebook.cells.firstIndex(where: { $0.id == currentId }),
      index > 0
    else {
      // If no cell selected, select last cell
      if !notebook.cells.isEmpty {
        selectedCellId = notebook.cells[notebook.cells.count - 1].id
      }
      return
    }

    selectedCellId = notebook.cells[index - 1].id
  }

  // MARK: - Cell Execution

  /// Run a specific cell
  func runCell(id: UUID) async {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
    guard notebook.cells[index].cellType == .sql else { return }
    guard connectionState.isConnected else {
      notebook.cells[index].result = .errorResult("Not connected to database")
      return
    }

    notebook.cells[index].isRunning = true

    let query = notebook.cells[index].content

    do {
      // Execute query using DatabaseConnectionManager
      let queryResult = try await connectionManager.executeQuery(query)

      executionCounter += 1

      // Convert QueryResult to CellResult
      let result = CellResult(
        columns: queryResult.columns,
        rows: queryResult.rows,
        executionTime: queryResult.executionTime,
        rowCount: queryResult.rowCount,
        timestamp: Date(),
        wasLimited: queryResult.wasLimited
      )

      notebook.cells[index].result = result
      notebook.cells[index].executionCount = executionCounter
    } catch let error as DatabaseError {
      // Handle database-specific errors
      let executionTime = error.executionTime ?? 0
      notebook.cells[index].result = .errorResult(
        error.localizedDescription,
        executionTime: executionTime
      )
    } catch {
      // Handle general errors
      notebook.cells[index].result = .errorResult(error.localizedDescription)
    }

    notebook.cells[index].isRunning = false
  }

  /// Run all SQL cells sequentially
  func runAllCells() async {
    for cell in notebook.cells where cell.cellType == .sql {
      await runCell(id: cell.id)
    }
  }

  /// Clear output from a specific cell
  func clearCellOutput(id: UUID, registerUndo: Bool = true) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let previousResult = notebook.cells[index].result
    let previousExecutionCount = notebook.cells[index].executionCount

    notebook.cells[index].result = nil
    notebook.cells[index].executionCount = nil

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.restoreCellOutput(
          id: id,
          result: previousResult,
          executionCount: previousExecutionCount,
          registerUndo: true
        )
      }
      undoManager.setActionName("Clear Output")
      onDocumentChanged?()
    }
  }

  /// Helper: Restore cell output (used for undo of clear)
  private func restoreCellOutput(
    id: UUID, result: CellResult?, executionCount: Int?, registerUndo: Bool
  ) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    notebook.cells[index].result = result
    notebook.cells[index].executionCount = executionCount

    // Register redo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.clearCellOutput(id: id, registerUndo: true)
      }
    }
  }

  /// Clear all cell outputs
  func clearAllOutputs(registerUndo: Bool = true) {
    var previousOutputs: [(id: UUID, result: CellResult?, executionCount: Int?)] = []

    for index in notebook.cells.indices {
      let cell = notebook.cells[index]
      previousOutputs.append(
        (id: cell.id, result: cell.result, executionCount: cell.executionCount))
      notebook.cells[index].result = nil
      notebook.cells[index].executionCount = nil
    }

    // Register undo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.restoreAllOutputs(outputs: previousOutputs, registerUndo: true)
      }
      undoManager.setActionName("Clear All Outputs")
      onDocumentChanged?()
    }
  }

  /// Helper: Restore all cell outputs (used for undo of clear all)
  private func restoreAllOutputs(
    outputs: [(id: UUID, result: CellResult?, executionCount: Int?)], registerUndo: Bool
  ) {
    for output in outputs {
      if let index = notebook.cells.firstIndex(where: { $0.id == output.id }) {
        notebook.cells[index].result = output.result
        notebook.cells[index].executionCount = output.executionCount
      }
    }

    // Register redo
    if registerUndo {
      undoManager.registerUndo(withTarget: self) { target in
        target.clearAllOutputs(registerUndo: true)
      }
    }
  }

  // MARK: - Connection Management

  /// Connect to database
  func connect() async throws {
    connectionState = .connecting

    do {
      try await connectionManager.connect(config: editingConnectionConfig)
      notebook.connectionConfig = editingConnectionConfig
      connectionState = .connected

      // Auto-load database schema after successful connection
      await loadDatabaseSchema()
    } catch {
      connectionState = .error(error.localizedDescription)
      throw error
    }
  }

  /// Disconnect from database
  func disconnect() {
    Task {
      await connectionManager.disconnect()
      connectionState = .disconnected

      // Clear database schema when disconnected
      databaseTables = []
    }
  }

  /// Test the current connection configuration
  func testConnection() async -> Bool {
    do {
      return try await connectionManager.testConnection(config: editingConnectionConfig)
    } catch {
      return false
    }
  }

  // MARK: - Sidebar

  /// Show JSON in the sidebar
  func showJSONInSidebar(json: String, path: String) {
    rightSidebarContent = .jsonViewer(json: json, path: path)
    isRightSidebarVisible = true
  }

  /// Show cell value details in sidebar
  func showCellDetail(columnName: String, columnType: String, value: CellValue) {
    rightSidebarContent = .cellInfo(columnName: columnName, columnType: columnType, value: value)
    isRightSidebarVisible = true
  }

  /// Show connection details in sidebar
  func showConnectionDetails() {
    rightSidebarContent = .connectionDetails
    isRightSidebarVisible = true
  }

  /// Show connection form in sidebar
  func showConnectionForm() {
    rightSidebarContent = .connectionForm
    isRightSidebarVisible = true
  }

  /// Toggle sidebar visibility
  func toggleSidebar() {
    isRightSidebarVisible.toggle()
  }

  /// Close the sidebar
  func closeSidebar() {
    isRightSidebarVisible = false
  }

  // MARK: - Left Sidebar - Database Schema

  /// Toggle left sidebar visibility
  func toggleLeftSidebar() {
    isLeftSidebarVisible.toggle()
  }

  /// Load database schema (tables and columns)
  func loadDatabaseSchema() async {
    guard connectionState.isConnected else {
      databaseTables = []
      return
    }

    isLoadingSchema = true

    do {
      // Fetch tables
      var tables = try await connectionManager.fetchTables()

      // Fetch columns for each table
      for index in tables.indices {
        let table = tables[index]
        do {
          let columns = try await connectionManager.fetchColumns(
            tableSchema: table.schema,
            tableName: table.name
          )
          tables[index].columns = columns
        } catch {
          // If fetching columns fails, continue with other tables
          print("Failed to fetch columns for \(table.qualifiedName): \(error)")
        }
      }

      databaseTables = tables
    } catch {
      print("Failed to load database schema: \(error)")
      databaseTables = []
    }

    isLoadingSchema = false
  }

  /// Refresh database schema
  func refreshDatabaseSchema() async {
    await loadDatabaseSchema()
  }

  /// Toggle table expansion state
  func toggleTableExpansion(tableId: UUID) {
    if let index = databaseTables.firstIndex(where: { $0.id == tableId }) {
      databaseTables[index].isExpanded.toggle()
    }
  }

  /// Insert text into selected cell at cursor position
  func insertTextIntoSelectedCell(_ text: String) {
    // Post notification to insert text - will be handled by CellView
    NotificationCenter.default.post(
      name: .insertTextIntoCell,
      object: nil,
      userInfo: ["text": text]
    )
  }

  // MARK: - Statistics

  var cellCount: Int {
    notebook.cells.count
  }

  var executedCellCount: Int {
    notebook.cells.filter { $0.executionCount != nil }.count
  }
}
