//
//  WorkspaceWelcomeView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Welcome view shown inside a workspace when no tabs are open
struct WorkspaceWelcomeView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @FocusState private var isFocused: Bool

  /// Recent files filtered to only .sqlnb and .sql
  private var recentFiles: [URL] {
    NSDocumentController.shared.recentDocumentURLs.filter { url in
      let ext = url.pathExtension.lowercased()
      return ext == "sqlnb" || ext == "sql"
    }
  }

  /// Display name for workspace - shows "Untitled Workspace" if not saved
  private var workspaceDisplayName: String {
    if workspaceManager.workspace.isSaved {
      return "Welcome to workspace \"\(workspaceManager.workspace.name)\""
    } else {
      return "Untitled Workspace"
    }
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: Spacing.lg) {
          // Workspace info
          VStack(spacing: Spacing.xs) {
            Image(nsImage: NSApp.applicationIconImage)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 56, height: 56)

            Text(workspaceDisplayName)
              .font(.title2)
              .fontWeight(.semibold)
              .foregroundColor(.foreground)

            // Connection status and Settings
            HStack(spacing: Spacing.md) {
              ConnectionStatusView(workspaceManager: workspaceManager)

              // Settings button
              Button {
                workspaceManager.showSettings()
              } label: {
                HStack(spacing: Spacing.xs) {
                  Image(systemName: "gearshape")
                    .font(.system(size: 12))
                  Text("Settings")
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }

          // Document type cards
          HStack(spacing: Spacing.lg) {
            // Notebook Card
            DocumentTypeCard(
              icon: "doc.text.fill",
              title: "Notebook",
              description: "Interactive SQL with multiple cells and inline results",
              accentColor: .accent,
              onNew: { workspaceManager.newNotebook() },
              onOpen: { openFile(type: .notebook) }
            )

            // SQL File Card
            DocumentTypeCard(
              icon: "doc.fill",
              title: "SQL File",
              description: "Simple SQL script editor for queries",
              accentColor: .syntaxFunction,
              onNew: { workspaceManager.newSQLFile() },
              onOpen: { openFile(type: .sqlFile) }
            )
          }
          .padding(.top, Spacing.sm)

          // Recent Files Section
          if !recentFiles.isEmpty {
            WorkspaceRecentFilesSection(
              recentFiles: recentFiles,
              workspaceManager: workspaceManager
            )
            .padding(.top, Spacing.lg)
          }
        }
        .padding(.vertical, Spacing.xl)
        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    // Make view focusable for keyboard shortcuts
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    .onAppear {
      // Request focus when view appears
      isFocused = true
    }
    // Propagate focused actions for keyboard shortcuts
    .focusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) {
      // No-op: Right sidebar is per-tab, and welcome view has no active tab
    }
  }

  private func openFile(type: TabDocumentType) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    switch type {
    case .notebook:
      panel.allowedContentTypes = [.sqlNotebook]
    case .sqlFile:
      panel.allowedContentTypes = [.sql]
    }

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

// MARK: - Connection Status View

struct ConnectionStatusView: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      Text(statusText)
        .font(.subheadline)
        .foregroundColor(.foregroundMuted)

      if workspaceManager.connectionState == .disconnected {
        Button("Connect") {
          workspaceManager.showConnectionForm()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
    .padding(.top, Spacing.xs)
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
      // Use connection name if available, otherwise fall back to displayString
      if let config = workspaceManager.workspace.connectionConfig {
        return config.name.isEmpty ? config.displayString : config.name
      }
      return "Connected"
    case .connecting:
      return "Connecting..."
    case .disconnected:
      return "Not connected"
    case .error(let message):
      return "Error: \(message)"
    }
  }
}

// MARK: - Recent Files Section

struct WorkspaceRecentFilesSection: View {
  let recentFiles: [URL]
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Recent")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.xs)

      VStack(spacing: 0) {
        ForEach(recentFiles.prefix(10), id: \.self) { url in
          WorkspaceRecentFileRow(url: url) {
            Task {
              try? await workspaceManager.openFile(url: url)
            }
          }
        }
      }
    }
    .frame(width: 460)
  }
}

// MARK: - Recent File Row

struct WorkspaceRecentFileRow: View {
  let url: URL
  let onOpen: () -> Void

  @State private var isHovering = false

  private var fileType: TabDocumentType? {
    TabDocumentType.from(url: url)
  }

  private var icon: String {
    fileType?.icon ?? "doc"
  }

  private var iconColor: Color {
    switch fileType {
    case .notebook: return .accent
    case .sqlFile: return .syntaxFunction
    case nil: return .foregroundMuted
    }
  }

  var body: some View {
    Button {
      onOpen()
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 12))
          .foregroundColor(iconColor)
          .frame(width: 16)

        Text(url.lastPathComponent)
          .font(.callout)
          .foregroundColor(.foreground)
          .lineLimit(1)

        Text(url.deletingLastPathComponent().path)
          .font(.caption)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer()
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(isHovering ? Color.cellBackgroundHover : Color.clear)
      .cornerRadius(CornerRadius.sm)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

// MARK: - Preview

#Preview("Welcome - Disconnected") {
  WorkspaceWelcomeView(workspaceManager: .preview(isConnected: false))
    .frame(width: 800, height: 600)
}

#Preview("Welcome - Connected") {
  WorkspaceWelcomeView(workspaceManager: .preview(isConnected: true))
    .frame(width: 800, height: 600)
}
