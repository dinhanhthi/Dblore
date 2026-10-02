//
//  DataViewerControls.swift
//  Dblore
//
//  Data viewer header controls: table title, + Row, and staged-change actions.
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
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(state.title)

        Divider().frame(height: 14)

        addRowButton

        if let set = state.changeSet, !set.isEmpty {
          stagedSummary(set.counts)
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
    }
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
    .help(viewModel.rowStagingUnavailableReason ?? "Stage a new row")
    .overlay { disabledStagingHelp }
  }

  private func stageNewRow() {
    Task {
      if let message = await viewModel.addStagedRow() {
        viewModel.showToast(message, type: .error)
      }
    }
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
        Text("Preview SQL")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help("Show the staged SQL. Nothing is sent to the database.")
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
      dataViewerCapsuleLabel(fill: .accent, bordered: false) {
        Text("Commit")
          .font(.system(size: 11))
          .foregroundColor(.foreground)
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .opacity(viewModel.stagingEnabled ? 1 : 0.5)
    .disabled(!viewModel.stagingEnabled)
    .help(viewModel.rowStagingUnavailableReason ?? "Commit staged changes")
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

        Spacer(minLength: Spacing.sm)

        if showsChartPicker {
          ResultDisplayPicker(mode: $viewModel.dataViewerDisplayMode)
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

  /// Same rule as the in-grid picker: a loaded page that can be plotted.
  private var showsChartPicker: Bool {
    guard let result = viewModel.editorResult, result.error == nil else { return false }
    let showingRows =
      !result.rows.isEmpty
      || viewModel.dataViewer?.changeSet?.inserts.isEmpty == false
    guard showingRows else { return false }
    return ChartSpec.suggested(for: ChartQueryResult.make(result)) != nil
  }

  private func pageSizeMenu(state: DataViewerState) -> some View {
    Menu {
      ForEach(DataViewerState.pageSizes, id: \.self) { size in
        Button(action: { Task { await viewModel.setPageSize(size) } }) {
          HStack {
            Text("\(size) rows")
            if size == state.pageSize {
              Image(systemName: "checkmark")
            }
          }
        }
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
      Capsule().stroke(Color.border, lineWidth: 1)
    }
  }
}
