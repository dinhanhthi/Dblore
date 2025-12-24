//
//  NotebookViewModel.swift
//  SQLNotebook
//

import SwiftUI
import Observation

/// Content types for the right sidebar
enum SidebarContent: Equatable {
    case jsonViewer(json: String, path: String)
    case cellInfo(columnName: String, columnType: String, value: CellValue)
    case connectionDetails
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

    // Connection config for the sheet
    var editingConnectionConfig: ConnectionConfig
    
    // Database connection manager
    private let connectionManager = DatabaseConnectionManager()

    init(notebook: SQLNotebook = .newDocument()) {
        self.notebook = notebook
        self.editingConnectionConfig = notebook.connectionConfig ?? ConnectionConfig()
    }

    // MARK: - Cell Management

    /// Add a new cell of the specified type
    func addCell(type: CellType, after cellId: UUID? = nil) {
        let newCell = NotebookCell(cellType: type, content: "")

        if let afterId = cellId ?? selectedCellId,
           let index = notebook.cells.firstIndex(where: { $0.id == afterId }) {
            notebook.cells.insert(newCell, at: index + 1)
        } else {
            notebook.cells.append(newCell)
        }

        selectedCellId = newCell.id
    }

    /// Delete a cell by ID
    func deleteCell(id: UUID) {
        guard notebook.cells.count > 1 else { return } // Keep at least one cell

        if let index = notebook.cells.firstIndex(where: { $0.id == id }) {
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
        }
    }

    /// Duplicate a cell
    func duplicateCell(id: UUID) {
        guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

        let original = notebook.cells[index]
        var duplicate = NotebookCell(
            cellType: original.cellType,
            content: original.content
        )
        duplicate.result = nil
        duplicate.executionCount = nil

        notebook.cells.insert(duplicate, at: index + 1)
        selectedCellId = duplicate.id
    }

    /// Move a cell from one position to another
    func moveCell(from source: IndexSet, to destination: Int) {
        notebook.cells.move(fromOffsets: source, toOffset: destination)
    }

    /// Move selected cell up
    func moveSelectedCellUp() {
        guard let id = selectedCellId,
              let index = notebook.cells.firstIndex(where: { $0.id == id }),
              index > 0 else { return }

        notebook.cells.swapAt(index, index - 1)
    }

    /// Move selected cell down
    func moveSelectedCellDown() {
        guard let id = selectedCellId,
              let index = notebook.cells.firstIndex(where: { $0.id == id }),
              index < notebook.cells.count - 1 else { return }

        notebook.cells.swapAt(index, index + 1)
    }

    /// Select next cell, create new one if at the end
    func selectNextCell(createIfNeeded: Bool = true) {
        guard let currentId = selectedCellId,
              let index = notebook.cells.firstIndex(where: { $0.id == currentId }) else {
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
              index > 0 else {
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
    func clearCellOutput(id: UUID) {
        guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }
        notebook.cells[index].result = nil
        notebook.cells[index].executionCount = nil
    }

    /// Clear all cell outputs
    func clearAllOutputs() {
        for index in notebook.cells.indices {
            notebook.cells[index].result = nil
            notebook.cells[index].executionCount = nil
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

    /// Toggle sidebar visibility
    func toggleSidebar() {
        isRightSidebarVisible.toggle()
    }

    /// Close the sidebar
    func closeSidebar() {
        isRightSidebarVisible = false
    }

    // MARK: - Statistics

    var cellCount: Int {
        notebook.cells.count
    }

    var executedCellCount: Int {
        notebook.cells.filter { $0.executionCount != nil }.count
    }
}
