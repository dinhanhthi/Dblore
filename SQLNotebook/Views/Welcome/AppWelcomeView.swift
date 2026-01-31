//
//  AppWelcomeView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Welcome screen shown when no workspace is open
/// Displays recent workspaces and recent connections in two columns
struct AppWelcomeView: View {
  @Bindable var recentManager = RecentManager.shared

  // State for connection form sidebar (before workspace is created)
  @State private var isShowingConnectionSidebar = false
  @State private var editingConnectionConfig = ConnectionConfig()

  var body: some View {
    ZStack {
      // Main content
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: Spacing.xl) {
            // Header
            WelcomeHeader()

            // Two columns for recent items
            if recentManager.hasRecentItems {
              HStack(alignment: .top, spacing: Spacing.xl) {
                // Recent Workspaces column
                if !recentManager.recentWorkspaces.isEmpty {
                  RecentWorkspacesColumn(
                    workspaces: recentManager.recentWorkspaces,
                    onSelect: openWorkspace,
                    onNew: createNewWorkspace,
                    fullWidth: recentManager.hasOnlyWorkspaces
                  )
                }

                // Recent Connections column
                if !recentManager.recentConnections.isEmpty {
                  RecentConnectionsColumn(
                    connections: recentManager.recentConnections,
                    onSelect: openConnectionAsWorkspace,
                    onNew: showConnectionForm,
                    fullWidth: recentManager.hasOnlyConnections
                  )
                }
              }
              .frame(maxWidth: 900)
            } else {
              // No recent items - show action buttons
              EmptyWelcomeActions(
                onNewWorkspace: createNewWorkspace,
                onConnect: showConnectionForm
              )
            }
          }
          .padding(.vertical, Spacing.xxl)
          .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)

      // Connection sidebar overlay
      if isShowingConnectionSidebar {
        HStack(spacing: 0) {
          Spacer()
          AppWelcomeConnectionSidebar(
            connectionConfig: $editingConnectionConfig,
            onClose: { isShowingConnectionSidebar = false },
            onConnectSuccess: { config in
              // Create workspace and connect
              createWorkspaceWithConnection(config)
            }
          )
          .transition(.move(edge: .trailing))
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingConnectionSidebar)
      }
    }
    .ignoresSafeArea(.all, edges: .top)
    .background(
      TrafficLightPositioner(tabBarHeight: ComponentSize.tabBarHeight)
    )
  }

  // MARK: - Actions

  private func openWorkspace(_ entry: WorkspaceHistoryEntry) {
    Task {
      do {
        try await WorkspaceWindowManager.shared.openWorkspace(url: entry.fileURL)
      } catch {
        await AppLogger.shared.error("Failed to open workspace: \(error)", category: "Workspace")
      }
    }
  }

  private func createNewWorkspace() {
    _ = WorkspaceWindowManager.shared.newWorkspace()
  }

  private func openConnectionAsWorkspace(_ entry: ConnectionHistoryEntry) {
    // Create new workspace with this connection
    let manager = WorkspaceWindowManager.shared.newWorkspace(connection: entry.config)

    // Auto-connect
    Task {
      do {
        try await manager.connect(config: entry.config)
      } catch {
        await AppLogger.shared.error("Failed to connect: \(error)", category: "Connection")
      }
    }
  }

  private func showConnectionForm() {
    // Reset config and show sidebar
    editingConnectionConfig = ConnectionConfig()
    isShowingConnectionSidebar = true
  }

  private func createWorkspaceWithConnection(_ config: ConnectionConfig) {
    // Close sidebar first
    isShowingConnectionSidebar = false

    // Create workspace with connection and auto-connect
    let manager = WorkspaceWindowManager.shared.newWorkspace(connection: config)
    Task {
      do {
        try await manager.connect(config: config)
      } catch {
        await AppLogger.shared.error("Failed to connect: \(error)", category: "Connection")
      }
    }
  }
}

// MARK: - App Welcome Connection Sidebar

/// Connection sidebar used in AppWelcomeView before any workspace is created
struct AppWelcomeConnectionSidebar: View {
  @Binding var connectionConfig: ConnectionConfig
  let onClose: () -> Void
  let onConnectSuccess: (ConnectionConfig) -> Void

  @State private var width: CGFloat = 380

  private let minWidth: CGFloat = 320
  private let maxWidth: CGFloat = 600

  var body: some View {
    VStack(spacing: 0) {
      // Header
      RightSidebarOverlayHeader(
        title: "Connect to Database",
        onClose: onClose
      )

      // Connection form - using the unified ConnectionFormContent
      ConnectionFormContent(
        connectionConfig: $connectionConfig,
        onTestConnection: testConnection,
        onConnect: connectAndCreateWorkspace,
        onConnectionSuccess: nil  // We handle success in onConnect
      )
    }
    .frame(width: width)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color.border)
        .frame(width: 1)
    }
    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
    .overlay(alignment: .leading) {
      ResizeHandle(
        width: $width,
        minWidth: minWidth,
        maxWidth: maxWidth
      )
    }
  }

  private func testConnection(_ config: ConnectionConfig) async throws -> Bool {
    // Create temporary connection manager for testing
    let tempManager = DatabaseConnectionManager()
    return try await tempManager.testConnection(config: config)
  }

  private func connectAndCreateWorkspace(_ config: ConnectionConfig) async throws {
    // Test connection first
    let tempManager = DatabaseConnectionManager()
    let success = try await tempManager.testConnection(config: config)
    if success {
      // Call success handler on main thread
      await MainActor.run {
        onConnectSuccess(config)
      }
    }
  }
}

// MARK: - Welcome Header

struct WelcomeHeader: View {
  var body: some View {
    VStack(spacing: Spacing.xs) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 80, height: 80)

      Text("Welcome to SQLNotebook")
        .font(.largeTitle)
        .fontWeight(.bold)
        .foregroundColor(.foreground)

      Text("Open a workspace or connect to a database to get started")
        .font(.body)
        .foregroundColor(.foregroundMuted)
    }
    .padding(.bottom, Spacing.lg)
  }
}

// MARK: - Recent Workspaces Column

struct RecentWorkspacesColumn: View {
  let workspaces: [WorkspaceHistoryEntry]
  let onSelect: (WorkspaceHistoryEntry) -> Void
  let onNew: () -> Void
  let fullWidth: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Header with action button
      HStack {
        Label("Recent Workspaces", systemImage: "folder.badge.gearshape")
          .font(.headline)
          .foregroundColor(.foreground)

        Spacer()

        Button {
          onNew()
        } label: {
          Label("New", systemImage: "plus")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      // Workspace list
      VStack(spacing: 0) {
        ForEach(workspaces.prefix(8)) { workspace in
          RecentWorkspaceRow(workspace: workspace, onSelect: onSelect)
        }
      }
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .frame(width: fullWidth ? 500 : 400)
  }
}

// MARK: - Recent Workspace Row

struct RecentWorkspaceRow: View {
  let workspace: WorkspaceHistoryEntry
  let onSelect: (WorkspaceHistoryEntry) -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect(workspace)
    } label: {
      HStack(spacing: Spacing.sm) {
        // Workspace icon
        Image(systemName: "folder.badge.gearshape")
          .font(.system(size: 16))
          .foregroundColor(.accent)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(workspace.name)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.foreground)
            .lineLimit(1)

          HStack(spacing: Spacing.xs) {
            if let conn = workspace.connectionDisplayString {
              Text(conn)
                .font(.caption)
                .foregroundColor(.foregroundMuted)
            }

            Text(workspace.formattedLastOpened)
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
          }
        }

        Spacer()

        // Tab count badge
        if workspace.tabCount > 0 {
          Text("\(workspace.tabCount)")
            .font(.caption2)
            .foregroundColor(.foregroundMuted)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.cellBackground)
            .cornerRadius(CornerRadius.sm)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

// MARK: - Recent Connections Column

struct RecentConnectionsColumn: View {
  let connections: [ConnectionHistoryEntry]
  let onSelect: (ConnectionHistoryEntry) -> Void
  let onNew: () -> Void
  let fullWidth: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Header with action button
      HStack {
        Label("Recent Connections", systemImage: "server.rack")
          .font(.headline)
          .foregroundColor(.foreground)

        Spacer()

        Button {
          onNew()
        } label: {
          Label("Connect", systemImage: "plus")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      // Connection list
      VStack(spacing: 0) {
        ForEach(connections.prefix(8)) { connection in
          RecentConnectionRow(connection: connection, onSelect: onSelect)
        }
      }
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .frame(width: fullWidth ? 500 : 400)
  }
}

// MARK: - Recent Connection Row

struct RecentConnectionRow: View {
  let connection: ConnectionHistoryEntry
  let onSelect: (ConnectionHistoryEntry) -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect(connection)
    } label: {
      HStack(spacing: Spacing.sm) {
        // Database icon
        Image(systemName: "server.rack")
          .font(.system(size: 16))
          .foregroundColor(.syntaxFunction)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 2) {
          Text(connection.shortDisplayName)
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.foreground)
            .lineLimit(1)

          Text(connection.displayString)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
        }

        Spacer()

        // Database type badge
        Text(connection.config.databaseType.displayName)
          .font(.caption2)
          .foregroundColor(.foregroundMuted)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, 2)
          .background(Color.cellBackground)
          .cornerRadius(CornerRadius.sm)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

// MARK: - Empty Welcome Actions

struct EmptyWelcomeActions: View {
  let onNewWorkspace: () -> Void
  let onConnect: () -> Void

  var body: some View {
    HStack(spacing: Spacing.lg) {
      // New Workspace Card
      ActionCard(
        icon: "folder.badge.gearshape",
        title: "New Workspace",
        description: "Create a new workspace to organize your SQL files",
        accentColor: .accent,
        buttonTitle: "Create Workspace",
        action: onNewWorkspace
      )

      // Connect to Database Card
      ActionCard(
        icon: "server.rack",
        title: "Connect to Database",
        description: "Connect to a database and start querying",
        accentColor: .syntaxFunction,
        buttonTitle: "Connect",
        action: onConnect
      )
    }
  }
}

// MARK: - Action Card

struct ActionCard: View {
  let icon: String
  let title: String
  let description: String
  let accentColor: Color
  let buttonTitle: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Icon and Title
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 24))
          .foregroundColor(accentColor)

        Text(title)
          .font(.headline)
          .foregroundColor(.foreground)
      }

      // Description
      Text(description)
        .font(.subheadline)
        .foregroundColor(.foregroundMuted)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      // Action button
      Button(action: action) {
        Text(buttonTitle)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(accentColor)
      .controlSize(.regular)
    }
    .padding(Spacing.lg)
    .frame(width: 260, height: 180)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.lg)
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.lg)
        .stroke(isHovering ? accentColor.opacity(0.5) : Color.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 4, y: 2)
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.easeInOut(duration: 0.15), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
