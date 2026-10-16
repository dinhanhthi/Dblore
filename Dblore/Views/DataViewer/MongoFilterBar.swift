//
//  MongoFilterBar.swift
//  Dblore
//
//  MongoDB data viewer filter: an Extended JSON / mongosh filter document above the grid, in
//  place of the SQL filter form. Text that is not a document shows the error inline.
//

import SwiftUI

struct MongoFilterBar: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var draft = ""
  @State private var error: DataViewerState.DocumentFilterError?

  /// The collection shown: a new one restarts the draft from its applied filter
  private var collection: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  private var appliedFilter: String { viewModel.dataViewer?.documentFilter ?? "" }

  /// Field names of the shown collection, from the workspace's sampled schema
  private var fieldCompletion: SQLAutocompleteProvider? {
    guard let name = viewModel.dataViewer?.name else { return nil }
    return MongoDocumentAutocompleteProvider(
      collection: name, mode: .filter, source: viewModel.autocompleteProvider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11))
          .foregroundColor(appliedFilter.isEmpty ? .foregroundMuted : .accent)
        MongoQueryField(
          text: $draft,
          placeholder: #"Filter, e.g. {status: "active"}"#,
          autocompleteProvider: fieldCompletion,
          onSubmit: apply
        )
        // One style at every height (switching styles would rebuild the field): its corner
        // radius makes a pill at one line and a rounded card at several
        .inputStyle()
        .onChange(of: draft) { error = nil }
        Button("Apply", action: apply)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(viewModel.isEditorQueryRunning)
          .help("Run the filter on the server")
        Button("Clear", action: clear)
          .buttonStyle(GhostButtonStyle())
          .disabled(viewModel.isEditorQueryRunning || (draft.isEmpty && appliedFilter.isEmpty))
          .help("Show every document")
      }
      if let error {
        Text(error.localizedDescription)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1)
    }
    .onAppear { draft = appliedFilter }
    .onChange(of: collection) {
      draft = appliedFilter
      error = nil
    }
  }

  private func apply() {
    let text = draft
    Task { @MainActor in error = await viewModel.applyDocumentFilter(text) }
  }

  /// Empties the draft only once the clear went through: a cancelled staged-changes prompt
  /// leaves the filter applied, so the bar keeps showing it (as the SQL `clearFilter`)
  private func clear() {
    error = nil
    guard !appliedFilter.isEmpty else {
      draft = ""
      return
    }
    Task { @MainActor in
      await viewModel.clearDocumentFilter()
      if appliedFilter.isEmpty { draft = "" }
    }
  }
}
