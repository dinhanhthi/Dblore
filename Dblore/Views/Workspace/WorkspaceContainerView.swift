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
  /// Native tab bar band below the titlebar row (0 while hidden), reported by the configurator
  @State private var nativeTabBarHeight: CGFloat = 0
  @State private var trafficLightsWidth = ComponentSize.trafficLightWidth
  /// In full screen the window has no titlebar row (see `DocumentWindowConfigurator`)
  @State private var isFullScreen = false
  @State private var hostWindow = HostWindowReference()
  @Environment(\.controlActiveState) private var controlActiveState
  @ReduceMotion private var reduceMotion
  @State private var isImportPresented = false
  @State private var isImportBusy = false
  @State private var importTabID: UUID?
  @State private var importDestination: TableImportDestination?
  /// Import Files: its model, the tab it runs in and the table whose menu opened it
  @State private var multiFileImport: MultiFileImportRequest?
  @State private var isMultiFileImportPresented = false
  @State private var isMultiFileImportBusy = false
  /// Generate Rows: its model and the tab it runs in
  @State private var generateRows: GenerateRowsPanelRequest?
  @State private var isGenerateRowsPresented = false
  @State private var isGenerateRowsBusy = false
  /// Build Join Query: its model (the sheet opens its query in a new tab)
  @State private var joinBuilder: JoinBuilderModel?
  @State private var isJoinBuilderPresented = false
  @State private var isConnectionImportPresented = false
  /// Export SQL Dump / Copy Database File / Restore SQL Dump panel, and the tab it runs for
  @State private var backupSheet: BackupSheet?
  @State private var backupTabID: UUID?
  /// A collection or view change started from the left sidebar
  @State private var sidebarMongoAdmin: SidebarMongoAdmin?

  /// Get the active view model (if any tab is active)
  private var activeViewModel: NotebookViewModel? {
    guard let activeTabId = workspaceManager.activeTabId else { return nil }
    return workspaceManager.viewModel(for: activeTabId)
  }

  /// Whether the content area shows `WorkspaceEmptyStateView` (no tab, no schema visualizer and
  /// no MongoDB overview screen)
  private var showsEmptyState: Bool {
    !workspaceManager.isSchemaVisualizerActive && workspaceManager.mongoOverview == nil
      && activeViewModel == nil
  }

  /// Hides the AI assistant only in its sidebar mode: the floating bubble takes no width
  private func hideAIAssistantSidebar() {
    guard workspaceManager.aiAssistant.showsSidebarPanel else { return }
    withSidebarAnimation { workspaceManager.aiAssistant.hide() }
  }

  /// Whether the left sidebar beside the open right sidebars (AI assistant panel and the tab's
  /// sidebar) leaves the tab content less than its minimum width.
  private var sidebarsCrowdContent: Bool {
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

  /// Sidebars, tabs, content and footer: not built while the window is covered (relocked), so
  /// nothing of the workspace shows through or takes keyboard input
  private var workspaceLayout: some View {
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
              onImportTable: { requestImport(for: $0) },
              onImportFiles: { requestMultiFileImport(schema: $0, table: $1) },
              onGenerateRows: { requestGenerateRows(for: $0) },
              onBuildJoinQuery: { requestJoinBuilder(initialTables: [$0]) },
              mongoAdmin: $sidebarMongoAdmin
            )

            // Main content area (tabs + content)
            VStack(spacing: 0) {
              // Tab bar in titlebar area
              WorkspaceTitleBarTabsView(
                workspaceManager: workspaceManager,
                hasLeftSidebar: workspaceManager.isLeftSidebarVisible
              )
              // Above the views below it: the titlebar row is unsafe area, and a background or scroll
              // view that starts at its edge extends up into the row
              .zIndex(1)

              // Room for the native tab bar, which AppKit draws below the titlebar row; its line
              // continues the one under the left sidebar's tabs
              Color.appBackground.frame(height: nativeTabBarHeight)
              if nativeTabBarHeight > 0 {
                Divider()
              }

              // Pending Protected transaction (Commit / Rollback)
              if !workspaceManager.pendingTransaction.isIdle {
                PendingTransactionBanner(workspaceManager: workspaceManager)
              }

              // The server closed the connection (Reconnect)
              if workspaceManager.connectionLostMessage != nil {
                ConnectionLostBanner(workspaceManager: workspaceManager)
              }

              // Auto-connect stopped on a locked connection (Unlock), with or without tabs
              if workspaceManager.isConnectLocked, !workspaceManager.connectionState.isConnected {
                LockedConnectionBanner(workspaceManager: workspaceManager)
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
                WorkspaceSchemaVisualizerContent(
                  workspaceManager: workspaceManager,
                  onBuildJoinQuery: { requestJoinBuilder(initialTables: $0) })
              } else if let screen = workspaceManager.mongoOverview {
                // MongoDB Databases / Collections at workspace level (over the tabs)
                switch screen {
                case .databases: MongoDatabasesView(workspaceManager: workspaceManager)
                case .collections: MongoCollectionsView(workspaceManager: workspaceManager)
                }
              } else if let activeTabId = workspaceManager.activeTabId,
                let viewModel = workspaceManager.viewModel(for: activeTabId)
              {
                WorkspaceTabContentView(
                  tabId: activeTabId,
                  workspaceManager: workspaceManager,
                  viewModel: viewModel
                )
              } else {
                // App-level toasts (connect warnings) need an overlay before a tab opens one
                WorkspaceEmptyStateView(workspaceManager: workspaceManager)
                  .overlay { ToastOverlay() }
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
                width: trafficLightsWidth + ComponentSize.sidebarToggleOffset
                  + workspaceManager.connectionState.connectionButtonsWidth,
                height: ComponentSize.tabBarHeight
              )
              .background {
                if !workspaceManager.isLeftSidebarVisible {
                  Color.appBackground
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
            // The card stays below the native tab bar
            .padding(.top, nativeTabBarHeight)
            .transition(.opacity)
            .zIndex(2)
          }
        }

        FooterView(
          viewModel: workspaceManager.isSchemaVisualizerActive
            || workspaceManager.mongoOverview != nil ? nil : activeViewModel,
          connectionState: workspaceManager.connectionState,
          connectionConfig: workspaceManager.workspace.connectionConfig,
          transport: workspaceManager.mysqlTransport
        )
      }
      // The native tab bar starts after the left sidebar, at the width it renders with. In full
      // screen the tab bar is pinned above the content at full width; the header row sits below it.
      .background(
        NativeTabBarSidebarInset(
          width: !isFullScreen && workspaceManager.isLeftSidebarVisible
            ? SidebarRoom.leftWidth(
              workspaceManager.workspace.settings.leftSidebarWidth
                ?? CGFloat(AppSettings.shared.leftSidebarWidth),
              windowWidth: geometry.size.width) : 0)
      )
    }
  }

  var body: some View {
    // A ZStack, not a Group: a Group hands every modifier below to each branch, so a cover
    // change rebuilt the whole chain (the window reader lost its window, the close guard its
    // button, the sheets their state)
    ZStack {
      if workspaceManager.lockCoverage == nil {
        workspaceLayout
      } else {
        Color.appBackground
      }
    }
    // No min frame here: `documentWindowMode` sets the limits, and a fixed 600 overflowed the
    // 540 compact window (sidebars and the footer were cut off at the bottom)
    .background(Color.appBackground)
    // The header fills the titlebar row; the native tab bar band below it gets spacers. Full
    // screen has no titlebar row: the header sits below what AppKit pins at the top (the tab bar).
    .ignoresSafeArea(.all, edges: isFullScreen ? [] : .top)
    .environment(\.nativeTabBarHeight, nativeTabBarHeight)
    .environment(\.trafficLightsWidth, trafficLightsWidth)
    .background(
      DocumentWindowConfigurator(
        tabTitle: WorkspaceWindowTitle.tab(workspaceName: workspaceManager.workspace.name),
        windowTitle: WorkspaceWindowTitle.window(
          // Covered: no file name in the title either
          fileName: workspaceManager.lockCoverage == nil ? workspaceManager.activeTab?.title : nil,
          workspaceName: workspaceManager.workspace.name),
        isTabBarVisible: $isNativeTabBarVisible,
        tabBarHeight: $nativeTabBarHeight,
        trafficLightsWidth: $trafficLightsWidth,
        isFullScreen: $isFullScreen)
    )
    .background(WorkspaceWindowCloseGuard(workspaceManager: workspaceManager))
    // The window's sheets and dialogs hang on this anchor, which exists only while the window
    // is not covered: none shows over the cover, and one open at the relock goes away
    .background {
      if workspaceManager.lockCoverage == nil {
        windowPresentations
      }
    }
    // Note: File opening is handled by AppDelegate.application(_:open:) in DbloreApp.swift
    // Don't use .onOpenURL here as it conflicts with NSApplicationDelegateAdaptor
    // Focused actions for keyboard shortcuts (Cmd+B, Cmd+Shift+B, etc.)
    .bridgedFocusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .bridgedFocusedSceneValue(\.toggleRightSidebarAction) { [workspaceManager] in
      if let activeTabId = workspaceManager.activeTabId,
        let viewModel = workspaceManager.viewModel(for: activeTabId),
        viewModel.viewMode != .markdown
      {
        viewModel.toggleSidebar()
      }
    }
    .bridgedFocusedSceneValue(\.toggleAIAssistantAction) { [workspaceManager] in
      workspaceManager.toggleAIAssistant()
    }
    .bridgedFocusedSceneValue(\.openCommandPaletteAction) { [workspaceManager] in
      workspaceManager.openCommandPalette()
    }
    .bridgedFocusedSceneValue(\.openTableImportAction, importAction)
    .bridgedFocusedSceneValue(\.openSQLDumpAction, backupAction(.dump))
    .bridgedFocusedSceneValue(\.openSQLRestoreAction, backupAction(.restore))
    .bridgedFocusedSceneValue(\.openDatabaseFileCopyAction, backupAction(.fileCopy))
    .bridgedFocusedSceneValue(\.openDataDictionaryAction, dataDictionaryAction)
    .bridgedFocusedSceneValue(\.openSchemaCompareAction, schemaCompareAction)
    .bridgedFocusedSceneValue(\.activeViewModel, activeViewModel)
    .bridgedFocusedSceneValue(\.activeWorkspace, workspaceManager)
    .connectionFormModal(workspaceManager: workspaceManager)
    .workspaceInfoModal(workspaceManager: workspaceManager)
    // After the connection form, so they open on top of it
    .connectionImportPanel(
      isPresented: $isConnectionImportPresented, workspaceManager: workspaceManager
    )
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
    .sidePanelOverlay(
      isPresented: Binding(
        get: { isMultiFileImportPresented },
        set: { if $0 || !isMultiFileImportBusy { isMultiFileImportPresented = $0 } }
      ),
      width: TableImportSheet.panelWidth, maxWidthFraction: 0.8
    ) {
      if let request = multiFileImport,
        let viewModel = workspaceManager.viewModel(for: request.tabID)
      {
        MultiFileImportSheet(
          viewModel: viewModel, model: request.model, table: request.table,
          isPresented: $isMultiFileImportPresented, isBusy: $isMultiFileImportBusy
        )
        // A new request starts a fresh sheet (no edited file or task of the last one)
        .id(ObjectIdentifier(request.model))
      }
    }
    .sidePanelOverlay(
      isPresented: Binding(
        get: { isGenerateRowsPresented },
        set: { if $0 || !isGenerateRowsBusy { isGenerateRowsPresented = $0 } }
      ),
      width: TableImportSheet.panelWidth, maxWidthFraction: 0.8
    ) {
      if let request = generateRows, let viewModel = workspaceManager.viewModel(for: request.tabID)
      {
        GenerateRowsSheet(
          viewModel: viewModel, model: request.model,
          isPresented: $isGenerateRowsPresented, isBusy: $isGenerateRowsBusy
        )
        // A new request starts a fresh sheet (no settings or task of the last one)
        .id(ObjectIdentifier(request.model))
      }
    }
    .modifier(
      JoinBuilderPanel(
        workspaceManager: workspaceManager, model: joinBuilder,
        isPresented: $isJoinBuilderPresented, menuAction: joinBuilderAction)
    )
    .modifier(
      BackupPanel(workspaceManager: workspaceManager, sheet: $backupSheet, tabID: backupTabID)
    )
    .modifier(DataRewindPanel(workspaceManager: workspaceManager))
    .favoriteFormPanel(workspaceManager: workspaceManager)
    .pendingTransactionDetailsModal(workspaceManager: workspaceManager)
    // Right sidebars above run the full window height, like the content
    .ignoresSafeArea(.all, edges: isNativeTabBarVisible ? [] : .top)
    .favoriteModals(workspaceManager: workspaceManager)
    .historyDetailModal(workspaceManager: workspaceManager)
    .sidebarMongoAdmin($sidebarMongoAdmin, workspaceManager: workspaceManager)
    .commandPaletteModal(workspaceManager: workspaceManager)
    // Relocked: the panels and modals open below take no input and stay hidden under the cover
    .disabled(workspaceManager.lockCoverage != nil)
    .overlay {
      if let coverage = workspaceManager.lockCoverage {
        LockedOverlayView(coverage: coverage, workspaceManager: workspaceManager) {
          hostWindow.window
        }
      }
    }
    // Covered: the AI request in flight stops, no field keeps the keyboard and every sheet
    // and dialog of the window closes
    .onChange(of: workspaceManager.lockCoverage != nil) { _, covered in
      guard covered else { return }
      if workspaceManager.aiAssistant.isGenerating { workspaceManager.aiAssistant.stop() }
      hostWindow.window?.makeFirstResponder(nil)
      dismissPresentationsForCover()
    }
    .background(HostWindowReader(reference: hostWindow))
    .claimsConnectionImport(hostWindow: hostWindow, isPresented: $isConnectionImportPresented)
    // Full size even with no tab open: the left sidebar opens tables from there
    .documentWindowMode(.regular, isTabbed: isNativeTabBarVisible)
    .environment(\.hostWindowReference, hostWindow)
    // Here rather than on the tabs, so the theme also applies while no tab is open
    .windowAppearance(AppSettings.shared.themePreference.colorScheme)
    // When the tab content would lose its minimum width, only one side stays open: opening a
    // right sidebar collapses the left one and opening the left one collapses the right ones.
    .onChange(of: workspaceManager.aiAssistant.showsSidebarPanel) { _, shows in
      if shows { collapseLeftSidebarIfCrowded() }
    }
    .onChange(of: activeViewModel?.isRightSidebarVisible == true) { _, shows in
      if shows { collapseLeftSidebarIfCrowded() }
    }
    .onChange(of: workspaceManager.isLeftSidebarVisible) { _, isVisible in
      if isVisible { collapseRightSidebarsIfCrowded() }
    }
    .modifier(
      SidebarWidthChanges(
        activeTabId: workspaceManager.activeTabId,
        rightSidebarWidth: activeViewModel?.rightSidebarWidth,
        leftSidebarWidth: workspaceManager.workspace.settings.leftSidebarWidth,
        onRightSidebarChange: {
          if activeViewModel?.isRightSidebarVisible == true { collapseLeftSidebarIfCrowded() }
        },
        onLeftSidebarChange: {
          if workspaceManager.isLeftSidebarVisible { collapseRightSidebarsIfCrowded() }
        })
    )
    // With no tab open, the left sidebar is where a table opens: show it (animated once the
    // window is up). Not saved in the workspace settings, so the workspace does not turn dirty.
    .onChange(of: showsEmptyState, initial: true) { wasEmpty, isEmpty in
      guard isEmpty, !workspaceManager.isLeftSidebarVisible else { return }
      if wasEmpty == isEmpty {
        workspaceManager.isLeftSidebarVisible = true
      } else {
        withSidebarAnimation { workspaceManager.isLeftSidebarVisible = true }
      }
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
      guard workspaceManager.isActiveWorkspace(in: hostWindow),
        workspaceManager.lockCoverage == nil
      else { return }
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

  /// The window-level sheets and dialogs (each one a sheet on the window, above any overlay):
  /// attached to an empty anchor that is not built while the window is covered
  private var windowPresentations: some View {
    Color.clear
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
      .dataDictionaryExportSheet(workspaceManager: workspaceManager)
      .schemaCompareSheet(workspaceManager: workspaceManager)
      .lockWorkspaceSheet(workspaceManager: workspaceManager)
      .crossTableSearchSheet(workspaceManager: workspaceManager)
  }

  /// The window was just covered: its sheets, dialogs and panels close (a running Lock
  /// Workspace or schema compare keeps its sheet state and shows again after the unlock). Then,
  /// once SwiftUI dismissed its own, any AppKit sheet still on the window (alerts, save panels)
  /// ends as cancelled; an unlock prompt stays.
  private func dismissPresentationsForCover() {
    let manager = workspaceManager
    if manager.showingCloseConfirmation { manager.cancelClose() }
    if manager.isCommitConfirmationVisible {
      manager.isCommitConfirmationVisible = false
      manager.cancelCommitConfirmation()
    }
    if manager.isCommitUnlockVisible { manager.cancelCommitUnlock() }
    manager.dataDictionaryExport?.cancel()
    manager.closeSchemaCompare()
    manager.lockSheet?.close()
    if manager.isCrossTableSearchPresented { manager.crossTableSearch?.hide() }
    if manager.pendingWeakeningConnect != nil { manager.cancelPendingWeakeningConnect() }
    // MongoDB confirmations name what they act on; one that runs shows again after the unlock
    sidebarMongoAdmin?.model.cancel()
    if let model = manager.mongoBackup?.model, case .confirming = model.state { model.cancel() }
    if let model = manager.mongoImport?.model, case .confirming = model.state { model.cancel() }
    manager.isSettingsModalVisible = false
    isConnectionImportPresented = false
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard manager.lockCoverage != nil, let window = hostWindow.window else { return }
      UnlockPromptSheet.endSheets(on: window)
    }
  }

  /// Import Data: the MongoDB Import form (the table import never opens for MongoDB), else the
  /// table import
  private var importAction: (() -> Void)? {
    if workspaceManager.isMongoWorkspace {
      guard workspaceManager.canImportDocuments else { return nil }
      return { [workspaceManager] in workspaceManager.openMongoImport(collection: nil) }
    }
    guard workspaceManager.canImportData else { return nil }
    return { requestImport() }
  }

  /// Connected to an engine with a SQL dump (the file copy: SQLite only); the sheet runs for the
  /// active tab, or a new SQL file when none is open. MongoDB (no SQL dump): Back Up Database and
  /// Restore Backup (`WorkspaceManager.mongoBackup`), no file copy.
  private func backupAction(_ sheet: BackupSheet) -> (() -> Void)? {
    if workspaceManager.isMongoWorkspace {
      guard sheet != .fileCopy, workspaceManager.canBackUpMongo else { return nil }
      return { [workspaceManager] in
        workspaceManager.openMongoBackup(sheet == .restore ? .restore : .backup)
      }
    }
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

  private var dataDictionaryAction: (() -> Void)? {
    guard workspaceManager.canExportDataDictionary else { return nil }
    return { [workspaceManager] in workspaceManager.openDataDictionaryExport() }
  }

  private var schemaCompareAction: (() -> Void)? {
    guard workspaceManager.canCompareSchemas else { return nil }
    return { [workspaceManager] in workspaceManager.openSchemaCompare() }
  }

  private var joinBuilderAction: (() -> Void)? {
    guard workspaceManager.canBuildJoinQuery else { return nil }
    return { requestJoinBuilder() }
  }

  private func requestImport(for table: DatabaseTable? = nil) {
    guard workspaceManager.canImportData else { return }
    let tabID = workspaceManager.activeTabId ?? workspaceManager.newSQLFile()
    importTabID = tabID
    importDestination = table.map { .existing(schema: $0.schema, table: $0.name) }
    isImportPresented = true
  }

  /// Import Files into `schema` (a table's menu passes its table: one file goes into it)
  private func requestMultiFileImport(schema: String?, table: DatabaseTable?) {
    guard workspaceManager.canImportData else { return }
    let tabID = workspaceManager.activeTabId ?? workspaceManager.newSQLFile()
    multiFileImport = MultiFileImportRequest(
      model: MultiFileImportModel(schema: schema, tables: workspaceManager.databaseTables),
      tabID: tabID, table: table)
    isMultiFileImportPresented = true
  }

  /// Generate Rows into `table`, in the active tab or a new SQL file
  private func requestGenerateRows(for table: DatabaseTable) {
    guard workspaceManager.canGenerateRows else { return }
    let tabID = workspaceManager.activeTabId ?? workspaceManager.newSQLFile()
    generateRows = GenerateRowsPanelRequest(
      model: GenerateRowsModel(schema: table.schema, table: table.name), tabID: tabID)
    isGenerateRowsPresented = true
  }

  /// Build Join Query with `initialTables` picked in order (none from the File menu)
  private func requestJoinBuilder(initialTables: [DatabaseTable] = []) {
    guard workspaceManager.canBuildJoinQuery else { return }
    joinBuilder = workspaceManager.makeJoinBuilderModel(initialTables: initialTables)
    isJoinBuilderPresented = true
  }
}

/// The Import Files panel's model, the tab it runs in and the table whose menu opened it
private struct MultiFileImportRequest {
  let model: MultiFileImportModel
  let tabID: UUID
  let table: DatabaseTable?
}

/// The Generate Rows panel's model and the tab it runs in
private struct GenerateRowsPanelRequest {
  let model: GenerateRowsModel
  let tabID: UUID
}

/// The Build Join Query panel, and its File menu item's action (published here rather than in
/// the container's body, whose chain is at the type checker's limit)
private struct JoinBuilderPanel: ViewModifier {
  let workspaceManager: WorkspaceManager
  let model: JoinBuilderModel?
  @Binding var isPresented: Bool
  let menuAction: (() -> Void)?

  func body(content: Content) -> some View {
    content
      .bridgedFocusedSceneValue(\.openJoinBuilderAction, menuAction)
      .sidePanelOverlay(
        isPresented: $isPresented, width: TableImportSheet.panelWidth, maxWidthFraction: 0.8
      ) {
        if let model {
          JoinBuilderSheet(
            workspaceManager: workspaceManager, model: model, isPresented: $isPresented
          )
          // A new request starts a fresh sheet (no picks of the last one)
          .id(ObjectIdentifier(model))
        }
      }
  }
}

// MARK: - Sidebar Width Changes

/// Sidebars that take more room once open: another tab's right sidebar, a right sidebar dragged
/// wider or showing other content, and a left sidebar dragged wider. The side that changed stays
/// open.
private struct SidebarWidthChanges: ViewModifier {
  let activeTabId: UUID?
  let rightSidebarWidth: CGFloat?
  let leftSidebarWidth: Double?
  let onRightSidebarChange: () -> Void
  let onLeftSidebarChange: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: activeTabId) { onRightSidebarChange() }
      .onChange(of: rightSidebarWidth) { onRightSidebarChange() }
      .onChange(of: leftSidebarWidth) { onLeftSidebarChange() }
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
/// its work) and the panel go away. Also the MongoDB Back Up Database and Restore Backup panel
/// (`WorkspaceManager.mongoBackup`, cleared with its work stopped on tab close and disconnect).
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

  /// The MongoDB backup or restore panel; closing it is refused while a file panel is open or
  /// the work runs (its Cancel stops it)
  private var isMongoPresented: Binding<Bool> {
    Binding(
      get: { workspaceManager.mongoBackup != nil },
      set: {
        guard !$0, let model = workspaceManager.mongoBackup?.model, !model.isBusy else { return }
        model.dismiss()
        workspaceManager.mongoBackup = nil
      })
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: isTabOpen) { _, isOpen in
        guard !isOpen, sheet != nil else { return }
        isBusy = false
        sheet = nil
      }
      .sidePanelOverlay(isPresented: isMongoPresented, width: SQLDumpSheet.panelWidth) {
        if let request = workspaceManager.mongoBackup {
          switch request.kind {
          case .backup:
            MongoBackupSheet(
              model: request.model,
              // `system.` collections are never backed up
              collections: workspaceManager.databaseTables.map(\.name)
                .filter { !$0.hasPrefix("system.") },
              views: workspaceManager.databaseViews.map(\.name), isPresented: isMongoPresented)
          case .restore:
            MongoRestoreSheet(
              model: request.model,
              databasePassword: workspaceManager.workspace.connectionConfig?.password,
              isConnected: workspaceManager.connectionState == .connected,
              isPresented: isMongoPresented)
          }
        }
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
  let onImportFiles: (_ schema: String?, _ table: DatabaseTable?) -> Void
  let onGenerateRows: (DatabaseTable) -> Void
  let onBuildJoinQuery: (DatabaseTable) -> Void
  @Binding var mongoAdmin: SidebarMongoAdmin?

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
          // Above the list, which can extend up into the titlebar row (unsafe area)
          .zIndex(1)

        // Main sidebar content - always use workspace schema
        WorkspaceLeftSidebarContent(
          workspaceManager: workspaceManager, onImportTable: onImportTable,
          onImportFiles: onImportFiles, onGenerateRows: onGenerateRows,
          onBuildJoinQuery: onBuildJoinQuery, mongoAdmin: $mongoAdmin)

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
      .bridgedFocusedSceneValue(\.documentMode, documentMode)
      .focusedSceneValue(\.activeTabId, tabId)
      .bridgedFocusedSceneValue(\.activeViewModel, viewModel)
      .bridgedFocusedSceneValue(\.toggleRightSidebarAction, toggleRightSidebarAction)
      .bridgedFocusedSceneValue(\.openSearchAction, openSearchAction)
      .bridgedFocusedSceneValue(\.findReplaceAction, findReplaceAction)
      .bridgedFocusedSceneValue(\.findNextAction, findNextAction)
      .bridgedFocusedSceneValue(\.findPreviousAction, findPreviousAction)
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

  /// Nil where Replace may not edit (data viewer, read-only source, note): the menu item is
  /// disabled there
  private var findReplaceAction: (() -> Void)? {
    guard viewModel.isReplaceAvailable else { return nil }
    return { [viewModel] in viewModel.openFindReplace() }
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
            openQuery: { _ = workspaceManager.newSQLFile(content: $0) },
            aiAssistant: workspaceManager.aiAssistant
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

        // The AI composer's `/` or `@` popup closes itself on Escape
        if workspaceManager.aiAssistant.composerSuggestionsShown {
          return event
        }

        // Priority 0: If search panel is open, close it
        if self.viewModel.isSearchPanelVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSearch()
          }
          return nil
        }

        // AI ghost text shown in the focused editor: hide it and keep the focus (an open
        // autocomplete popup or a modifier keeps the usual Esc)
        if textViewIsFocused,
          (eventWindow.firstResponder as? SQLTextView)?.handleGhostTextKey(with: event) == true
        {
          return nil
        }

        // Priority 1: If text editor is focused, unfocus it. A result grid cell edit cancels
        // first, before any observer or the blur can end the edit (ending it commits).
        // Otherwise synchronous observers (cells, inline edits) run first; the blur then
        // covers the editors and SwiftUI fields.
        if textViewIsFocused {
          if let fieldEditor = eventWindow.firstResponder as? NSTextView,
            fieldEditor.isFieldEditor,
            let control = fieldEditor.delegate as? NSTextField,
            let grid = control.delegate as? ResultGridCoordinator,
            grid.control(
              control, textView: fieldEditor,
              doCommandBy: #selector(NSResponder.cancelOperation(_:)))
          {
            return nil
          }
          NotificationCenter.default.post(name: .unfocusEditor, object: nil)
          eventWindow.makeFirstResponder(nil)
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
  @Environment(\.trafficLightsWidth) private var trafficLightsWidth
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var updater = UpdaterController.shared

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
            width: trafficLightsWidth + ComponentSize.sidebarToggleOffset
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
        // Update button, while Sparkle has a new version waiting
        if let version = updater.availableUpdateVersion {
          Button(action: updater.checkForUpdates) {
            Image(systemName: "arrow.down")
          }
          .buttonStyle(SuccessButtonStyle(iconOnly: true))
          .controlSize(.small)
          .blockDoubleClickZoom()
          .help("Update to Dblore \(version)")
        }

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
            .fill(isHoveringNewTabButton ? Color.hoverFill : Color.clear)
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
