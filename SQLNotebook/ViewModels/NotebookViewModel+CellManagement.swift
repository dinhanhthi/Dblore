//
//  NotebookViewModel+CellManagement.swift
//  SQLNotebook
//

import Foundation
import SwiftUI

// MARK: - Cell Management

extension NotebookViewModel {
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
        MainActor.assumeIsolated {
          target.removeCellForUndo(
            id: newCell.id, restoreSelection: previousSelection, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.restoreCellForUndo(
            cell: deletedCell,
            at: deletedIndex,
            restoreSelection: previousSelection,
            currentSelection: newSelection,
            registerUndo: true
          )
        }
      }
      undoManager.setActionName("Delete Cell")
      onDocumentChanged?()
    }
  }

  /// Helper: Remove cell without keeping at least one (used for undo of add)
  func removeCellForUndo(id: UUID, restoreSelection: UUID?, registerUndo: Bool) {
    guard let index = notebook.cells.firstIndex(where: { $0.id == id }) else { return }

    let deletedCell = notebook.cells[index]
    let deletedIndex = index

    notebook.cells.remove(at: index)
    selectedCellId = restoreSelection

    // Register redo
    if registerUndo {
      let afterId = deletedIndex > 0 ? notebook.cells[deletedIndex - 1].id : nil
      undoManager.registerUndo(withTarget: self) { target in
        MainActor.assumeIsolated {
          target.addCell(type: deletedCell.cellType, after: afterId, registerUndo: true)
        }
      }
    }
  }

  /// Helper: Restore deleted cell (used for undo of delete)
  func restoreCellForUndo(
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
        MainActor.assumeIsolated {
          target.deleteCell(id: cell.id, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.removeCellForUndo(
            id: duplicate.id, restoreSelection: previousSelection, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          // Move back from actualDestination to sourceIndex
          let reverseSource = IndexSet(integer: actualDestination)
          let reverseDestination = sourceIndex < actualDestination ? sourceIndex : sourceIndex + 1
          target.moveCell(from: reverseSource, to: reverseDestination, registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.moveSelectedCellDown(registerUndo: true)
        }
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
        MainActor.assumeIsolated {
          target.moveSelectedCellUp(registerUndo: true)
        }
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
}
