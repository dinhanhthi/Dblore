//
//  TabContentView.swift
//  SQLNotebook
//

import SwiftUI

/// Wrapper view that renders the appropriate content view based on the active tab's document type.
/// Sets up FocusedValues for menu command routing.
struct TabContentView: View {
  let tabId: UUID
  @Bindable var tabManager: TabStateManager
  @Bindable var viewModel: NotebookViewModel

  @State private var lastSaved: Date?

  var body: some View {
    contentView
      .focusedSceneValue(\.documentMode, documentMode)
      .focusedSceneValue(\.activeTabId, tabId)
      .focusedSceneValue(\.activeViewModel, viewModel)
      .focusedSceneValue(\.toggleLeftSidebarAction, toggleLeftSidebarAction)
      .focusedSceneValue(\.toggleRightSidebarAction, toggleRightSidebarAction)
      .focusedSceneValue(\.openSearchAction, openSearchAction)
      .focusedSceneValue(\.findNextAction, findNextAction)
      .focusedSceneValue(\.findPreviousAction, findPreviousAction)
      .onAppear {
        setupDocumentChangedCallback()
      }
      .onChange(of: tabId) { _, _ in
        // Re-setup callback when tab changes (view may be reused)
        setupDocumentChangedCallback()
      }
      .onDisappear {
        viewModel.onDocumentChanged = nil
      }
  }

  private func setupDocumentChangedCallback() {
    viewModel.onDocumentChanged = { [tabManager, tabId] in
      tabManager.markDirty(tabId: tabId)
    }
  }

  @ViewBuilder
  private var contentView: some View {
    if viewModel.viewMode == .notebook {
      notebookContent
    } else {
      editorContent
    }
  }

  private var documentMode: DocumentMode {
    viewModel.viewMode == .notebook ? .notebook : .editor
  }

  private var toggleLeftSidebarAction: () -> Void {
    { [viewModel] in viewModel.toggleLeftSidebar() }
  }

  private var toggleRightSidebarAction: () -> Void {
    { [viewModel] in viewModel.toggleSidebar() }
  }

  private var openSearchAction: () -> Void {
    { [viewModel] in viewModel.openSearch() }
  }

  private var findNextAction: () -> Void {
    { [viewModel] in viewModel.navigateToNextMatch() }
  }

  private var findPreviousAction: () -> Void {
    { [viewModel] in viewModel.navigateToPreviousMatch() }
  }

  private func markDirty() {
    tabManager.markDirty(tabId: tabId)
  }

  private func syncNotebookDocument() {
    guard let document = tabManager.notebookDocument(for: tabId) else { return }
    document.notebook = viewModel.notebook
    lastSaved = Date()
  }

  private func syncEditorDocument() {
    guard let document = tabManager.editorDocument(for: tabId) else { return }
    document.content = viewModel.editorContent
    lastSaved = Date()
  }

  // MARK: - Notebook Content

  @ViewBuilder
  private var notebookContent: some View {
    NotebookLayoutView(
      viewModel: viewModel,
      lastSaved: $lastSaved,
      isEditorMode: false
    ) {
      NotebookScrollContent(viewModel: viewModel, syncDocument: syncNotebookDocument)
    }
    .modifier(
      TabNotebookNotificationHandler(
        tabId: tabId,
        tabManager: tabManager,
        viewModel: viewModel,
        syncDocument: syncNotebookDocument
      )
    )
    .destructiveQueryDialog(viewModel: viewModel, syncDocument: syncNotebookDocument)
    .searchNotifications(viewModel: viewModel)
  }

  // MARK: - Editor Content

  @ViewBuilder
  private var editorContent: some View {
    NotebookLayoutView(
      viewModel: viewModel,
      lastSaved: $lastSaved,
      isEditorMode: true
    ) {
      EditorModeView(viewModel: viewModel)
    }
    .modifier(
      TabEditorNotificationHandler(
        tabId: tabId,
        tabManager: tabManager,
        viewModel: viewModel,
        syncDocument: syncEditorDocument
      )
    )
    .searchNotifications(viewModel: viewModel)
  }
}

// MARK: - Notification Handlers

/// Handles notifications for notebook mode in a tab context
struct TabNotebookNotificationHandler: ViewModifier {
  let tabId: UUID
  let tabManager: TabStateManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  @State private var showRunAllConfirmation = false

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .addCodeCell)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        viewModel.addCell(type: .sql)
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCell)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.selectNextCell(createIfNeeded: true)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.insertCellBelow(type: .sql)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runAllCells)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        showRunAllConfirmation = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearCellOutput)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.clearCellOutput(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearAllOutputs)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        viewModel.clearAllOutputs()
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .deleteCell)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.deleteCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .duplicateCell)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.duplicateCell(id: id)
          syncDocument()
        }
      }
      .confirmationDialog(
        "Run all cells?",
        isPresented: $showRunAllConfirmation,
        titleVisibility: .visible
      ) {
        Button("Run All Cells", role: .none) {
          Task { @MainActor in
            await viewModel.runAllCells()
            syncDocument()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will execute all SQL cells in sequence. Existing results will be replaced.")
      }
  }
}

/// Handles notifications for editor mode in a tab context
struct TabEditorNotificationHandler: ViewModifier {
  let tabId: UUID
  let tabManager: TabStateManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .runEditorQuery)) { _ in
        guard tabManager.activeTabId == tabId else { return }
        Task {
          await viewModel.runEditorQuery()
          syncDocument()
        }
      }
  }
}
