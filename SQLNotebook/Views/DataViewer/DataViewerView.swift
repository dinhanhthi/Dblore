//
//  DataViewerView.swift
//  SQLNotebook
//
//  Data viewer tab: the result grid of one table/view page plus a pagination footer
//

import SwiftUI

/// Grid of the loaded page (inline edit, cell details and search come from
/// EditorResultGridView) with rows-per-page, Previous/Next and column visibility controls.
struct DataViewerView: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var showColumns = false

  var body: some View {
    VStack(spacing: 0) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let state = viewModel.dataViewer {
        footer(state: state)
      }
    }
    .background(Color.appBackground)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let result = viewModel.editorResult {
      if let error = result.error {
        errorView(error: error)
      } else if result.rows.isEmpty {
        placeholder(icon: "tray", text: "No rows")
      } else {
        EditorResultGridView(
          result: result, viewModel: viewModel,
          hiddenColumns: viewModel.dataViewer?.hiddenColumns ?? []
        )
        // New page or relation: reset sort, search match and scroll; a reload of the same
        // page (inline edit, Refresh, Cmd+R) keeps them
        .id(viewModel.dataViewer?.loadKey)
      }
    } else if viewModel.isEditorQueryRunning {
      ProgressView()
    } else {
      placeholder(icon: "tablecells", text: "No data loaded")
    }
  }

  private func errorView(error: String) -> some View {
    ScrollView {
      Text(error)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.foreground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
    }
    .background(Color.red.opacity(0.05))
  }

  private func placeholder(icon: String, text: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: 28))
        .foregroundColor(.foregroundSubtle)
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.foregroundMuted)
    }
  }

  // MARK: - Footer

  private func footer(state: DataViewerState) -> some View {
    HStack(spacing: Spacing.sm) {
      pageSizeMenu(state: state)
      columnsButton(state: state)

      Spacer()

      Text(Self.pageLabel(state: state, loadedRows: viewModel.editorResult?.rows.count ?? 0))
        .font(.monoSmall)
        .foregroundColor(.foregroundSubtle)

      pageButton("chevron.left", help: "Previous page", enabled: state.canGoPrevious) {
        await viewModel.goToPage(state.page - 1)
      }
      pageButton("chevron.right", help: "Next page", enabled: state.canGoNext) {
        await viewModel.goToPage(state.page + 1)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .top
    )
  }

  /// "Page X of Y · a–b of N" once the total is known, "Page X" while it is not
  static func pageLabel(state: DataViewerState, loadedRows: Int) -> String {
    guard let total = state.totalRows, let pageCount = state.pageCount else {
      return "Page \(state.page)"
    }
    let label = "Page \(state.page) of \(pageCount)"
    guard let range = state.rowRange(loadedRows: loadedRows) else {
      return "\(label) · \(total) rows"
    }
    return "\(label) · \(range.lowerBound)–\(range.upperBound) of \(total)"
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
