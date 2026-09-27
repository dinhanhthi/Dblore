//
//  WorkspaceContainerView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Main container view for a workspace with tabs, sidebars, and content
struct WorkspaceContainerView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var showSafeModeModal = false

  /// Get the active view model (if any tab is active)
  private var activeViewModel: NotebookViewModel? {
    guard let activeTabId = workspaceManager.activeTabId else { return nil }
    return workspaceManager.viewModel(for: activeTabId)
  }

  var body: some View {
    GeometryReader { geometry in
      // Footer below the sidebar + content area: always full window width, unaffected by the
      // left sidebar toggle
      VStack(spacing: 0) {
        ZStack(alignment: .topLeading) {
          // Main layout (z-index 0 - lowest)
          HStack(spacing: 0) {
            // Left sidebar (full height, covers traffic light area)
            WorkspaceLeftSidebar(
              workspaceManager: workspaceManager,
              tabBarHeight: ComponentSize.tabBarHeight,
              maxWidth: geometry.size.width * 0.35
            )

            // Main content area (tabs + content)
            VStack(spacing: 0) {
              // Tab bar in titlebar area
              WorkspaceTitleBarTabsView(
                workspaceManager: workspaceManager,
                hasLeftSidebar: workspaceManager.isLeftSidebarVisible
              )

              // Pending Protected transaction (Commit / Rollback)
              if !workspaceManager.pendingTransaction.isIdle {
                PendingTransactionBanner(workspaceManager: workspaceManager)
              }

              // The server closed the connection (Reconnect)
              if workspaceManager.connectionLostMessage != nil {
                ConnectionLostBanner(workspaceManager: workspaceManager)
              }

              // Content area
              if workspaceManager.isSchemaVisualizerActive {
                // Schema visualizer at workspace level (overlays everything)
                WorkspaceSchemaVisualizerContent(workspaceManager: workspaceManager)
              } else if let activeTabId = workspaceManager.activeTabId,
                let viewModel = workspaceManager.viewModel(for: activeTabId)
              {
                WorkspaceTabContentView(
                  tabId: activeTabId,
                  workspaceManager: workspaceManager,
                  viewModel: viewModel
                )
              } else {
                WorkspaceWelcomeView(workspaceManager: workspaceManager)
              }
            }
          }
          .zIndex(0)

          // Traffic light area background + toggle button + connection button (z-index 1)
          // This covers sidebar buttons during animation
          HStack(spacing: 0) {
            // Background for traffic light area + buttons
            Color.clear
              .frame(
                width: ComponentSize.trafficLightAndToggleWidth
                  + workspaceManager.connectionState.connectionButtonsWidth,
                height: ComponentSize.tabBarHeight
              )
              .chromeGlass()
              .overlay(alignment: .trailing) {
                // Buttons positioned at trailing edge of background
                HStack(spacing: Spacing.xxs) {
                  SidebarToggleButton(isSidebarVisible: workspaceManager.isLeftSidebarVisible) {
                    workspaceManager.toggleLeftSidebar()
                  }

                  DatabaseConnectionButton(workspaceManager: workspaceManager)

                  // Schema Visualizer button (only show when connected)
                  if case .connected = workspaceManager.connectionState {
                    Button(action: { workspaceManager.toggleSchemaVisualizer() }) {
                      Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12))
                        .foregroundColor(.accent)
                    }
                    .buttonStyle(
                      GhostButtonStyle(
                        isActive: workspaceManager.isSchemaVisualizerActive, iconOnly: true
                      )
                    )
                    .controlSize(.small)
                    .blockDoubleClickZoom()
                    .help(
                      workspaceManager.isSchemaVisualizerActive
                        ? "Close Schema Visualizer" : "Visualize Schema Relationships")
                  }
                }
                .padding(.trailing, Spacing.md)
              }

            Spacer()
          }
          .frame(height: ComponentSize.tabBarHeight)
          // Border bottom - overlay to match title bar's divider
          .overlay(alignment: .bottom) {
            Divider()
          }
          .zIndex(1)
        }

        FooterView(
          viewModel: workspaceManager.isSchemaVisualizerActive ? nil : activeViewModel,
          connectionState: workspaceManager.connectionState,
          connectionConfig: workspaceManager.workspace.connectionConfig,
          onSafeModeTap: { showSafeModeModal = true }
        )
      }
    }
    .frame(minWidth: 800, minHeight: 600)
    .background(Color.appBackground)
    .ignoresSafeArea(.all, edges: .top)
    .background(
      TrafficLightPositioner(tabBarHeight: ComponentSize.tabBarHeight)
    )
    .background(WorkspaceWindowCloseGuard(workspaceManager: workspaceManager))
    .pendingTransactionDialogs(workspaceManager: workspaceManager)
    .confirmationDialog(
      "Save changes?",
      isPresented: $workspaceManager.showingCloseConfirmation,
      titleVisibility: .visible
    ) {
      Button("Save") {
        Task {
          await workspaceManager.saveAndCloseTab()
        }
      }
      Button("Don't Save", role: .destructive) {
        workspaceManager.closeTabWithoutSaving()
      }
      Button("Cancel", role: .cancel) {
        workspaceManager.cancelClose()
      }
    } message: {
      if let tabId = workspaceManager.tabToClose,
        let tab = workspaceManager.tabs.first(where: { $0.id == tabId })
      {
        Text("Do you want to save changes to \"\(tab.title)\"?")
      }
    }
    // Note: File opening is handled by AppDelegate.application(_:open:) in SQLNotebookApp.swift
    // Don't use .onOpenURL here as it conflicts with NSApplicationDelegateAdaptor
    // Focused actions for keyboard shortcuts (Cmd+B, Cmd+Shift+B, etc.)
    .focusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) { [workspaceManager] in
      if let activeTabId = workspaceManager.activeTabId,
        let viewModel = workspaceManager.viewModel(for: activeTabId)
      {
        viewModel.toggleSidebar()
      }
    }
    .focusedSceneValue(\.activeViewModel, activeViewModel)
    .connectionFormModal(workspaceManager: workspaceManager)
    .connectionInfoModal(workspaceManager: workspaceManager)
    .settingsModal(workspaceManager: workspaceManager)
    .safeModeModal(isPresented: $showSafeModeModal)
    .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
      // Toggle settings modal: if already showing, close it; otherwise show settings
      workspaceManager.isSettingsModalVisible.toggle()
    }
  }
}

// MARK: - Left Sidebar for Workspace

/// Left sidebar that uses workspace's shared connection state
/// Reuses shared components from Views/LeftSidebar/
struct WorkspaceLeftSidebar: View {
  @Bindable var workspaceManager: WorkspaceManager
  let tabBarHeight: CGFloat
  let maxWidth: CGFloat

  /// Effective sidebar width from workspace settings or app settings
  private var effectiveSidebarWidth: CGFloat {
    workspaceManager.workspace.settings.leftSidebarWidth
      ?? CGFloat(AppSettings.shared.leftSidebarWidth)
  }

  var body: some View {
    if workspaceManager.isLeftSidebarVisible {
      let constrainedWidth = min(effectiveSidebarWidth, maxWidth)

      VStack(spacing: 0) {
        // Top area with workspace controls
        WorkspaceSidebarTopArea(workspaceManager: workspaceManager, height: tabBarHeight)

        // Main sidebar content - always use workspace schema
        WorkspaceLeftSidebarContent(workspaceManager: workspaceManager)
      }
      .frame(width: constrainedWidth)
      .chromeGlass()
      .transition(.move(edge: .leading))
      .overlay(alignment: .trailing) {
        ResizableSidebarDivider(
          sidebarWidth: Binding(
            get: { effectiveSidebarWidth },
            set: { newValue in
              workspaceManager.workspace.settings.leftSidebarWidth = newValue
              workspaceManager.isDirty = true
            }
          ),
          minWidth: 320,
          maxWidth: maxWidth,
          side: .left
        )
        .offset(x: 4)
      }
      .overlay(alignment: .trailing) {
        Divider()
      }
    }
  }
}

// MARK: - Tab Content View for Workspace

/// Wrapper for tab content that connects to workspace
/// Note: This replaces the need for TabStateManager by using WorkspaceManager directly
struct WorkspaceTabContentView: View {
  let tabId: UUID
  @Bindable var workspaceManager: WorkspaceManager
  @Bindable var viewModel: NotebookViewModel

  @State private var keyEventMonitor: Any?
  @State private var monitorWindow: NSWindow?

  var body: some View {
    contentView
      .focusedSceneValue(\.documentMode, documentMode)
      .focusedSceneValue(\.activeTabId, tabId)
      .focusedSceneValue(\.activeViewModel, viewModel)
      .focusedSceneValue(\.toggleRightSidebarAction, toggleRightSidebarAction)
      .focusedSceneValue(\.openSearchAction, openSearchAction)
      .focusedSceneValue(\.findNextAction, findNextAction)
      .focusedSceneValue(\.findPreviousAction, findPreviousAction)
      .onAppear {
        setupDocumentChangedCallback()
        syncConnectionState()
        setupKeyEventMonitor()
      }
      .onChange(of: tabId) { _, _ in
        setupDocumentChangedCallback()
      }
      .onChange(of: workspaceManager.connectionState) { _, _ in
        syncConnectionState()
      }
      .onDisappear {
        viewModel.onDocumentChanged = nil
        removeKeyEventMonitor()
      }
  }

  private func setupDocumentChangedCallback() {
    viewModel.onDocumentChanged = { [workspaceManager, tabId] in
      workspaceManager.markDirty(tabId: tabId)
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

  // MARK: - Notebook Content

  @ViewBuilder
  private var notebookContent: some View {
    DocumentLayoutView(viewModel: viewModel) {
      NotebookScrollContent(viewModel: viewModel, syncDocument: syncNotebookDocument)
    }
    .modifier(
      WorkspaceNotebookNotificationHandler(
        tabId: tabId,
        workspaceManager: workspaceManager,
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
    DocumentLayoutView(viewModel: viewModel) {
      // Wrap in List so it absorbs parent geometry changes gracefully
      // during sidebar animation, just like NotebookScrollContent does.
      // Without List, EditorModeView's SizeReader recalculates on every
      // animation frame causing layout flash.
      // GeometryReader captures container height so the single List row
      // can fill the entire available space.
      GeometryReader { geometry in
        ScrollView {
          EditorModeView(viewModel: viewModel)
            .frame(height: geometry.size.height)
        }
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
      }
    }
    .modifier(
      WorkspaceEditorNotificationHandler(
        tabId: tabId,
        workspaceManager: workspaceManager,
        viewModel: viewModel,
        syncDocument: syncEditorDocument
      )
    )
    .destructiveQueryDialog(viewModel: viewModel, syncDocument: syncEditorDocument)
    .searchNotifications(viewModel: viewModel)
  }

  // MARK: - Document Sync

  private func syncNotebookDocument() {
    guard let document = workspaceManager.notebookDocument(for: tabId) else { return }
    document.notebook = viewModel.notebook
    viewModel.lastSaved = Date()
  }

  private func syncEditorDocument() {
    guard let document = workspaceManager.editorDocument(for: tabId) else { return }
    document.content = viewModel.editorContent
    viewModel.lastSaved = Date()
  }

  private func syncConnectionState() {
    viewModel.connectionState = workspaceManager.connectionState
    viewModel.connectionManager = workspaceManager.connectionManager
    viewModel.databaseTables = workspaceManager.databaseTables
    viewModel.databaseViews = workspaceManager.databaseViews
    viewModel.databaseFunctions = workspaceManager.databaseFunctions
    viewModel.databaseProcedures = workspaceManager.databaseProcedures
    viewModel.databaseUsers = workspaceManager.databaseUsers
    viewModel.databaseRoles = workspaceManager.databaseRoles
    viewModel.databaseForeignKeys = workspaceManager.databaseForeignKeys
  }

  // MARK: - Keyboard Event Monitoring

  private func setupKeyEventMonitor() {
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
      // Only handle events for the key window
      guard let eventWindow = event.window,
        eventWindow == NSApplication.shared.keyWindow
      else {
        return event
      }

      // Store our window on first event if not set
      if self.monitorWindow == nil {
        self.monitorWindow = eventWindow
      }

      // Only handle if this is OUR window
      guard eventWindow == self.monitorWindow else {
        return event
      }

      // Only handle for active tab
      guard workspaceManager.activeTabId == tabId else {
        return event
      }

      // Check if a NSTextView is currently first responder (excluding search field)
      let textViewIsFocused: Bool = {
        guard let firstResponder = eventWindow.firstResponder else {
          return false
        }
        if self.viewModel.isSearchPanelVisible {
          return false
        }
        return firstResponder is NSTextView
      }()

      // Handle ESC key
      let isEscape = event.keyCode == 53
      if isEscape {
        // Priority 0: If search panel is open, close it
        if self.viewModel.isSearchPanelVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSearch()
          }
          return nil
        }

        // Priority 1: If text editor is focused, unfocus it
        if textViewIsFocused {
          NotificationCenter.default.post(name: .unfocusEditor, object: nil)
          return nil
        }

        // Priority 2: If right sidebar is open, close it
        if self.viewModel.isRightSidebarVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSidebar()
          }
          return nil
        }
      }

      return event
    }
  }

  private func removeKeyEventMonitor() {
    if let monitor = keyEventMonitor {
      NSEvent.removeMonitor(monitor)
      keyEventMonitor = nil
    }
  }
}

// MARK: - Workspace Notification Handlers

/// Handles notifications for notebook mode in workspace context
struct WorkspaceNotebookNotificationHandler: ViewModifier {
  let tabId: UUID
  let workspaceManager: WorkspaceManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  @State private var showRunAllConfirmation = false

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .addCodeCell)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        viewModel.addCell(type: .sql)
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCell)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.selectNextCell(createIfNeeded: true)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.insertCellBelow(type: .sql)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runAllCells)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        showRunAllConfirmation = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearCellOutput)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.clearCellOutput(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearAllOutputs)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        viewModel.clearAllOutputs()
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .deleteCell)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        if let id = viewModel.selectedCellId {
          viewModel.deleteCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .duplicateCell)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
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

/// Handles notifications for editor mode in workspace context
struct WorkspaceEditorNotificationHandler: ViewModifier {
  let tabId: UUID
  let workspaceManager: WorkspaceManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .runEditorQuery)) { _ in
        guard workspaceManager.activeTabId == tabId else { return }
        Task {
          await viewModel.runEditorQuery()
          syncDocument()
        }
      }
  }
}

// MARK: - Title Bar Tabs View for Workspace

/// Tab bar view adapted for workspace with Chrome-like drag-and-drop
struct WorkspaceTitleBarTabsView: View {
  @Bindable var workspaceManager: WorkspaceManager
  let hasLeftSidebar: Bool

  /// Whether can navigate to previous tab
  private var canGoToPreviousTab: Bool {
    guard let activeId = workspaceManager.activeTabId,
      let currentIndex = workspaceManager.tabs.firstIndex(where: { $0.id == activeId })
    else { return false }
    return currentIndex > 0
  }

  /// Whether can navigate to next tab
  private var canGoToNextTab: Bool {
    guard let activeId = workspaceManager.activeTabId,
      let currentIndex = workspaceManager.tabs.firstIndex(where: { $0.id == activeId })
    else { return false }
    return currentIndex < workspaceManager.tabs.count - 1
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      if !hasLeftSidebar {
        Color.clear
          .frame(
            width: ComponentSize.trafficLightAndToggleWidth
              + workspaceManager.connectionState.connectionButtonsWidth)
      } else {
        Color.clear.frame(width: 10)
      }

      // Navigation arrows
      HStack(spacing: 2) {
        TabNavigationArrowButton(
          direction: .left,
          isEnabled: canGoToPreviousTab,
          action: goToPreviousTab
        )
        TabNavigationArrowButton(
          direction: .right,
          isEnabled: canGoToNextTab,
          action: goToNextTab
        )
      }
      .padding(.leading, Spacing.xxs)
      .padding(.trailing, Spacing.sm)

      // Scrollable tabs area with Chrome-like drag reordering
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          WorkspaceDraggableTabsContainer(workspaceManager: workspaceManager)
            .padding(.horizontal, Spacing.xs)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .onChange(of: workspaceManager.activeTabId) { _, newTabId in
          if let newTabId {
            withAnimation(.easeInOut(duration: 0.2)) {
              proxy.scrollTo(newTabId, anchor: .center)
            }
          }
        }
      }

      HStack(spacing: Spacing.xxs) {
        // Settings button
        Button {
          NotificationCenter.default.post(name: .openSettings, object: nil)
        } label: {
          Image(systemName: "gearshape")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.foregroundMuted)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .blockDoubleClickZoom()
        .help("Settings (⌘,)")

        // New tab button
        Menu {
          Button {
            workspaceManager.newNotebook()
          } label: {
            Label("New Notebook", systemImage: "doc.text")
          }

          Button {
            workspaceManager.newSQLFile()
          } label: {
            Label("New SQL File", systemImage: "doc")
          }

          Divider()

          Button {
            openNotebookWithPanel()
          } label: {
            Label("Open Notebook...", systemImage: "folder")
          }

          Button {
            openSQLFileWithPanel()
          } label: {
            Label("Open SQL File...", systemImage: "folder")
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.foregroundMuted)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .pointerStyle(.link)
        .menuIndicator(.hidden)
        .fixedSize()
        .blockDoubleClickZoom()
      }
      .padding(.horizontal, Spacing.sm)
    }
    .frame(height: ComponentSize.tabBarHeight)
    .chromeGlass()
    .background(WindowDragArea())
  }

  private func goToPreviousTab() {
    guard let activeId = workspaceManager.activeTabId,
      let currentIndex = workspaceManager.tabs.firstIndex(where: { $0.id == activeId }),
      currentIndex > 0
    else { return }
    let previousTab = workspaceManager.tabs[currentIndex - 1]
    workspaceManager.selectTab(id: previousTab.id)
  }

  private func goToNextTab() {
    guard let activeId = workspaceManager.activeTabId,
      let currentIndex = workspaceManager.tabs.firstIndex(where: { $0.id == activeId }),
      currentIndex < workspaceManager.tabs.count - 1
    else { return }
    let nextTab = workspaceManager.tabs[currentIndex + 1]
    workspaceManager.selectTab(id: nextTab.id)
  }

  private func openNotebookWithPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.sqlNotebook]

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          try? await workspaceManager.openFile(url: url)
        }
      }
    }
  }

  private func openSQLFileWithPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.sql]

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          try? await workspaceManager.openFile(url: url)
        }
      }
    }
  }
}

// MARK: - Tab Navigation

/// Direction for tab navigation arrows
enum TabNavigationDirection {
  case left, right
}

/// Fixed arrow button for navigating between tabs
struct TabNavigationArrowButton: View {
  let direction: TabNavigationDirection
  let isEnabled: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(isEnabled ? .foregroundMuted : .foregroundMuted.opacity(0.3))
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .disabled(!isEnabled)
    .blockDoubleClickZoom()
    .onHover { isHovering = $0 }
    .help(direction == .left ? "Previous tab" : "Next tab")
  }
}

/// Database connection button with bolt icon
struct DatabaseConnectionButton: View {
  @Bindable var workspaceManager: WorkspaceManager

  private var isConnected: Bool {
    if case .connected = workspaceManager.connectionState {
      return true
    }
    return false
  }

  var body: some View {
    Button {
      if isConnected {
        // Show connection info modal instead of disconnecting immediately
        workspaceManager.isConnectionInfoModalVisible = true
      } else {
        workspaceManager.showConnectionForm()
      }
    } label: {
      Image(systemName: isConnected ? "bolt.fill" : "bolt.slash")
        .font(.system(size: 12))
        .foregroundColor(isConnected ? .green : nil)
    }
    .buttonStyle(
      GhostButtonStyle(
        iconOnly: true
      )
    )
    .controlSize(.small)
    .blockDoubleClickZoom()
    .help(isConnected ? "Connection Details" : "Connect to database")
  }
}
