//
//  WorkspaceEmptyStateView.swift
//  Dblore
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Content area of a workspace with no tab open: the app icon, a hint to open a table from the
/// left sidebar, and the new/open file actions.
struct WorkspaceEmptyStateView: View {
  @Bindable var workspaceManager: WorkspaceManager
  @FocusState private var isFocused: Bool

  private var hint: String {
    guard workspaceManager.connectionState.isConnected else {
      return "Connect to a database to browse its tables"
    }
    return
      "Open a \(workspaceManager.isMongoWorkspace ? "collection" : "table") from the sidebar to view its data"
  }

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 64, height: 64)

      VStack(spacing: Spacing.xs) {
        Text(hint)
          .font(.headline)
          .foregroundColor(.foreground)
        Text(
          "Or create a notebook, \(workspaceManager.isMongoWorkspace ? "query" : "SQL file") or note"
        )
        .font(.callout)
        .foregroundColor(.foregroundMuted)
      }
      .multilineTextAlignment(.center)

      VStack(spacing: Spacing.sm) {
        WelcomeActionButton(title: "New Notebook", systemImage: "doc.text") {
          workspaceManager.newNotebook()
        }
        WelcomeActionButton(title: workspaceManager.newScriptLabel, systemImage: "doc") {
          workspaceManager.newSQLFile()
        }
        WelcomeActionButton(title: "New Markdown Note", systemImage: "doc.richtext") {
          workspaceManager.newMarkdownFile()
        }
        WelcomeActionButton(
          title: "Open File...", systemImage: "folder",
          help:
            "Open a notebook, \(workspaceManager.isMongoWorkspace ? "query" : "SQL file") or Markdown note",
          action: openFiles)
      }
      .frame(width: ComponentSize.welcomeSidebarWidth)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
    // Make view focusable for keyboard shortcuts
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    .onAppear {
      isFocused = true
    }
    // Propagate focused actions for keyboard shortcuts
    .bridgedFocusedSceneValue(\.toggleLeftSidebarAction) { [workspaceManager] in
      workspaceManager.toggleLeftSidebar()
    }
    .bridgedFocusedSceneValue(\.toggleRightSidebarAction) {
      // No-op: Right sidebar is per-tab, and no tab is open
    }
  }

  /// One panel for every document type; `openFile(url:)` picks the tab type from the extension.
  private func openFiles() {
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

// MARK: - Preview

#Preview("Empty - Disconnected") {
  WorkspaceEmptyStateView(workspaceManager: .preview(isConnected: false))
    .frame(width: 800, height: 600)
}

#Preview("Empty - Connected") {
  WorkspaceEmptyStateView(workspaceManager: .preview(isConnected: true))
    .frame(width: 800, height: 600)
}
