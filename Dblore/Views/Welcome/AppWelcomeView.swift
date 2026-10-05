//
//  AppWelcomeView.swift
//  Dblore
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
  /// Set while the connection form is editing one recent card. Nil creates a workspace.
  @State private var editingConnectionId: UUID?
  /// Recent workspace whose name and file path are being edited.
  @State private var editingWorkspace: WorkspaceHistoryEntry?
  @State private var isNativeTabBarVisible = false
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    ZStack {
      WelcomeWindowMarker().frame(width: 0, height: 0)
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
                    onConfigure: editWorkspace,
                    onRemove: { recentManager.removeWorkspace(id: $0.id) },
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
                    onConfigure: editConnection,
                    onRemove: { recentManager.removeConnection(id: $0.id) },
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
      title: editingConnectionId == nil ? "Connect to Database" : "Edit Connection",
      submitTitle: editingConnectionId == nil ? "Connect" : "Save",
      showsRecentHistory: editingConnectionId == nil,
      onTestConnection: testConnectionForWelcome,
      onConnect: submitConnectionForm
    )
    .modalOverlay(isPresented: workspaceEditPresented) {
      if let entry = editingWorkspace {
        RecentWorkspaceEditModal(
          entry: entry,
          isPresented: workspaceEditPresented,
          onSave: saveWorkspaceEdit
        )
        .id(entry.id)
      }
    }
    .ignoresSafeArea(.all, edges: isNativeTabBarVisible ? [] : .top)
    .background(
      DocumentWindowConfigurator(tabTitle: "Welcome", isTabBarVisible: $isNativeTabBarVisible)
    )
    .background(
      TrafficLightPositioner(
        tabBarHeight: ComponentSize.tabBarHeight, isTabBarVisible: isNativeTabBarVisible)
    )
    .onChange(of: controlActiveState) { _, newState in
      if newState == .key { WorkspaceWindowManager.shared.clearActiveWorkspace() }
    }
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
          if RecentManager.isFileNotFound(error) {
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

  private var workspaceEditPresented: Binding<Bool> {
    Binding(
      get: { editingWorkspace != nil },
      set: { if !$0 { editingWorkspace = nil } }
    )
  }

  private func editWorkspace(_ entry: WorkspaceHistoryEntry) {
    editingWorkspace = entry
  }

  private func saveWorkspaceEdit(
    _ entry: WorkspaceHistoryEntry, _ name: String, _ destination: URL
  ) async throws {
    try RecentWorkspaceEditor.apply(
      entry: entry,
      name: name,
      destination: destination,
      recents: recentManager,
      openWorkspaces: Array(windowManager.workspaces.values)
    )
  }

  private func showConnectionForm() {
    // Reset config and show sidebar
    editingConnectionId = nil
    editingConnectionConfig = ConnectionConfig()
    isShowingConnectionSidebar = true
  }

  private func editConnection(_ entry: ConnectionHistoryEntry) {
    editingConnectionId = entry.id
    editingConnectionConfig = entry.config
    isShowingConnectionSidebar = true
  }

  /// Connect creates a workspace. Save updates the recent card that was opened.
  private func submitConnectionForm(_ config: ConnectionConfig) async throws {
    if let id = editingConnectionId {
      guard recentManager.replaceConnection(id: id, with: config) else {
        throw CertificateFormError.keychainSave
      }
      return
    }
    try await connectAndCreateWorkspaceForWelcome(config)
  }

  private func testConnectionForWelcome(_ config: ConnectionConfig) async throws -> Bool {
    let tempManager = DatabaseConnectionManager()
    return try await tempManager.testConnection(config: config)
  }

  private func connectAndCreateWorkspaceForWelcome(_ config: ConnectionConfig) async throws {
    let windowManager = WorkspaceWindowManager.shared
    let manager = windowManager.newWorkspace(connection: config)
    do {
      try await manager.connect(config: config)
      isShowingConnectionSidebar = false
      onWorkspaceSelected?(manager.id)
    } catch {
      _ = await windowManager.closeWorkspace(id: manager.id, force: true)
      throw error
    }
  }
}

// MARK: - Welcome Header

struct WelcomeHeader: View {
  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  var body: some View {
    VStack(spacing: Spacing.xs) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 80, height: 80)

      Text("Welcome to Dblore")
        .font(.largeTitle)
        .fontWeight(.bold)
        .foregroundColor(.foreground)

      Text("Open a workspace or connect to a database to get started")
        .font(.body)
        .foregroundColor(.foregroundMuted)

      Text("Version \(appVersion)")
        .font(.callout)
        .foregroundColor(.foregroundSubtle)
    }
    .padding(.bottom, Spacing.lg)
  }
}

// MARK: - Recent Workspaces Column

struct RecentWorkspacesColumn: View {
  let workspaces: [WorkspaceHistoryEntry]
  let onSelect: (WorkspaceHistoryEntry) -> Void
  let onConfigure: (WorkspaceHistoryEntry) -> Void
  let onRemove: (WorkspaceHistoryEntry) -> Void
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
        let rows = Array(workspaces.prefix(6))
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, workspace in
          RecentWorkspaceRow(
            workspace: workspace,
            isFirst: index == 0,
            isLast: index == rows.count - 1,
            isLoading: loadingWorkspaceId == workspace.id,
            onSelect: { entry in
              loadingWorkspaceId = entry.id
              onSelect(entry)
            },
            onConfigure: { onConfigure(workspace) },
            onRemove: { onRemove(workspace) }
          )
          .disabled(loadingWorkspaceId != nil)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground)
      )
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
  let isFirst: Bool
  let isLast: Bool
  let isLoading: Bool
  let onSelect: (WorkspaceHistoryEntry) -> Void
  let onConfigure: () -> Void
  let onRemove: () -> Void

  @State private var isHovering = false
  @State private var isHoveringConfigure = false
  @State private var isHoveringRemove = false

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
          // Name. Config and remove take the old tab-count chip slot on hover.
          HStack(spacing: Spacing.xs) {
            Text(workspace.name)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: 0)
          }
          .recentActionSlot(
            isShown: showsRecentActions,
            isHoveringConfigure: $isHoveringConfigure,
            isHoveringRemove: $isHoveringRemove,
            configureHelp: "Edit workspace",
            onConfigure: onConfigure,
            onRemove: onRemove
          )

          workspaceDetailLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(Spacing.sm)
      .background(
        recentRowShape(isFirst: isFirst, isLast: isLast)
          .fill(isHovering ? Color.cellBackgroundHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .animation(.easeOut(duration: 0.12), value: isHoveringConfigure)
    .animation(.easeOut(duration: 0.12), value: isHoveringRemove)
  }

  /// Connection string, then tab count and relative time, separated by dots.
  /// The string truncates; the count and time stay fully visible.
  private var workspaceDetailLine: some View {
    let connection = workspace.connectionDisplayString.flatMap { $0.isEmpty ? nil : $0 }
    let showsTabCount = workspace.tabCount > 0

    return HStack(spacing: Spacing.xs) {
      if let connection {
        Text(connection)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(minWidth: 0, alignment: .leading)
      }

      if showsTabCount {
        if connection != nil {
          RecentMetaDot()
        }
        Text("\(workspace.tabCount)")
          .font(.caption.weight(.bold))
          .foregroundColor(.foreground)
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
          .help("Number of tabs open in this workspace")
      }

      if connection != nil || showsTabCount {
        RecentMetaDot()
      }

      Text(workspace.formattedLastOpened)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .help("Last opened date")

      Spacer(minLength: 0)
        .layoutPriority(-1)
    }
    .font(.caption)
    .foregroundColor(.foregroundSubtle)
  }

  private var showsRecentActions: Bool {
    (isHovering || isHoveringConfigure || isHoveringRemove) && !isLoading
  }
}

// MARK: - Recent Connections Column

struct RecentConnectionsColumn: View {
  let connections: [ConnectionHistoryEntry]
  let onSelect: (ConnectionHistoryEntry) -> Void
  let onConfigure: (ConnectionHistoryEntry) -> Void
  let onRemove: (ConnectionHistoryEntry) -> Void
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
        let rows = Array(connections.prefix(6))
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, connection in
          RecentConnectionRow(
            connection: connection,
            isFirst: index == 0,
            isLast: index == rows.count - 1,
            isLoading: loadingConnectionId == connection.id,
            onSelect: { entry in
              loadingConnectionId = entry.id
              onSelect(entry)
            },
            onConfigure: { onConfigure(connection) },
            onRemove: { onRemove(connection) }
          )
          .disabled(loadingConnectionId != nil)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground)
      )
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
  let isFirst: Bool
  let isLast: Bool
  let isLoading: Bool
  let onSelect: (ConnectionHistoryEntry) -> Void
  let onConfigure: () -> Void
  let onRemove: () -> Void

  @State private var isHovering = false
  @State private var isHoveringConfigure = false
  @State private var isHoveringRemove = false

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
          // Name. Config and remove take the trailing slot on hover, same as workspace rows.
          HStack(spacing: Spacing.xs) {
            Text(connection.shortDisplayName)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.foreground)
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: 0)
          }
          .recentActionSlot(
            isShown: showsRecentActions,
            isHoveringConfigure: $isHoveringConfigure,
            isHoveringRemove: $isHoveringRemove,
            configureHelp: "Edit connection",
            onConfigure: onConfigure,
            onRemove: onRemove
          )

          connectionDetailLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(Spacing.sm)
      .background(
        recentRowShape(isFirst: isFirst, isLast: isLast)
          .fill(isHovering ? Color.cellBackgroundHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .animation(.easeOut(duration: 0.12), value: isHoveringConfigure)
    .animation(.easeOut(duration: 0.12), value: isHoveringRemove)
  }

  /// Connection string, then last-used date, separated by a dot.
  /// The string truncates; the date stays fully visible.
  private var connectionDetailLine: some View {
    HStack(spacing: Spacing.xs) {
      Text(connection.config.displayString)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, alignment: .leading)

      RecentMetaDot()

      Text(connection.formattedLastUsedDate)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .help("Last used date")

      Spacer(minLength: 0)
        .layoutPriority(-1)
    }
    .font(.caption)
    .foregroundColor(.foregroundSubtle)
  }

  private var showsRecentActions: Bool {
    (isHovering || isHoveringConfigure || isHoveringRemove) && !isLoading
  }
}

// MARK: - Recent Hover Buttons

/// Hover highlight of a row: rounded only at the corners it shares with the card
private func recentRowShape(isFirst: Bool, isLast: Bool) -> UnevenRoundedRectangle {
  UnevenRoundedRectangle(
    topLeadingRadius: isFirst ? CornerRadius.md : 0,
    bottomLeadingRadius: isLast ? CornerRadius.md : 0,
    bottomTrailingRadius: isLast ? CornerRadius.md : 0,
    topTrailingRadius: isFirst ? CornerRadius.md : 0)
}

private enum RecentHoverMetrics {
  static let diameter: CGFloat = 16
  /// Title-line inset so the name clears the gear and the remove mark.
  static let pairWidth: CGFloat = diameter * 2 + Spacing.xs
}

/// Hover-only control on a recent row. The remove mark is drawn, not an SF Symbol:
/// `xmark`'s alignment rect sits off the circle's center.
private struct RecentHoverButton: View {
  enum Mark {
    case configure
    case remove
  }

  let mark: Mark
  let help: String
  let action: () -> Void
  @Binding var isHovering: Bool

  private var color: Color {
    isHovering ? .foreground : .foregroundMuted
  }

  var body: some View {
    Button(action: action) {
      markView
        .frame(width: RecentHoverMetrics.diameter, height: RecentHoverMetrics.diameter)
        .background {
          Circle().fill(isHovering ? Color.foreground.opacity(0.12) : Color.clear)
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help(help)
    .accessibilityLabel(help)
    .onHover { isHovering = $0 }
  }

  @ViewBuilder
  private var markView: some View {
    switch mark {
    case .configure:
      Image(systemName: "gearshape")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(color)
    case .remove:
      CenteredXMark(color: color)
    }
  }
}

/// Two strokes that cross at the center of their frame.
private struct CenteredXMark: View {
  var color: Color

  var body: some View {
    Canvas { context, size in
      let arm = min(size.width, size.height) * 0.22
      let midX = size.width / 2
      let midY = size.height / 2
      var path = Path()
      path.move(to: CGPoint(x: midX - arm, y: midY - arm))
      path.addLine(to: CGPoint(x: midX + arm, y: midY + arm))
      path.move(to: CGPoint(x: midX + arm, y: midY - arm))
      path.addLine(to: CGPoint(x: midX - arm, y: midY + arm))
      context.stroke(
        path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
    }
  }
}

extension View {
  /// Puts config and remove on the trailing edge of a title line.
  fileprivate func recentActionSlot(
    isShown: Bool,
    isHoveringConfigure: Binding<Bool>,
    isHoveringRemove: Binding<Bool>,
    configureHelp: String,
    onConfigure: @escaping () -> Void,
    onRemove: @escaping () -> Void
  ) -> some View {
    padding(.trailing, isShown ? RecentHoverMetrics.pairWidth : 0)
      .overlay(alignment: .trailing) {
        if isShown {
          HStack(spacing: Spacing.xs) {
            RecentHoverButton(
              mark: .configure,
              help: configureHelp,
              action: onConfigure,
              isHovering: isHoveringConfigure
            )
            RecentHoverButton(
              mark: .remove,
              help: "Remove from recent",
              action: onRemove,
              isHovering: isHoveringRemove
            )
          }
          .transition(.opacity)
        }
      }
      .zIndex(isShown ? 1 : 0)
  }
}

/// Separator between connection string, tab count, and relative time.
private struct RecentMetaDot: View {
  var body: some View {
    Circle()
      .fill(Color.foregroundSubtle)
      .frame(width: 3, height: 3)
      .accessibilityHidden(true)
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
        description: "Create a new workspace to organize your notebooks and queries",
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
  @State private var isHoveringRemove = false

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
      .buttonBorderShape(.capsule)
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
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/analytics.dblore"),
        name: "Analytics Dashboard",
        connectionDisplayString: "analytics@prod-db:5432",
        lastOpenedAt: Date().addingTimeInterval(-3600),  // 1 hour ago
        tabCount: 5
      ),
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/users-migration.dblore"),
        name: "Users Migration",
        connectionDisplayString: "users@localhost:5432",
        lastOpenedAt: Date().addingTimeInterval(-86400),  // 1 day ago
        tabCount: 3
      ),
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/reporting.dblore"),
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
                    onConfigure: { _ in },
                    onRemove: { _ in },
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
                    onConfigure: { _ in },
                    onRemove: { _ in },
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
