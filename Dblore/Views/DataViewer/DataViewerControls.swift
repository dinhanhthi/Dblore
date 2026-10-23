//
//  DataViewerControls.swift
//  Dblore
//
//  Data viewer header controls: table title, MongoDB collection sections, + Row, Bulk Update /
//  Delete, Export, and staged-change actions.
//  Rows-per-page, column visibility, paging, and the Grid / Chart slider sit
//  in DataViewerPagingBar under the result table. The slider is trailing.
//

import SwiftUI

/// Left side of the header in data viewer mode
struct DataViewerControls: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showPreview = false
  @State private var confirmDiscard = false

  /// Commit is click-only. Cmd+S stays Save in `DbloreApp`.
  static let commitKeyEquivalent: KeyEquivalent? = nil

  /// "14 changes · 2 inserts, 4 edits, 8 deletes"
  static func stagedChangesSummary(_ counts: RowChangeSet.Counts) -> String {
    let total = counts.inserts + counts.edits + counts.deletes
    let changes = total == 1 ? "change" : "changes"
    let inserts = countPhrase(counts.inserts, "insert")
    let edits = countPhrase(counts.edits, "edit")
    let deletes = countPhrase(counts.deletes, "delete")
    return "\(total) \(changes) · \(inserts), \(edits), \(deletes)"
  }

  var body: some View {
    if let state = viewModel.dataViewer {
      HStack(spacing: Spacing.sm) {
        Text(state.title)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundColor(.accent)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(state.title)

        Divider().frame(height: 14)

        // MongoDB collection sections; + Row only stages into the Documents section
        if let model = viewModel.mongoCollection {
          MongoCollectionTabBar(model: model, documentCount: state.totalRows)
          if model.section == .documents {
            Divider().frame(height: 14)
            addRowButton
            if viewModel.canBulkWriteMongoDocuments { bulkWriteButton }
            exportButton(model)
          }
        } else {
          addRowButton
        }

        if let counts = viewModel.stagedChangeCounts {
          stagedSummary(counts)
          previewButton
          discardButton
          commitButton
        }
      }
      .sheet(isPresented: $showPreview) {
        StagedChangesPreviewSheet(viewModel: viewModel)
      }
      .confirmationDialog(
        "Discard staged changes?",
        isPresented: $confirmDiscard,
        titleVisibility: .visible
      ) {
        Button("Discard", role: .destructive) { viewModel.discardStaged() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Staged inserts, edits, and deletes on this page will be dropped.")
      }
      .confirmationDialog(
        "Staged changes",
        isPresented: leavePromptPresented,
        titleVisibility: .visible
      ) {
        Button("Commit") { viewModel.resolveStagedLeavePrompt(.commit) }
        Button("Discard", role: .destructive) { viewModel.resolveStagedLeavePrompt(.discard) }
        Button("Cancel", role: .cancel) { viewModel.resolveStagedLeavePrompt(.cancel) }
      } message: {
        Text(
          "Commit or discard staged row changes before continuing. Cancel keeps them."
        )
      }
      .confirmationDialog(
        "Foreign key may block this delete",
        isPresented: blockerPromptPresented,
        titleVisibility: .visible
      ) {
        Button("Commit Anyway", role: .destructive) {
          viewModel.resolveStagedBlockerPrompt(commitAnyway: true)
        }
        Button("Cancel", role: .cancel) {
          viewModel.resolveStagedBlockerPrompt(commitAnyway: false)
        }
      } message: {
        Text(
          ((viewModel.stagedBlockerPrompt?.blockers.map(\.text) ?? [])
            + [Self.commitAnywayNote]).joined(separator: "\n\n"))
      }
    }
  }

  /// Next to Commit Anyway: the counts are advisory, the server enforces the keys
  static let commitAnywayNote =
    "The database decides: it refuses the delete if these rows still refer to it."

  /// Dismissal without a button choice cancels on the next turn, as for the leave prompt
  private var blockerPromptPresented: Binding<Bool> {
    Binding(
      get: { viewModel.stagedBlockerPrompt != nil },
      set: { isPresented in
        guard !isPresented else { return }
        Task { @MainActor in viewModel.resolveStagedBlockerPrompt(commitAnyway: false) }
      }
    )
  }

  /// Dialog dismissal without a button choice cancels on the next turn, after a button
  /// has already resumed the prompt.
  private var leavePromptPresented: Binding<Bool> {
    Binding(
      get: { viewModel.stagedLeavePromptVisible },
      set: { isPresented in
        guard !isPresented else { return }
        Task { @MainActor in viewModel.cancelStagedLeavePromptIfNeeded() }
      }
    )
  }

  /// "a–b of N" once the total is known, "a–b" while it is not; "0 rows" or "Page X" when the
  /// page has no rows
  static func pageLabel(state: DataViewerState, loadedRows: Int) -> String {
    guard let range = state.rowRange(loadedRows: loadedRows) else {
      return state.totalRows == 0 ? "0 rows" : "Page \(state.page)"
    }
    let span = "\(range.lowerBound)–\(range.upperBound)"
    guard let total = state.totalRows else { return span }
    return "\(span) of \(total)"
  }

  private static func countPhrase(_ count: Int, _ singular: String) -> String {
    "\(count) \(count == 1 ? singular : singular + "s")"
  }

  private var addRowButton: some View {
    Button(action: stageNewRow) {
      dataViewerCapsuleLabel {
        Text("+ Row")
          .font(.system(size: 11))
          .foregroundColor(viewModel.stagingEnabled ? .foreground : .foregroundMuted)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .disabled(!viewModel.stagingEnabled)
    .help(viewModel.rowStagingUnavailableReason ?? "Fill in a new row")
    .overlay { disabledStagingHelp }
  }

  /// Opens the bulk write form (hosted by `DataViewerView`, as the header is too small)
  private var bulkWriteButton: some View {
    Button(action: viewModel.openMongoBulkWrite) {
      dataViewerCapsuleLabel {
        Text("Bulk Update / Delete…")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help("Update or delete every document matching a filter")
  }

  /// Opens the Export form (hosted by `DataViewerView`): the applied query when a filter or
  /// options are set, else the whole collection. A read: offered on read-only connections too.
  private func exportButton(_ collection: MongoCollectionModel) -> some View {
    Button(action: { openExport(collection) }) {
      dataViewerCapsuleLabel {
        Text("Export...")
          .font(.system(size: 11))
          .foregroundColor(viewModel.connectionState == .connected ? .foreground : .foregroundMuted)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .disabled(viewModel.connectionState != .connected)
    .help("Export the documents as Extended JSON or CSV")
  }

  private func openExport(_ collection: MongoCollectionModel) {
    guard collection.export == nil, let manager = viewModel.connectionManager,
      let state = viewModel.dataViewer
    else { return }
    let wholeCollection = MongoCommand.find(
      collection: state.name, filter: nil, projection: nil, sort: nil, skip: nil, limit: nil)
    // A filter or options that do not parse export nothing but the whole collection
    let query = (try? state.userQuery()).flatMap { $0 == wholeCollection ? nil : $0 }
    collection.export = MongoExportModel(
      collection: state.name, database: collection.database, query: query,
      connectionManager: manager, caller: viewModel.id)
  }

  private func stageNewRow() {
    Task { await viewModel.toggleAddRowForm() }
  }

  private func stagedSummary(_ counts: RowChangeSet.Counts) -> some View {
    let total = counts.inserts + counts.edits + counts.deletes
    let changes = total == 1 ? "change" : "changes"
    return
      (Text("\(total) \(changes)")
      .foregroundColor(.foreground)
      + Text(" · ")
      .foregroundColor(.foregroundSubtle)
      + Text(Self.countPhrase(counts.inserts, "insert"))
      .foregroundColor(.success)
      + Text(", ")
      .foregroundColor(.foregroundSubtle)
      + Text(Self.countPhrase(counts.edits, "edit"))
      .foregroundColor(.warning)
      + Text(", ")
      .foregroundColor(.foregroundSubtle)
      + Text(Self.countPhrase(counts.deletes, "delete"))
      .foregroundColor(.destructive))
      .font(.monoSmall)
      .lineLimit(1)
      .help(Self.stagedChangesSummary(counts))
      .accessibilityLabel(Self.stagedChangesSummary(counts))
  }

  private var previewButton: some View {
    Button(action: { showPreview = true }) {
      dataViewerCapsuleLabel {
        Text(viewModel.isMongoDataViewer ? "Preview" : "Preview SQL")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help(
      viewModel.isMongoDataViewer
        ? "Show the staged commands. Nothing is sent to the database."
        : "Show the staged SQL. Nothing is sent to the database.")
  }

  private var discardButton: some View {
    Button(action: { confirmDiscard = true }) {
      dataViewerCapsuleLabel {
        Text("Discard")
          .font(.system(size: 11))
          .foregroundColor(.destructive)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help("Discard staged changes")
  }

  @ViewBuilder
  private var commitButton: some View {
    if let key = Self.commitKeyEquivalent {
      commitButtonBase.keyboardShortcut(key)
    } else {
      commitButtonBase
    }
  }

  /// Same capsule metrics as Preview SQL and Discard. Accent fill keeps it the primary action.
  private var commitButtonBase: some View {
    Button(action: { Task { await viewModel.commitStaged() } }) {
      dataViewerCapsuleLabel(fill: .accentFill, bordered: false) {
        HStack(spacing: Spacing.xs) {
          if viewModel.isCheckingStagedDeletes {
            ProgressView().controlSize(.mini)
          }
          Text("Commit")
            .font(.system(size: 11))
            // Matches the selected slider segment
            .foregroundColor(.onAccentFill)
        }
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .opacity(viewModel.stagingEnabled ? 1 : 0.5)
    .disabled(!viewModel.stagingEnabled || viewModel.isCheckingStagedDeletes)
    .help(
      viewModel.rowStagingUnavailableReason
        ?? (viewModel.isCheckingStagedDeletes
          ? "Checking related rows…" : "Commit staged changes")
    )
    .overlay { disabledStagingHelp }
  }

  /// Disabled controls do not show help on their own; this overlay does.
  @ViewBuilder
  private var disabledStagingHelp: some View {
    if !viewModel.stagingEnabled, let reason = viewModel.rowStagingUnavailableReason {
      Color.clear
        .contentShape(Rectangle())
        .help(reason)
    }
  }

}

/// Rows per page, column visibility, paging, and the Grid / Chart slider.
/// Sits under the result table. The slider is on the trailing edge.
struct DataViewerPagingBar: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showColumns = false

  var body: some View {
    if let state = viewModel.dataViewer {
      HStack(spacing: Spacing.sm) {
        pageSizeMenu(state: state)
        columnsButton(state: state)

        Text(
          DataViewerControls.pageLabel(
            state: state, loadedRows: viewModel.editorResult?.rows.count ?? 0)
        )
        .font(.monoSmall)
        .foregroundColor(.foregroundSubtle)

        HStack(spacing: 0) {
          pageButton("chevron.left", help: "Previous page", enabled: state.canGoPrevious) {
            await viewModel.goToPage(state.page - 1)
          }
          pageButton("chevron.right", help: "Next page", enabled: state.canGoNext) {
            await viewModel.goToPage(state.page + 1)
          }
        }

        if let summary = selectionSummary {
          ResultSelectionSummaryView(summary: summary)
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)
        }

        Spacer(minLength: Spacing.sm)

        let tabs = displayTabs
        if tabs.count > 1 {
          ResultDisplayPicker(mode: $viewModel.dataViewerDisplayMode, tabs: tabs, large: true)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.appBackground)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(Color.foregroundMuted.opacity(0.1))
          .frame(height: 1)
      }
    }
  }

  /// Selected rows of the grid, in Grid mode and the Documents section of a collection only
  private var selectionSummary: ResultSelectionSummary? {
    guard viewModel.dataViewerDisplayMode == .grid,
      (viewModel.mongoCollection?.section ?? .documents) == .documents
    else { return nil }
    return viewModel.editorSelectionSummary
  }

  /// Same rule as the in-grid picker: a loaded page, with Documents and JSON for a MongoDB
  /// collection and Chart when it can be plotted. One tab hides the picker.
  private var displayTabs: [ResultDisplayMode] {
    guard let result = viewModel.editorResult, result.error == nil else { return [] }
    let showingRows =
      !result.rows.isEmpty
      || viewModel.dataViewer?.changeSet?.inserts.isEmpty == false
      || viewModel.dataViewer?.documentChangeSet?.inserts.isEmpty == false
    guard showingRows else { return [] }
    return ResultDisplayMode.tabs(
      chartable: ChartSpec.suggested(for: ChartQueryResult.make(result)) != nil,
      documents: viewModel.sqlDialect == .mongodb,
      json: viewModel.sqlDialect == .mongodb)
  }

  private func pageSizeMenu(state: DataViewerState) -> some View {
    Menu {
      ForEach(DataViewerState.pageSizes, id: \.self) { size in
        Toggle(
          "\(size) rows",
          isOn: Binding(
            get: { size == state.pageSize },
            set: { _ in Task { await viewModel.setPageSize(size) } }))
      }
    } label: {
      dataViewerCapsuleLabel {
        Text("\(state.pageSize) rows")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundColor(.foregroundMuted)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help("Rows per page")
    .fixedSize()
  }

  private func columnsButton(state: DataViewerState) -> some View {
    Button(action: { showColumns.toggle() }) {
      dataViewerCapsuleLabel {
        Image(systemName: "eye")
          .font(.system(size: 10))
          .foregroundColor(.foregroundMuted)
        Text("Columns")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help("Show or hide columns")
    .fixedSize()
    .disabled(viewModel.editorResult?.columns.isEmpty ?? true)
    .popover(isPresented: $showColumns, arrowEdge: .bottom) {
      columnsPopover(state: state)
    }
  }

  /// One Toggle per result column (on = visible); the popover stays open while toggling
  private func columnsPopover(state: DataViewerState) -> some View {
    let columns = viewModel.editorResult?.columns ?? []
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Columns")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.foreground)
        Spacer()
        Button("Show all") { viewModel.showAllColumns() }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundColor(.accentColor)
          .linkPointer()
          .disabled(state.hiddenColumns.isEmpty)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(columns.indices, id: \.self) { index in
            let name = columns[index].name
            Toggle(
              isOn: Binding(
                get: { !(viewModel.dataViewer?.hiddenColumns.contains(name) ?? false) },
                set: { viewModel.setColumnHidden(name, !$0) }
              )
            ) {
              Text(name)
                .font(.monoSmall)
                .foregroundColor(.foreground)
            }
            .toggleStyle(.checkbox)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
    }
    .padding(Spacing.md)
    .frame(width: 240)
  }

  private func pageButton(
    _ icon: String, help: String, enabled: Bool, action: @escaping () async -> Void
  ) -> some View {
    Button(action: { Task { await action() } }) {
      Image(systemName: icon)
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .controlSize(.small)
    .help(help)
    .disabled(!enabled || viewModel.isEditorQueryRunning)
  }
}

/// Capsule control look of the result panel's statement Menu.
/// Preview SQL, Discard, Commit, and the paging controls share this padding so their heights match.
@ViewBuilder
private func dataViewerCapsuleLabel<Content: View>(
  fill: Color = .inputBackground,
  bordered: Bool = true,
  @ViewBuilder content: () -> Content
) -> some View {
  HStack(spacing: Spacing.xs) {
    content()
  }
  .padding(.horizontal, Spacing.sm)
  .padding(.vertical, Spacing.xs)
  .background(Capsule().fill(fill))
  .overlay {
    if bordered {
      HairlineBorder(shape: Capsule())
    }
  }
}
