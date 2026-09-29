//
//  CellView+ContextMenu.swift
//  Dblore
//
//  Context menu for CellView, extracted to maintain 400-line limit.
//

import SwiftUI

extension CellView {
  /// Context menu for cell operations
  @ViewBuilder
  var cellContextMenu: some View {
    if cell.isRunning || viewModel.executionQueue.isInQueue(cellId: cell.id) {
      Button {
        viewModel.cancelCell(id: cell.id)
      } label: {
        Label("Cancel Execution", systemImage: "stop.fill")
      }
    } else {
      Button(action: onRun) {
        Label("Run", systemImage: "play.fill")
      }
    }

    Divider()

    Button {
      viewModel.duplicateCell(id: cell.id)
    } label: {
      Label("Duplicate", systemImage: "doc.on.doc")
    }

    Button {
      viewModel.moveSelectedCellUp()
    } label: {
      Label("Move Up", systemImage: "arrow.up")
    }

    Button {
      viewModel.moveSelectedCellDown()
    } label: {
      Label("Move Down", systemImage: "arrow.down")
    }

    Divider()

    Button {
      viewModel.toggleResultVisibility(cellId: cell.id)
    } label: {
      Label(
        cell.isResultVisible ? "Hide Result" : "Show Result",
        systemImage: cell.isResultVisible ? "eye.slash" : "eye"
      )
    }
    .disabled(cell.result == nil)

    Button {
      viewModel.clearCellOutput(id: cell.id)
    } label: {
      Label("Clear Output", systemImage: "trash")
    }
    .disabled(cell.result == nil)

    Button(role: .destructive) {
      viewModel.deleteCell(id: cell.id)
    } label: {
      Label("Delete", systemImage: "trash.fill")
    }
  }
}
