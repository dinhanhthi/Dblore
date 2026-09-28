//
//  AppWelcomeView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Welcome screen shown when no workspace is open
/// Displays recent workspaces and recent connections in two columns
struct AppWelcomeView: View {
  /// Callback when a workspace is selected - opens workspace in current window
  var onWorkspaceSelected: ((UUID) -> Void)?

  @Bindable var recentManager = RecentManager.shared
  @Bindable var windowManager = WorkspaceWindowManager.shared

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
                    columnWidth: columnWidth(
                      containerWidth: geometry.size.width,
                      hasBothColumns: recentManager.hasBothLists
                    )
                  )
                }

                // Recent Connections column
                if !recentManager.recentConnections.isEmpty {
                  RecentConnectionsColumn(
                    connections: recentManager.recentConnections,
                    onSelect: openConnectionAsWorkspace,
                    onNew: showConnectionForm,
                    columnWidth: columnWidth(
                      containerWidth: geometry.size.width,
                      hasBothColumns: recentManager.hasBothLists
                    )
                  )
                }
              }
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

    }
    .overlay {
      ToastOverlay()
    }
    .connectionFormModal(
      isPresented: $isShowingConnectionSidebar,
      connectionConfig: $editingConnectionConfig,
      onTestConnection: testConnectionForWelcome,
      onConnect: connectAndCreateWorkspaceForWelcome
    )
    .ignoresSafeArea(.all, edges: .top)
    .background(
      TrafficLightPositioner(tabBarHeight: ComponentSize.tabBarHeight)
    )
  }

  // MARK: - Layout Helpers

  /// Calculate column width based on container width and whether both columns are shown
  /// - When only one column: 500px (fixed)
  /// - When both columns and container < 900px: 350px each
  /// - When both columns and container >= 900px: 400px each
  private func columnWidth(containerWidth: CGFloat, hasBothColumns: Bool) -> CGFloat {
    if !hasBothColumns {
      return 500
    }
    return containerWidth < 900 ? 350 : 400
  }

  // MARK: - Actions

  private func openWorkspace(_ entry: WorkspaceHistoryEntry) {
    Task {
      do {
        let manager = try await WorkspaceWindowManager.shared.openWorkspace(url: entry.fileURL)
        // Open workspace in THIS window (replace welcome)
        onWorkspaceSelected?(manager.id)
      } catch let error as NSError {
        await AppLogger.shared.error("Failed to open workspace: \(error)", category: "Workspace")
        // Show user-friendly toast message
        await MainActor.run {
          if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            windowManager.showToast(
              "Workspace file not found: \(entry.name)",
              type: .error
            )
            // Remove from recent list since file doesn't exist
            RecentManager.shared.removeWorkspace(url: entry.fileURL)
          } else {
            windowManager.showToast(
              "Failed to open workspace: \(error.localizedDescription)",
              type: .error
            )
          }
        }
      }
    }
  }

  private func createNewWorkspace() {
    let manager = WorkspaceWindowManager.shared.newWorkspace()
    // Open workspace in THIS window (replace welcome)
    onWorkspaceSelected?(manager.id)
  }

  private func openConnectionAsWorkspace(_ entry: ConnectionHistoryEntry) {
    // Create new workspace with this connection
    let manager = WorkspaceWindowManager.shared.newWorkspace(connection: entry.config)
    // Open workspace in THIS window (replace welcome)
    onWorkspaceSelected?(manager.id)

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
    // Close modal first
    isShowingConnectionSidebar = false

    // Create workspace with connection and auto-connect
    let manager = WorkspaceWindowManager.shared.newWorkspace(connection: config)
    // Open workspace in THIS window (replace welcome)
    onWorkspaceSelected?(manager.id)

    Task {
      do {
        try await manager.connect(config: config)
      } catch {
        await AppLogger.shared.error("Failed to connect: \(error)", category: "Connection")
      }
    }
  }

  private func testConnectionForWelcome(_ config: ConnectionConfig) async throws -> Bool {
    let tempManager = DatabaseConnectionManager()
    return try await tempManager.testConnection(config: config)
  }

  private func connectAndCreateWorkspaceForWelcome(_ config: ConnectionConfig) async throws {
    let tempManager = DatabaseConnectionManager()
    let success = try await tempManager.testConnection(config: config)
    if success {
      await MainActor.run {
        createWorkspaceWithConnection(config)
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
  let columnWidth: CGFloat

  /// Track which workspace is currently being loaded
  @State private var loadingWorkspaceId: UUID?

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
        }
        .buttonStyle(PrimaryButtonStyle())
        .controlSize(.small)
      }

      // Workspace list
      VStack(spacing: 0) {
        ForEach(workspaces.prefix(6)) { workspace in
          RecentWorkspaceRow(
            workspace: workspace,
            isLoading: loadingWorkspaceId == workspace.id,
            onSelect: { entry in
              loadingWorkspaceId = entry.id
              onSelect(entry)
            }
          )
          .disabled(loadingWorkspaceId != nil)
        }
      }
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .frame(width: columnWidth)
  }
}

// MARK: - Recent Workspace Row

struct RecentWorkspaceRow: View {
  let workspace: WorkspaceHistoryEntry
  let isLoading: Bool
  let onSelect: (WorkspaceHistoryEntry) -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect(workspace)
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm) {
        // Workspace icon or loading indicator
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .frame(width: 24)
        } else {
          Image(systemName: "folder.badge.gearshape")
            .font(.system(size: 16))
            .foregroundColor(.accent)
            .frame(width: 24)
        }

        VStack(alignment: .leading, spacing: 2) {
          // First line: workspace name + tab count badge (right-aligned)
          HStack(spacing: Spacing.xs) {
            Text(workspace.name)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            // Tab count badge
            if workspace.tabCount > 0 {
              Text("\(workspace.tabCount)")
                .font(.caption2)
                .foregroundColor(.foregroundMuted)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(Color.inputBackground)
                .cornerRadius(CornerRadius.sm)
                .layoutPriority(1)
                .help("Number of tabs open in this workspace")
            }
          }

          // Second line: connection string + date (right-aligned)
          HStack(spacing: Spacing.xs) {
            if let conn = workspace.connectionDisplayString {
              Text(conn)
                .font(.caption)
                .foregroundColor(.foregroundMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: Spacing.xs)

            Text(workspace.formattedLastOpened)
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
              .layoutPriority(1)
              .help("Last opened date")
          }
        }

        Spacer(minLength: 0)
      }
      .padding(Spacing.sm)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .linkPointer()
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
  let columnWidth: CGFloat

  /// Track which connection is currently being loaded
  @State private var loadingConnectionId: UUID?

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
        }
        .buttonStyle(PrimaryButtonStyle())
        .controlSize(.small)
      }

      // Connection list
      VStack(spacing: 0) {
        ForEach(connections.prefix(6)) { connection in
          RecentConnectionRow(
            connection: connection,
            isLoading: loadingConnectionId == connection.id,
            onSelect: { entry in
              loadingConnectionId = entry.id
              onSelect(entry)
            }
          )
          .disabled(loadingConnectionId != nil)
        }
      }
      .background(Color.cardBackground)
      .cornerRadius(CornerRadius.md)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .frame(width: columnWidth)
  }
}

// MARK: - Recent Connection Row

struct RecentConnectionRow: View {
  let connection: ConnectionHistoryEntry
  let isLoading: Bool
  let onSelect: (ConnectionHistoryEntry) -> Void

  @State private var isHovering = false

  var body: some View {
    Button {
      onSelect(connection)
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm) {
        // Database type icon or loading indicator
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .frame(width: 24)
        } else {
          Image(connection.config.databaseType.iconAssetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .foregroundColor(.syntaxFunction)
            .frame(width: 24)
        }

        VStack(alignment: .leading, spacing: 2) {
          // First line: shortDisplayName + date (right-aligned)
          HStack(spacing: Spacing.xs) {
            Text(connection.shortDisplayName)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            Text(connection.formattedLastUsedDate)
              .font(.caption)
              .foregroundColor(.foregroundSubtle)
              .layoutPriority(1)
          }

          // Second line: connection string (e.g., "mydb@localhost:5432")
          Text(connection.config.displayString)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(Spacing.sm)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
    }
    .buttonStyle(.plain)
    .linkPointer()
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
      .linkPointer()
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

// MARK: - Preview Helpers

private enum PreviewData {
  static func makeWorkspaces() -> [WorkspaceHistoryEntry] {
    [
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/analytics.sqlnb"),
        name: "Analytics Dashboard",
        connectionDisplayString: "analytics@prod-db:5432",
        lastOpenedAt: Date().addingTimeInterval(-3600),  // 1 hour ago
        tabCount: 5
      ),
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/users-migration.sqlnb"),
        name: "Users Migration",
        connectionDisplayString: "users@localhost:5432",
        lastOpenedAt: Date().addingTimeInterval(-86400),  // 1 day ago
        tabCount: 3
      ),
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/reporting.sqlnb"),
        name: "Reporting Queries",
        connectionDisplayString: nil,
        lastOpenedAt: Date().addingTimeInterval(-172_800),  // 2 days ago
        tabCount: 0
      ),
    ]
  }

  static func makeConnections() -> [ConnectionHistoryEntry] {
    [
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .postgresql,
          host: "prod-db.example.com",
          port: 5432,
          database: "analytics",
          username: "analyst",
          name: "Production Analytics"
        )
      ),
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .postgresql,
          host: "localhost",
          port: 5432,
          database: "development",
          username: "dev",
          name: "Local Dev"
        )
      ),
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .sqlite,
          host: "",
          port: 0,
          database: "/Users/dev/data.sqlite",
          username: "",
          name: "Local SQLite"
        )
      ),
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .sqlite,
          host: "",
          port: 0,
          database: "/Users/dev/data.sqlite",
          username: "",
          name: "Local SQLite"
        )
      ),
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .sqlite,
          host: "",
          port: 0,
          database: "/Users/dev/data.sqlite",
          username: "",
          name: "Local SQLite"
        )
      ),
      ConnectionHistoryEntry(
        config: ConnectionConfig(
          databaseType: .sqlite,
          host: "",
          port: 0,
          database: "/Users/dev/data.sqlite",
          username: "",
          name: "Local SQLite"
        )
      ),
    ]
  }
}

// MARK: - Preview RecentManager

@MainActor
@Observable
private class PreviewRecentManager {
  var recentWorkspaces: [WorkspaceHistoryEntry]
  var recentConnections: [ConnectionHistoryEntry]

  init(
    workspaces: [WorkspaceHistoryEntry] = [],
    connections: [ConnectionHistoryEntry] = []
  ) {
    self.recentWorkspaces = workspaces
    self.recentConnections = connections
  }

  var hasRecentItems: Bool {
    !recentWorkspaces.isEmpty || !recentConnections.isEmpty
  }

  var hasOnlyWorkspaces: Bool {
    !recentWorkspaces.isEmpty && recentConnections.isEmpty
  }

  var hasOnlyConnections: Bool {
    recentWorkspaces.isEmpty && !recentConnections.isEmpty
  }

  var hasBothLists: Bool {
    !recentWorkspaces.isEmpty && !recentConnections.isEmpty
  }
}

// MARK: - Preview AppWelcomeView

private struct PreviewAppWelcomeView: View {
  let previewManager: PreviewRecentManager

  /// Calculate column width based on container width and whether both columns are shown
  private func columnWidth(containerWidth: CGFloat, hasBothColumns: Bool) -> CGFloat {
    if !hasBothColumns {
      return 500
    }
    return containerWidth < 900 ? 350 : 400
  }

  var body: some View {
    ZStack {
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: Spacing.xl) {
            WelcomeHeader()

            if previewManager.hasRecentItems {
              HStack(alignment: .top, spacing: Spacing.xl) {
                if !previewManager.recentWorkspaces.isEmpty {
                  RecentWorkspacesColumn(
                    workspaces: previewManager.recentWorkspaces,
                    onSelect: { _ in },
                    onNew: {},
                    columnWidth: columnWidth(
                      containerWidth: geometry.size.width,
                      hasBothColumns: previewManager.hasBothLists
                    )
                  )
                }

                if !previewManager.recentConnections.isEmpty {
                  RecentConnectionsColumn(
                    connections: previewManager.recentConnections,
                    onSelect: { _ in },
                    onNew: {},
                    columnWidth: columnWidth(
                      containerWidth: geometry.size.width,
                      hasBothColumns: previewManager.hasBothLists
                    )
                  )
                }
              }
            } else {
              EmptyWelcomeActions(
                onNewWorkspace: {},
                onConnect: {}
              )
            }
          }
          .padding(.vertical, Spacing.xxl)
          .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)
    }
  }
}

// MARK: - Previews

#Preview("Both Workspaces and Connections") {
  PreviewAppWelcomeView(
    previewManager: PreviewRecentManager(
      workspaces: PreviewData.makeWorkspaces(),
      connections: PreviewData.makeConnections()
    )
  )
  .frame(width: 800, height: 600)
}

#Preview("Empty - No Recent Items") {
  PreviewAppWelcomeView(
    previewManager: PreviewRecentManager()
  )
  .frame(width: 800, height: 600)
}

#Preview("Only Workspaces") {
  PreviewAppWelcomeView(
    previewManager: PreviewRecentManager(
      workspaces: PreviewData.makeWorkspaces()
    )
  )
  .frame(width: 800, height: 600)
}

#Preview("Only Connections") {
  PreviewAppWelcomeView(
    previewManager: PreviewRecentManager(
      connections: PreviewData.makeConnections()
    )
  )
  .frame(width: 800, height: 600)
}
