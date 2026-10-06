//
//  CellParametersFormView.swift
//  Dblore
//
//  A cell's inline :name parameter form: one ParameterInputBlock per detected name,
//  flowed into as many adaptive columns as the cell width allows, plus the per-cell
//  "Save values in file" choice.
//

import SwiftUI

struct CellParametersFormView: View {
  @Bindable var viewModel: NotebookViewModel
  let cell: NotebookCell

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(
              minimum: ComponentSize.parameterBlockMinWidth,
              maximum: ComponentSize.parameterBlockMaxWidth),
            alignment: .top)
        ],
        alignment: .leading,
        spacing: Spacing.md
      ) {
        ForEach(viewModel.parameterNames(in: cell.content), id: \.self) { name in
          ParameterInputBlock(
            name: name,
            stored: cell.parameters.first { $0.name == name },
            // Writes go through the view model so its dirty-marking rules apply.
            onStore: { viewModel.updateParameter($0, for: name, cellId: cell.id) }
          )
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Toggle("Save values in file", isOn: savesValuesBinding)
          .toggleStyle(.checkbox)
          .font(.small)
          .foregroundColor(.foreground)
          .controlSize(.small)
          .fixedSize()
        Text(persistenceNote)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Reading the flag from `cell` keeps the toggle in step with undo and reloads.
  private var savesValuesBinding: Binding<Bool> {
    Binding(
      get: { cell.savesParameterValues },
      set: { viewModel.setSavesParameterValues($0, cellId: cell.id) }
    )
  }

  private var persistenceNote: String {
    cell.savesParameterValues
      ? "Values are saved in plain text in the notebook file."
      : "Values stay until this tab closes."
  }
}
