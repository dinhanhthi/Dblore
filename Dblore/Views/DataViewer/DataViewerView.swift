//
//  DataViewerView.swift
//  Dblore
//
//  Data viewer tab: the result grid of one table/view page plus
//

import SwiftUI

/// Grid of the loaded page (inline edit, cell details and search come from
/// EditorResultGridView). Page size, column visibility, paging, and the
/// Grid / Chart slider sit under the grid. The slider is trailing.
struct DataViewerView: View {
  @Bindable var viewModel: NotebookViewModel
  /// Opens a new query tab holding the text (Open in Query of the Aggregations section); nil
  /// disables it
  var openQuery: ((String) -> Void)? = nil

  var body: some View {
    VStack(spacing: 0) {
      // The documents stay in the hierarchy, hidden, while another section shows: the filter
      // draft and the grid's sort, search, value filter and scroll live in view state and would
      // reset
      ZStack {
        documents
          .opacity(hidesDocuments ? 0 : 1)
          .allowsHitTesting(!hidesDocuments)
          .disabled(hidesDocuments)
          .accessibilityHidden(hidesDocuments)
        if let model = viewModel.mongoCollection {
          switch model.section {
          case .documents:
            EmptyView()
          case .aggregations:
            MongoAggregationsView(
              model: model, openQuery: openQuery,
              fieldSource: viewModel.autocompleteProvider)
          case .schema:
            MongoSchemaView(model: model, autocompleteSource: viewModel.autocompleteProvider)
          case .indexes:
            MongoIndexesView(model: model)
          }
        }
      }
      // AppKit views ignore `disabled`: drop the focus so keys never reach the hidden filter
      // field (Return would apply it) or grid
      .onChange(of: hidesDocuments) { _, hidden in
        if hidden { NSApp.keyWindow?.makeFirstResponder(nil) }
      }
      // Explain of the Documents bar and the Aggregations section. On its own node: two
      // sheets on one view would conflict
      .sheet(isPresented: explainPresented) {
        if let model = viewModel.mongoCollection {
          MongoExplainSheet(model: model)
        }
      }
    }
    .background(Color.appBackground)
    .sheet(item: documentEditorRequest, onDismiss: viewModel.documentEditorDismissed) { request in
      MongoDocumentEditorSheet(viewModel: viewModel, request: request)
    }
  }

  /// MongoDB document editor: presented while `pendingDocumentEditor` is set; dismissing the
  /// sheet clears it. A Safe Mode dialog its field edit armed opens once it has dismissed.
  private var documentEditorRequest: Binding<DataViewerState.DocumentEditorRequest?> {
    Binding(
      get: { viewModel.dataViewer?.pendingDocumentEditor },
      set: { request in
        guard request == nil else { return }
        viewModel.dataViewer?.pendingDocumentEditor = nil
      }
    )
  }

  /// MongoDB explain: presented while an explain runs or has a result; dismissing the sheet
  /// drops it.
  private var explainPresented: Binding<Bool> {
    Binding(
      get: { (viewModel.mongoCollection?.explainState ?? .idle) != .idle },
      set: { presented in
        guard !presented else { return }
        viewModel.mongoCollection?.dismissExplain()
      }
    )
  }

  // MARK: - Content

  private var hidesDocuments: Bool {
    guard let section = viewModel.mongoCollection?.section else { return false }
    return section != .documents
  }

  /// Filter bar (MongoDB), the page, and the paging bar
  private var documents: some View {
    VStack(spacing: 0) {
      if viewModel.isMongoDataViewer {
        MongoFilterBar(viewModel: viewModel)
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      DataViewerPagingBar(viewModel: viewModel)
    }
  }

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
      || viewModel.dataViewer?.documentChangeSet?.inserts.isEmpty == false
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
