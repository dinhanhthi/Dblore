//
//  CellView+ContextMenu.swift
//  SQLNotebook
//
//  Context menu for CellView, extracted to maintain 400-line limit.
//

import SwiftUI

extension CellView {
  /// Context menu for cell operations
  @ViewBuilder
  var cellContextMenu: some View {
    if cell.isRunning || viewModel.executionQueue.isInQueue(cellId: cell.id) {
      Button(action: { viewModel.cancelCell(id: cell.id) }) {
        Label("Cancel Execution", systemImage: "stop.fill")
      }
    } else {
      Button(action: onRun) {
        Label("Run", systemImage: "play.fill")
      }
    }

    Divider()

    Button(action: { viewModel.duplicateCell(id: cell.id) }) {
      Label("Duplicate", systemImage: "doc.on.doc")
    }

    Button(action: { viewModel.moveSelectedCellUp() }) {
      Label("Move Up", systemImage: "arrow.up")
    }

    Button(action: { viewModel.moveSelectedCellDown() }) {
      Label("Move Down", systemImage: "arrow.down")
    }

    Divider()

    Button(action: { viewModel.toggleResultVisibility(cellId: cell.id) }) {
      Label(
        cell.isResultVisible ? "Hide Result" : "Show Result",
        systemImage: cell.isResultVisible ? "eye.slash" : "eye"
      )
    }
    .disabled(cell.result == nil)

    Button(action: { viewModel.clearCellOutput(id: cell.id) }) {
      Label("Clear Output", systemImage: "trash")
    }
    .disabled(cell.result == nil)

    Button(role: .destructive, action: { viewModel.deleteCell(id: cell.id) }) {
      Label("Delete", systemImage: "trash.fill")
    }
  }
}
