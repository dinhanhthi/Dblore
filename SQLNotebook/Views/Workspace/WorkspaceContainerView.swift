//
//  WorkspaceContainerView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Main container view for a workspace with tabs, sidebars, and content
struct WorkspaceContainerView: View {
  @Bindable var workspaceManager: WorkspaceManager

  /// Get the active view model (if any tab is active)
  private var activeViewModel: NotebookViewModel? {
    guard let activeTabId = workspaceManager.activeTabId else { return nil }
    return workspaceManager.viewModel(for: activeTabId)
  }

  var body: some View {
    GeometryReader { geometry in
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

        // Right sidebar overlay (floating, not pushing layout) - z-index 1
        if workspaceManager.isRightSidebarVisible {
          HStack {
            Spacer()
            RightSidebarOverlay(workspaceManager: workspaceManager)
          }
          .transition(.move(edge: .trailing))
          .zIndex(1)
        }

        // Traffic light area background + toggle button + connection button (z-index 2 - highest)
        // This covers sidebar buttons during animation
        HStack(spacing: 0) {
          // Background for traffic light area + buttons
          Color.cardBackground
            .frame(
              width: ComponentSize.trafficLightAndToggleWidth
                + (workspaceManager.connectionState.isConnected ? 75 : 44),
              height: ComponentSize.tabBarHeight
            )
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
        .zIndex(2)
      }
    }
    .frame(minWidth: 800, minHeight: 600)
    .background(Color.appBackground)
    .ignoresSafeArea(.all, edges: .top)
    .animation(.easeInOut(duration: 0.2), value: workspaceManager.isLeftSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: workspaceManager.isRightSidebarVisible)
    .background(
      TrafficLightPositioner(tabBarHeight: ComponentSize.tabBarHeight)
    )
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
    .onOpenURL { url in
      Task {
        // Handle different file types
        let ext = url.pathExtension.lowercased()
        if ext == "sqlws" {
          // Open workspace
          _ = try? await WorkspaceWindowManager.shared.openWorkspace(url: url)
        } else {
          // Open file in current workspace
          try? await workspaceManager.openFile(url: url)
        }
      }
    }
    // Focused actions for keyboard shortcuts (Cmd+B, Cmd+Shift+B, etc.)
    .focusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) { [workspaceManager] in
      workspaceManager.toggleRightSidebar()
    }
    .focusedSceneValue(\.activeViewModel, activeViewModel)
    .connectionFormModal(workspaceManager: workspaceManager)
    .connectionInfoModal(workspaceManager: workspaceManager)
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
      .background(Color.cardBackground)
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
struct WorkspaceTabContentView: View {
  let tabId: UUID
  @Bindable var workspaceManager: WorkspaceManager
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    // Use existing TabContentView but with workspace connection
    TabContentView(
      tabId: tabId,
      tabManager: TabStateManager.shared,
      viewModel: viewModel
    )
    .onAppear {
      // Setup document changed callback to use workspace manager instead of TabStateManager
      viewModel.onDocumentChanged = { [workspaceManager, tabId] in
        workspaceManager.markDirty(tabId: tabId)
      }
      // Sync workspace connection to viewModel
      syncConnectionState()
    }
    .onChange(of: workspaceManager.connectionState) { _, _ in
      syncConnectionState()
    }
  }

  private func syncConnectionState() {
    viewModel.connectionState = workspaceManager.connectionState
    viewModel.databaseTables = workspaceManager.databaseTables
    viewModel.databaseViews = workspaceManager.databaseViews
    viewModel.databaseFunctions = workspaceManager.databaseFunctions
    viewModel.databaseProcedures = workspaceManager.databaseProcedures
    viewModel.databaseUsers = workspaceManager.databaseUsers
    viewModel.databaseRoles = workspaceManager.databaseRoles
    viewModel.databaseForeignKeys = workspaceManager.databaseForeignKeys
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
              + (workspaceManager.connectionState.isConnected ? 75 : 44))
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
      .padding(.top, 4)
      .padding(.trailing, Spacing.xs)

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
      .menuIndicator(.hidden)
      .fixedSize()
      .blockDoubleClickZoom()
      .padding(.horizontal, Spacing.sm)
    }
    .frame(height: ComponentSize.tabBarHeight)
    .background(Color.cardBackground)
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
