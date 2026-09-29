//
//  TableFilterContent.swift
//  SQLNotebook
//
//  Filter form of the data viewer in the right sidebar: condition rows (column, operator,
//  value, AND/OR). Apply/Clear are in the sidebar footer. Saved filters live in `SavedFiltersPopover`.
//

import SwiftUI

struct TableFilterContent: View {
  @Bindable var viewModel: NotebookViewModel

  private var relation: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  var body: some View {
    ScrollView {
      FilterConditionsEditor(
        conditions: $viewModel.filterDraft.conditions, columns: viewModel.filterColumns,
        onSubmit: { Task { await viewModel.applyFilter() } }
      )
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear { viewModel.prepareFilterDraft() }
    .onChange(of: relation) { viewModel.prepareFilterDraft() }
  }
}

// MARK: - Saved filters

/// Popover of the header Save button: name the current form and save it, load or delete saved ones
struct SavedFiltersPopover: View {
  @Bindable var viewModel: NotebookViewModel

  @State private var saveName = ""

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved filters")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(save)
        Button("Save", action: save)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(trimmedSaveName.isEmpty)
      }

      if !viewModel.savedFilters.isEmpty {
        Divider()
        ForEach(viewModel.savedFilters) { saved in
          HStack(spacing: Spacing.xs) {
            Text(saved.name)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
            Spacer()
            Button("Load") { viewModel.loadSavedFilter(saved) }
              .buttonStyle(GhostButtonStyle())
            Button(action: { viewModel.deleteSavedFilter(saved) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Delete saved filter")
          }
        }
      }
    }
    .padding(Spacing.md)
    .frame(width: 280)
  }

  private func save() {
    if viewModel.saveCurrentFilter(named: saveName) { saveName = "" }
  }
}
