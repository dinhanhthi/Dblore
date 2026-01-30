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
            if let activeTabId = workspaceManager.activeTabId,
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

        // Traffic light area background + toggle button (z-index 2 - highest)
        // This covers sidebar buttons during animation
        HStack(spacing: 0) {
          // Background for traffic light area + toggle button
          Color.cardBackground
            .frame(
              width: ComponentSize.trafficLightAndToggleWidth + Spacing.md,
              height: ComponentSize.tabBarHeight
            )
            .overlay(alignment: .trailing) {
              // Toggle button positioned at trailing edge of background
              SidebarToggleButton(isSidebarVisible: workspaceManager.isLeftSidebarVisible) {
                workspaceManager.toggleLeftSidebar()
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
      TrafficLightPositioner(
        tabBarHeight: ComponentSize.tabBarHeight,
        hasSidebar: workspaceManager.isLeftSidebarVisible
      )
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

/// Tab bar view adapted for workspace
struct WorkspaceTitleBarTabsView: View {
  @Bindable var workspaceManager: WorkspaceManager
  let hasLeftSidebar: Bool

  var body: some View {
    // Reuse existing TitleBarTabsView pattern
    // This is a simplified version - full implementation would match TitleBarTabsView.swift
    HStack(spacing: 0) {
      if !hasLeftSidebar {
        Color.clear
          .frame(width: ComponentSize.trafficLightAndToggleWidth)
      }

      // Tabs
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 1) {
          ForEach(workspaceManager.tabs) { tab in
            WorkspaceTabItemView(
              tab: tab,
              isActive: workspaceManager.activeTabId == tab.id,
              workspaceManager: workspaceManager
            )
          }
        }
        .padding(.horizontal, Spacing.xs)
      }

      Spacer()

      // Connection status indicator
      WorkspaceConnectionBadge(workspaceManager: workspaceManager)
        .padding(.trailing, Spacing.sm)
    }
    .frame(height: ComponentSize.tabBarHeight)
    .background(Color.cardBackground)
    .background(WindowDragArea())
  }
}

/// Single tab item view for workspace
struct WorkspaceTabItemView: View {
  let tab: TabItem
  let isActive: Bool
  @Bindable var workspaceManager: WorkspaceManager

  @State private var isHovering = false

  var body: some View {
    Button {
      workspaceManager.selectTab(id: tab.id)
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: tab.documentType.icon)
          .font(.system(size: 11))
          .foregroundColor(isActive ? .accent : .foregroundMuted)

        Text(tab.title)
          .font(.caption)
          .foregroundColor(isActive ? .foreground : .foregroundMuted)
          .lineLimit(1)

        if tab.isDirty {
          Circle()
            .fill(Color.foregroundMuted)
            .frame(width: 6, height: 6)
        }

        if isHovering {
          Button {
            workspaceManager.requestCloseTab(id: tab.id)
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 9, weight: .medium))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        isActive ? Color.cellBackgroundHover : (isHovering ? Color.cellBackground : Color.clear)
      )
      .cornerRadius(CornerRadius.sm)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

/// Connection status badge in tab bar
struct WorkspaceConnectionBadge: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    Button {
      workspaceManager.showConnectionForm()
    } label: {
      HStack(spacing: Spacing.xxs) {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)

        Text(statusText)
          .font(.caption2)
          .foregroundColor(.foregroundMuted)
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 3)
      .background(Color.cardBackground.opacity(0.5))
      .cornerRadius(CornerRadius.sm)
    }
    .buttonStyle(.plain)
    .help(connectionHelp)
  }

  private var statusColor: Color {
    switch workspaceManager.connectionState {
    case .connected: return .green
    case .connecting: return .orange
    case .disconnected: return .foregroundSubtle
    case .error: return .red
    }
  }

  private var statusText: String {
    switch workspaceManager.connectionState {
    case .connected:
      return workspaceManager.workspace.connectionConfig?.displayString ?? "Connected"
    case .connecting:
      return "Connecting..."
    case .disconnected:
      return "Not connected"
    case .error(let message):
      return "Error: \(message)"
    }
  }

  private var connectionHelp: String {
    switch workspaceManager.connectionState {
    case .connected:
      return "Click to manage connection"
    case .connecting:
      return "Connecting to database..."
    case .disconnected:
      return "Click to connect"
    case .error:
      return "Connection error - click to retry"
    }
  }
}
