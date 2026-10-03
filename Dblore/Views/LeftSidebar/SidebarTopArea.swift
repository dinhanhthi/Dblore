//
//  SidebarTopArea.swift
//  Dblore
//

import SwiftUI

// Note: Legacy SidebarTopArea struct (NotebookViewModel-based) has been removed
// Use WorkspaceSidebarTopArea for workspace-level controls

/// Top area of the sidebar for workspace-level controls
/// Used when connected but no document is open
struct WorkspaceSidebarTopArea: View {
  @Bindable var workspaceManager: WorkspaceManager
  let height: CGFloat
  @Environment(\.isNativeTabBarVisible) private var isNativeTabBarVisible

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      Color.clear
        .frame(
          width: ComponentSize.trafficLightAndToggleWidth
            - (isNativeTabBarVisible ? ComponentSize.trafficLightWidth : 0))

      Spacer()

      if workspaceManager.isSchemaPaused {
        Label("Schema is paused until Commit/Rollback", systemImage: "pause.circle")
          .font(.caption2)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(
            "Schema is paused until Commit/Rollback: the browser and autocomplete use cached metadata"
          )
          .padding(.trailing, Spacing.xs)
      }

      HStack(spacing: Spacing.sm) {
        if workspaceManager.connectionState.isConnected && !workspaceManager.isLoadingSchema {
          // Expand/Collapse all button
          Button {
            workspaceManager.toggleExpandCollapseAll()
          } label: {
            Image(
              systemName: workspaceManager.areAllEntitiesExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .controlSize(.small)
          .blockDoubleClickZoom()
          .help(workspaceManager.areAllEntitiesExpanded ? "Collapse all" : "Expand all")
        }

        // Refresh button
        if workspaceManager.connectionState.isConnected {
          Button {
            Task {
              await workspaceManager.refreshDatabaseSchema()
            }
          } label: {
            Image(systemName: "arrow.clockwise")
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .controlSize(.small)
          .blockDoubleClickZoom()
          .disabled(workspaceManager.isLoadingSchema || workspaceManager.isSchemaPaused)
          .help(
            workspaceManager.isSchemaPaused
              ? "Schema is paused until Commit/Rollback" : "Refresh schema")
        }
      }
      .padding(.trailing, Spacing.sm)
    }
    .frame(height: height)
    .background(WindowDragArea())
  }
}

/// Empty sidebar view when no tab is active or not connected
struct SidebarEmptyState: View {
  let isConnected: Bool
  let onConnect: (() -> Void)?

  var body: some View {
    VStack(spacing: Spacing.md) {
      if !isConnected {
        Image(systemName: "server.rack")
          .font(.largeTitle)
          .foregroundColor(.foregroundSubtle)

        Text("Not Connected")
          .font(.headline)
          .foregroundColor(.foregroundMuted)

        if let onConnect = onConnect {
          Button("Connect") {
            onConnect()
          }
          .buttonStyle(FilledSecondaryButtonStyle())
        }
      } else {
        Image(systemName: "doc.text")
          .font(.largeTitle)
          .foregroundColor(.foregroundSubtle)

        Text("No document open")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
