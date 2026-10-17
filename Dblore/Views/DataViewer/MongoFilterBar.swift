//
//  MongoFilterBar.swift
//  Dblore
//
//  MongoDB data viewer filter: an Extended JSON / mongosh filter document above the grid, in
//  place of the SQL filter form, with the query options panel, saved queries, Explain and
//  Export Code of the draft, and an AI button that writes the draft from a prompt. Text that is
//  not a document or an option that does not parse shows inline.
//

import SwiftUI

struct MongoFilterBar: View {
  @Bindable var viewModel: NotebookViewModel
  var aiAssistant: AIAssistantViewModel? = nil
  @State private var draft = ""
  @State private var draftOptions = MongoQueryOptions()
  @State private var showsOptions = false
  @State private var error: DataViewerState.DocumentFilterError?
  @State private var showsSavedQueries = false
  @State private var savedQueries: [SavedMongoQuery] = []
  @State private var saveName = ""
  @State private var exportRequest: MongoExportCodeSheet.Request?

  /// The collection shown: a new one restarts the draft from its applied filter
  private var collection: String {
    "\(viewModel.dataViewer?.schema ?? "").\(viewModel.dataViewer?.name ?? "")"
  }

  private var appliedFilter: String { viewModel.dataViewer?.documentFilter ?? "" }

  private var appliedOptions: MongoQueryOptions {
    viewModel.dataViewer?.documentOptions ?? MongoQueryOptions()
  }

  /// Field names of the shown collection, from the workspace's sampled schema
  private var fieldCompletion: SQLAutocompleteProvider? {
    guard let name = viewModel.dataViewer?.name else { return nil }
    return MongoDocumentAutocompleteProvider(
      collection: name, mode: .filter, source: viewModel.autocompleteProvider)
  }

  private var isCleared: Bool {
    draft.isEmpty && draftOptions.isEmpty && appliedFilter.isEmpty && appliedOptions.isEmpty
  }

  private var isExplaining: Bool {
    viewModel.mongoCollection?.explainState == .running
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      filterRow
      if showsOptions {
        MongoQueryOptionsPanel(
          options: $draftOptions, collection: viewModel.dataViewer?.name,
          fieldSource: viewModel.autocompleteProvider, onSubmit: apply)
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
      restartDraft()
      consumePendingDraft()
    }
    .onChange(of: collection) { restartDraft() }
    // The draft follows a filter or options applied elsewhere
    .onChange(of: appliedFilter) {
      if !Self.sameFilter(appliedFilter, draft) { draft = appliedFilter }
    }
    .onChange(of: appliedOptions) { draftOptions = appliedOptions }
    .onChange(of: draftOptions) { error = nil }
    .sheet(item: $exportRequest) { request in
      MongoExportCodeSheet(request: request)
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

  // MARK: - Filter row

  private var filterRow: some View {
    // Top aligned: the icon and buttons stay level with the first line as the field grows
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 11))
        .foregroundColor(
          appliedFilter.isEmpty && appliedOptions.isEmpty ? .foregroundMuted : .accent
        )
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
      Button(optionsTitle) { showsOptions.toggle() }
        .buttonStyle(GhostButtonStyle(isActive: showsOptions))
        .help(showsOptions ? "Hide the query options" : "Show the query options")
        .frame(height: MongoQueryField.styledLineHeight)
      Button("Apply", action: apply)
        .buttonStyle(SecondaryButtonStyle())
        .disabled(viewModel.isEditorQueryRunning)
        .help("Run the filter and options on the server")
        .frame(height: MongoQueryField.styledLineHeight)
      Button("Clear", action: clear)
        .buttonStyle(GhostButtonStyle())
        .disabled(viewModel.isEditorQueryRunning || isCleared)
        .help("Clear the filter and options and show every document")
        .frame(height: MongoQueryField.styledLineHeight)
      savedQueriesButton
        .frame(height: MongoQueryField.styledLineHeight)
      Button("Explain", action: explain)
        .buttonStyle(GhostButtonStyle())
        .disabled(viewModel.mongoCollection == nil || isExplaining)
        .help("Explain the filter and options as typed, with execution statistics")
        .frame(height: MongoQueryField.styledLineHeight)
      Button(action: exportCode) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .disabled(viewModel.dataViewer == nil)
      .help("Export Code: the filter and options as typed, as driver code")
      .accessibilityLabel("Export Code")
      .frame(height: MongoQueryField.styledLineHeight)
    }
  }

  /// "Options", with the number of set options while the panel is hidden
  private var optionsTitle: String {
    let count = draftOptions.setCount
    return showsOptions || count == 0 ? "Options" : "Options (\(count))"
  }

  // MARK: - Saved queries

  private var savedQueriesButton: some View {
    Button {
      refreshSavedQueries()
      showsSavedQueries.toggle()
    } label: {
      Image(systemName: "bookmark")
        .foregroundColor(.foregroundMuted)
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .disabled(savedQueryKey == nil)
    .help("Saved queries")
    .popover(isPresented: $showsSavedQueries, arrowEdge: .bottom) {
      savedQueriesPopover
    }
  }

  /// Name the draft (filter and options) and save it; load or delete saved ones
  private var savedQueriesPopover: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Saved queries")
        .font(.small)
        .foregroundColor(.foregroundMuted)

      HStack(spacing: Spacing.xs) {
        TextField("Name", text: $saveName)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(saveQuery)
        Button("Save", action: saveQuery)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(trimmedSaveName.isEmpty)
          .help("Save the filter and options as typed; a query of the same name is replaced")
      }

      if !savedQueries.isEmpty {
        Divider()
        ForEach(savedQueries) { saved in
          HStack(spacing: Spacing.xs) {
            Text(saved.name)
              .font(.small)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .help(saved.filter)
            Spacer()
            Button("Load") { loadQuery(saved) }
              .buttonStyle(GhostButtonStyle())
              .help("Put the query in the bar without running it")
            Button(action: { deleteQuery(saved) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(iconOnly: true))
            .help("Delete saved query")
          }
        }
      }
    }
    .padding(Spacing.md)
    .frame(width: 280)
  }

  private var trimmedSaveName: String {
    saveName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Saved queries are kept per connection and collection
  private var savedQueryKey: String? {
    guard let state = viewModel.dataViewer, let config = viewModel.notebook.connectionConfig
    else { return nil }
    return SavedFilterStore.key(for: config, schema: state.schema, name: state.name)
  }

  private func refreshSavedQueries() {
    savedQueries = savedQueryKey.map { viewModel.savedFilterStore.listMongoQueries(for: $0) } ?? []
  }

  private func saveQuery() {
    let name = trimmedSaveName
    guard !name.isEmpty, let key = savedQueryKey else { return }
    viewModel.savedFilterStore.saveMongoQuery(
      filter: draft, options: draftOptions, named: name, for: key)
    saveName = ""
    refreshSavedQueries()
  }

  /// Fills the draft (filter and options); nothing runs until Apply
  private func loadQuery(_ saved: SavedMongoQuery) {
    draft = saved.filter
    draftOptions = saved.options
    if !saved.options.isEmpty { showsOptions = true }
    error = nil
    showsSavedQueries = false
  }

  private func deleteQuery(_ saved: SavedMongoQuery) {
    guard let key = savedQueryKey else { return }
    viewModel.savedFilterStore.deleteMongoQuery(id: saved.id, for: key)
    refreshSavedQueries()
  }

  // MARK: - Actions

  /// The applied filter and options of the shown collection; the panel shows when options are set
  private func restartDraft() {
    draft = appliedFilter
    draftOptions = appliedOptions
    showsOptions = !appliedOptions.isEmpty
    error = nil
    refreshSavedQueries()
  }

  private func apply() {
    let text = draft
    let options = draftOptions
    Task { @MainActor in
      error = await viewModel.applyDocumentQuery(filter: text, options: options)
      revealOptionError()
    }
  }

  /// Empties the drafts only once the clear went through: a cancelled staged-changes prompt
  /// leaves the filter and options applied, so the bar keeps showing them (as the SQL
  /// `clearFilter`)
  private func clear() {
    error = nil
    guard !appliedFilter.isEmpty || !appliedOptions.isEmpty else {
      draft = ""
      draftOptions = MongoQueryOptions()
      return
    }
    Task { @MainActor in
      _ = await viewModel.applyDocumentQuery(filter: "", options: MongoQueryOptions())
      if appliedFilter.isEmpty, appliedOptions.isEmpty {
        draft = ""
        draftOptions = MongoQueryOptions()
      }
    }
  }

  /// Explains the draft (filter and options as typed, not the applied page)
  private func explain() {
    guard let model = viewModel.mongoCollection, let command = draftQuery() else { return }
    model.explain(command)
  }

  /// Opens the driver code of the draft (filter and options as typed)
  private func exportCode() {
    guard let command = draftQuery() else { return }
    exportRequest = MongoExportCodeSheet.Request(
      command: command, database: MongoExportCodeSheet.database(for: viewModel))
  }

  /// The `find` of the draft (filter and options as typed, not the applied page); nil with the
  /// error shown inline when it does not parse
  private func draftQuery() -> MongoCommand? {
    guard var state = viewModel.dataViewer else { return nil }
    state.documentFilter = draft
    state.documentOptions = draftOptions
    do {
      let command = try state.userQuery()
      error = nil
      return command
    } catch {
      self.error = error
      revealOptionError()
      return nil
    }
  }

  /// Opens the options panel when the error is not the filter's (so it is an option's), so the
  /// bad option is visible
  private func revealOptionError() {
    guard error != nil, case .success = DataViewerState.documentFilterValue(draft) else { return }
    showsOptions = true
  }

  /// True when the applied filter is the draft once trimmed (`{}` applies as no filter), so an
  /// Apply does not rewrite the field under the caret
  private static func sameFilter(_ applied: String, _ draft: String) -> Bool {
    if applied == draft.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
    guard applied.isEmpty, case .success(nil) = DataViewerState.documentFilterValue(draft)
    else { return false }
    return true
  }
}
