//
//  AppWelcomeView.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Welcome screen shown when no workspace is open
/// Sidebar with logo and start actions; recent workspaces and connections on the right
struct AppWelcomeView: View {
  /// Callback when a workspace is selected - opens workspace in current window
  var onWorkspaceSelected: ((UUID) -> Void)?

  @Bindable var recentManager = RecentManager.shared
  @Bindable var windowManager = WorkspaceWindowManager.shared

  // State for connection form sidebar (before workspace is created)
  @State private var isShowingConnectionSidebar = false
  /// Settings modal; no workspace hosts it here, so connection-scoped pages show a placeholder
  @State private var isShowingSettings = false
  /// Page requested by the opener (nil opens General)
  @State private var settingsSection: SettingsPage?
  /// Bumped on open only: a fresh token per render would reset the selected tab
  @State private var settingsToken = UUID()
  @State private var hostWindow = HostWindowReference()
  @State private var editingConnectionConfig = ConnectionFormContent.newFormDraft()
  /// Set while the connection form is editing one recent card. Nil creates a workspace.
  @State private var editingConnectionId: UUID?
  /// Recent workspace whose name and file path are being edited.
  /// Kept after close so the panel keeps its content while it slides out.
  @State private var editingWorkspace: WorkspaceHistoryEntry?
  @State private var isWorkspaceEditPresented = false
  @State private var isImportPresented = false
  /// Kept after close so the panel keeps its content while it slides out.
  @State private var exportModel: ConnectionExportModel?
  @State private var isExportPresented = false
  @State private var isNativeTabBarVisible = false
  /// Height of the native window tab bar below the titlebar row (0 when hidden or in full screen)
  @State private var nativeTabBarHeight: CGFloat = 0
  @State private var isFullScreen = false
  @Environment(\.controlActiveState) private var controlActiveState

  @Environment(\.pixelLength) private var pixelLength

  /// Clears the traffic lights. In full screen the window tab bar is pinned above the content,
  /// so a tabbed window needs no inset there.
  private var topInset: CGFloat {
    isFullScreen && isNativeTabBarVisible ? 0 : ComponentSize.tabBarHeight
  }

  /// Keeps the recents below the native tab bar, which starts after the sidebar
  private var recentsTopInset: CGFloat {
    nativeTabBarHeight > 0 ? ComponentSize.tabBarHeight + nativeTabBarHeight : 0
  }

  var body: some View {
    ZStack {
      WelcomeWindowMarker().frame(width: 0, height: 0)
      HStack(spacing: 0) {
        WelcomeSidebar(
          topInset: topInset,
          onNewWorkspace: createNewWorkspace,
          onConnect: showConnectionForm,
          onImport: { isImportPresented = true },
          onSettings: { NotificationCenter.default.post(name: .openSettings, object: nil) }
        )

        Rectangle()
          .fill(Color.border)
          .frame(width: pixelLength)

        WelcomeRecents(
          workspaces: recentManager.recentWorkspaces,
          connections: recentManager.recentConnections,
          onOpenWorkspace: openWorkspace,
          onEditWorkspace: editWorkspace,
          onRemoveWorkspace: { recentManager.removeWorkspace(id: $0.id) },
          onOpenConnection: openConnectionAsWorkspace,
          onEditConnection: editConnection,
          onRemoveConnection: { recentManager.removeConnection(id: $0.id) },
          onExportConnections: showConnectionExport,
          onNewWorkspace: createNewWorkspace,
          onConnect: showConnectionForm
        )
        .padding(.top, recentsTopInset)
        .background(alignment: .top) {
          WindowDragArea().frame(height: recentsTopInset)
        }
        // Fills the titlebar row above the native tab bar
        .overlay(alignment: .top) {
          if recentsTopInset > 0 {
            Text("Welcome")
              .font(.subheading)
              .frame(height: ComponentSize.tabBarHeight)
              .allowsHitTesting(false)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)
      // The native tab bar starts after the sidebar and its divider
      .background(
        NativeTabBarSidebarInset(
          width: isFullScreen ? 0 : ComponentSize.welcomeSidebarWidth + pixelLength)
      )
    }
    // The content fills the titlebar row; the native tab bar is cleared by the insets above
    .ignoresSafeArea(.all, edges: isFullScreen ? [] : .top)
    .overlay {
      ToastOverlay()
    }
    .connectionFormModal(
      isPresented: $isShowingConnectionSidebar,
      connectionConfig: $editingConnectionConfig,
      title: editingConnectionId == nil ? "Connect to Database" : "Edit Connection",
      submitTitle: editingConnectionId == nil ? "Connect" : "Save",
      showsRecentHistory: false,
      onTestConnection: testConnectionForWelcome,
      onConnect: submitConnectionForm,
      onOpenPluginSettings: { openSettings(section: .plugins) }
    )
    // After the connection form, so they open on top of it
    .connectionImportPanel(isPresented: $isImportPresented)
    .sidePanelOverlay(isPresented: $isExportPresented, width: ConnectionExportSheet.panelWidth) {
      if let exportModel {
        ConnectionExportSheet(model: exportModel, isPresented: $isExportPresented)
      }
    }
    .settingsModal(
      isPresented: $isShowingSettings, viewMode: nil, section: settingsSection,
      openToken: settingsToken
    )
    .sidePanelOverlay(
      isPresented: $isWorkspaceEditPresented, width: RecentWorkspaceEditModal.panelWidth
    ) {
      if let entry = editingWorkspace {
        RecentWorkspaceEditModal(
          entry: entry,
          isPresented: $isWorkspaceEditPresented,
          onSave: saveWorkspaceEdit
        )
        .id(entry.id)
      }
    }
    // Modals and side panels stay below the native tab bar
    .ignoresSafeArea(.all, edges: isNativeTabBarVisible ? [] : .top)
    .background(
      DocumentWindowConfigurator(
        tabTitle: "Welcome", isTabBarVisible: $isNativeTabBarVisible,
        tabBarHeight: $nativeTabBarHeight, isFullScreen: $isFullScreen)
    )
    .background(
      HostWindowReader(reference: hostWindow) {
        // A request made while this window was opening finds it once the window is known
        Task { @MainActor in
          if ConnectionImportPresenter.claim(for: hostWindow.window) { isImportPresented = true }
        }
      }
    )
    .claimsConnectionImport(hostWindow: hostWindow, isPresented: $isImportPresented)
    .documentWindowMode(.compact, isTabbed: isNativeTabBarVisible)
    .windowAppearance(AppSettings.shared.themePreference.colorScheme)
    .onChange(of: controlActiveState) { _, newState in
      if newState == .key { WorkspaceWindowManager.shared.clearActiveWorkspace() }
    }
    // Dblore > Settings (Cmd+,) posts this; only the key Welcome window answers
    .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { notification in
      guard let window = hostWindow.window, let keyWindow = NSApp.keyWindow,
        keyWindow === window || keyWindow.sheetParent === window
      else { return }
      if let raw = notification.userInfo?[SettingsPage.userInfoKey] as? String,
        let section = SettingsPage(rawValue: raw)
      {
        openSettings(section: section)
      } else {
        settingsSection = nil
        isShowingSettings.toggle()
      }
    }
  }

  private func openSettings(section: SettingsPage) {
    settingsSection = section
    settingsToken = UUID()
    isShowingSettings = true
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
        // The window now shows the workspace: its form offers the plugin install
        manager.presentConnectErrorIfActionable(error, config: entry.config)
      }
    }
  }

  private func editWorkspace(_ entry: WorkspaceHistoryEntry) {
    editingWorkspace = entry
    isWorkspaceEditPresented = true
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
    editingConnectionConfig = ConnectionFormContent.newFormDraft()
    isShowingConnectionSidebar = true
  }

  /// A fresh picker each time: all saved connections checked, favorites of no workspace.
  private func showConnectionExport() {
    exportModel = ConnectionExportModel(
      connections: recentManager.recentConnections, workspaces: windowManager.allWorkspaces)
    isExportPresented = true
  }

  private func editConnection(_ entry: ConnectionHistoryEntry) {
    editingConnectionId = entry.id
    editingConnectionConfig = entry.config
    isShowingConnectionSidebar = true
  }

  /// Connect creates a workspace. Save updates the recent card that was opened; unless the AI
  /// fields were edited it keeps the saved row's AI policy and rules, so a stale form copy never
  /// loosens a policy another window saved meanwhile.
  private func submitConnectionForm(_ config: ConnectionConfig, aiFieldsEdited: Bool) async throws {
    if let id = editingConnectionId {
      let row = aiFieldsEdited ? config : WorkspaceManager.keepingSavedAIFields(config)
      guard recentManager.replaceConnection(id: id, with: row) else {
        throw CertificateFormError.keychainSave
      }
      return
    }
    try await connectAndCreateWorkspaceForWelcome(config, aiFieldsEdited: aiFieldsEdited)
  }

  private func testConnectionForWelcome(_ config: ConnectionConfig) async throws -> Bool {
    let tempManager = Self.makeTestConnectionManager()
    return try await tempManager.testConnection(config: config)
  }

  /// Test Connection before a workspace exists. Asks through the app-wide trust sheet.
  static func makeTestConnectionManager() -> DatabaseConnectionManager {
    .withTrustPrompt()
  }

  private func connectAndCreateWorkspaceForWelcome(
    _ config: ConnectionConfig, aiFieldsEdited: Bool
  ) async throws {
    let windowManager = WorkspaceWindowManager.shared
    let manager = windowManager.newWorkspace(connection: config)
    do {
      try await manager.connect(config: config, aiFieldsEdited: aiFieldsEdited, fromForm: true)
      isShowingConnectionSidebar = false
      onWorkspaceSelected?(manager.id)
    } catch {
      _ = await windowManager.closeWorkspace(id: manager.id, force: true)
      throw error
    }
  }
}

// MARK: - Welcome Sidebar

/// Logo, version and the start actions. Settings sits at the bottom.
struct WelcomeSidebar: View {
  var topInset: CGFloat = 0
  let onNewWorkspace: () -> Void
  let onConnect: () -> Void
  let onImport: () -> Void
  let onSettings: () -> Void

  @ObservedObject private var updater = UpdaterController.shared
  @Environment(\.openURL) private var openURL
  @Environment(\.colorScheme) private var colorScheme

  private static let repositoryURL = URL(string: "https://github.com/dinhanhthi/Dblore")!
  private static let issuesURL = URL(string: "https://github.com/dinhanhthi/Dblore/issues")!

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  var body: some View {
    WelcomeSidebarColumn(topInset: topInset) {
      VStack(spacing: Spacing.xs) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 72, height: 72)
        Text("Dblore")
          .font(.title3.weight(.semibold))
          .foregroundColor(.foreground)
        Text("Version \(appVersion)")
          .font(.callout)
          .foregroundColor(.foregroundMuted)
      }
    } actions: {
      WelcomeActionButton(
        title: "New Workspace", systemImage: "folder.badge.plus", action: onNewWorkspace)
      WelcomeActionButton(
        title: "Connect to Database", systemImage: "server.rack", action: onConnect)
      WelcomeActionButton(
        title: "Import Connections...", systemImage: "square.and.arrow.down",
        help:
          "Import connections from a Dblore export file, a URI, .pgpass, DBeaver, TablePlus or DataGrip",
        action: onImport)
    } footer: {
      HStack(spacing: Spacing.sm) {
        Button(action: updater.checkForUpdates) {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .help("Check for Updates")
        .disabled(!updater.canCheckForUpdates)

        Button {
          openURL(Self.repositoryURL)
        } label: {
          Image("GitHubMark")
            .resizable()
            .frame(width: 14, height: 14)
        }
        .help("GitHub Repository (github.com/dinhanhthi/Dblore)")

        Button {
          openURL(Self.issuesURL)
        } label: {
          Image(systemName: "ladybug")
        }
        .help("Find a bug or suggest a feature?")

        Button {
          AppSettings.shared.themePreference = ThemePreference.toggled(from: colorScheme)
        } label: {
          Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
        }
        .help(colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode")

        Button(action: onSettings) {
          Image(systemName: "gearshape")
        }
        .help("Settings (⌘,)")
      }
      .buttonStyle(SecondaryButtonStyle(iconOnly: true))
      .frame(maxWidth: .infinity)
    }
  }
}

// MARK: - Welcome Recents

/// Filter field and Workspaces / Connections tabs above a compact list of the selected kind.
struct WelcomeRecents: View {
  let workspaces: [WorkspaceHistoryEntry]
  let connections: [ConnectionHistoryEntry]
  let onOpenWorkspace: (WorkspaceHistoryEntry) -> Void
  let onEditWorkspace: (WorkspaceHistoryEntry) -> Void
  let onRemoveWorkspace: (WorkspaceHistoryEntry) -> Void
  let onOpenConnection: (ConnectionHistoryEntry) -> Void
  let onEditConnection: (ConnectionHistoryEntry) -> Void
  let onRemoveConnection: (ConnectionHistoryEntry) -> Void
  let onExportConnections: () -> Void
  /// Start actions offered when there is nothing recent yet
  let onNewWorkspace: () -> Void
  let onConnect: () -> Void

  private enum RecentsTab: Hashable {
    case workspaces
    case connections
  }

  @Environment(\.pixelLength) private var pixelLength
  @State private var filter = ""
  @State private var tab: RecentsTab = .workspaces
  /// Row being opened; every row is disabled meanwhile
  @State private var loadingId: UUID?

  private var query: String { filter.trimmingCharacters(in: .whitespaces) }

  private var shownWorkspaces: [WorkspaceHistoryEntry] {
    guard !query.isEmpty else { return workspaces }
    return workspaces.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || ($0.connectionDisplayString?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var shownConnections: [ConnectionHistoryEntry] {
    Self.matchingConnections(connections, query: query)
  }

  /// Connections whose name, connection string or group contains `query` (all when empty).
  static func matchingConnections(
    _ connections: [ConnectionHistoryEntry], query: String
  ) -> [ConnectionHistoryEntry] {
    guard !query.isEmpty else { return connections }
    return connections.filter {
      $0.shortDisplayName.localizedCaseInsensitiveContains(query)
        || $0.config.displayString.localizedCaseInsensitiveContains(query)
        || ($0.config.groupName?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  var body: some View {
    if workspaces.isEmpty && connections.isEmpty {
      emptyState
    } else {
      VStack(spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          WelcomeFilterField(prompt: "Filter recents", text: $filter)
          CapsuleTabPicker(
            selection: $tab, tabs: [.workspaces, .connections], height: 30
          ) { item in
            CapsuleTabLabel(text: tabTitle(item), isSelected: tab == item)
          }
          .fitsContent()
          if tab == .connections && !connections.isEmpty {
            Button(action: onExportConnections) {
              Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle(iconOnly: true))
            .help("Export Connections...")
            .accessibilityLabel("Export Connections...")
          }
        }

        // The list scrolls inside its own card, which ends above the bottom edge
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            switch tab {
            case .workspaces: workspaceRows
            case .connections: connectionRows
            }
          }
          .disabled(loadingId != nil)
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.lg)
            .strokeBorder(Color.border, lineWidth: pixelLength)
        )
      }
      // Same inset on all four sides, lined up with the native tab bar's edges
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        // Open on the list that has something in it
        if workspaces.isEmpty { tab = .connections }
      }
    }
  }

  private func tabTitle(_ item: RecentsTab) -> String {
    switch item {
    case .workspaces: "Workspaces (\(workspaces.count))"
    case .connections: "Connections (\(connections.count))"
    }
  }

  @ViewBuilder
  private var workspaceRows: some View {
    let rows = shownWorkspaces
    ForEach(rows, id: \.id) { workspace in
      RecentWorkspaceRow(
        workspace: workspace,
        isLoading: loadingId == workspace.id,
        onSelect: { entry in
          loadingId = entry.id
          onOpenWorkspace(entry)
        },
        onConfigure: { onEditWorkspace(workspace) },
        onRemove: { onRemoveWorkspace(workspace) }
      )
    }
    if rows.isEmpty {
      emptyListText(workspaces.isEmpty ? "No recent workspaces" : noMatchText)
    }
  }

  /// Grouped under section headers; ungrouped connections come last, under "Ungrouped" only
  /// when some connection has a group.
  @ViewBuilder
  private var connectionRows: some View {
    let rows = shownConnections
    let groups = ConnectionAppearance.grouped(rows)
    let showsHeaders = groups.contains { $0.name != nil }
    ForEach(groups, id: \.name) { group in
      if showsHeaders {
        groupHeader(group.name ?? "Ungrouped")
      }
      ForEach(group.entries, id: \.id) { connection in
        RecentConnectionRow(
          connection: connection,
          isLoading: loadingId == connection.id,
          onSelect: { entry in
            loadingId = entry.id
            onOpenConnection(entry)
          },
          onConfigure: { onEditConnection(connection) },
          onRemove: { onRemoveConnection(connection) }
        )
      }
    }
    if rows.isEmpty {
      emptyListText(connections.isEmpty ? "No recent connections" : noMatchText)
    }
  }

  private var noMatchText: String { "Nothing matches \"\(query)\"" }

  private func groupHeader(_ name: String) -> some View {
    Text(name)
      .font(.caption.weight(.semibold))
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.sm)
      .padding(.top, Spacing.sm)
      .padding(.bottom, Spacing.xxs)
      .accessibilityAddTraits(.isHeader)
  }

  private func emptyListText(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundColor(.foregroundMuted)
      .padding(.horizontal, Spacing.sm)
      .padding(.top, Spacing.sm)
  }

  /// First run: a welcome and the two ways to start, instead of an empty filter and tabs
  private var emptyState: some View {
    VStack(spacing: Spacing.md) {
      Text("Welcome to Dblore")
        .font(.title2.weight(.semibold))
        .foregroundColor(.foreground)
      Text(
        "Connect to a database to start querying, or create a workspace to keep your notebooks, SQL files and notes together."
      )
      .font(.callout)
      .foregroundColor(.foregroundMuted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 380)

      HStack(spacing: Spacing.sm) {
        Button(action: onNewWorkspace) {
          Label("New Workspace", systemImage: "folder.badge.plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        Button(action: onConnect) {
          Label("Connect to Database", systemImage: "server.rack")
        }
        .buttonStyle(PrimaryButtonStyle())
      }
      .padding(.top, Spacing.sm)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Recent Workspace Row

/// One line: name, connection string, then tab count and relative time.
struct RecentWorkspaceRow: View {
  let workspace: WorkspaceHistoryEntry
  let isLoading: Bool
  let onSelect: (WorkspaceHistoryEntry) -> Void
  let onConfigure: () -> Void
  let onRemove: () -> Void

  @State private var isHovering = false
  @State private var isHoveringReveal = false
  @State private var isHoveringConfigure = false
  @State private var isHoveringRemove = false

  var body: some View {
    Button {
      onSelect(workspace)
    } label: {
      RecentRowLayout(isHovering: isHovering) {
        if isLoading {
          ProgressView().controlSize(.small)
        } else {
          // Plain folder; the connection engine badges its bottom-right corner through a cutout
          Image(systemName: "folder")
            .font(.system(size: 14))
            .foregroundColor(.foreground)
            .mask {
              Rectangle()
                .overlay(alignment: .bottomTrailing) {
                  if workspace.databaseType != nil {
                    Circle()
                      .frame(width: 14, height: 14)
                      .offset(x: 4, y: 4)
                      .blendMode(.destinationOut)
                  }
                }
                .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
              if let type = workspace.databaseType {
                Image(type.iconAssetName)
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .frame(width: 12, height: 12)
                  .foregroundColor(type.brandColor)
                  .offset(x: 3, y: 3)
              }
            }
        }
      } title: {
        Text(workspace.name)
      } detail: {
        if let connection = workspace.connectionDisplayString, !connection.isEmpty {
          Text(connection)
        }
      } trailing: {
        RecentTrailingSlot(
          isShown: showsRecentActions,
          isHoveringReveal: $isHoveringReveal,
          isHoveringConfigure: $isHoveringConfigure,
          isHoveringRemove: $isHoveringRemove,
          configureHelp: "Edit workspace",
          onReveal: { NSWorkspace.shared.activateFileViewerSelecting([workspace.fileURL]) },
          onConfigure: onConfigure,
          onRemove: onRemove
        ) {
          HStack(spacing: Spacing.xs) {
            if workspace.tabCount > 0 {
              Text("\(workspace.tabCount)")
                .font(.caption.weight(.bold))
                .foregroundColor(.foreground)
                .help("Number of tabs open in this workspace")
              RecentMetaDot()
            }
            Text(workspace.formattedLastOpened)
              .help("Last opened date")
          }
        }
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .animation(.easeOut(duration: 0.12), value: isHoveringReveal)
    .animation(.easeOut(duration: 0.12), value: isHoveringConfigure)
    .animation(.easeOut(duration: 0.12), value: isHoveringRemove)
  }

  private var showsRecentActions: Bool {
    (isHovering || isHoveringReveal || isHoveringConfigure || isHoveringRemove) && !isLoading
  }
}

// MARK: - Recent Connection Row

/// One line: name, connection string, then last-used date.
struct RecentConnectionRow: View {
  let connection: ConnectionHistoryEntry
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
      RecentRowLayout(isHovering: isHovering) {
        if isLoading {
          ProgressView().controlSize(.small)
        } else {
          Image(connection.config.databaseType.iconAssetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 17, height: 17)
            .foregroundColor(connection.config.databaseType.brandColor)
        }
      } title: {
        HStack(spacing: Spacing.xs) {
          // Apart from the engine badge in the icon slot
          if let color = connection.config.colorTag {
            Circle()
              .fill(color.tagColor)
              .frame(width: 7, height: 7)
              .help(color.rawValue)
              .accessibilityLabel("Color \(color.rawValue)")
          }
          Text(connection.shortDisplayName)
        }
      } detail: {
        Text(connection.config.displayString)
      } trailing: {
        RecentTrailingSlot(
          isShown: showsRecentActions,
          isHoveringConfigure: $isHoveringConfigure,
          isHoveringRemove: $isHoveringRemove,
          configureHelp: "Edit connection",
          onConfigure: onConfigure,
          onRemove: onRemove
        ) {
          Text(connection.formattedLastUsedDate)
            .help("Last used date")
        }
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .animation(.easeOut(duration: 0.12), value: isHoveringConfigure)
    .animation(.easeOut(duration: 0.12), value: isHoveringRemove)
  }

  private var showsRecentActions: Bool {
    (isHovering || isHoveringConfigure || isHoveringRemove) && !isLoading
  }
}

// MARK: - Recent Hover Buttons

private enum RecentHoverMetrics {
  static let diameter: CGFloat = 16

  /// Minimum width of the trailing slot so the buttons never cover the detail text.
  static func slotWidth(buttonCount: Int) -> CGFloat {
    diameter * CGFloat(buttonCount) + Spacing.xs * CGFloat(buttonCount - 1)
  }
}

/// Hover-only control on a recent row. The remove mark is drawn, not an SF Symbol:
/// `xmark`'s alignment rect sits off the circle's center.
private struct RecentHoverButton: View {
  enum Mark {
    case reveal
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
    case .reveal:
      Image(systemName: "folder")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(color)
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

/// Meta on the trailing edge of a row; reveal (optional), config and remove take its place on hover.
private struct RecentTrailingSlot<Meta: View>: View {
  let isShown: Bool
  var isHoveringReveal: Binding<Bool> = .constant(false)
  @Binding var isHoveringConfigure: Bool
  @Binding var isHoveringRemove: Bool
  let configureHelp: String
  var onReveal: (() -> Void)? = nil
  let onConfigure: () -> Void
  let onRemove: () -> Void
  @ViewBuilder let meta: Meta

  var body: some View {
    meta
      .fixedSize()
      .frame(
        minWidth: RecentHoverMetrics.slotWidth(buttonCount: onReveal == nil ? 2 : 3),
        alignment: .trailing
      )
      .opacity(isShown ? 0 : 1)
      .overlay(alignment: .trailing) {
        if isShown {
          HStack(spacing: Spacing.xs) {
            if let onReveal {
              RecentHoverButton(
                mark: .reveal,
                help: "Go to location",
                action: onReveal,
                isHovering: isHoveringReveal
              )
            }
            RecentHoverButton(
              mark: .configure,
              help: configureHelp,
              action: onConfigure,
              isHovering: $isHoveringConfigure
            )
            RecentHoverButton(
              mark: .remove,
              help: "Remove from recent",
              action: onRemove,
              isHovering: $isHoveringRemove
            )
          }
          .transition(.opacity)
        }
      }
  }
}

/// Separator between tab count and relative time.
private struct RecentMetaDot: View {
  var body: some View {
    Circle()
      .fill(Color.foregroundSubtle)
      .frame(width: 3, height: 3)
      .accessibilityHidden(true)
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
        databaseType: .postgresql,
        lastOpenedAt: Date().addingTimeInterval(-3600),  // 1 hour ago
        tabCount: 5
      ),
      WorkspaceHistoryEntry(
        fileURL: URL(fileURLWithPath: "/Users/dev/Projects/users-migration.dblore"),
        name: "Users Migration",
        connectionDisplayString: "users@localhost:5432",
        databaseType: .postgresql,
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

// MARK: - Previews

private struct PreviewWelcome: View {
  var workspaces: [WorkspaceHistoryEntry] = []
  var connections: [ConnectionHistoryEntry] = []

  var body: some View {
    HStack(spacing: 0) {
      WelcomeSidebar(onNewWorkspace: {}, onConnect: {}, onImport: {}, onSettings: {})
      Divider()
      WelcomeRecents(
        workspaces: workspaces,
        connections: connections,
        onOpenWorkspace: { _ in },
        onEditWorkspace: { _ in },
        onRemoveWorkspace: { _ in },
        onOpenConnection: { _ in },
        onEditConnection: { _ in },
        onRemoveConnection: { _ in },
        onExportConnections: {},
        onNewWorkspace: {},
        onConnect: {}
      )
    }
    .background(Color.appBackground)
    .frame(width: 800, height: 600)
  }
}

#Preview("Both Workspaces and Connections") {
  PreviewWelcome(
    workspaces: PreviewData.makeWorkspaces(),
    connections: PreviewData.makeConnections()
  )
}

#Preview("Empty - No Recent Items") {
  PreviewWelcome()
}

#Preview("Only Workspaces") {
  PreviewWelcome(workspaces: PreviewData.makeWorkspaces())
}

#Preview("Only Connections") {
  PreviewWelcome(connections: PreviewData.makeConnections())
}
