//
//  WorkspaceContainerView.swift
//  Dblore
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main container view for a workspace with tabs, sidebars, and content
struct WorkspaceContainerView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var settingsSection: SettingsPage?
  @State private var settingsOpenToken = UUID()
  @State private var isNativeTabBarVisible = false
  @State private var hostWindow = HostWindowReference()
  @Environment(\.controlActiveState) private var controlActiveState
  @ReduceMotion private var reduceMotion
  @State private var isImportPresented = false
  @State private var isImportBusy = false
  @State private var importTabID: UUID?
  @State private var importDestination: TableImportDestination?
  @State private var isConnectionImportPresented = false
  /// Export SQL Dump / Copy Database File / Restore SQL Dump panel, and the tab it runs for
  @State private var backupSheet: BackupSheet?
  @State private var backupTabID: UUID?

  /// Get the active view model (if any tab is active)
  private var activeViewModel: NotebookViewModel? {
    guard let activeTabId = workspaceManager.activeTabId else { return nil }
    return workspaceManager.viewModel(for: activeTabId)
  }

  /// Whether the content area shows `WorkspaceWelcomeView` (no tab and no schema visualizer)
  private var showsWorkspaceWelcome: Bool {
    !workspaceManager.isSchemaVisualizerActive && activeViewModel == nil
  }

  /// Hides the AI assistant only in its sidebar mode: the floating bubble takes no width
  private func hideAIAssistantSidebar() {
    guard workspaceManager.aiAssistant.showsSidebarPanel else { return }
    withSidebarAnimation { workspaceManager.aiAssistant.hide() }
  }

  /// Whether the left sidebar beside the open right sidebars (AI assistant panel and the tab's
  /// sidebar) leaves the tab content less than its minimum width. The compact workspace welcome
  /// never has room for both sides.
  private var sidebarsCrowdContent: Bool {
    if showsWorkspaceWelcome { return true }
    guard let window = hostWindow.window else { return false }
    let windowWidth = window.contentLayoutRect.width
    let storedLeftWidth =
      workspaceManager.workspace.settings.leftSidebarWidth
      ?? CGFloat(AppSettings.shared.leftSidebarWidth)
    var rightWidth: CGFloat = 0
    if workspaceManager.aiAssistant.showsSidebarPanel {
      rightWidth += SidebarRoom.aiWidth(
        AppSettings.shared.aiSidebarWidth, windowWidth: windowWidth)
    }
    if let viewModel = activeViewModel, viewModel.isRightSidebarVisible {
      rightWidth += viewModel.rightSidebarWidth
    }
    return !SidebarRoom.leftSidebarFits(
      windowWidth: windowWidth,
      leftWidth: SidebarRoom.leftWidth(storedLeftWidth, windowWidth: windowWidth),
      rightWidth: rightWidth)
  }

  /// A right sidebar just opened: collapses the left one when both sides do not fit
  private func collapseLeftSidebarIfCrowded() {
    if workspaceManager.isLeftSidebarVisible && sidebarsCrowdContent {
      workspaceManager.toggleLeftSidebar()
    }
  }

  /// This window just resized: collapses the left sidebar when it no longer fits beside an open
  /// right sidebar
  private func collapseLeftSidebarOnResize(_ notification: Notification) {
    guard let window = hostWindow.window, notification.object as? NSWindow === window,
      workspaceManager.aiAssistant.showsSidebarPanel
        || activeViewModel?.isRightSidebarVisible == true
    else { return }
    collapseLeftSidebarIfCrowded()
  }

  /// The left sidebar just opened: collapses the right ones when both sides do not fit
  private func collapseRightSidebarsIfCrowded() {
    guard sidebarsCrowdContent else { return }
    hideAIAssistantSidebar()
    if let viewModel = activeViewModel, viewModel.isRightSidebarVisible {
      viewModel.closeSidebar()
    }
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
              maxWidth: geometry.size.width * 0.35,
              onImportTable: { requestImport(for: $0) }
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

              // A SQLite file opened read-only because its sidecar files cannot be written
              if workspaceManager.connectionState.isConnected,
                workspaceManager.readOnlyFileNotice != nil
              {
                ReadOnlyFileBanner(workspaceManager: workspaceManager)
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

            // AI assistant panel, resizable from its leading edge
            if workspaceManager.aiAssistant.showsSidebarPanel {
              // Same max rule as the left sidebar, from this layout pass's window width
              let maxAIWidth = SidebarRoom.aiMaxWidth(windowWidth: geometry.size.width)
              let aiWidth = SidebarRoom.aiWidth(
                AppSettings.shared.aiSidebarWidth, windowWidth: geometry.size.width)
              AIAssistantPanel(
                assistant: workspaceManager.aiAssistant,
                activeTab: activeViewModel,
                tables: workspaceManager.databaseTables,
                width: aiWidth
              )
              .overlay(alignment: .leading) {
                ResizableSidebarDivider(
                  sidebarWidth: Binding(
                    get: { aiWidth },
                    set: { AppSettings.shared.aiSidebarWidth = $0 }
                  ),
                  minWidth: ComponentSize.sidebarWidth,
                  maxWidth: maxAIWidth,
                  side: .right
                )
                .offset(x: -4)
              }
              .transition(SidebarAnimation.trailingSlide)
            }
          }
          .animation(
            reduceMotion ? nil : SidebarAnimation.animation,
            value: workspaceManager.aiAssistant.showsSidebarPanel
          )
          .zIndex(0)

          // Traffic light controls stay above the sidebar while it slides (z-index 1).
          // Solid fill only while the sidebar is closed, matching the tab bar.
          // While it is open, leave the strip clear so the sidebar chromeGlass
          // shows through: the same surface as Expand all and Refresh schema.
          HStack(spacing: 0) {
            Color.clear
              .frame(
                width: ComponentSize.trafficLightAndToggleWidth
                  - (isNativeTabBarVisible ? ComponentSize.trafficLightButtonsWidth : 0)
                  + workspaceManager.connectionState.connectionButtonsWidth,
                height: ComponentSize.tabBarHeight
              )
              .background {
                if !workspaceManager.isLeftSidebarVisible {
                  Color.appBackground
                    // Keep the tab bar's top border (native tab bar above) across this strip
                    .overlay(alignment: .top) {
                      if isNativeTabBarVisible {
                        Rectangle().fill(Color.border).frame(height: 1)
                      }
                    }
                }
              }
              .overlay(alignment: .trailing) {
                // Buttons positioned at trailing edge of background
                HStack(spacing: Spacing.xxs) {
                  SidebarToggleButton(isSidebarVisible: workspaceManager.isLeftSidebarVisible) {
                    workspaceManager.toggleLeftSidebar()
                  }

                  // Connect stays available until a connection exists. Details live on the info button.
                  if case .connected = workspaceManager.connectionState {
                    Button(action: { workspaceManager.toggleSchemaVisualizer() }) {
                      Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12))
                        .foregroundColor(
                          workspaceManager.isSchemaVisualizerActive
                            ? Color.accent : Color.foregroundMuted)
                    }
                    .buttonStyle(GhostButtonStyle(iconOnly: true))
                    .controlSize(.small)
                    .blockDoubleClickZoom()
                    .help(
                      workspaceManager.isSchemaVisualizerActive
                        ? "Close Schema Visualizer" : "Visualize Schema Relationships")
                  } else {
                    DatabaseConnectionButton(workspaceManager: workspaceManager)
                  }

                  WorkspaceInfoButton(workspaceManager: workspaceManager)
                }
                .padding(.trailing, Spacing.xsm)
              }

            Spacer()
          }
          .frame(height: ComponentSize.tabBarHeight)
          // Single full-width border under the tab bar (flat, no glass rim)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Color.border).frame(height: 1)
          }
          .zIndex(1)

          // Floating AI bubble above everything in the content area (z-index 2)
          if workspaceManager.aiAssistant.showsBubble {
            AIBubbleOverlay(
              assistant: workspaceManager.aiAssistant,
              activeTab: activeViewModel,
              tables: workspaceManager.databaseTables
            )
            .transition(.opacity)
            .zIndex(2)
          }
        }

        FooterView(
          viewModel: workspaceManager.isSchemaVisualizerActive ? nil : activeViewModel,
          connectionState: workspaceManager.connectionState,
          connectionConfig: workspaceManager.workspace.connectionConfig,
          transport: workspaceManager.mysqlTransport
        )
      }
    }
    // No min frame here: `documentWindowMode` sets the limits, and a fixed 600 overflowed the
    // 540 compact window (sidebars and the footer were cut off at the bottom)
    .background(Color.appBackground)
    .ignoresSafeArea(.all, edges: isNativeTabBarVisible ? [] : .top)
    .environment(\.isNativeTabBarVisible, isNativeTabBarVisible)
    .background(
      DocumentWindowConfigurator(
        tabTitle: WorkspaceWindowTitle.tab(workspaceName: workspaceManager.workspace.name),
        windowTitle: WorkspaceWindowTitle.window(
          fileName: workspaceManager.activeTab?.title,
          workspaceName: workspaceManager.workspace.name),
        isTabBarVisible: $isNativeTabBarVisible)
    )
    .background(
      TrafficLightPositioner(
        tabBarHeight: ComponentSize.tabBarHeight, isTabBarVisible: isNativeTabBarVisible)
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
    // Note: File opening is handled by AppDelegate.application(_:open:) in DbloreApp.swift
    // Don't use .onOpenURL here as it conflicts with NSApplicationDelegateAdaptor
    // Focused actions for keyboard shortcuts (Cmd+B, Cmd+Shift+B, etc.)
    .focusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) { [workspaceManager] in
      if let activeTabId = workspaceManager.activeTabId,
        let viewModel = workspaceManager.viewModel(for: activeTabId),
        viewModel.viewMode != .markdown
      {
        viewModel.toggleSidebar()
      }
    }
    .focusedSceneValue(\.toggleAIAssistantAction) { [workspaceManager] in
      workspaceManager.toggleAIAssistant()
    }
    .focusedSceneValue(\.openCommandPaletteAction) { [workspaceManager] in
      workspaceManager.openCommandPalette()
    }
    .focusedSceneValue(\.openTableImportAction, importAction)
    .focusedSceneValue(\.openSQLDumpAction, backupAction(.dump))
    .focusedSceneValue(\.openSQLRestoreAction, backupAction(.restore))
    .focusedSceneValue(\.openDatabaseFileCopyAction, backupAction(.fileCopy))
    .focusedSceneValue(\.activeViewModel, activeViewModel)
    .connectionFormModal(workspaceManager: workspaceManager)
    .workspaceInfoModal(workspaceManager: workspaceManager)
    // After the connection form, so they open on top of it
    .connectionImportPanel(isPresented: $isConnectionImportPresented)
    .settingsModal(
      workspaceManager: workspaceManager,
      section: settingsSection,
      openToken: settingsOpenToken
    )
    .structureEditorPanel(workspaceManager: workspaceManager)
    .sidePanelOverlay(
      isPresented: Binding(
        get: { isImportPresented },
        set: { if $0 || !isImportBusy { isImportPresented = $0 } }
      ),
      width: TableImportSheet.panelWidth, maxWidthFraction: 0.8
    ) {
      if let importTabID, let viewModel = workspaceManager.viewModel(for: importTabID) {
        TableImportSheet(
          viewModel: viewModel, isPresented: $isImportPresented, isBusy: $isImportBusy,
          initialDestination: importDestination, tables: workspaceManager.databaseTables)
      }
    }
    .modifier(
      BackupPanel(workspaceManager: workspaceManager, sheet: $backupSheet, tabID: backupTabID)
    )
    .favoriteFormPanel(workspaceManager: workspaceManager)
    .pendingTransactionDetailsModal(workspaceManager: workspaceManager)
    // Right sidebars above run the full window height, like the content
    .ignoresSafeArea(.all, edges: isNativeTabBarVisible ? [] : .top)
    .favoriteModals(workspaceManager: workspaceManager)
    .historyDetailModal(workspaceManager: workspaceManager)
    .commandPaletteModal(workspaceManager: workspaceManager)
    .background(HostWindowReader(reference: hostWindow))
    .claimsConnectionImport(hostWindow: hostWindow, isPresented: $isConnectionImportPresented)
    // The workspace welcome (no tab open) keeps the small Welcome size; tabs need room
    .documentWindowMode(
      showsWorkspaceWelcome ? .compact : .regular, isTabbed: isNativeTabBarVisible
    )
    .environment(\.hostWindowReference, hostWindow)
    // Here rather than on the tabs, so the theme also applies while no tab is open
    .windowAppearance(AppSettings.shared.themePreference.colorScheme)
    // When the tab content would lose its minimum width, only one side stays open: opening a
    // right sidebar collapses the left one and opening the left one collapses the right ones.
    // The compact workspace welcome never has room for both, and closing the last tab with both
    // open keeps the left sidebar
    .onChange(of: workspaceManager.aiAssistant.showsSidebarPanel) { _, shows in
      if shows { collapseLeftSidebarIfCrowded() }
    }
    .onChange(of: activeViewModel?.isRightSidebarVisible == true) { _, shows in
      if shows { collapseLeftSidebarIfCrowded() }
    }
    .onChange(of: workspaceManager.isLeftSidebarVisible) { _, isVisible in
      if isVisible { collapseRightSidebarsIfCrowded() }
    }
    .onChange(of: showsWorkspaceWelcome) { _, shows in
      if shows && workspaceManager.isLeftSidebarVisible { hideAIAssistantSidebar() }
    }
    // Shrinking the window with both sides open collapses the left sidebar once they stop fitting
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) {
      collapseLeftSidebarOnResize($0)
    }
    .onChange(of: controlActiveState, initial: true) { _, newState in
      if newState == .key { WorkspaceWindowManager.shared.setActiveWorkspace(workspaceManager.id) }
    }
    // A reselected native tab keeps controlActiveState at .key, so onChange above misses it
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      notification in
      guard let window = hostWindow.window, notification.object as? NSWindow === window else {
        return
      }
      WorkspaceWindowManager.shared.setActiveWorkspace(workspaceManager.id)
    }
    .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { notification in
      guard workspaceManager.isActiveWorkspace(in: hostWindow) else { return }
      if let raw = notification.userInfo?[SettingsPage.userInfoKey] as? String,
        let section = SettingsPage(rawValue: raw)
      {
        settingsSection = section
        settingsOpenToken = UUID()
        workspaceManager.isSettingsModalVisible = true
      } else {
        settingsSection = nil
        workspaceManager.isSettingsModalVisible.toggle()
      }
    }
  }

  private var importAction: (() -> Void)? {
    guard workspaceManager.canImportData else { return nil }
    return { requestImport() }
  }

  /// Connected to an engine with a SQL dump (the file copy: SQLite only); the sheet runs for the
  /// active tab, or a new SQL file when none is open
  private func backupAction(_ sheet: BackupSheet) -> (() -> Void)? {
    guard workspaceManager.connectionState.isConnected,
      let type = workspaceManager.workspace.connectionConfig?.databaseType,
      type.capabilities.supportsSQLDump, sheet != .fileCopy || type == .sqlite
    else { return nil }
    return {
      guard backupSheet == nil else { return }
      backupTabID = workspaceManager.activeTabId ?? workspaceManager.newSQLFile()
      backupSheet = sheet
    }
  }

  private func requestImport(for table: DatabaseTable? = nil) {
    guard workspaceManager.canImportData else { return }
    let tabID = workspaceManager.activeTabId ?? workspaceManager.newSQLFile()
    importTabID = tabID
    importDestination = table.map { .existing(schema: $0.schema, table: $0.name) }
    isImportPresented = true
  }
}

// MARK: - SQL Dump Panels

private enum BackupSheet {
  case dump
  case fileCopy
  case restore
}

/// Export SQL Dump, Copy Database File and Restore SQL Dump in the right side panel. The panel
/// stays open while the sheet works, unless the sheet's tab closes: then the sheet (which stops
/// its work) and the panel go away.
private struct BackupPanel: ViewModifier {
  let workspaceManager: WorkspaceManager
  @Binding var sheet: BackupSheet?
  let tabID: UUID?
  @State private var isBusy = false

  /// The sheet's tab is still open (a tab restored at launch has no view model until it loads,
  /// so the tab list is checked rather than the view model)
  private var isTabOpen: Bool {
    tabID.map { id in workspaceManager.tabs.contains { $0.id == id } } ?? false
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: isTabOpen) { _, isOpen in
        guard !isOpen, sheet != nil else { return }
        isBusy = false
        sheet = nil
      }
      .sidePanelOverlay(
        isPresented: Binding(
          get: { sheet != nil },
          set: { if !$0 && !isBusy { sheet = nil } }
        ),
        width: SQLDumpSheet.panelWidth
      ) {
        if let sheet, let tabID, let viewModel = workspaceManager.viewModel(for: tabID) {
          let isPresented = Binding(
            get: { self.sheet != nil }, set: { if !$0 { self.sheet = nil } })
          switch sheet {
          case .dump, .fileCopy:
            SQLDumpSheet(
              kind: sheet == .dump ? .sqlDump : .fileCopy, viewModel: viewModel,
              tables: workspaceManager.databaseTables, isPresented: isPresented,
              isBusy: $isBusy)
          case .restore:
            SQLRestoreSheet(
              viewModel: viewModel,
              databasePassword: workspaceManager.workspace.connectionConfig?.password,
              isConnected: workspaceManager.connectionState == .connected,
              isPresented: isPresented, isBusy: $isBusy)
          }
        }
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
  let onImportTable: (DatabaseTable) -> Void

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
        WorkspaceLeftSidebarContent(
          workspaceManager: workspaceManager, onImportTable: onImportTable)

        if workspaceManager.isSchemaPaused {
          SchemaPausedFooter()
        }
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

  @Environment(\.hostWindowReference) private var hostWindow
  @State private var keyEventMonitor: Any?

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
        removeKeyEventMonitor()
        setupKeyEventMonitor()
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
    } else if viewModel.viewMode == .markdown {
      // No SQL handlers, destructive-query dialog or search on a note. PlainTextEditor's
      // NSScrollView fills the area, so it needs no GeometryReader wrapper like editorContent.
      DocumentLayoutView(viewModel: viewModel) {
        MarkdownNoteView(viewModel: viewModel).id(tabId)
      }
    } else if viewModel.dataViewer != nil {
      dataViewerContent
    } else {
      editorContent
    }
  }

  private var documentMode: DocumentMode {
    switch viewModel.viewMode {
    case .notebook: .notebook
    case .markdown: .markdown
    default: .editor
    }
  }

  /// Markdown notes have no right sidebar content.
  private var toggleRightSidebarAction: () -> Void {
    { [viewModel] in
      if viewModel.viewMode != .markdown { viewModel.toggleSidebar() }
    }
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
          EditorModeView(
            viewModel: viewModel,
            objectSource: workspaceManager.tabs.first { $0.id == tabId }?.objectSource,
            onRetrySource: { workspaceManager.reloadObjectSource(tabId: tabId) },
            onOpenEditableCopy: { workspaceManager.openEditableCopy(ofSourceTab: tabId) }
          )
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

  // MARK: - Data Viewer Content

  /// Same wrapper as editorContent (sidebars, no layout flash during sidebar animation); Run
  /// reaches runEditorQuery, which refreshes the page. No editor document, so sync is a no-op.
  @ViewBuilder
  private var dataViewerContent: some View {
    DocumentLayoutView(viewModel: viewModel) {
      GeometryReader { geometry in
        ScrollView {
          DataViewerView(
            viewModel: viewModel,
            openQuery: { _ = workspaceManager.newSQLFile(content: $0) }
          )
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
    viewModel.databaseTriggers = workspaceManager.databaseTriggers
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

      // Only handle in this tab's own window, while it is the active tab there
      guard eventWindow === hostWindow?.window,
        workspaceManager.isActiveTab(tabId, in: hostWindow)
      else {
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
        // A presented modal closes itself. Yielding lets that monitor see Escape;
        // swallowing it here would blur the editor or close the sidebar instead.
        if ModalDismissRegistry.shared.hasModal(in: eventWindow) {
          return event
        }

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

      // Cmd+Z / Cmd+Shift+Z outside any text input -> undo/redo cell operations.
      // Text views, including field editors, keep their own undo. Data viewer tabs
      // use this path too; a SQL editor tab does not.
      let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
      let routeCellUndo = CellUndoRouting.routesCellUndo(
        firstResponderIsText: eventWindow.firstResponder is NSTextView,
        viewMode: self.viewModel.viewMode,
        hasDataViewer: self.viewModel.dataViewer != nil)
      if event.charactersIgnoringModifiers?.lowercased() == "z",
        flags == .command || flags == [.command, .shift],
        routeCellUndo
      {
        let isRedo = flags.contains(.shift)
        Task { @MainActor [viewModel] in
          if isRedo { viewModel.redoCellChange() } else { viewModel.undoCellChange() }
        }
        return nil
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

extension WorkspaceManager {
  /// Menu commands are broadcast to every window, including background native tabs: only the
  /// active workspace's active tab may act on them.
  fileprivate func isActiveTab(_ tabId: UUID, in hostWindow: HostWindowReference?) -> Bool {
    isActiveWorkspace(in: hostWindow) && activeTabId == tabId
  }

  /// The cached active workspace id can lag behind AppKit (a Welcome tab became key, a tab
  /// closed), so the workspace's own window must also be the key window (or own the key sheet).
  fileprivate func isActiveWorkspace(in hostWindow: HostWindowReference?) -> Bool {
    guard WorkspaceWindowManager.shared.activeWorkspaceId == id,
      let window = hostWindow?.window,
      let keyWindow = NSApp.keyWindow
    else { return false }
    return keyWindow === window || keyWindow.sheetParent === window
  }
}

extension EnvironmentValues {
  /// The window hosting the enclosing workspace container. Optional so the `@Entry` default is
  /// nil instead of a class instance; the container always injects the real reference.
  @Entry fileprivate var hostWindowReference: HostWindowReference? = nil
}

/// Handles notifications for notebook mode in workspace context
struct WorkspaceNotebookNotificationHandler: ViewModifier {
  @Environment(\.hostWindowReference) private var hostWindow
  let tabId: UUID
  let workspaceManager: WorkspaceManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  @State private var showRunAllConfirmation = false

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .addCodeCell)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        viewModel.addCell(type: .sql)
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCell)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.selectNextCell(createIfNeeded: true)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.insertCellBelow(type: .sql)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runAllCells)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        showRunAllConfirmation = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearCellOutput)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.clearCellOutput(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearAllOutputs)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        viewModel.clearAllOutputs()
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .deleteCell)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.deleteCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .duplicateCell)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        if let id = viewModel.selectedCellId {
          viewModel.duplicateCell(id: id)
          syncDocument()
        }
      }
      .onExplainCommands(
        tabId: tabId, workspaceManager: workspaceManager, hostWindow: hostWindow,
        viewModel: viewModel,
        syncDocument: syncDocument
      )
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
        Text("This will execute all cells in sequence. Existing results will be replaced.")
      }
  }
}

/// Handles notifications for editor mode in workspace context
struct WorkspaceEditorNotificationHandler: ViewModifier {
  @Environment(\.hostWindowReference) private var hostWindow
  let tabId: UUID
  let workspaceManager: WorkspaceManager
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .runEditorQuery)) { _ in
        guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
        Task {
          await viewModel.runEditorQuery()
          syncDocument()
        }
      }
      .onExplainCommands(
        tabId: tabId, workspaceManager: workspaceManager, hostWindow: hostWindow,
        viewModel: viewModel, syncDocument: syncDocument)
  }
}

extension View {
  /// Explain commands from the Cell and Query menus. Only the active tab runs them.
  fileprivate func onExplainCommands(
    tabId: UUID,
    workspaceManager: WorkspaceManager,
    hostWindow: HostWindowReference?,
    viewModel: NotebookViewModel,
    syncDocument: @escaping () -> Void
  ) -> some View {
    onReceive(NotificationCenter.default.publisher(for: .explainStatement)) { _ in
      guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
      Task {
        await viewModel.explainSelectedStatement(analyze: false)
        syncDocument()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .explainAnalyzeStatement)) { _ in
      guard workspaceManager.isActiveTab(tabId, in: hostWindow) else { return }
      Task {
        await viewModel.explainSelectedStatement(analyze: true)
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
  @Environment(\.isNativeTabBarVisible) private var isNativeTabBarVisible
  @Environment(\.colorScheme) private var colorScheme

  @State private var isHoveringNewTabButton = false

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
              - (isNativeTabBarVisible ? ComponentSize.trafficLightButtonsWidth : 0)
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
        // AI assistant button
        Button {
          workspaceManager.toggleAIAssistant()
        } label: {
          Image(systemName: "sparkles")
            .foregroundStyle(
              LinearGradient(
                colors: [Color.accent, Color.accent.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .blockDoubleClickZoom()
        .help("AI Assistant (⌘L)")

        // Light/dark toggle button
        Button {
          AppSettings.shared.themePreference = ThemePreference.toggled(from: colorScheme)
        } label: {
          Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .blockDoubleClickZoom()
        .help(colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode")

        // Settings button
        Button {
          NotificationCenter.default.post(name: .openSettings, object: nil)
        } label: {
          Image(systemName: "gearshape")
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .blockDoubleClickZoom()
        .help("Settings")

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
            Label(workspaceManager.newScriptLabel, systemImage: "doc")
          }

          Button {
            workspaceManager.newMarkdownFile()
          } label: {
            Label("New Markdown Note", systemImage: "doc.richtext")
          }

          Divider()

          Button {
            openFileWithPanel()
          } label: {
            Label("Open File…", systemImage: "folder")
          }

          Divider()

          Button {
            NewWindowStore.shared.openWelcomeWindowTab()
          } label: {
            Label("New Window", systemImage: "macwindow.badge.plus")
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 11))
            .foregroundColor(.foregroundMuted)
        }
        .menuStyle(.borderlessButton)
        .linkPointer()
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(Spacing.sm - 2)
        .contentShape(Circle())
        .background {
          Circle()
            .fill(isHoveringNewTabButton ? Color.cellBackgroundHover : Color.clear)
        }
        .animation(.easeInOut(duration: 0.15), value: isHoveringNewTabButton)
        .onHover { isHoveringNewTabButton = $0 }
        .blockDoubleClickZoom()
        .help("New or open tab")
      }
      .padding(.horizontal, Spacing.sm)
    }
    .frame(height: ComponentSize.tabBarHeight)
    .background(Color.appBackground)
    .background(WindowDragArea())
    // With the native tab bar above, match the sidebar's top edge
    .overlay(alignment: .top) {
      if isNativeTabBarVisible {
        Rectangle().fill(Color.border).frame(height: 1)
      }
    }
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

  private func openFileWithPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.dblore, .sql, .javaScript, .markdownText]

    panel.begin { response in
      guard response == .OK else { return }
      Task { @MainActor in
        for url in panel.urls {
          try? await workspaceManager.openFile(url: url, checksScriptKind: true)
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

  var body: some View {
    Button(action: action) {
      Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .controlSize(.small)
    .disabled(!isEnabled)
    .blockDoubleClickZoom()
    .help(direction == .left ? "Previous tab" : "Next tab")
  }
}

/// Info button that opens the details modal on the Workspace tab
struct WorkspaceInfoButton: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    Button {
      workspaceManager.workspaceInfoTab = .workspace
      workspaceManager.isWorkspaceInfoModalVisible = true
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 12))
    }
    .buttonStyle(
      GhostButtonStyle(isActive: workspaceManager.isWorkspaceInfoModalVisible, iconOnly: true)
    )
    .controlSize(.small)
    .blockDoubleClickZoom()
    .help("Details")
  }
}

/// Bolt button that opens the connection form. Hidden once connected; details are on the info button.
struct DatabaseConnectionButton: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    Button {
      workspaceManager.showConnectionForm()
    } label: {
      Image(systemName: "bolt.slash")
        .font(.system(size: 12))
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .controlSize(.small)
    .blockDoubleClickZoom()
    .help("Connect to database")
  }
}
