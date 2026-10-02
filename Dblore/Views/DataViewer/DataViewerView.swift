//
//  DataViewerView.swift
//  Dblore
//
//  Data viewer tab: the result grid of one table/view page plus
//

import SwiftUI

/// Grid of the loaded page (inline edit, cell details and search come from
/// EditorResultGridView). Page size, column visibility, and paging sit under the grid.
struct DataViewerView: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(spacing: 0) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      DataViewerPagingBar(viewModel: viewModel)
    }
    .background(Color.appBackground)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let result = viewModel.editorResult {
      if let error = result.error {
        errorView(error: error)
      } else if result.rows.isEmpty && !hasStagedInserts {
        placeholder(icon: "tray", text: "No rows")
      } else {
        EditorResultGridView(
          result: result, viewModel: viewModel,
          hiddenColumns: viewModel.dataViewer?.hiddenColumns ?? [],
          highlight: viewModel.dataViewer?.highlight,
          dialect: viewModel.dataViewer?.databaseType ?? .postgresql,
          canHighlight: true,
          displayMode: $viewModel.dataViewerDisplayMode,
          showsDisplayPicker: false
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

  /// A staged insert on an empty page still belongs in the grid.
  private var hasStagedInserts: Bool {
    viewModel.dataViewer?.changeSet?.inserts.isEmpty == false
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
}
