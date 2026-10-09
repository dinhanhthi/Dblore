//
//  WorkspaceWelcomeView.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Welcome view shown inside a workspace when no tabs are open
struct WorkspaceWelcomeView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @Bindable var recentManager = RecentManager.shared
  @FocusState private var isFocused: Bool

  /// Recent files from RecentManager (observable)
  private var recentFiles: [URL] {
    recentManager.recentDocuments
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

            WorkspaceTitleView(workspaceManager: workspaceManager)
              .padding(.bottom, Spacing.sm)

            // Connection status and Settings
            HStack(spacing: Spacing.md) {
              ConnectionStatusView(workspaceManager: workspaceManager)

              // Settings button
              Button {
                workspaceManager.showSettings()
              } label: {
                Image(systemName: "gearshape")
                  .frame(width: 14, height: 14)
              }
              .buttonStyle(SecondaryButtonStyle(iconOnly: true))
              .controlSize(.small)
              .help("Settings")

              // Save button, only for unsaved workspaces
              if !workspaceManager.workspace.isSaved {
                Button {
                  Task { try? await workspaceManager.saveWorkspace() }
                } label: {
                  Image(systemName: "square.and.arrow.down")
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(SecondaryButtonStyle(iconOnly: true))
                .controlSize(.small)
                .help("Save Workspace")
              }
            }
          }

          // Document type cards, stacked as compact rows (same width as Recent)
          VStack(spacing: Spacing.sm) { documentTypeCards }
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
      // Refresh recent documents list
      recentManager.refreshRecentDocuments()
    }
    // Propagate focused actions for keyboard shortcuts
    .focusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) {
      // No-op: Right sidebar is per-tab, and welcome view has no active tab
    }
  }

  @ViewBuilder
  private var documentTypeCards: some View {
    // Notebook Card
    DocumentTypeCard(
      icon: "doc.text.fill",
      title: "Notebook",
      description: "Interactive queries with multiple cells and inline results",
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

    // Markdown Note Card
    DocumentTypeCard(
      icon: "doc.richtext.fill",
      title: "Markdown Note",
      description: "Plain Markdown notes saved as .md files",
      accentColor: .syntaxString,
      onNew: { workspaceManager.newMarkdownFile() },
      onOpen: { openFile(type: .markdown) }
    )
  }

  private func openFile(type: TabDocumentType) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false

    switch type {
    case .notebook:
      panel.allowedContentTypes = [.dblore]
    case .sqlFile:
      panel.allowedContentTypes = [.sql]
    case .markdown:
      panel.allowedContentTypes = [.markdownText]
    case .dataViewer:
      return  // No file to open
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

// MARK: - Workspace Title

/// Workspace title; click to rename inline (Return/blur commits, Escape cancels)
struct WorkspaceTitleView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var isEditing = false
  @State private var draft = ""
  @FocusState private var isFieldFocused: Bool

  private var displayName: String {
    let workspace = workspaceManager.workspace
    return !workspace.isSaved && workspace.name == "Untitled"
      ? "Untitled Workspace" : workspace.name
  }

  var body: some View {
    Group {
      if isEditing {
        TextField("Workspace name", text: $draft)
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .focused($isFieldFocused)
          .onSubmit(commit)
          .onExitCommand { isEditing = false }
          .onChange(of: isFieldFocused) { _, focused in
            if !focused { commit() }
          }
          .frame(width: 280)
      } else {
        Text(displayName)
          .lineLimit(1)
          .contentShape(Rectangle())
          .onTapGesture {
            draft = displayName
            isEditing = true
            isFieldFocused = true
          }
          .linkPointer()
          .help("Click to rename")
      }
    }
    .font(.title2)
    .fontWeight(.semibold)
    .foregroundColor(.foreground)
  }

  private func commit() {
    guard isEditing else { return }
    isEditing = false
    if draft != displayName {
      workspaceManager.renameWorkspace(to: draft)
    }
  }
}

// MARK: - Connection Status View

struct ConnectionStatusView: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      statusLabel

      if workspaceManager.connectionState == .disconnected {
        Button("Connect") {
          workspaceManager.showConnectionForm()
        }
        .buttonStyle(SecondaryButtonStyle())
        .controlSize(.small)
      }
    }
  }

  private var statusColor: Color {
    switch workspaceManager.connectionState {
    case .connected: return .green
    case .connecting: return .orange
    case .disconnected: return .foregroundSubtle
    case .error: return .red
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    let label = Text(statusText)
      .font(.subheadline)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .truncationMode(.tail)
    if let detail = FooterView.connectionFailureDetail(for: workspaceManager.connectionState) {
      label.help(detail)
    } else {
      label
    }
  }

  private var statusText: String {
    FooterView.connectionStatusText(
      for: workspaceManager.connectionState,
      config: workspaceManager.workspace.connectionConfig)
  }
}

// MARK: - Recent Files Section

struct WorkspaceRecentFilesSection: View {
  let recentFiles: [URL]
  @Bindable var workspaceManager: WorkspaceManager

  /// Track which file is currently being loaded
  @State private var loadingFileURL: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Recent")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.foregroundMuted)
        .padding(.horizontal, Spacing.xs)

      VStack(spacing: 0) {
        ForEach(recentFiles.prefix(10), id: \.self) { url in
          WorkspaceRecentFileRow(
            url: url,
            isLoading: loadingFileURL == url
          ) {
            loadingFileURL = url
            Task {
              try? await workspaceManager.openFile(url: url)
            }
          }
          .disabled(loadingFileURL != nil)
        }
      }
    }
    .frame(width: 460)
  }
}

// MARK: - Recent File Row

struct WorkspaceRecentFileRow: View {
  let url: URL
  let isLoading: Bool
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
    case .markdown: return .syntaxString
    case .dataViewer: return .foregroundMuted
    case nil: return .foregroundMuted
    }
  }

  var body: some View {
    Button {
      onOpen()
    } label: {
      HStack(spacing: Spacing.sm) {
        // File icon or loading indicator
        if isLoading {
          ProgressView()
            .controlSize(.mini)
            .frame(width: 16)
        } else {
          Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(iconColor)
            .frame(width: 16)
        }

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
    .linkPointer()
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
