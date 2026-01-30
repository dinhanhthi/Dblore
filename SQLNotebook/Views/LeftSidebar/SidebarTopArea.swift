//
//  SidebarTopArea.swift
//  SQLNotebook
//

import SwiftUI

/// Top area of the sidebar that aligns with traffic lights
/// Contains action buttons (schema visualizer, expand/collapse, refresh)
/// Note: Sidebar toggle button is rendered in container view at fixed position
struct SidebarTopArea: View {
  let viewModel: NotebookViewModel
  let height: CGFloat

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      // Left area: space for traffic light buttons + sidebar toggle button
      // The sidebar toggle button is rendered in container view at fixed position
      Color.clear
        .frame(width: ComponentSize.trafficLightAndToggleWidth)

      Spacer()

      // Action buttons (right side)
      HStack(spacing: Spacing.sm) {
        // Schema Visualizer button (only when connected and not loading)
        if viewModel.connectionState.isConnected && !viewModel.isLoadingSchema {
          Button {
            viewModel.toggleSchemaVisualizer()
          } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.accent)
          }
          .buttonStyle(SidebarHeaderButtonStyle(isActive: viewModel.isSchemaVisualizerActive))
          .blockDoubleClickZoom()
          .help(
            viewModel.isSchemaVisualizerActive
              ? "Close Schema Visualizer" : "Visualize Schema Relationships")

          // Expand/Collapse all button
          Button {
            viewModel.toggleExpandCollapseAll()
          } label: {
            Image(
              systemName: viewModel.areAllEntitiesExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .blockDoubleClickZoom()
          .help(viewModel.areAllEntitiesExpanded ? "Collapse all" : "Expand all")
        }

        // Refresh button (only when connected)
        if viewModel.connectionState.isConnected {
          Button {
            Task { @MainActor [viewModel] in
              await viewModel.refreshDatabaseSchema()
            }
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .blockDoubleClickZoom()
          .disabled(viewModel.isLoadingSchema)
          .help("Refresh schema")
        }
      }
      .padding(.trailing, Spacing.sm)
    }
    .frame(height: height)
    .background(Color.cardBackground)
    .background(WindowDragArea())
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

/// Top area of the sidebar for workspace-level controls
/// Used when connected but no document is open
struct WorkspaceSidebarTopArea: View {
  @Bindable var workspaceManager: WorkspaceManager
  let height: CGFloat

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      Color.clear
        .frame(width: ComponentSize.trafficLightAndToggleWidth)

      Spacer()

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
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
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
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .blockDoubleClickZoom()
          .disabled(workspaceManager.isLoadingSchema)
          .help("Refresh schema")
        }
      }
      .padding(.trailing, Spacing.sm)
    }
    .frame(height: height)
    .background(Color.cardBackground)
    .background(WindowDragArea())
    .overlay(alignment: .bottom) {
      Divider()
    }
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
          .buttonStyle(.bordered)
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
    .background(Color.cardBackground)
  }
}
