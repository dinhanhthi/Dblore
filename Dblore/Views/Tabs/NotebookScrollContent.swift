//
//  NotebookScrollContent.swift
//  Dblore
//

import SwiftUI

/// The main scrollable content for notebook mode - displays list of cells
struct NotebookScrollContent: View {
  @Bindable var viewModel: NotebookViewModel
  let syncDocument: () -> Void

  var body: some View {
    ScrollViewReader { proxy in
      List {
        ForEach(viewModel.notebook.cells) { cell in
          CellView(
            viewModel: viewModel,
            cell: binding(for: cell.id),
            isSelected: viewModel.selectedCellId == cell.id,
            onRun: {
              viewModel.confirmAndRunCell(id: cell.id)
              syncDocument()
            }
          )
          .id(cell.id)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(
            EdgeInsets(
              top: Spacing.md,
              leading: Spacing.md,
              bottom: Spacing.md,
              trailing: Spacing.xs
            )
          )
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .onChange(of: viewModel.selectedCellId) { _, newId in
        if let id = newId {
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: nil)
          }
        }
      }
    }
  }

  /// Creates a safe binding for a cell by ID
  private func binding(for cellId: UUID) -> Binding<NotebookCell> {
    Binding(
      get: {
        self.viewModel.notebook.cells.first(where: { $0.id == cellId }) ?? NotebookCell()
      },
      set: { newValue in
        if let index = self.viewModel.notebook.cells.firstIndex(where: { $0.id == cellId }) {
          self.viewModel.notebook.cells[index] = newValue
          self.syncDocument()
        }
      }
    )
  }
}
