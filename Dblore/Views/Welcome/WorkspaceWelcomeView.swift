//
//  WorkspaceWelcomeView.swift
//  Dblore
//

import AppKit
import SwiftUI

/// Welcome view shown inside a workspace when no tabs are open.
/// Left column: workspace name, connection and the new/open actions. Right: recent files.
struct WorkspaceWelcomeView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @Bindable var recentManager = RecentManager.shared
  @FocusState private var isFocused: Bool
  @Environment(\.pixelLength) private var pixelLength

  /// Recent files from RecentManager (observable)
  private var recentFiles: [URL] {
    recentManager.recentDocuments
  }

  var body: some View {
    HStack(spacing: 0) {
      WelcomeSidebarColumn {
        VStack(spacing: Spacing.sm) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: 56)

          WorkspaceTitleView(workspaceManager: workspaceManager)

          ConnectionStatusView(workspaceManager: workspaceManager)
        }
      } actions: {
        WelcomeActionButton(title: "New Notebook", systemImage: "doc.text") {
          workspaceManager.newNotebook()
        }
        WelcomeActionButton(title: "New SQL File", systemImage: "doc") {
          workspaceManager.newSQLFile()
        }
        WelcomeActionButton(title: "New Markdown Note", systemImage: "doc.richtext") {
          workspaceManager.newMarkdownFile()
        }
        WelcomeActionButton(
          title: "Open File...", systemImage: "folder",
          help: "Open a notebook, SQL file or Markdown note", action: openFiles)
      } footer: {
        // Save, only for unsaved workspaces (Settings is in the title bar)
        if !workspaceManager.workspace.isSaved {
          WelcomeSidebarItem(title: "Save Workspace", systemImage: "square.and.arrow.down") {
            Task { try? await workspaceManager.saveWorkspace() }
          }
        }
      }

      Rectangle()
        .fill(Color.border)
        .frame(width: pixelLength)

      WorkspaceRecentFiles(recentFiles: recentFiles, workspaceManager: workspaceManager)
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

  /// One panel for every document type; `openFile(url:)` picks the tab type from the extension.
  private func openFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.dblore, .sql, .markdownText]

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
          .frame(maxWidth: .infinity)
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
    .font(.title3)
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

// MARK: - Recent Files

/// Filter field above a compact list of recent files.
struct WorkspaceRecentFiles: View {
  let recentFiles: [URL]
  @Bindable var workspaceManager: WorkspaceManager

  @State private var filter = ""
  /// Track which file is currently being loaded
  @State private var loadingFileURL: URL?
  private let collapsedCount = 10
  /// Keeps rows readable on wide windows
  private let contentMaxWidth: CGFloat = 680

  private var query: String { filter.trimmingCharacters(in: .whitespaces) }

  private var shownFiles: [URL] {
    guard !query.isEmpty else { return Array(recentFiles.prefix(collapsedCount)) }
    return recentFiles.filter { $0.path.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    if recentFiles.isEmpty {
      emptyState
    } else {
      VStack(spacing: 0) {
        WelcomeFilterField(prompt: "Filter recent files", text: $filter)
          .frame(maxWidth: contentMaxWidth)
          .padding(.horizontal, Spacing.xl)
          .padding(.vertical, Spacing.md)

        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            let shownFiles = shownFiles
            WelcomeSectionHeader(title: "Recent Files", count: recentFiles.count)

            ForEach(shownFiles, id: \.self) { url in
              WorkspaceRecentFileRow(url: url, isLoading: loadingFileURL == url) {
                loadingFileURL = url
                Task {
                  try? await workspaceManager.openFile(url: url)
                }
              }
            }

            if shownFiles.isEmpty {
              Text("No recent files match \"\(query)\"")
                .font(.callout)
                .foregroundColor(.foregroundMuted)
                .padding(.horizontal, Spacing.sm)
            }
          }
          .disabled(loadingFileURL != nil)
          .frame(maxWidth: contentMaxWidth, alignment: .leading)
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.xl)
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "doc.on.doc")
        .font(.system(size: 28))
        .foregroundColor(.foregroundSubtle)
      Text("No recent files")
        .font(.headline)
        .foregroundColor(.foreground)
      Text("Create a notebook, SQL file or note to get started")
        .font(.callout)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Recent File Row

/// One line: file name, then its folder.
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
      RecentRowLayout(isHovering: isHovering) {
        if isLoading {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundColor(iconColor)
        }
      } title: {
        Text(url.lastPathComponent)
      } detail: {
        Text(url.deletingLastPathComponent().path)
          .truncationMode(.middle)
          .help(url.path)
      } trailing: {
        EmptyView()
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovering)
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
