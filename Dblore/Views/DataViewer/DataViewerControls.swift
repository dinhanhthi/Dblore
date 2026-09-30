//
//  DataViewerControls.swift
//  Dblore
//
//  Data viewer header controls: rows-per-page, column visibility and paging
//

import SwiftUI

/// Left side of the header in data viewer mode
struct DataViewerControls: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showColumns = false

  var body: some View {
    if let state = viewModel.dataViewer {
      HStack(spacing: Spacing.sm) {
        Text(state.title)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(state.title)

        pageSizeMenu(state: state)
        columnsButton(state: state)

        Text(Self.pageLabel(state: state, loadedRows: viewModel.editorResult?.rows.count ?? 0))
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
      }
    }
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
      capsuleLabel {
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
      capsuleLabel {
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
    .popover(isPresented: $showColumns, arrowEdge: .top) {
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
        .font(.system(size: 10))
        .foregroundColor(.foregroundSubtle)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help(help)
    .disabled(!enabled || viewModel.isEditorQueryRunning)
  }

  /// Capsule control look of the result panel's statement Menu
  private func capsuleLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: Spacing.xs) {
      content()
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(
      Capsule()
        .fill(Color.inputBackground)
    )
    .overlay(
      Capsule()
        .stroke(Color.border, lineWidth: 1)
    )
  }
}
