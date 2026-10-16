//
//  MongoFilterBar.swift
//  Dblore
//
//  MongoDB data viewer filter: an Extended JSON / mongosh filter document above the grid, in
//  place of the SQL filter form. Text that is not a document shows the error inline. An AI
//  button writes the draft from a prompt.
//

import SwiftUI

struct MongoFilterBar: View {
  @Bindable var viewModel: NotebookViewModel
  var aiAssistant: AIAssistantViewModel? = nil
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
      // Top aligned: the icon and buttons stay level with the first line as the field grows
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 11))
          .foregroundColor(appliedFilter.isEmpty ? .foregroundMuted : .accent)
          .frame(height: MongoQueryField.styledLineHeight)
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
        if let aiAssistant {
          MongoAIPromptButton(
            assistant: aiAssistant,
            placeholder: "Describe the filter, or paste a query (e.g. SQL)",
            help: "Write the filter with AI"
          ) { prompt in
            guard let model = viewModel.mongoCollection else { return }
            let reply = try await aiAssistant.mongoAssist(
              .filter, prompt: prompt, database: model.database, collection: model.collection,
              current: draft)
            draft = try AIMongoAssist.filter(fromReply: reply)
            error = nil
          }
          .frame(height: MongoQueryField.styledLineHeight)
        }
        Button("Apply", action: apply)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(viewModel.isEditorQueryRunning)
          .help("Run the filter on the server")
          .frame(height: MongoQueryField.styledLineHeight)
        Button("Clear", action: clear)
          .buttonStyle(GhostButtonStyle())
          .disabled(viewModel.isEditorQueryRunning || (draft.isEmpty && appliedFilter.isEmpty))
          .help("Show every document")
          .frame(height: MongoQueryField.styledLineHeight)
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
    .onAppear {
      draft = appliedFilter
      consumePendingDraft()
    }
    .onChange(of: collection) {
      draft = appliedFilter
      error = nil
    }
    .onChange(of: viewModel.mongoCollection?.pendingFilterDraft) { consumePendingDraft() }
  }

  /// Takes a filter sent from outside the bar (the AI chat) into the draft, without applying it
  private func consumePendingDraft() {
    guard let pending = viewModel.mongoCollection?.pendingFilterDraft else { return }
    draft = pending
    error = nil
    viewModel.mongoCollection?.pendingFilterDraft = nil
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
