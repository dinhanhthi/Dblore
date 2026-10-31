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
  /// Workspace AI assistant behind the MongoDB filter and pipeline prompts; nil hides them
  var aiAssistant: AIAssistantViewModel? = nil
  /// A Reload of the stale banner is running: its bar stays in place as the loading state
  @State private var isReloadingStale = false

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
              model: model, viewModel: viewModel, openQuery: openQuery,
              fieldSource: viewModel.autocompleteProvider,
              database: MongoExportCodeSheet.database(for: viewModel), aiAssistant: aiAssistant,
              runLimit: viewModel.dataViewer?.pageSize ?? 100,
              savedPipelineStore: viewModel.savedFilterStore,
              savedPipelineKey: savedPipelineKey)
          case .schema:
            MongoSchemaView(
              model: model, autocompleteSource: viewModel.autocompleteProvider,
              showDocuments: { filter in
                await viewModel.applyDocumentQuery(
                  filter: filter,
                  options: viewModel.dataViewer?.documentOptions ?? MongoQueryOptions())
              })
          case .indexes:
            MongoIndexesView(model: model, viewModel: viewModel)
          case .validation:
            MongoValidationView(model: model, viewModel: viewModel)
          }
        }
      }
      // AppKit views ignore `disabled`: drop the focus so keys never reach the hidden filter
      // field (Return would apply it) or grid. The search panel only searches the documents:
      // close it first, as closing restores the focus it took.
      .onChange(of: hidesDocuments) { _, hidden in
        guard hidden else { return }
        if viewModel.isSearchPanelVisible { viewModel.closeSearch() }
        NSApp.keyWindow?.makeFirstResponder(nil)
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
    // View > Zoom: the grid is the tab's only zoomable pane
    .bridgedFocusedSceneValue(\.zoomTarget, .grid)
    // A MongoDB collection remembers its view mode (Chart excepted) and page size
    .onChange(of: viewModel.dataViewerDisplayMode) { viewModel.saveMongoViewPreference() }
    .sheet(item: documentEditorRequest, onDismiss: viewModel.documentEditorDismissed) { request in
      MongoDocumentEditorSheet(viewModel: viewModel, request: request)
    }
    // Bulk Update / Delete of the Documents header: the header is too small to host the form
    .modalOverlay(isPresented: bulkWritePresented) {
      if let model = viewModel.mongoCollection?.bulkWrite {
        MongoBulkWriteSheet(
          model: model, fieldSource: viewModel.autocompleteProvider,
          databasePassword: viewModel.notebook.connectionConfig?.password,
          isConnected: viewModel.connectionState == .connected, isPresented: bulkWritePresented)
      }
    }
    // Export of the Documents header, hosted here for the same reason
    .modalOverlay(isPresented: exportPresented) {
      if let model = viewModel.mongoCollection?.export {
        MongoExportSheet(model: model, isPresented: exportPresented)
      }
    }
  }

  /// The bulk write form: shown while the collection screen holds one; closing it is refused
  /// while its command runs
  private var bulkWritePresented: Binding<Bool> {
    Binding(
      get: { viewModel.mongoCollection?.bulkWrite != nil },
      set: { if !$0 { viewModel.closeMongoBulkWrite() } })
  }

  /// The Export form: shown while the collection screen holds one; closing it is refused
  /// while an export runs (its Cancel stops it)
  private var exportPresented: Binding<Bool> {
    Binding(
      get: { viewModel.mongoCollection?.export != nil },
      set: {
        guard !$0, let collection = viewModel.mongoCollection, let model = collection.export,
          !model.isRunning
        else { return }
        model.dismiss()
        collection.export = nil
      })
  }

  /// Saved pipelines are kept per connection and collection, as the filter bar's saved queries
  private var savedPipelineKey: String? {
    guard let state = viewModel.dataViewer, let config = viewModel.notebook.connectionConfig
    else { return nil }
    return SavedFilterStore.key(for: config, schema: state.schema, name: state.name)
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
        MongoFilterBar(viewModel: viewModel, aiAssistant: aiAssistant)
      }
      if isReloadingStale
        || (viewModel.dataViewer?.isStale == true && viewModel.editorResult != nil)
      {
        StaleTableBanner(
          isReloading: isReloadingStale, canReload: !viewModel.isEditorQueryRunning,
          reload: reloadStale)
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
          frozenThroughColumn: viewModel.dataViewer?.frozenThroughColumn,
          onFreezeChange: { viewModel.setFrozenThroughColumn($0) },
          highlights: viewModel.dataViewer?.highlights ?? [],
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

  /// The bar shows the reload from the click's frame until the page is in; `isStale` is cleared
  /// only by the page read, so the banner comes back when none started
  private func reloadStale() {
    isReloadingStale = true
    Task {
      await viewModel.reloadStaleDataViewer()
      isReloadingStale = false
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

/// "This table changed in another tab." with Reload, over a page another tab wrote to since it
/// was read. While the reload runs the bar keeps its place (no layout jump) and shows
/// "Reloading...", faded in after ~150 ms so a quick reload does not flash it.
private struct StaleTableBanner: View {
  let isReloading: Bool
  let canReload: Bool
  let reload: () -> Void

  @State private var showsProgress = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      if isReloading {
        progress
      } else {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundColor(.warning)
          .accessibilityHidden(true)
        Text("This table changed in another tab.")
          .font(.small)
          .foregroundColor(.foreground)
          .lineLimit(1)
        Spacer(minLength: Spacing.sm)
        Button("Reload", action: reload)
          .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
          .linkPointer()
          .disabled(!canReload)
          .help("Read this page and the row count again; staged changes stay")
      }
    }
    .padding(.horizontal, Spacing.md)
    .frame(minHeight: ComponentSize.compactHeaderHeight)
    .background(isReloading ? Color.clear : Color.warning.opacity(0.12), in: Rectangle())
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.warning.opacity(isReloading ? 0 : 0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(isReloading ? "Reloading the table" : "Table changed in another tab")
  }

  private var progress: some View {
    HStack(spacing: Spacing.sm) {
      ProgressView()
        .controlSize(.small)
      Text("Reloading...")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer(minLength: 0)
    }
    .opacity(showsProgress ? 1 : 0)
    .animation(.easeIn(duration: 0.15), value: showsProgress)
    // Opt out of the app-wide animation kill switch, only for the fade
    .transaction(value: showsProgress) { $0.disablesAnimations = false }
    .task {
      // A cancelled sleep must not show the progress after the reload ended
      guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
      showsProgress = true
    }
    .onDisappear { showsProgress = false }
  }
}
